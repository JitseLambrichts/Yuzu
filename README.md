<div align="center">

# <img width="34" alt="Logo" src="https://github.com/user-attachments/assets/f5506968-25a3-42cb-946d-1c678c644b23" /> Yuzu

**Convert, compress and share files without opening an app.**
Drag a file, tap a key, drop it on the wheel. Everything happens offline on your Mac.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)
![Apple silicon](https://img.shields.io/badge/Apple%20silicon-arm64-black)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)
![License: MIT](https://img.shields.io/badge/license-MIT-blue)

<picture>
  <img width="640" alt="Preview of the dial" src="https://github.com/user-attachments/assets/c07aceac-1e71-4c86-9d88-7c24166a7a67" />
</picture>

</div>

## How it works

Yuzu lives in the menu bar. Start dragging one or more files anywhere (Finder, the
desktop, a browser download), tap a modifier key while you're still holding the mouse
button, and a wheel appears around the cursor. Drop the files on a slice and Yuzu does
the rest.

| Key (default) | Wheel | What it offers |
|---|---|---|
| <kbd>⇧ Shift</kbd> | **Convert** | Target formats that fit the selection |
| <kbd>⌘ Command</kbd> | **Tools** | Compress, crop, add background, annotate, trim, remove metadata, create/merge/split PDF, mute, normalize, extract, read QR |
| <kbd>⌃ Control</kbd> | **Actions** | AirDrop, Float, copy, move, copy path, open in Terminal |

<table>
  <tr>
    <td align="center">
      <picture>
        <img width="360" alt="Preview of tools for an image" src="https://github.com/user-attachments/assets/c5b414e1-8cb4-43fc-b798-fd6a9ef53ee7" />
      </picture>
      <br><sub><b>Tools</b> for an image</sub>
    </td>
    <td align="center">
      <picture>
        <img width="360"alt="Preview of actions for any file" src="https://github.com/user-attachments/assets/62cc3b9c-610f-452d-9794-2e23a0de8c35" />
      </picture>
      <br><sub><b>Actions</b> for any file</sub>
    </td>
  </tr>
</table>

### Highlights

- **Offline.** No uploads, no accounts, no network access.
- **Non-destructive.** Output is saved next to the original; nothing is ever overwritten.
- **No special permissions.** Drag detection reads the drag pasteboard and modifier state,
  so Yuzu needs no Accessibility or Input Monitoring access.
- **Batch-friendly.** Drop several files at once and they're processed together.
- **Configurable.** Rebind the wheel keys, pick output quality, keep or strip metadata,
  and launch at login.

## Supported formats

| Category | Formats |
|---|---|
| Images | JPG, PNG, WebP, HEIC, TIFF, AVIF, BMP → each other and PDF (SVG, PSD and RAW as input) |
| Audio | MP3, M4A, WAV, FLAC, OGG, Opus, AIFF, WMA |
| Video | MP4, MOV, MKV, WebM, AVI, WMV → each other, GIF and MP3 |
| PDF | → DOCX, TXT, Markdown, RTF, HTML, PNG/JPG (300 DPI) |
| Documents | DOCX, DOC, RTF, RTFD, ODT, HTML, TXT, Markdown → PDF, DOCX, RTF, ODT, HTML, TXT, Markdown |
| Spreadsheets | XLSX ↔ CSV ↔ TSV |
| Subtitles | SRT ↔ VTT → TXT |
| Archives and folders | ZIP, TAR, TAR.GZ (extracting also handles GZ, RAR and 7z) |

## Installation

There are no prebuilt releases yet, so build Yuzu from source.

**Requirements**

- macOS 14 or later on Apple silicon (the wheel uses Liquid Glass on macOS 26 and a frosted
  disc on older versions)
- Xcode 26 or later, for the macOS 26 SDK
- [Homebrew](https://brew.sh) packages for audio, video and WebP:

  ```bash
  brew install ffmpeg webp
  ```

  Yuzu looks for `ffmpeg` and `cwebp` in `Yuzu.app/Contents/Resources/Tools` first, then in
  `/opt/homebrew/bin` and `/usr/local/bin`. Everything else uses built-in macOS frameworks.

**Build and install**

```bash
git clone https://github.com/JitseLambrichts/Yuzu.git
cd Yuzu
scripts/build-app.sh --install
```

This builds a release version, signs it ad hoc and copies it to `/Applications`. Without
`--install` the app ends up in `build/Yuzu.app`.

To bundle your own static `ffmpeg`/`cwebp` builds, put them in `vendor/Tools/` before
running the script.

### Opening Yuzu for the first time

Yuzu is signed ad hoc but not notarized by Apple (notarization needs a paid Apple Developer
account). A copy you build yourself usually opens straight away, but a copy that was
downloaded or sent to you gets blocked the first time with a message like
*"Apple could not verify “Yuzu” is free of malware"*. You only need to allow it once.

**macOS 15 Sequoia and later**

1. Open `Yuzu.app`. When the warning appears, click **Done**.
2. Open **System Settings → Privacy & Security** and scroll down to **Security**.
3. Next to *"“Yuzu” was blocked to protect your Mac"*, click **Open Anyway**. The button shows
   up for about an hour after you tried to open the app.
4. Confirm with your password or Touch ID, then click **Open Anyway** once more.

**macOS 14 Sonoma**

Right-click `Yuzu.app` in Finder, choose **Open**, then click **Open** in the dialog.

**Or use Terminal**

Removing the quarantine flag works on every version:

```bash
xattr -dr com.apple.quarantine /Applications/Yuzu.app
```

Yuzu has no network access and its full source code is in this repository, so you can check
what you're running, or build it yourself instead.

## Development

```bash
swift build                    # debug build
swift test                     # core test suite (media tests need ffmpeg)
```

Useful flags on the debug binary:

| Command | What it does |
|---|---|
| `.build/debug/Yuzu --render-previews /tmp/yuzu` | Writes PNGs of the wheels, settings and option panels in light and dark mode |
| `.build/debug/Yuzu --demo-wheel 6` | Shows the real Liquid Glass wheel around the cursor for six seconds |

Liquid Glass only renders on screen, so `--demo-wheel` is the way to check the real look.
To follow what drag detection sees:

```bash
log stream --predicate 'subsystem == "app.yuzu.Yuzu"' --level info
```

### Project layout

```
Sources/
├── YuzuCore/        Formats, catalog, DragStateMachine, converters and tools (tested)
└── Yuzu/            Menu bar app: drag monitor, wheel, progress panel, actions,
                     Float shelf, settings and tool option panels
Tests/
└── YuzuCoreTests/   Swift Testing suite
scripts/
└── build-app.sh     Builds and optionally installs Yuzu.app
```

## Roadmap

- Editors with their own window: photo editing, collage, redaction, splitting and joining video
- PowerPoint, Pages, EPUB and ODS support
- Onboarding with a practice wheel
- Sandboxing and signed, notarized releases

## Contributing

Issues and pull requests are welcome. Please run `swift test` before opening a pull request,
and add tests in `Tests/YuzuCoreTests` for new converters or tools.

## Acknowledgements

Yuzu is inspired by [Tangerine](https://tangerineformac.com) and is an independent project,
not affiliated with it. Audio and video conversion is powered by [FFmpeg](https://ffmpeg.org),
WebP encoding by [libwebp](https://developers.google.com/speed/webp).

## License

Yuzu is released under the [MIT License](LICENSE). FFmpeg and libwebp are separate projects
with their own licenses; Yuzu calls them as external tools.
