import SwiftUI
import AppKit

// Monochrome palette — black, white, grays. Nothing else.
enum Mono {
    static let bg = Color(hex: 0x0B0B0C)
    static let card = Color.white.opacity(0.04)
    static let line = Color.white.opacity(0.09)
    static let text = Color(hex: 0xF5F5F7)
    static let dim = Color(hex: 0x9A9AA0)
    // 0x858589 clears WCAG AA (5.3:1 on bg, 4.6:1 on cards); the old 0x6E6E73 didn't.
    static let faint = Color(hex: 0x858589)
}

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var showSettings = false
    @FocusState private var urlFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 18) {
                    if !state.toolsReady { errorCard(EngineError.toolsMissing.localizedDescription) }
                    urlBar
                    if let e = state.errorText { errorCard(e) }
                    if state.probing { probingCard }
                    if let info = state.info { MediaCard(info: info) }
                    if let pl = state.playlist { PlaylistCard(playlist: pl) }
                    if state.active != nil || !state.queue.isEmpty { QueueSection() }
                    if !state.history.isEmpty { HistoryList() }
                    Spacer(minLength: 20)
                }
                .padding(24)
            }
        }
        .background(Mono.bg)
        .defaultFocus($urlFocused, true)
        // After Download/✕ empties the field, put the cursor back so ⌘V just works.
        .onChange(of: state.urlText) { _, new in if new.isEmpty { urlFocused = true } }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("pull.")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Mono.text)
            Spacer()
            Text("YouTube · Instagram · TikTok · X · 1,800+ sites")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Mono.faint)
            Button { showSettings.toggle() } label: {
                Image(systemName: "gearshape")
                    .foregroundStyle(Mono.dim)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(",", modifiers: .command)
            .help("Settings (⌘,)")
            .accessibilityLabel("Settings")
            .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                SettingsPopover()
                    .environmentObject(state)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 38)
        .padding(.bottom, 14)
    }

    private var urlBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "link")
                .foregroundStyle(Mono.faint)
            TextField("paste a link — video or playlist", text: $state.urlText)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(Mono.text)
                .focused($urlFocused)
                // Return: fetch a new link, or download the one already fetched.
                .onSubmit { state.submit() }
                .onExitCommand { state.clearLink() }
            if !state.urlText.isEmpty {
                Button { state.clearLink() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Mono.faint)
                }
                .buttonStyle(.plain)
                .help("Clear (Esc)")
                .accessibilityLabel("Clear link")
            }
            Button { state.pasteAndProbe() } label: {
                Text("Paste")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Mono.dim)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(Color.white.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .disabled(state.probing || !state.toolsReady)
            .opacity(state.probing || !state.toolsReady ? 0.4 : 1)
            Button { state.probe() } label: {
                Text("Fetch")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Capsule().fill(Color.white))
            }
            .buttonStyle(.plain)
            .disabled(state.urlText.isEmpty || state.probing || !state.toolsReady)
            .opacity(state.urlText.isEmpty || state.probing || !state.toolsReady ? 0.4 : 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Mono.card))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(state.dropTargeted ? Color.white.opacity(0.5)
                              : urlFocused ? Color.white.opacity(0.22) : Mono.line)
        )
        .animation(.easeOut(duration: 0.15), value: state.dropTargeted)
    }

    private var probingCard: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Reading link…")
                .font(.system(size: 13))
                .foregroundStyle(Mono.dim)
            Spacer()
            Button { state.clearLink() } label: {
                Text("cancel")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Mono.faint)
                    .underline()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel reading link")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Mono.card))
    }

    private func errorCard(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.system(size: 12.5))
            .foregroundStyle(Mono.dim)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.14)))
    }
}

// ── Settings ────────────────────────────────────────────────────
struct SettingsPopover: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings")
                .font(.system(size: 13, weight: .semibold))
            Toggle(isOn: $state.useBrowserCookies) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use browser cookies (Chrome)")
                        .font(.system(size: 12.5))
                    Text("For Instagram / TikTok posts that need login. macOS will ask for Keychain access the first time — click Allow, not Always Allow.")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Toggle(isOn: $state.soundOnDone) {
                Text("Sound when a download finishes")
                    .font(.system(size: 12.5))
            }
            Divider()
            HStack {
                Text("Saving to: \(state.outputDir.lastPathComponent)")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .help(state.outputDir.path)
                Spacer()
                Button("Change…") { state.chooseOutputDir() }
                    .font(.system(size: 11.5))
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}

// ── The main card: metadata + options + queue button ───────────
struct MediaCard: View {
    @EnvironmentObject var state: AppState
    let info: MediaInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                AsyncImage(url: info.thumbnailURL) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(Color.white.opacity(0.06))
                }
                .frame(width: 148, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 5) {
                    Text(info.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Mono.text)
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        badge(info.platform)
                        if !info.durationLabel.isEmpty { badge(info.durationLabel) }
                        if !info.uploader.isEmpty {
                            Text(info.uploader)
                                .font(.system(size: 12))
                                .foregroundStyle(Mono.faint)
                                .lineLimit(1)
                        }
                    }
                }
                Spacer()
            }
            .padding(16)

            Divider().overlay(Mono.line)

            HStack(spacing: 4) {
                ForEach(AppState.Mode.allCases, id: \.self) { m in
                    let active = state.mode == m
                    let unavailable = m == .video && info.videoOptions.isEmpty
                    Button { withAnimation(.easeOut(duration: 0.15)) { state.mode = m } } label: {
                        Text(m.rawValue)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(active ? .black : Mono.dim)
                            .padding(.horizontal, 16).padding(.vertical, 7)
                            .background(Capsule().fill(active ? Color.white : Color.clear))
                    }
                    .buttonStyle(.plain)
                    .disabled(unavailable)
                    .opacity(unavailable ? 0.35 : 1)
                    .help(unavailable ? "This link has no video stream" : "")
                    .accessibilityAddTraits(active ? .isSelected : [])
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            VStack(spacing: 6) {
                if state.mode == .video {
                    ForEach(info.videoOptions) { v in
                        optionRow(selected: state.selectedVideo == v, title: v.label,
                                  subtitle: v.detail, size: v.sizeLabel) { state.selectedVideo = v }
                    }
                } else {
                    ForEach(info.audioOptions) { a in
                        optionRow(selected: state.selectedAudio == a, title: a.label,
                                  subtitle: a.detail, size: a.sizeLabel) { state.selectedAudio = a }
                    }
                }
            }
            .padding(.horizontal, 16)

            VStack(spacing: 10) {
                Button { state.enqueueCurrent() } label: {
                    Text(state.isWorking ? "Add to queue" : "Download")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
                }
                .buttonStyle(.plain)
                Button { state.chooseOutputDir() } label: {
                    Text("saves to \(state.outputDir.lastPathComponent) — change")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Mono.faint)
                        .underline()
                }
                .buttonStyle(.plain)
                .help(state.outputDir.path)
            }
            .padding(16)
        }
        .background(RoundedRectangle(cornerRadius: 16).fill(Mono.card))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Mono.line))
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .foregroundStyle(Mono.dim)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Color.white.opacity(0.07)))
    }

    private func optionRow(
        selected: Bool, title: String, subtitle: String, size: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Circle()
                    .strokeBorder(selected ? Color.white : Mono.faint, lineWidth: selected ? 5 : 1.5)
                    .frame(width: 16, height: 16)
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Mono.text)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Mono.faint)
                    .lineLimit(1)
                Spacer()
                Text(size)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(selected ? Mono.text : Mono.faint)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(selected ? Color.white.opacity(0.07) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// ── Playlist card ───────────────────────────────────────────────
struct PlaylistCard: View {
    @EnvironmentObject var state: AppState
    let playlist: PlaylistInfo

    private let presets: [(String, Selection)] = [
        ("Best video", .video(maxHeight: 4320)),
        ("1080p", .video(maxHeight: 1080)),
        ("Original audio", .audioOriginal),
        ("MP3", .audioMP3),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "square.stack")
                        .foregroundStyle(Mono.dim)
                    Text(playlist.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Mono.text)
                        .lineLimit(2)
                }
                Text("\(playlist.entries.count) items\(playlist.uploader.isEmpty ? "" : " · \(playlist.uploader)")")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Mono.faint)
            }
            .padding(16)

            Divider().overlay(Mono.line)

            VStack(spacing: 6) {
                ForEach(presets, id: \.0) { name, sel in
                    let selected = state.playlistSelection == sel
                    Button { state.playlistSelection = sel } label: {
                        HStack(spacing: 12) {
                            Circle()
                                .strokeBorder(selected ? Color.white : Mono.faint,
                                              lineWidth: selected ? 5 : 1.5)
                                .frame(width: 16, height: 16)
                            Text(name)
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(Mono.text)
                            Spacer()
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 10)
                            .fill(selected ? Color.white.opacity(0.07) : Color.clear))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            VStack(spacing: 10) {
                Button { state.enqueuePlaylist() } label: {
                    Text("Queue all \(playlist.entries.count)")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
                }
                .buttonStyle(.plain)
                Button { state.chooseOutputDir() } label: {
                    Text("saves to \(state.outputDir.lastPathComponent) — change")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Mono.faint)
                        .underline()
                }
                .buttonStyle(.plain)
                .help(state.outputDir.path)
            }
            .padding(16)
        }
        .background(RoundedRectangle(cornerRadius: 16).fill(Mono.card))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Mono.line))
    }
}

// ── Queue ───────────────────────────────────────────────────────
struct QueueSection: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("QUEUE")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(Mono.faint)
                .padding(.leading, 4)

            if let active = state.active {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(active.title)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Mono.text)
                                .lineLimit(1)
                            Text(active.selection.label)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Mono.faint)
                        }
                        Spacer()
                        Button { state.cancelActive() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Mono.dim)
                                .padding(6)
                                .background(Circle().fill(Color.white.opacity(0.07)))
                        }
                        .buttonStyle(.plain)
                        .help("Cancel this download")
                        .accessibilityLabel("Cancel download")
                    }
                    // 0% = still extracting / merging: show motion, not a dead bar.
                    ProgressView(value: state.progress > 0 && state.progress < 1 ? state.progress : nil)
                        .tint(.white)
                    HStack {
                        Text("\(Int(state.progress * 100))%")
                        Spacer()
                        if let s = state.speedText { Text(s) }
                    }
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Mono.faint)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
            }

            ForEach(state.queue) { item in
                HStack(spacing: 12) {
                    Image(systemName: "clock")
                        .font(.system(size: 11))
                        .foregroundStyle(Mono.faint)
                    Text(item.title)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Mono.dim)
                        .lineLimit(1)
                    Text(item.selection.label)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Mono.faint)
                    Spacer()
                    Button { state.remove(item) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Mono.faint)
                    }
                    .buttonStyle(.plain)
                    .help("Remove from queue")
                    .accessibilityLabel("Remove from queue")
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 10).fill(Mono.card))
            }
        }
    }
}

// ── History ─────────────────────────────────────────────────────
struct HistoryList: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("DONE")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(2)
                    .foregroundStyle(Mono.faint)
                Spacer()
                Button { state.clearHistory() } label: {
                    Text("clear")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Mono.faint)
                        .underline()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear history")
            }
            .padding(.horizontal, 4)

            ForEach(state.history) { item in
                // Only local files that still exist get Finder/open actions.
                let file = item.fileURL.flatMap {
                    $0.isFileURL && FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
                }
                HStack(spacing: 12) {
                    Image(systemName: item.failed ? "xmark.circle" : "checkmark.circle.fill")
                        .foregroundStyle(item.failed ? Mono.faint : Mono.text)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Mono.text)
                            .lineLimit(1)
                        Text(file == nil && !item.failed ? "\(item.detail) · file moved or deleted" : item.detail)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Mono.faint)
                    }
                    Spacer()
                    if let url = file {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } label: {
                            Text("Show in Finder")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Mono.dim)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Capsule().fill(Color.white.opacity(0.07)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Mono.card))
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    if let url = file { NSWorkspace.shared.open(url) }
                }
                .help(file != nil ? "Double-click to open" : "")
                .accessibilityElement(children: .combine)
                .accessibilityAction(named: "Open") { if let url = file { NSWorkspace.shared.open(url) } }
            }
        }
    }
}

// ── Menu bar quick-grab ─────────────────────────────────────────
struct MenuBarView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let active = state.active {
                VStack(alignment: .leading, spacing: 6) {
                    Text(active.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    ProgressView(value: state.progress > 0 && state.progress < 1 ? state.progress : nil)
                    Text("\(Int(state.progress * 100))%\(state.queue.isEmpty ? "" : " · \(state.queue.count) queued")")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            if !state.toolsReady {
                Text(EngineError.toolsMissing.localizedDescription)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let url = state.clipboardLink {
                let queued = state.isQueued(url)
                Text(url)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(url)
                HStack(spacing: 8) {
                    Button("Best video") { state.enqueueClipboard(.video(maxHeight: 4320)) }
                    Button("MP3") { state.enqueueClipboard(.audioMP3) }
                    Button("Original audio") { state.enqueueClipboard(.audioOriginal) }
                }
                .controlSize(.small)
                .disabled(queued)
                if queued {
                    Text("Already in the queue.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Copy a link, then grab it here.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            Divider()
            HStack {
                Button("Open Pull") {
                    NSApp.activate()
                    openWindow(id: "main")
                }
                Spacer()
                Button("Quit") { state.quit() }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 280)
        .onAppear { state.refreshTools() }
    }
}
