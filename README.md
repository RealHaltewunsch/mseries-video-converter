# M-Series Video Converter

A small native macOS app for converting iPhone and camera videos to space-saving HEVC at up to 1080p. It uses the media engine in Apple Silicon, keeps the original files untouched, and verifies every result before accepting it.

The interface and documentation are currently German; contributions and translations are welcome.

## What it does

- Select source and destination folders in a native SwiftUI interface.
- Encode SDR video with `hevc_videotoolbox` on Apple Silicon.
- Downscale Dolby Vision/HLG to 1080p while retaining 10-bit HDR and Dolby Vision when Apple's converter supports it.
- Preserve the primary audio track(s), recording date, local creation date, and QuickTime GPS coordinates.
- Remove optional embedded preview images and allow Apple auxiliary tracks such as APAC to be omitted.
- Resume an interrupted run and re-check existing output files.
- Show global progress, live messages, a TSV report, and a summary.
- Put rejected outputs in `Problemfaelle` instead of silently accepting them.

## Requirements

- Apple Silicon Mac (M1 or newer)
- macOS 13 or newer
- [Homebrew](https://brew.sh/)
- FFmpeg, ExifTool, and jq

Install the command-line dependencies:

```bash
brew install ffmpeg exiftool jq
```

## Build the app

Xcode Command Line Tools or Xcode 15+ are required.

```bash
git clone https://github.com/RealHaltewunsch/mseries-video-converter.git
cd mseries-video-converter
./Scripts/build-app.sh
open "dist/M-Series Video Converter.app"
```

To create a ZIP suitable for a GitHub release:

```bash
./Scripts/package-release.sh
```

The resulting app is ad-hoc signed, not notarized. After downloading it, macOS may require the user to right-click the app and choose **Open** the first time.

## Command-line use

The conversion engine can also be used without the GUI:

```bash
./Support/Engine/convert_videos.sh \
  --source "/path/to/originals" \
  --destination "/path/to/converted" \
  --jobs 2
```

Two parallel jobs are the recommended default. Depending on the video formats, more concurrent jobs do not necessarily increase throughput.

## Output and safety

- Source files are opened read-only and are never renamed, moved, or deleted.
- Results use the source directory structure and original base names, with `.mov` as the output extension.
- The destination must not be inside the source directory.
- A destination folder is tied to one source folder to prevent accidental mixing.
- Temporary state and logs live in `.mseries-video-converter` inside the destination.
- `konvertierungsprotokoll.tsv` and `zusammenfassung.txt` contain the final report.

## Metadata policy

This tool prioritizes the metadata used for chronological and geographical organization:

- QuickTime creation date
- Apple local creation date when present
- QuickTime GPS coordinates, including altitude when present
- Original filesystem modification date

It does not promise bit-for-bit preservation of every proprietary Apple track. Dolby Vision metadata is required to remain present when the source contains Dolby Vision. Optional APAC audio, timed metadata, and embedded preview images may be removed.

## Quality policy

SDR material is encoded with a quality-oriented VideoToolbox setting (`q:v 60`) and no fixed low bitrate. Existing HEVC files that already fit within 1080p are copied without re-encoding. HDR is handled by Apple's media framework, with an automatic single-pass fallback when multipass export is unavailable.

## License

MIT
