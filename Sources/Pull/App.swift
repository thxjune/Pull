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
    }
}

@MainActor
final class AppState: ObservableObject {
    enum Mode: String, CaseIterable { case video = "Video", audio = "Audio" }

    @Published var urlText = ""
    @Published var probing = false
    @Published var info: MediaInfo?
    @Published var mode: Mode = .video
    @Published var selectedVideo: VideoOption?
    @Published var selectedAudio: AudioOption?
    @Published var downloading = false
    @Published var progress: Double = 0
    @Published var errorText: String?
    @Published var history: [HistoryItem] = []
    @Published var outputDir: URL

    private var lastClipboard = ""
    private let historyFile: URL

    init() {
        let saved = UserDefaults.standard.string(forKey: "pull.outputDir")
        outputDir = saved.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pull", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        historyFile = support.appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: historyFile),
           let items = try? JSONDecoder().decode([HistoryItem].self, from: data) {
            history = items
        }
    }

    // Whenever the app comes to the front with a fresh link on the clipboard,
    // grab it and probe it — zero clicks.
    func adoptClipboardIfURL() {
        guard !downloading, !probing,
              let s = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              s.hasPrefix("http"), s.count < 500, s != lastClipboard, s != urlText,
              s != info?.url else { return }
        lastClipboard = s
        urlText = s
        probe()
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

    private func persistHistory() {
        let capped = Array(history.prefix(50))
        if let data = try? JSONEncoder().encode(capped) {
            try? data.write(to: historyFile, options: .atomic)
        }
    }

    func probe() {
        let url = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, !probing else { return }
        probing = true
        errorText = nil
        info = nil
        Task {
            do {
                let result = try await Engine.probe(url: url)
                self.info = result
                self.selectedVideo = result.videoOptions.first
                self.selectedAudio = result.audioOptions.first
                self.mode = result.videoOptions.isEmpty ? .audio : .video
            } catch {
                self.errorText = error.localizedDescription
            }
            self.probing = false
        }
    }

    func download() {
        guard let info, !downloading else { return }
        let video = mode == .video ? selectedVideo : nil
        let audio = mode == .audio ? selectedAudio : nil
        guard video != nil || audio != nil else { return }

        downloading = true
        progress = 0
        errorText = nil
        let detail: String = {
            if let v = video { return "\(v.label) MP4" }
            if let a = audio { return a.kind == .original ? "Original audio" : "MP3" }
            return ""
        }()

        Task {
            do {
                let file = try await Engine.download(
                    info: info, video: video, audio: audio, outputDir: outputDir,
                    progress: { p in Task { @MainActor in self.progress = p } }
                )
                let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? nil
                self.history.insert(HistoryItem(
                    title: info.title,
                    detail: "\(detail) · \(Format.size(size))",
                    fileURL: file, failed: false), at: 0)
                self.persistHistory()
                self.reset()
            } catch {
                self.errorText = error.localizedDescription
                self.history.insert(HistoryItem(
                    title: info.title, detail: detail, fileURL: nil, failed: true), at: 0)
                self.persistHistory()
                self.downloading = false
            }
        }
    }

    private func reset() {
        downloading = false
        progress = 0
        info = nil
        urlText = ""
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
