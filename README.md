# Yuzu

Offline file converter for macOS, inspired by Tangerine (see [PLAN.md](PLAN.md)).
Drag a file, tap a key while dragging and drop it on the wheel.

| Key (default) | Wheel | Contents |
|---|---|---|
| ⇧ Shift | Convert | target formats that fit the selection |
| ⌘ Command | Tools | compress (automatic, percentage or target size), crop, trim, remove metadata, create/merge/split PDF, mute, normalize, extract, read QR |
| ⌃ Control | Actions | AirDrop, Float, copy, move, copy path, Terminal |

The output is saved next to the original; nothing is ever overwritten.

## Formats

- **Images:** JPG, PNG, WebP, HEIC, TIFF, AVIF, BMP → each other and PDF (SVG/PSD/RAW as input)
- **Audio:** MP3, M4A, WAV, FLAC, OGG, Opus, AIFF, WMA
- **Video:** MP4, MOV, MKV, WebM, AVI, WMV → each other, GIF and MP3
- **PDF:** → DOCX, TXT, Markdown, RTF, HTML, PNG/JPG (300 DPI)
- **Documents:** DOCX, DOC, RTF, RTFD, ODT, HTML, TXT, Markdown → PDF, DOCX, RTF, ODT, HTML, TXT, Markdown
- **Spreadsheets:** XLSX ↔ CSV ↔ TSV
- **Subtitles:** SRT ↔ VTT → TXT
- **Archives and folders:** ZIP, TAR, TAR.GZ (extracting also handles GZ, RAR, 7z)

## Requirements

- macOS 14 or later, Apple silicon
- `ffmpeg` for audio/video and `cwebp` for WebP (when ImageIO can't write it):
  `brew install ffmpeg webp`. Yuzu looks in `Yuzu.app/Contents/Resources/Tools` first,
  then in `/opt/homebrew/bin` and `/usr/local/bin`.

## Building

```bash
swift test                      # all core tests
scripts/build-app.sh            # builds build/Yuzu.app
scripts/build-app.sh --install  # and copies it to /Applications
```

Development aid: `.build/debug/Yuzu --render-previews /tmp/yuzu` writes PNGs of the wheel,
the settings and the option panels (light and dark).

To follow what drag detection sees:

```bash
log stream --predicate 'subsystem == "app.yuzu.Yuzu"' --level info
```

## Structure

- `Sources/YuzuCore`: formats, catalog, `DragStateMachine`, converters and tools (tested)
- `Sources/Yuzu`: menu bar app: drag monitor, wheel, progress panel, actions, Float, settings, option panels
- `Tests/YuzuCoreTests`: Swift Testing; media tests only run when ffmpeg is installed

## Not built yet

See phases 4 and 6 in [PLAN.md](PLAN.md): editors with their own window (annotate, photo editing,
collage, redaction, splitting/joining video), PowerPoint, Pages, EPUB,
ODS, onboarding with a practice wheel and sandbox/App Store distribution.
