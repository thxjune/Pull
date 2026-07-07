import SwiftUI
import AppKit

// Monochrome palette — black, white, grays. Nothing else.
enum Mono {
    static let bg = Color(hex: 0x0B0B0C)
    static let card = Color.white.opacity(0.04)
    static let line = Color.white.opacity(0.09)
    static let text = Color(hex: 0xF5F5F7)
    static let dim = Color(hex: 0x9A9AA0)
    static let faint = Color(hex: 0x6E6E73)
}

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 18) {
                    urlBar
                    if let e = state.errorText { errorCard(e) }
                    if state.probing { probingCard }
                    if let info = state.info { MediaCard(info: info) }
                    if !state.history.isEmpty { HistoryList() }
                    Spacer(minLength: 20)
                }
                .padding(24)
            }
        }
        .background(Mono.bg)
    }

    private var header: some View {
        HStack {
            Text("pull.")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Mono.text)
            Spacer()
            Text("paste a link — YouTube · Instagram · TikTok · X · 1,800+ sites")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Mono.faint)
        }
        .padding(.horizontal, 24)
        .padding(.top, 38)
        .padding(.bottom, 14)
    }

    private var urlBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "link")
                .foregroundStyle(Mono.faint)
            TextField("https://…", text: $state.urlText)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(Mono.text)
                .onSubmit { state.probe() }
            if !state.urlText.isEmpty {
                Button {
                    state.urlText = ""
                    state.info = nil
                    state.errorText = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Mono.faint)
                }
                .buttonStyle(.plain)
            }
            Button {
                if let s = NSPasteboard.general.string(forType: .string) {
                    state.urlText = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    state.probe()
                }
            } label: {
                Text("Paste")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Mono.dim)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(Color.white.opacity(0.07)))
            }
            .buttonStyle(.plain)
            Button { state.probe() } label: {
                Text("Fetch")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Capsule().fill(Color.white))
            }
            .buttonStyle(.plain)
            .disabled(state.urlText.isEmpty || state.probing)
            .opacity(state.urlText.isEmpty ? 0.4 : 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Mono.card))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Mono.line))
    }

    private var probingCard: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Reading link…")
                .font(.system(size: 13))
                .foregroundStyle(Mono.dim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Mono.card))
    }

    private func errorCard(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.system(size: 12.5))
            .foregroundStyle(Mono.dim)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.14)))
    }
}

// ── The main card: metadata + options + download ────────────────
struct MediaCard: View {
    @EnvironmentObject var state: AppState
    let info: MediaInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // metadata row
            HStack(alignment: .top, spacing: 14) {
                AsyncImage(url: info.thumbnailURL) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(Color.white.opacity(0.06))
                }
                .frame(width: 148, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 10))

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

            // mode toggle
            HStack(spacing: 4) {
                ForEach(AppState.Mode.allCases, id: \.self) { m in
                    let active = state.mode == m
                    Button { withAnimation(.easeOut(duration: 0.15)) { state.mode = m } } label: {
                        Text(m.rawValue)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(active ? .black : Mono.dim)
                            .padding(.horizontal, 16).padding(.vertical, 7)
                            .background(Capsule().fill(active ? Color.white : Color.clear))
                    }
                    .buttonStyle(.plain)
                    .disabled(m == .video && info.videoOptions.isEmpty)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            // options
            VStack(spacing: 6) {
                if state.mode == .video {
                    ForEach(info.videoOptions) { v in
                        optionRow(
                            selected: state.selectedVideo == v,
                            title: v.label,
                            subtitle: "MP4",
                            size: v.sizeLabel
                        ) { state.selectedVideo = v }
                    }
                } else {
                    ForEach(info.audioOptions) { a in
                        optionRow(
                            selected: state.selectedAudio == a,
                            title: a.label,
                            subtitle: a.detail,
                            size: a.sizeLabel
                        ) { state.selectedAudio = a }
                    }
                }
            }
            .padding(.horizontal, 16)

            // download
            VStack(spacing: 10) {
                if state.downloading {
                    VStack(spacing: 8) {
                        ProgressView(value: state.progress)
                            .tint(.white)
                        Text("\(Int(state.progress * 100))%")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Mono.faint)
                    }
                } else {
                    Button { state.download() } label: {
                        Text("Download")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
                    }
                    .buttonStyle(.plain)
                }
                Button { state.chooseOutputDir() } label: {
                    Text("saves to \(state.outputDir.lastPathComponent) — change")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Mono.faint)
                        .underline()
                }
                .buttonStyle(.plain)
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
    }
}

// ── Session history ─────────────────────────────────────────────
struct HistoryList: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DONE")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(Mono.faint)
                .padding(.leading, 4)
            ForEach(state.history) { item in
                HStack(spacing: 12) {
                    Image(systemName: item.failed ? "xmark.circle" : "checkmark.circle.fill")
                        .foregroundStyle(item.failed ? Mono.faint : Mono.text)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Mono.text)
                            .lineLimit(1)
                        Text(item.detail)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Mono.faint)
                    }
                    Spacer()
                    if let url = item.fileURL {
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
            }
        }
    }
}
