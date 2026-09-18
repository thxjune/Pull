<p align="center">
  <img src="docs/icon.png" width="120" alt="Pull icon">
</p>

<h1 align="center">Pull</h1>

<p align="center">
  <b>Minimal macOS media downloader.</b><br>
  Paste a link from YouTube, Instagram, TikTok, X — or 1,800+ other sites — and pull it down in the quality you want.
</p>

---

<p align="center">
  <a href="https://github.com/thxjune/Pull/releases/latest"><b>⬇ Download the app</b></a> — no build needed. Unzip, right-click → Open. (Engine: <code>brew install yt-dlp ffmpeg</code>)
</p>

---

## Features

- 🎬 **Every quality the video has** — 4K/2K/1080p… with file sizes shown *before* you download
- 🎧 **Two audio modes** — **Original** (stream copy, zero re-encode — bit-identical to the source) and **MP3** (LAME V0, plays everywhere)
- 🧠 **Smart codecs** — H.264+AAC up to 1080p for universal playback; AV1 above that (YouTube only serves 4K in VP9/AV1). Sources that only come in VP9 (Instagram reels) are converted to H.264 on the fly, so every MP4 actually plays in QuickTime
- 📋 **Zero-click flow** — copy a link, switch to Pull: it's already fetched. Or drag & drop. Or use the menu-bar quick-grab
- 🧾 **Queue** — stack up downloads; live progress with speed + ETA; cancel anytime
- 📚 **Playlists** — paste a playlist link, pick one preset, queue every entry
- ⚡ **Fast** — 8 concurrent fragment streams
- 🌑 **Monochrome UI** — black, white, gray. Nothing doing too much.

## Requirements

```bash
brew install yt-dlp ffmpeg
```

macOS 14+. Keep yt-dlp current (`brew upgrade yt-dlp`) — YouTube breaks old versions every few weeks. For login-gated Instagram/TikTok posts, enable **Use browser cookies** in settings.

## Build

```bash
git clone https://github.com/thxjune/Pull.git
cd Pull
./build.sh
open build/Pull.app
```

## Note

Pull is a personal-use tool built on [yt-dlp](https://github.com/yt-dlp/yt-dlp). Download only content you have the right to save, and respect creators and platform terms.

---

Built by [@thxjune](https://github.com/thxjune) with [Claude Code](https://claude.com/claude-code).
