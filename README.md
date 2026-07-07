# Pull

Minimal macOS media downloader. Paste a link from YouTube, Instagram, TikTok, X,
or 1,800+ other sites — pick MP4 quality or audio format, see the size first,
download to ~/Downloads.

- **Original audio** = stream copy, zero re-encode. Bit-identical to the source.
- **MP3** = LAME V0 (highest practical MP3 quality).
- Engine: yt-dlp + ffmpeg (`brew install yt-dlp ffmpeg`).

Build: `./build.sh` → `open build/Pull.app`
