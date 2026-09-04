# M-Series Video Converter

A small native macOS app for converting iPhone and camera videos to space-saving HEVC. It uses the media engine in Apple Silicon, keeps the original files untouched, and verifies every result before accepting it.

## What it does

- Select source and destination folders in a native SwiftUI interface.
- Encode SDR video with `hevc_videotoolbox` on Apple Silicon.
- Choose 720p, 1080p, 4K, or original resolution without upscaling.
- Choose Low, Medium, High, or Very High variable-quality encoding for SDR video.
- Retain 10-bit HDR and Dolby Vision when Apple's converter supports it.
- Preserve the primary audio track(s), recording date, local creation date, and QuickTime GPS coordinates.
- Normalize and compare localized legacy QuickTime GPS fields by their actual coordinates.
- Remove optional embedded preview images and allow Apple auxiliary tracks such as APAC to be omitted.
- Resume an interrupted run, re-check existing output files, and recover valid files rejected by an older metadata check.
- Show global progress, live messages, a TSV report, and a summary.
- Put rejected outputs in `Problems` instead of silently accepting them.

## Requirements

- Apple Silicon Mac (M1 or newer)
- macOS 13 or newer
- [Homebrew](https://brew.sh/); the Cask installs FFmpeg, ExifTool, and jq automatically

## Install with Homebrew

```bash
brew tap RealHaltewunsch/tap
brew install --cask m-series-video-converter
```

Upgrade or uninstall the app with:

```bash
brew upgrade --cask m-series-video-converter
brew uninstall --cask m-series-video-converter
```

Until the Apple notarization secrets described below are configured, published ZIPs remain ad-hoc signed. On first launch, macOS may therefore require right-clicking the app and choosing **Open**.

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

Without release credentials, the resulting app is ad-hoc signed. With all Apple variables configured, the packaging script signs with Hardened Runtime, submits the ZIP for notarization, staples the ticket, and verifies the finished app.

## Publishing a release

Pushing a semantic version tag such as `v0.2.0` starts the release workflow. It builds an ARM64 app for macOS 13 or newer, publishes `M-Series-Video-Converter.zip`, calculates its SHA256, and updates `Casks/m-series-video-converter.rb` in the separate `RealHaltewunsch/homebrew-tap` repository.

The following GitHub Actions secrets enable Developer ID signing and Apple notarization:

- `APPLE_CERTIFICATE_P12_BASE64`: base64-encoded Developer ID Application certificate (`.p12`)
- `APPLE_CERTIFICATE_PASSWORD`: password of the `.p12` file
- `APPLE_ID`: Apple ID used for notarization
- `APPLE_TEAM_ID`: Apple Developer Team ID
- `APPLE_APP_PASSWORD`: app-specific password for the Apple ID

All five Apple secrets must be configured together. If none are configured, the workflow deliberately publishes an ad-hoc-signed fallback. A partially configured signing setup fails the release instead of silently publishing the wrong artifact.

`TAP_DEPLOY_KEY` contains a write-enabled SSH deploy key scoped only to the Homebrew tap. It lets the workflow update the Cask without a broadly privileged personal access token.

To build a specific version locally:

```bash
APP_VERSION=0.2.0 ./Scripts/package-release.sh
```

## Command-line use

The conversion engine can also be used without the GUI:

```bash
./Support/Engine/convert_videos.sh \
  --source "/path/to/originals" \
  --destination "/path/to/converted" \
  --jobs 2 \
  --resolution 1080p \
  --quality high
```

Resolution accepts `720p`, `1080p`, `2160p`, or `original`. Quality accepts `low`, `medium`, `high`, or `very-high`.

Two parallel jobs are the recommended default. Depending on the video formats, more concurrent jobs do not necessarily increase throughput.

## Output and safety

- Source files are opened read-only and are never renamed, moved, or deleted.
- Results use the source directory structure and original base names, with `.mov` as the output extension.
- The destination must not be inside the source directory.
- A destination folder is tied to one source folder to prevent accidental mixing.
- Temporary state and logs live in `.mseries-video-converter` inside the destination.
- `conversion-report.tsv` and `summary.txt` contain the final report.

## Metadata policy

This tool prioritizes the metadata used for chronological and geographical organization:

- QuickTime creation date
- Apple local creation date when present
- QuickTime GPS coordinates, including altitude when present
- Original filesystem modification date

It does not promise bit-for-bit preservation of every proprietary Apple track. Dolby Vision metadata is required to remain present when the source contains Dolby Vision. Optional APAC audio, timed metadata, and embedded preview images may be removed.

## Quality policy

SDR material uses quality-based variable bitrate rather than one fixed bitrate for every resolution and frame rate. The presets map to VideoToolbox quality values of 35, 50, 60, and 75. High is the default and matches the original quality setting. Existing HEVC files that already fit the selected resolution are copied without re-encoding.

HDR is handled by Apple's media framework to retain HDR and Dolby Vision metadata. High and Very High request multipass export, with an automatic single-pass fallback. Apple does not expose the same fine-grained quality control for this path, and its smallest HEVC HDR export preset is 1080p; selecting 720p therefore keeps HDR output at up to 1080p and reports that decision in the log.

## License

MIT
