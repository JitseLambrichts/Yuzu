# Yuzu

Offline bestandsconverter voor macOS, geïnspireerd op Tangerine (zie [PLAN.md](PLAN.md)).
Sleep een bestand, tik tijdens het slepen een toets en laat het los op het wiel.

| Toets (standaard) | Wiel | Inhoud |
|---|---|---|
| ⇧ Shift | Converteren | doelformaten die bij de selectie passen |
| ⌘ Command | Tools | comprimeren, metadata weg, PDF maken/samenvoegen/splitsen, dempen, normaliseren, uitpakken, QR lezen |
| ⌃ Control | Acties | AirDrop, Float, kopiëren, verplaatsen, pad kopiëren, Terminal |

De uitvoer komt naast het origineel; er wordt nooit iets overschreven.

## Formaten

- **Afbeeldingen:** JPG, PNG, WebP, HEIC, TIFF, AVIF, BMP → elkaar en PDF (SVG/PSD/RAW als invoer)
- **Audio:** MP3, M4A, WAV, FLAC, OGG, Opus, AIFF, WMA
- **Video:** MP4, MOV, MKV, WebM, AVI, WMV → elkaar, GIF en MP3
- **PDF:** → DOCX, TXT, Markdown, RTF, HTML, PNG/JPG (300 DPI)
- **Documenten:** DOCX, DOC, RTF, RTFD, ODT, HTML, TXT, Markdown → PDF, DOCX, RTF, ODT, HTML, TXT, Markdown
- **Spreadsheets:** XLSX ↔ CSV ↔ TSV
- **Ondertitels:** SRT ↔ VTT → TXT
- **Archieven en mappen:** ZIP, TAR, TAR.GZ (uitpakken ook GZ, RAR, 7z)

## Vereisten

- macOS 14 of nieuwer, Apple silicon
- `ffmpeg` voor audio/video en `cwebp` voor WebP (als ImageIO dat niet kan schrijven):
  `brew install ffmpeg webp`. Yuzu zoekt eerst in `Yuzu.app/Contents/Resources/Tools`,
  daarna in `/opt/homebrew/bin` en `/usr/local/bin`.

## Bouwen

```bash
swift test                    # alle core-tests
scripts/build-app.sh          # bouwt build/Yuzu.app
scripts/build-app.sh --install  # en kopieert naar /Applications
```

Ontwikkelhulp: `.build/debug/Yuzu --render-previews /tmp/yuzu` schrijft PNG's van het wiel
en de instellingen (licht en donker).

Wat de sleepdetectie ziet, kun je volgen met:

```bash
log stream --predicate 'subsystem == "app.yuzu.Yuzu"' --level info
```

## Structuur

- `Sources/YuzuCore`: formaten, catalogus, `DragStateMachine`, converters en tools (getest)
- `Sources/Yuzu`: menubalk-app: sleepmonitor, wiel, voortgangspaneel, acties, Float, instellingen
- `Tests/YuzuCoreTests`: Swift Testing; mediatests draaien alleen als ffmpeg aanwezig is

## Nog niet gebouwd

Zie fase 4 en 6 in [PLAN.md](PLAN.md): editors met eigen venster (bijsnijden, annoteren,
fotobewerking, collage, redactie, trimmen/splitsen met tijdlijn), PowerPoint, Pages, EPUB,
ODS, onboarding met oefenwiel en sandbox/App Store-distributie.
