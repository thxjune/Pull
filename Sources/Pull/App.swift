import SwiftUI
import AppKit

@main
struct PullApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 680, minHeight: 620)
                .background(Color(hex: 0x0B0B0C))
                .preferredColorScheme(.dark)
                .onAppear {
                    // Hidden title bar: let the whole background drag the window.
                    NSApp.windows.forEach { $0.isMovableByWindowBackground = true }
                    state.adoptClipboardIfURL()
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.didBecomeActiveNotification)) { _ in
                    state.refreshTools()
                    state.adoptClipboardIfURL()
                }
                .onDrop(of: [.url, .text], isTargeted: $state.dropTargeted) { providers in
                    _ = providers.first?.loadObject(ofClass: NSString.self) { s, _ in
                        if let str = (s as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                           AppState.isWebURL(str) {
                            Task { @MainActor in
                                state.urlText = str
                                state.probe()
                            }
                        }
                    }
                    return true
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)

        // Quick-grab from the menu bar: copied link → one click → queued.
        MenuBarExtra {
            MenuBarView().environmentObject(state)
        } label: {
            Image(systemName: state.isWorking ? "arrow.down.circle.fill" : "arrow.down.circle")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppState: ObservableObject {
    enum Mode: String, CaseIterable { case video = "Video", audio = "Audio" }

    // link + probe
    @Published var urlText = ""
    @Published var probing = false
    @Published var info: MediaInfo?
    @Published var playlist: PlaylistInfo?
    @Published var mode: Mode = .video
    @Published var selectedVideo: VideoOption?
    @Published var selectedAudio: AudioOption?
    @Published var playlistSelection: Selection = .video(maxHeight: 1080)
    @Published var errorText: String?
    @Published var dropTargeted = false
    @Published var toolsReady = Tools.ready
    @Published var clipboardLink: String?   // refreshed on activate / menu open (a computed var wouldn't re-render)

    // queue
    @Published var queue: [QueueItem] = []
    @Published var active: QueueItem?
    @Published var progress: Double = 0
    @Published var speedText: String?
    @Published var history: [HistoryItem] = []
    @Published var outputDir: URL

    // settings
    @Published var useBrowserCookies: Bool {
        didSet { UserDefaults.standard.set(useBrowserCookies, forKey: "pull.cookies") }
    }
    @Published var soundOnDone: Bool {
        didSet { UserDefaults.standard.set(soundOnDone, forKey: "pull.sound") }
    }

    var isWorking: Bool { active != nil }

    private var lastClipboard = ""
    private let historyFile: URL

    init() {
        let d = UserDefaults.standard
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        // A saved folder that no longer exists (unmounted drive) falls back to Downloads.
        outputDir = d.string(forKey: "pull.outputDir").map { URL(fileURLWithPath: $0) }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? downloads
        useBrowserCookies = d.bool(forKey: "pull.cookies")
        soundOnDone = d.object(forKey: "pull.sound") as? Bool ?? true

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pull", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        historyFile = support.appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: historyFile),
           let items = try? JSONDecoder().decode([HistoryItem].self, from: data) {
            // Never open anything from history that isn't a local file.
            history = items.filter { $0.fileURL == nil || $0.fileURL!.isFileURL }
        }
        Engine.cleanupTempDirs(in: outputDir)
    }

    func refreshTools() {
        toolsReady = Tools.ready
        clipboardLink = clipboardURL
        // Output folder vanished (external drive unplugged): fall back rather
        // than letting yt-dlp mkdir a ghost /Volumes/<name> on the boot disk.
        if !FileManager.default.fileExists(atPath: outputDir.path) {
            outputDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            UserDefaults.standard.removeObject(forKey: "pull.outputDir")
        }
    }

    // Only http(s) links ever reach yt-dlp — no file://, no option-shaped text.
    nonisolated static func isWebURL(_ s: String) -> Bool {
        let lower = s.lowercased()
        return (lower.hasPrefix("http://") || lower.hasPrefix("https://")) && s.count < 2048
            && !s.contains(where: { $0.isWhitespace })
    }

    // ── Clipboard / input ──────────────────────────────────────
    func adoptClipboardIfURL() {
        // Don't yank a card the user is looking at just because they copied
        // some unrelated link while away.
        guard !probing, info == nil, playlist == nil,
              let s = clipboardURL,
              s != lastClipboard, s != urlText else { return }
        lastClipboard = s
        urlText = s
        probe()
    }

    var clipboardURL: String? {
        guard let s = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              AppState.isWebURL(s) else { return nil }
        return s
    }

    func pasteAndProbe() {
        guard let s = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return }
        urlText = s
        probe()
    }

    func clearLink() {
        if probing { Engine.cancelProbe() }
        urlText = ""
        info = nil
        playlist = nil
        errorText = nil
    }

    func probe() {
        let url = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, !probing else { return }
        guard AppState.isWebURL(url) else {
            errorText = "That doesn't look like a web link. Paste an http(s) URL."
            return
        }
        refreshTools()
        guard toolsReady else { return }   // the tools-missing card is already on screen
        probing = true
        errorText = nil
        info = nil
        playlist = nil
        lastClipboard = url   // whatever path it came in by, don't auto-fetch it again later
        let cookies = useBrowserCookies
        Task {
            do {
                let result = try await Engine.probeAny(url: url, useBrowserCookies: cookies)
                // The field changed (or was cleared) while yt-dlp was thinking:
                // this result is for the wrong link — drop it and re-probe.
                guard self.urlText.trimmingCharacters(in: .whitespacesAndNewlines) == url else {
                    self.probing = false
                    if !self.urlText.isEmpty { self.probe() }
                    return
                }
                switch result {
                case .single(let result):
                    self.info = result
                    self.selectedVideo = result.videoOptions.first
                    self.selectedAudio = result.audioOptions.first
                    self.mode = result.videoOptions.isEmpty ? .audio : .video
                case .playlist(let pl):
                    self.playlist = pl
                }
            } catch {
                self.probing = false
                let now = self.urlText.trimmingCharacters(in: .whitespacesAndNewlines)
                if now == url {
                    // A probe the user cancelled with ✕ isn't an error worth showing.
                    if case EngineError.cancelled = error {} else { self.errorText = hint(for: error) }
                } else if !now.isEmpty {
                    self.probe()   // field changed mid-probe: go read the new link
                }
                return
            }
            self.probing = false
        }
    }

    // True when the link in the field is the one the current card describes —
    // i.e. Return should download, not re-fetch.
    var fieldMatchesCard: Bool {
        let t = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        return t == info?.url || t == playlist?.url
    }

    // Return in the URL field: one deterministic route (SwiftUI's default-
    // action button doesn't reliably fire while a text field has focus).
    func submit() {
        guard fieldMatchesCard else { probe(); return }
        if info != nil { enqueueCurrent() } else if playlist != nil { enqueuePlaylist() }
    }

    // ── Queue ──────────────────────────────────────────────────
    func enqueueCurrent() {
        guard let info else { return }
        let selection: Selection
        switch mode {
        case .video:
            guard let v = selectedVideo else { return }
            selection = .video(maxHeight: v.height)
        case .audio:
            guard let a = selectedAudio else { return }
            selection = a.kind == .original ? .audioOriginal : .audioMP3
        }
        enqueue(QueueItem(url: info.url, title: info.title, selection: selection))
        self.info = nil
        self.urlText = ""
    }

    func enqueuePlaylist() {
        guard let playlist else { return }
        for entry in playlist.entries {
            enqueue(QueueItem(url: entry.url, title: entry.title, selection: playlistSelection))
        }
        self.playlist = nil
        self.urlText = ""
    }

    func enqueueClipboard(_ selection: Selection) {
        guard let url = clipboardLink, !isQueued(url) else { return }
        enqueue(QueueItem(url: url, title: url, selection: selection))
    }

    func isQueued(_ url: String) -> Bool {
        active?.url == url || queue.contains { $0.url == url }
    }

    private func enqueue(_ item: QueueItem) {
        queue.append(item)
        errorText = nil
        lastClipboard = item.url
        processNext()
    }

    func remove(_ item: QueueItem) {
        queue.removeAll { $0.id == item.id }
    }

    func cancelActive() {
        Engine.cancelActive()
    }

    func quit() {
        // Otherwise yt-dlp keeps running headless and a file appears later
        // with no history entry.
        Engine.cancelProbe()
        Engine.cancelActive()
        NSApplication.shared.terminate(nil)
    }

    private func processNext() {
        guard active == nil, !queue.isEmpty else { return }
        refreshTools()
        let item = queue.removeFirst()
        active = item
        progress = 0
        speedText = nil

        Task {
            do {
                let result = try await Engine.download(
                    url: item.url,
                    selection: item.selection,
                    outputDir: outputDir,
                    useBrowserCookies: useBrowserCookies,
                    progress: { p, rate in
                        Task { @MainActor in
                            self.progress = p
                            self.speedText = rate
                        }
                    }
                )
                let title = result.fileURL.deletingPathExtension().lastPathComponent
                self.history.insert(HistoryItem(
                    title: item.title == item.url ? title : item.title,
                    detail: result.detail,
                    fileURL: result.fileURL, failed: false), at: 0)
                if self.soundOnDone { NSSound(named: "Glass")?.play() }
            } catch EngineError.cancelled {
                // The user asked for this — not an error, not history.
            } catch {
                self.errorText = "\(item.title) — \(hint(for: error))"
                self.history.insert(HistoryItem(
                    title: item.title, detail: item.selection.label, fileURL: nil, failed: true), at: 0)
            }
            self.persistHistory()
            self.active = nil
            self.progress = 0
            self.speedText = nil
            self.processNext()
        }
    }

    // Make common failures actionable.
    private func hint(for error: Error) -> String {
        let msg = error.localizedDescription
        let lower = msg.lowercased()
        let loginGated = lower.contains("login") || lower.contains("cookies") || lower.contains("rate-limit")
            || lower.contains("sign in") || (lower.contains("not available") && lower.contains("instagram"))
        if loginGated && !useBrowserCookies {
            return msg + "  Tip: enable “Use browser cookies” in settings (gear icon) for private or login-gated posts."
        }
        return msg
    }

    func chooseOutputDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = outputDir
        panel.prompt = "Save here"
        if panel.runModal() == .OK, let url = panel.url {
            outputDir = url
            UserDefaults.standard.set(url.path, forKey: "pull.outputDir")
        }
    }

    func clearHistory() {
        history.removeAll()
        persistHistory()
    }

    private func persistHistory() {
        let capped = Array(history.prefix(50))
        if let data = try? JSONEncoder().encode(capped) {
            try? data.write(to: historyFile, options: .atomic)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
