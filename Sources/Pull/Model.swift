import Foundation

// What we know about a pasted link after probing it with yt-dlp.
struct MediaInfo: Identifiable {
    let id = UUID()
    let url: String
    let title: String
    let uploader: String
    let platform: String          // "YouTube", "Instagram", "TikTok", …
    let durationSeconds: Double?
    let thumbnailURL: URL?
    let videoOptions: [VideoOption]
    let audioOptions: [AudioOption]

    var durationLabel: String {
        guard let s = durationSeconds else { return "" }
        let total = Int(s)
        let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%d:%02d", m, sec)
    }
}

struct VideoOption: Identifiable, Hashable {
    let id = UUID()
    let height: Int               // 2160, 1440, 1080, 720…
    let fps: Int?
    let estimatedBytes: Int64?    // video + best audio, when known

    var label: String {
        let fpsPart = (fps ?? 0) > 40 ? "\(fps!)" : ""
        let base = "\(height)p\(fpsPart)"
        if height >= 2160 { return "4K · \(base)" }
        if height >= 1440 { return "2K · \(base)" }
        return base
    }
    var sizeLabel: String { Format.size(estimatedBytes) }
}

enum AudioKind: String {
    case original   // stream copy — bit-identical to the source, no re-encode
    case mp3        // universal compatibility, highest VBR quality
}

struct AudioOption: Identifiable, Hashable {
    let id = UUID()
    let kind: AudioKind
    let codecNote: String         // "m4a" / "opus" etc. for the original stream
    let estimatedBytes: Int64?

    var label: String {
        switch kind {
        case .original: return "Original"
        case .mp3: return "MP3"
        }
    }
    var detail: String {
        switch kind {
        case .original: return "untouched source audio · \(codecNote)"
        case .mp3: return "highest quality · plays everywhere"
        }
    }
    var sizeLabel: String { Format.size(estimatedBytes) }
}

enum Format {
    static func size(_ bytes: Int64?) -> String {
        guard let b = bytes, b > 0 else { return "size unknown" }
        let mb = Double(b) / 1_048_576
        if mb >= 1024 { return String(format: "%.2f GB", mb / 1024) }
        if mb >= 100 { return String(format: "%.0f MB", mb) }
        return String(format: "%.1f MB", mb)
    }
}

// What to actually fetch — independent of a probe, so playlist entries and
// queue items can carry it around without pre-fetched format lists.
enum Selection: Codable, Hashable {
    case video(maxHeight: Int)
    case audioOriginal
    case audioMP3

    var label: String {
        switch self {
        case .video(let h):
            if h >= 4320 { return "8K MP4" }
            if h >= 2160 { return "4K MP4" }
            if h >= 1440 { return "2K MP4" }
            return "\(h)p MP4"
        case .audioOriginal: return "Original audio"
        case .audioMP3: return "MP3"
        }
    }
}

// A playlist (or channel/set) probe result.
struct PlaylistInfo: Identifiable {
    let id = UUID()
    let url: String
    let title: String
    let uploader: String
    let entries: [(title: String, url: String)]
}

// One item waiting in (or moving through) the download queue.
struct QueueItem: Identifiable, Equatable {
    let id = UUID()
    let url: String
    let title: String
    let selection: Selection
}

// One finished (or failed) download. Persisted across launches.
struct HistoryItem: Identifiable, Codable {
    var id = UUID()
    let title: String
    let detail: String            // "1080p MP4 · 145 MB" / "MP3 · 9.8 MB"
    let fileURL: URL?
    let failed: Bool
}
