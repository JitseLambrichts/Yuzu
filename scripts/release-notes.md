The first downloadable build of Yuzu: convert, compress and share files without opening an app.

## Install

1. Download **Yuzu.zip** below (macOS 14 or later on Apple silicon).
2. Unpack it and drag `Yuzu.app` into your Applications folder.
3. Open Yuzu. Because the app isn't notarized by Apple yet, macOS blocks the first launch:
   - **macOS 15 and later:** click **Done**, open **System Settings → Privacy & Security**,
     scroll down and click **Open Anyway** next to Yuzu, then confirm.
   - **macOS 14:** right-click `Yuzu.app`, choose **Open**, then click **Open**.
4. For audio, video and WebP, install FFmpeg and libwebp with [Homebrew](https://brew.sh):

   ```bash
   brew install ffmpeg webp
   ```

Yuzu lives in the menu bar. Start dragging a file, tap ⇧ Shift, ⌘ Command or ⌃ Control, and
drop it on the wheel.

More details are in the [README](https://github.com/JitseLambrichts/Yuzu#installation).
