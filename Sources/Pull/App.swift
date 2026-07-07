import SwiftUI
import AppKit

@main
struct PullApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 680, minHeight: 620)
                .background(Color(hex: 0x0B0B0C))
                .preferredColorScheme(.dark)
                .onAppear { state.adoptClipboardIfURL() }
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.didBecomeActiveNotification)) { _ in
                    state.adoptClipboardIfURL()
                }
                .onDrop(of: [.url, .text], isTargeted: nil) { providers in
                    _ = providers.first?.loadObject(ofClass: NSString.self) { s, _ in
                        if let str = (s as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                           str.hasPrefix("http") {
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
        outputDir = d.string(forKey: "pull.outputDir").map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        useBrowserCookies = d.bool(forKey: "pull.cookies")
        soundOnDone = d.object(forKey: "pull.sound") as? Bool ?? true

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pull", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        historyFile = support.appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: historyFile),
           let items = try? JSONDecoder().decode([HistoryItem].self, from: data) {
            history = items
        }
    }

    // ── Clipboard / input ──────────────────────────────────────
    func adoptClipboardIfURL() {
        guard !probing,
              let s = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              s.hasPrefix("http"), s.count < 500, s != lastClipboard, s != urlText,
              s != info?.url, s != playlist?.url else { return }
        lastClipboard = s
        urlText = s
        probe()
    }

    var clipboardURL: String? {
        guard let s = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              s.hasPrefix("http"), s.count < 500 else { return nil }
        return s
    }

    func probe() {
        let url = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, !probing else { return }
        probing = true
        errorText = nil
        info = nil
        playlist = nil
        Task {
            do {
                switch try await Engine.probeAny(url: url) {
                case .single(let result):
                    self.info = result
                    self.selectedVideo = result.videoOptions.first
                    self.selectedAudio = result.audioOptions.first
                    self.mode = result.videoOptions.isEmpty ? .audio : .video
                case .playlist(let pl):
                    self.playlist = pl
                }
            } catch {
                self.errorText = error.localizedDescription
            }
            self.probing = false
        }
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
        guard let url = clipboardURL else { return }
        enqueue(QueueItem(url: url, title: url, selection: selection))
    }

    private func enqueue(_ item: QueueItem) {
        queue.append(item)
        errorText = nil
        processNext()
    }

    func remove(_ item: QueueItem) {
        queue.removeAll { $0.id == item.id }
    }

    func cancelActive() {
        Engine.cancelActive()
    }

    private func processNext() {
        guard active == nil, !queue.isEmpty else { return }
        let item = queue.removeFirst()
        active = item
        progress = 0
        speedText = nil

        Task {
            do {
                let file = try await Engine.download(
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
                let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? nil
                let title = file.deletingPathExtension().lastPathComponent
                self.history.insert(HistoryItem(
                    title: item.title == item.url ? title : item.title,
                    detail: "\(item.selection.label) · \(Format.size(size))",
                    fileURL: file, failed: false), at: 0)
                if self.soundOnDone { NSSound(named: "Glass")?.play() }
            } catch {
                self.errorText = hint(for: error)
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
        if lower.contains("login") || lower.contains("cookies") || lower.contains("rate-limit")
            || lower.contains("not available") && lower.contains("instagram") {
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
