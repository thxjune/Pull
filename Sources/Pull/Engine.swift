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
    static var ffprobe: String? { find("ffprobe") }
    static var ready: Bool { ytdlp != nil && ffmpegDir != nil && ffprobe != nil }
}

enum EngineError: LocalizedError {
    case toolsMissing
    case probeFailed(String)
    case downloadFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .toolsMissing:
            return "yt-dlp / ffmpeg not found. Install with:  brew install yt-dlp ffmpeg"
        case .probeFailed(let m): return "Couldn't read that link. \(m)"
        case .downloadFailed(let m): return "Download failed. \(m)"
        case .cancelled: return "Cancelled."
        }
    }
}

struct Engine {
    // (2026-07 needed "youtube:player_client=default,android" to dodge 403s on
    // audio-only streams; as of yt-dlp 2026.08 the android client only yields
    // "formats skipped, missing URL" warnings and the default client is
    // clean, so it's gone. Re-add here if YouTube regresses.)
    static let extractorArgs: [String] = []
    // Applied to every yt-dlp call. A stray ~/.config/yt-dlp/config or plugin
    // dir must not be able to change what Pull does (--exec, --proxy, -o…),
    // and a stalled host must not hang the app forever.
    static let commonArgs = ["--ignore-config", "--no-plugin-dirs", "--socket-timeout", "30", "--no-warnings"]

    enum ProbeResult {
        case single(MediaInfo)
        case playlist(PlaylistInfo)
    }

    // ── Probe: what is this link? ──────────────────────────────
    private static let probeProcess = ProcessBox()
    private static let probeCancelFlag = FlagBox()

    static func probeAny(url: String, useBrowserCookies: Bool = false) async throws -> ProbeResult {
        probeCancelFlag.value = false
        // Playlist-shaped URLs get a fast flat probe (no per-entry format fetch).
        let lower = url.lowercased()
        let looksLikePlaylist = lower.contains("/playlist") || lower.contains("/sets/")
            || (lower.contains("list=") && !lower.contains("v="))
        if looksLikePlaylist {
            let pl = try? await probePlaylist(url: url, useBrowserCookies: useBrowserCookies)
            // The user hit ✕ mid-probe: don't fall through and launch a second yt-dlp.
            if probeCancelFlag.value { throw EngineError.cancelled }
            if let pl, pl.entries.count > 1 { return .playlist(pl) }
        }
        return try await probeSingle(url: url, useBrowserCookies: useBrowserCookies)
    }

    private static func cookieArgs(_ on: Bool) -> [String] {
        on ? ["--cookies-from-browser", "chrome"] : []
    }

    static func probePlaylist(url: String, useBrowserCookies: Bool = false) async throws -> PlaylistInfo {
        guard let ytdlp = Tools.ytdlp else { throw EngineError.toolsMissing }
        let (out, err, code) = try await run(
            ytdlp, ["-J", "--flat-playlist"] + commonArgs + extractorArgs + cookieArgs(useBrowserCookies) + ["--", url],
            trackAs: probeProcess)
        guard code == 0, let data = out.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["_type"] as? String) == "playlist" else {
            throw EngineError.probeFailed(tail(err))
        }
        return parsePlaylist(json: json, url: url)
    }

    private static func parsePlaylist(json: [String: Any], url: String) -> PlaylistInfo {
        let rawEntries = (json["entries"] as? [[String: Any]]) ?? []
        let entries: [(String, String)] = rawEntries.compactMap { e in
            guard let u = (e["url"] as? String) ?? (e["webpage_url"] as? String),
                  u.lowercased().hasPrefix("http") else { return nil }
            return ((e["title"] as? String) ?? "Untitled", u)
        }
        return PlaylistInfo(
            url: url,
            title: (json["title"] as? String) ?? "Playlist",
            uploader: (json["uploader"] as? String) ?? (json["channel"] as? String) ?? "",
            entries: entries
        )
    }

    static func probe(url: String, useBrowserCookies: Bool = false) async throws -> MediaInfo {
        guard case .single(let info) = try await probeSingle(url: url, useBrowserCookies: useBrowserCookies) else {
            throw EngineError.probeFailed("That link is a channel or playlist, not a single video.")
        }
        return info
    }

    // `--no-playlist` only applies to URLs that are BOTH a video and a
    // playlist. A channel / profile / bare playlist URL that slipped past the
    // heuristic would otherwise be fully extracted (slow) and then downloaded
    // as one giant queue item. `--flat-playlist` keeps that probe cheap and
    // lets us route it to the playlist card instead.
    private static func probeSingle(url: String, useBrowserCookies: Bool) async throws -> ProbeResult {
        guard let ytdlp = Tools.ytdlp else { throw EngineError.toolsMissing }
        let (out, err, code) = try await run(
            ytdlp, ["-J", "--no-playlist", "--flat-playlist"] + commonArgs + extractorArgs
                + cookieArgs(useBrowserCookies) + ["--", url],
            trackAs: probeProcess)
        guard code == 0, let data = out.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EngineError.probeFailed(tail(err))
        }
        if (json["_type"] as? String) == "playlist" {
            let pl = parsePlaylist(json: json, url: url)
            guard !pl.entries.isEmpty else { throw EngineError.probeFailed("No videos found at that link.") }
            return .playlist(pl)
        }
        return .single(parse(json: json, url: url))
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

        // Video ladder keyed on the SMALLEST dimension — that's what yt-dlp's
        // `res:` sort compares, and it's what "1080p" means for a vertical
        // 1080×1920 reel. Keying on height alone mislabels portrait video
        // ("960p" for 540×960) and then asks yt-dlp for the wrong stream.
        var byRes: [Int: (bytes: Int64?, fps: Int?, codec: String)] = [:]
        for f in formats where isVideo(f) {
            func dim(_ k: String) -> Int? { (f[k] as? Int) ?? (f[k] as? Double).map(Int.init) }
            guard let h = dim("height"), h >= 144 else { continue }
            let res = min(h, dim("width") ?? h)
            let fBytes = bytes(f)
            let hasAudio = (f["acodec"] as? String).map { $0 != "none" } ?? false
            let total = fBytes.map { $0 + (hasAudio ? 0 : (bestAudioBytes ?? 0)) }
            let fps = (f["fps"] as? Double).map(Int.init) ?? (f["fps"] as? Int)
            let codec = Codec.normalize(f["vcodec"] as? String)
            let existing = byRes[res]
            // Prefer a natively playable codec; then a known size; then the
            // larger (safer) estimate.
            let better: Bool = {
                guard let e = existing else { return true }
                if Codec.playable(codec) != Codec.playable(e.codec) { return Codec.playable(codec) }
                if (e.bytes == nil) != (total == nil) { return total != nil }
                return (e.bytes ?? 0) < (total ?? 0)
            }()
            if better { byRes[res] = (total, fps, codec) }
        }
        var videoOptions = byRes.keys.sorted(by: >).map { r in
            VideoOption(height: r, fps: byRes[r]?.fps, estimatedBytes: byRes[r]?.bytes ?? nil,
                        vcodec: byRes[r]?.codec ?? "?")
        }
        // Some sites (Instagram's progressive MP4s) list video formats with no
        // codec or dimensions at all. Still offer them rather than showing an
        // audio-only card.
        if videoOptions.isEmpty, formats.contains(where: { ($0["vcodec"] as? String) != "none" && $0["acodec"] as? String != "none" }) {
            videoOptions = [VideoOption(height: 4320, fps: nil, estimatedBytes: nil, vcodec: "?")]
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
    // The single active process, so the queue can cancel it.
    private static let activeProcess = ProcessBox()
    private static let cancelFlag = FlagBox()
    static func cancelActive() {
        cancelFlag.value = true
        gracefulStop(activeProcess)
    }
    static func cancelProbe() {
        probeCancelFlag.value = true
        gracefulStop(probeProcess)
    }

    // SIGINT lets yt-dlp run its KeyboardInterrupt path (exit 1, child
    // ffmpeg told to quit; partial files are left for the temp-dir cleanup)
    // where SIGTERM would orphan that ffmpeg holding our
    // stdout pipe open (queue stuck forever on a live stream). If it hasn't
    // died in 5 s, kill its children first, then SIGTERM it.
    private static func gracefulStop(_ box: ProcessBox) {
        guard let p = box.value, p.isRunning else { return }
        p.interrupt()
        let pid = p.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            guard p.isRunning else { return }
            for child in childPIDs(of: pid) { kill(child, SIGTERM) }
            p.terminate()
        }
    }

    private static func childPIDs(of pid: Int32) -> [Int32] {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-P", "\(pid)"]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        pgrep.standardError = FileHandle.nullDevice
        guard (try? pgrep.run()) != nil else { return [] }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        pgrep.waitUntilExit()
        return out.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    struct DownloadResult {
        let fileURL: URL
        let detail: String        // "1080p MP4 · 145 MB" — from the file itself, not the request
    }

    // Progress callback gets (0…1, "2.1 MiB/s · ETA 0:12" / "Converting to H.264…").
    static func download(
        url: String,
        selection: Selection,
        outputDir: URL,
        useBrowserCookies: Bool,
        progress: @escaping @Sendable (Double, String?) -> Void
    ) async throws -> DownloadResult {
        guard let ytdlp = Tools.ytdlp, let ffdir = Tools.ffmpegDir else { throw EngineError.toolsMissing }
        cancelFlag.value = false

        // Each job downloads into its own hidden temp folder on the same
        // volume, then the finished file is moved next to it under a unique
        // name. This fixes two things at once: generic titles ("Video by X")
        // no longer make yt-dlp say "already downloaded" and hand back the OLD
        // file, and a cancelled/failed job leaves no .part litter behind.
        let tempDir = outputDir.appendingPathComponent(".pull-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let template = tempDir.appendingPathComponent("%(title).120B.%(ext)s").path
        var args = commonArgs + [
            // `--print` puts yt-dlp in quiet mode, which silently disables
            // progress output — `--progress` turns it back on.
            "--no-playlist", "--newline", "--progress",
            "--ffmpeg-location", ffdir,
            "-o", template,
            "--print", "after_move:filepath",
            "--no-simulate",
            // Fetch 8 stream fragments in parallel — big speedup on
            // YouTube/HLS/DASH, harmless elsewhere.
            "-N", "8",
        ] + extractorArgs

        // For Instagram/TikTok posts that require being logged in.
        args += cookieArgs(useBrowserCookies)

        switch selection {
        case .video(let maxHeight):
            // ≤1080p: prefer H.264 + AAC — plays on literally everything.
            // Above 1080p YouTube only serves VP9/AV1 — prefer AV1 (better
            // quality per byte, native playback on modern Macs).
            let sort = maxHeight <= 1080
                ? "res:\(maxHeight),vcodec:h264,acodec:m4a"
                : "res:\(maxHeight),vcodec:av01,acodec:m4a"   // without acodec, Opus wins → silent in QuickTime
            args += ["-f", "bv*+ba/b", "-S", sort, "--merge-output-format", "mp4"]
        case .audioOriginal:
            // -x with "best" copies the source stream into its native
            // container — NO re-encode, bit-identical audio.
            args += ["-f", "ba[ext=m4a]/bestaudio/best", "-x", "--audio-format", "best"]
        case .audioMP3:
            // V0 VBR — the highest practical MP3 quality.
            args += ["-f", "ba[ext=m4a]/bestaudio/best", "-x", "--audio-format", "mp3", "--audio-quality", "0"]
        }
        // `--` so a pasted string that starts with "-" can never become an option.
        args += ["--", url]

        // A URL can still expand to several files (a bare playlist link grabbed
        // from the menu bar, a carousel post) — keep every path yt-dlp prints.
        let paths = PathsBox()
        let (_, err, code) = try await run(ytdlp, args, trackAs: activeProcess) { line in
            if line.hasPrefix(tempDir.path) { paths.append(line) }   // --print after_move:filepath
            if let (pct, rate) = parseProgress(line) {
                // 100% of a stream = merge / extract / convert running with no
                // percentage of its own; don't leave a stale speed up.
                progress(pct, pct >= 1 ? "Processing…" : rate)
            }
        }
        if cancelFlag.value { throw EngineError.cancelled }
        let files = paths.value.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
        guard let first = files.first else { throw EngineError.downloadFailed(tail(err)) }
        // Extra entries just get moved into place as-is; the first one is
        // the one the playability check + history row are about.
        for extra in files.dropFirst() {
            try? FileManager.default.moveItem(at: extra, to: uniqueDestination(for: extra.lastPathComponent, in: outputDir))
        }
        let partial = code != 0   // e.g. one private entry in a multi-entry URL
        var file = first

        // Playability net. Instagram (and others) now serve VP9-only DASH
        // video; yt-dlp happily muxes it into .mp4, and QuickTime plays such a
        // file as audio over black. If the video codec isn't one macOS decodes
        // natively, re-encode it with the hardware H.264 encoder (~1 s per
        // 20 s of 1080p on Apple silicon). AV1 is left alone: it plays on
        // M3+ and re-encoding it would only lose quality.
        var info = probeFile(file)
        if case .video = selection, let vcodec = info?.vcodec, !Codec.playable(vcodec) {
            if cancelFlag.value { throw EngineError.cancelled }   // cancelled while probing — skip the convert
            progress(0, "Converting \(vcodec) → H.264…")
            file = try await transcodeToH264(file, info: info, progress: progress)
            info = probeFile(file)
        }

        // Move into place under a name that doesn't clobber an existing file.
        let dest = uniqueDestination(for: file.lastPathComponent, in: outputDir)
        try FileManager.default.moveItem(at: file, to: dest)

        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? nil
        var detail: String
        if case .video = selection, let res = info?.res {
            detail = "\(res)p MP4 · \(Format.size(size))"
        } else {
            detail = "\(selection.label) · \(Format.size(size))"
        }
        if files.count > 1 { detail += " · +\(files.count - 1) more" }
        if partial { detail += " · some entries failed" }
        return DownloadResult(fileURL: dest, detail: detail)
    }

    struct FileInfo { let vcodec: String; let acodec: String?; let res: Int?; let duration: Double?; let bitrate: Int? }

    // ffprobe: first video + first audio stream codecs, smallest dimension,
    // duration, overall bitrate.
    static func probeFile(_ file: URL) -> FileInfo? {
        guard let ffprobe = Tools.ffprobe else { return nil }
        let args = ["-v", "error",
                    "-show_entries", "stream=codec_type,codec_name,width,height:format=duration,bit_rate",
                    "-of", "json", file.path]
        // Synchronous is fine here: ffprobe on a local file returns in milliseconds.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffprobe)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = json["streams"] as? [[String: Any]],
              let video = streams.first(where: { ($0["codec_type"] as? String) == "video" }),
              let codec = video["codec_name"] as? String else { return nil }
        let audio = streams.first(where: { ($0["codec_type"] as? String) == "audio" })
        let format = json["format"] as? [String: Any]
        let w = video["width"] as? Int, h = video["height"] as? Int
        return FileInfo(
            vcodec: Codec.normalize(codec),
            acodec: audio?["codec_name"] as? String,
            res: [w, h].compactMap { $0 }.min(),
            duration: (format?["duration"] as? String).flatMap(Double.init),
            bitrate: (format?["bit_rate"] as? String).flatMap(Int.init)
        )
    }

    private static func transcodeToH264(
        _ src: URL, info: FileInfo?,
        progress: @escaping @Sendable (Double, String?) -> Void
    ) async throws -> URL {
        guard let ffdir = Tools.ffmpegDir else { throw EngineError.toolsMissing }
        let dst = src.deletingPathExtension().appendingPathExtension("h264.mp4")
        let duration = info?.duration
        // ~2× the source bitrate keeps the generation loss invisible; clamped
        // so a tiny reel isn't starved and a 4K file doesn't balloon.
        let target = min(max((info?.bitrate ?? 0) * 2, 3_000_000), 25_000_000)
        // Audio is copied untouched unless it's something QuickTime can't play
        // inside MP4 (opus/vorbis from a WebM-only source).
        let audioArgs = ["aac", "mp3", "alac", nil].contains(info?.acodec)
            ? ["-c:a", "copy"] : ["-c:a", "aac", "-b:a", "192k"]
        let args = [
            "-y", "-v", "error", "-nostats", "-progress", "pipe:1",
            "-i", src.path,
            "-map", "0:v:0", "-map", "0:a?",
            "-c:v", "h264_videotoolbox", "-allow_sw", "1", "-b:v", "\(target)",
            "-pix_fmt", "yuv420p",
        ] + audioArgs + [
            "-movflags", "+faststart",
            dst.path,
        ]
        let (_, err, code) = try await run(ffdir + "/ffmpeg", args, trackAs: activeProcess) { line in
            // "-progress pipe:1" emits key=value lines; out_time_us is the encoded position.
            guard line.hasPrefix("out_time_us="), let d = duration, d > 0,
                  let us = Double(line.dropFirst("out_time_us=".count)) else { return }
            progress(min(us / 1_000_000 / d, 1), "Converting to H.264…")
        }
        if cancelFlag.value { throw EngineError.cancelled }
        guard code == 0, FileManager.default.fileExists(atPath: dst.path) else {
            throw EngineError.downloadFailed("Couldn't convert to H.264. " + tail(err))
        }
        try? FileManager.default.removeItem(at: src)
        // Drop the ".h264" marker so the final name is just "Title.mp4".
        let clean = src.deletingPathExtension().appendingPathExtension("mp4")
        try? FileManager.default.removeItem(at: clean)
        try FileManager.default.moveItem(at: dst, to: clean)
        return clean
    }

    // "Title.mp4" → "Title 2.mp4" → "Title 3.mp4"… (Finder-style) if taken.
    private static func uniqueDestination(for name: String, in dir: URL) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = dir.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    // Remove temp folders left behind by a crash / force-quit.
    static func cleanupTempDirs(in dir: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: []) else { return }
        for item in items where item.lastPathComponent.hasPrefix(".pull-")
            && ((try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false) {
            try? fm.removeItem(at: item)
        }
    }

    // "[download]  42.3% of 10.55MiB at 2.1MiB/s ETA 00:12" → (0.423, "2.1MiB/s · ETA 00:12")
    private static func parseProgress(_ line: String) -> (Double, String?)? {
        guard line.hasPrefix("[download]") else { return nil }
        guard let range = line.range(of: #"(\d{1,3}(?:\.\d+)?)%"#, options: .regularExpression) else { return nil }
        let pct = Double(line[range].dropLast()).map { $0 / 100 }
        var rate: String?
        if let atRange = line.range(of: #"at\s+\S+"#, options: .regularExpression),
           !line[atRange].hasSuffix("Unknown") {
            var parts = [String(line[atRange].dropFirst(3))]
            if let etaRange = line.range(of: #"ETA\s+\S+"#, options: .regularExpression) {
                parts.append(String(line[etaRange]))
            }
            rate = parts.joined(separator: " · ")
        }
        return pct.map { ($0, rate) }
    }

    private static func tail(_ s: String) -> String {
        let lines = s.split(separator: "\n").map { line -> String in
            var l = String(line).trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("ERROR:") { l = String(l.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
            return l
        }.filter { !$0.isEmpty }
        return lines.suffix(2).joined(separator: " ")
    }

    // ── Process plumbing ───────────────────────────────────────
    @discardableResult
    private static func run(
        _ launchPath: String,
        _ args: [String],
        trackAs box: ProcessBox? = nil,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> (out: String, err: String, code: Int32) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        // Deliberately NOT the parent's full environment: when Pull is
        // launched from a terminal that would hand yt-dlp every proxy
        // var, PYTHONPATH and API key in the shell. Just what it needs.
        let parent = ProcessInfo.processInfo.environment
        let path = (Tools.searchPaths + (parent["PATH"] ?? "").split(separator: ":").map(String.init))
            .joined(separator: ":")   // ours first, then whatever the shell had (nvm/deno for YouTube's JS)
        var env: [String: String] = [
            "HOME": NSHomeDirectory(),
            "PATH": path,
            "TMPDIR": parent["TMPDIR"] ?? NSTemporaryDirectory(),
            "LANG": parent["LANG"] ?? "en_US.UTF-8",
        ]
        // yt-dlp is Python: without this, its progress lines sit in an 8KB
        // pipe buffer and arrive in one burst at the end — the UI bar would
        // jump 0 → done. Unbuffered = live progress.
        env["PYTHONUNBUFFERED"] = "1"
        proc.environment = env

        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        proc.standardInput = FileHandle.nullDevice

        try proc.run()
        // Register only once launched — interrupt() on an unlaunched Process
        // throws an ObjC exception and takes the app down. A cancel that lands
        // in the launch window is caught by the flag check just below.
        box?.value = proc
        if box === activeProcess, cancelFlag.value { proc.interrupt() }
        if box === probeProcess, probeCancelFlag.value { proc.interrupt() }

        // Exactly one reader per pipe, each drained to EOF on its own thread.
        // (A readabilityHandler plus a final readDataToEndOfFile can interleave
        // and split the last line — the printed file path — in half.)
        let collector = LineCollector(onLine: onLine)
        let errBox = DataBox()
        return await withCheckedContinuation { cont in
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let h = outPipe.fileHandleForReading
                while true {
                    let d = h.availableData          // blocks; empty == EOF
                    if d.isEmpty { break }
                    collector.ingest(d)
                }
                group.leave()
            }
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                errBox.value = errPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            group.notify(queue: .global()) {
                proc.waitUntilExit()
                box?.value = nil
                cont.resume(returning: (
                    collector.text,
                    String(data: errBox.value, encoding: .utf8) ?? "",
                    proc.terminationStatus
                ))
            }
        }
    }
}

// Collected stderr, handed across the reader thread.
final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = Data()
    var value: Data {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}

// Codec names as yt-dlp / ffprobe report them → one short label, and
// whether macOS (AVFoundation / QuickTime) decodes it natively.
enum Codec {
    static func normalize(_ raw: String?) -> String {
        guard let c = raw?.lowercased(), c != "none" else { return "?" }
        if c.hasPrefix("avc") || c.hasPrefix("h264") { return "h264" }
        if c.hasPrefix("hev") || c.hasPrefix("hvc") || c.hasPrefix("h265") { return "hevc" }
        if c.hasPrefix("av01") || c == "av1" { return "av1" }
        if c.hasPrefix("vp09") || c.hasPrefix("vp9") { return "vp9" }
        if c.hasPrefix("vp08") || c.hasPrefix("vp8") { return "vp8" }
        return c
    }
    // "?" (unknown) is treated as playable: it's usually a progressive MP4
    // whose codec yt-dlp simply didn't report, and the post-download probe
    // catches the rare miss.
    static func playable(_ codec: String) -> Bool {
        ["h264", "hevc", "av1", "?"].contains(codec)
    }
}

// Set when the user cancels, so a terminated process isn't mistaken for a failure.
final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}

// Holds the active Process across threads so the queue can cancel it.
final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Process?
    var value: Process? {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}

// Collects every output path yt-dlp prints, across the Sendable line-callback boundary.
final class PathsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: [String] = []
    var value: [String] { lock.lock(); defer { lock.unlock() }; return _value }
    func append(_ s: String) { lock.lock(); defer { lock.unlock() }; _value.append(s) }
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
