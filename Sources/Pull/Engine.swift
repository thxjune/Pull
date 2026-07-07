import Foundation
import os

let plLog = Logger(subsystem: "com.juniortorres.pull", category: "engine")

// Wraps yt-dlp + ffmpeg. GUI apps don't inherit the shell PATH, so we locate
// the binaries ourselves.
enum Tools {
    static let searchPaths = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "\(NSHomeDirectory())/.local/bin",
        "/usr/bin",
    ]

    static func find(_ name: String) -> String? {
        searchPaths.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var ytdlp: String? { find("yt-dlp") }
    static var ffmpegDir: String? { find("ffmpeg").map { ($0 as NSString).deletingLastPathComponent } }
    static var ready: Bool { ytdlp != nil && ffmpegDir != nil }
}

enum EngineError: LocalizedError {
    case toolsMissing
    case probeFailed(String)
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .toolsMissing:
            return "yt-dlp / ffmpeg not found. Install with:  brew install yt-dlp ffmpeg"
        case .probeFailed(let m): return "Couldn't read that link. \(m)"
        case .downloadFailed(let m): return "Download failed. \(m)"
        }
    }
}

struct Engine {
    // YouTube's web client 403s some audio-only streams; the android client
    // fallback fixes it. Scoped to youtube: — harmless for every other site.
    static let extractorArgs = ["--extractor-args", "youtube:player_client=default,android"]

    // ── Probe: what is this link? ──────────────────────────────
    static func probe(url: String) async throws -> MediaInfo {
        guard let ytdlp = Tools.ytdlp else { throw EngineError.toolsMissing }
        let (out, err, code) = try await run(ytdlp, ["-J", "--no-playlist", "--no-warnings"] + extractorArgs + [url])
        guard code == 0, let data = out.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EngineError.probeFailed(tail(err))
        }
        return parse(json: json, url: url)
    }

    private static func parse(json: [String: Any], url: String) -> MediaInfo {
        let formats = (json["formats"] as? [[String: Any]]) ?? []

        func bytes(_ f: [String: Any]) -> Int64? {
            (f["filesize"] as? Int64) ?? (f["filesize_approx"] as? Int64)
            ?? (f["filesize"] as? Double).map(Int64.init) ?? (f["filesize_approx"] as? Double).map(Int64.init)
        }
        func isVideo(_ f: [String: Any]) -> Bool {
            (f["vcodec"] as? String).map { $0 != "none" } ?? false
        }
        func isAudioOnly(_ f: [String: Any]) -> Bool {
            !isVideo(f) && ((f["acodec"] as? String).map { $0 != "none" } ?? false)
        }

        // Best audio-only stream (for size estimates + "Original" option).
        let audioStreams = formats.filter(isAudioOnly)
        let bestAudio = audioStreams.max { a, b in
            ((a["abr"] as? Double) ?? 0) < ((b["abr"] as? Double) ?? 0)
        }
        let bestAudioBytes = bestAudio.flatMap(bytes)
        let bestAudioCodec: String = {
            guard let acodec = bestAudio?["acodec"] as? String else { return "audio" }
            if acodec.hasPrefix("mp4a") { return "m4a" }
            if acodec.contains("opus") { return "opus" }
            return acodec
        }()

        // Video ladder: best size estimate per height.
        var byHeight: [Int: (bytes: Int64?, fps: Int?)] = [:]
        for f in formats where isVideo(f) {
            guard let h = (f["height"] as? Int) ?? (f["height"] as? Double).map(Int.init), h >= 144 else { continue }
            let fBytes = bytes(f)
            let hasAudio = (f["acodec"] as? String).map { $0 != "none" } ?? false
            let total = fBytes.map { $0 + (hasAudio ? 0 : (bestAudioBytes ?? 0)) }
            let fps = (f["fps"] as? Double).map(Int.init) ?? (f["fps"] as? Int)
            let existing = byHeight[h]
            // Prefer entries with a known size; among those, the larger (safer estimate).
            if existing == nil || (existing?.bytes == nil && total != nil) ||
               ((existing?.bytes ?? 0) < (total ?? 0)) {
                byHeight[h] = (total, fps)
            }
        }
        let videoOptions = byHeight.keys.sorted(by: >).map { h in
            VideoOption(height: h, fps: byHeight[h]?.fps, estimatedBytes: byHeight[h]?.bytes ?? nil)
        }

        let audioOptions = [
            AudioOption(kind: .original, codecNote: bestAudioCodec, estimatedBytes: bestAudioBytes),
            // MP3 V0 lands near the source bitrate; the source size is the honest estimate.
            AudioOption(kind: .mp3, codecNote: "mp3", estimatedBytes: bestAudioBytes),
        ]

        let thumb = (json["thumbnail"] as? String).flatMap(URL.init(string:))
        return MediaInfo(
            url: url,
            title: (json["title"] as? String) ?? "Untitled",
            uploader: (json["uploader"] as? String) ?? (json["channel"] as? String) ?? "",
            platform: (json["extractor_key"] as? String) ?? "Web",
            durationSeconds: (json["duration"] as? Double) ?? (json["duration"] as? Int).map(Double.init),
            thumbnailURL: thumb,
            videoOptions: videoOptions,
            audioOptions: audioOptions
        )
    }

    // ── Download ───────────────────────────────────────────────
    // Returns the final file URL. Progress callback gets 0…1.
    static func download(
        info: MediaInfo,
        video: VideoOption?,
        audio: AudioOption?,
        outputDir: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        guard let ytdlp = Tools.ytdlp, let ffdir = Tools.ffmpegDir else { throw EngineError.toolsMissing }

        let template = outputDir.appendingPathComponent("%(title).120B.%(ext)s").path
        var args = [
            "--no-playlist", "--no-warnings", "--newline",
            "--ffmpeg-location", ffdir,
            "-o", template,
            "--print", "after_move:filepath",
            "--no-simulate",
        ] + extractorArgs

        if let v = video {
            // Best video at the chosen height + best audio, merged into MP4.
            args += [
                "-f", "bv*[height<=\(v.height)]+ba/b[height<=\(v.height)]",
                "--merge-output-format", "mp4",
            ]
        } else if let a = audio {
            switch a.kind {
            case .original:
                // -x with "best" copies the source stream into its native
                // container — NO re-encode, bit-identical audio.
                args += ["-f", "ba[ext=m4a]/bestaudio/best", "-x", "--audio-format", "best"]
            case .mp3:
                // V0 VBR — the highest practical MP3 quality.
                args += ["-f", "ba[ext=m4a]/bestaudio/best", "-x", "--audio-format", "mp3", "--audio-quality", "0"]
            }
        }
        args.append(info.url)

        let pathBox = PathBox()
        let (_, err, code) = try await run(ytdlp, args) { line in
            if line.hasPrefix("/") { pathBox.value = line }   // --print after_move:filepath
            if let pct = parseProgress(line) { progress(pct) }
        }
        guard code == 0, let path = pathBox.value else {
            throw EngineError.downloadFailed(tail(err))
        }
        return URL(fileURLWithPath: path)
    }

    // "[download]  42.3% of 10.55MiB at 2.1MiB/s" → 0.423
    private static func parseProgress(_ line: String) -> Double? {
        guard line.hasPrefix("[download]") else { return nil }
        guard let range = line.range(of: #"(\d{1,3}(?:\.\d+)?)%"#, options: .regularExpression) else { return nil }
        let num = line[range].dropLast()
        return Double(num).map { $0 / 100 }
    }

    private static func tail(_ s: String) -> String {
        let lines = s.split(separator: "\n").filter { !$0.isEmpty }
        return lines.suffix(2).joined(separator: " ")
    }

    // ── Process plumbing ───────────────────────────────────────
    @discardableResult
    private static func run(
        _ launchPath: String,
        _ args: [String],
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> (out: String, err: String, code: Int32) {
        try await withCheckedThrowingContinuation { cont in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: launchPath)
            proc.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = Tools.searchPaths.joined(separator: ":")
            proc.environment = env

            let outPipe = Pipe(), errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe

            let collector = LineCollector(onLine: onLine)
            outPipe.fileHandleForReading.readabilityHandler = { h in
                collector.ingest(h.availableData)
            }

            proc.terminationHandler = { p in
                outPipe.fileHandleForReading.readabilityHandler = nil
                collector.ingest(outPipe.fileHandleForReading.readDataToEndOfFile())
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                cont.resume(returning: (
                    collector.text,
                    String(data: errData, encoding: .utf8) ?? "",
                    p.terminationStatus
                ))
            }
            do { try proc.run() } catch { cont.resume(throwing: error) }
        }
    }
}

// Holds the final output path across the Sendable line-callback boundary.
final class PathBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: String?
    var value: String? {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}

// Accumulates stdout and emits complete lines (thread-safe enough for one pipe).
final class LineCollector: @unchecked Sendable {
    private var buffer = Data()
    private var all = Data()
    private let onLine: (@Sendable (String) -> Void)?
    private let lock = NSLock()

    init(onLine: (@Sendable (String) -> Void)?) { self.onLine = onLine }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(data: all, encoding: .utf8) ?? ""
    }

    func ingest(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        all.append(data)
        buffer.append(data)
        var lines: [String] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.prefix(upTo: nl)
            buffer.removeSubrange(...nl)
            if let s = String(data: lineData, encoding: .utf8) {
                lines.append(s.trimmingCharacters(in: .whitespaces))
            }
        }
        lock.unlock()
        lines.forEach { onLine?($0) }
    }
}
