# PLAN.md — `avc` (avconvert replacement CLI)

A macOS command-line tool in Swift that does what `avconvert` does, plus what it lacks:
custom bitrate control, remuxing multiple sources into one output, and real error messages.

## Goals

1. **Custom encode control** — bitrate, codec, resolution, keyframe interval via `AVAssetReader` + `AVAssetWriter` (not `AVAssetExportSession`, which only supports fixed presets).
2. **Remux** — combine tracks from multiple input files into a single `.mov`/`.mp4` without re-encoding (passthrough), or with selective re-encode per track.
3. **Better errors** — surface underlying `OSStatus` / `NSError` chains (e.g. `-12902 kVTParameterErr`) with human-readable explanations instead of `(null)`.

## Non-goals

- No cross-platform support. macOS 14+ only, Swift only, AVFoundation/VideoToolbox only.
- No filters, subtitles, or editing timelines. Encode + remux only.
- No GUI. No config files. Flags only.
- Do not reimplement `avconvert` presets. Explicit flags replace presets.

## Constraints (read before writing code)

- Standard library / platform frameworks only: `AVFoundation`, `VideoToolbox`, `CoreMedia`, `Foundation`, `ArgumentParser` is allowed (Apple's own package, the only dependency).
- Fewest files possible. Target: 5 source files max.
- No abstraction layers, no protocols "for testability", no dependency injection. Plain functions and one or two structs.
- Every error path must produce a message naming: the failing operation, the OSStatus code, and its symbolic name.

## CLI design

```
avc encode -i input.mp4 -o out.mov --codec hevc --bitrate 8M [--width 1920] [--height 1080] [--keyframe-interval 60] [--start 3.5] [--duration 30]
avc remux  -i video.mp4 -i audio.m4a -o out.mov [--map 0:v] [--map 1:a]
avc probe  -i input.mp4        # print tracks, codecs, durations, formats
```

Rules:
- `encode` re-encodes video; audio passes through unless `--audio-bitrate` given.
- `remux` never re-encodes. If a source codec is not writable to the output container, fail with a message saying which track/codec and why.
- Output container inferred from `-o` extension (`.mov` → QuickTime, `.mp4`/`.m4v` → MPEG-4). Unknown extension → error, list supported ones.
- `--replace` required to overwrite an existing output file (match avconvert behavior).

## File layout

```
Sources/avc/
  main.swift        # ArgumentParser command tree: Encode, Remux, Probe
  Encode.swift      # AVAssetReader → AVAssetWriter pipeline
  Remux.swift       # multi-input passthrough writer
  Probe.swift       # track/format inspection, prints table
  Errors.swift      # OSStatus → name/description mapping, error wrapping
```

## Implementation steps (in order, each independently verifiable)

### Step 1 — Project scaffold + `probe`
- `swift package init --type executable`, add `swift-argument-parser`.
- Implement `probe`: load `AVURLAsset`, iterate `tracks`, print per track: media type, codec FourCC, dimensions, duration, estimated data rate, format description details.
- Verify: `avc probe -i any.mp4` prints correct info. This also becomes the debugging tool for later steps.

### Step 2 — `Errors.swift`
- One function: `describe(_ status: OSStatus) -> String`.
- Hardcode a table of the VideoToolbox / CoreMedia codes that matter (source: VTErrors.h, CMBaseObject error ranges). Minimum set:
  - `-12902 kVTParameterErr`, `-12905 kVTInvalidSessionErr`, `-12909 kVTVideoDecoderBadDataErr`, `-12910 kVTVideoDecoderUnsupportedDataFormatErr`, `-12911 kVTVideoDecoderMalfunctionErr`, `-12912 kVTVideoEncoderMalfunctionErr`, `-12785`, `-12710 kCMFormatDescriptionBridgeError_InvalidParameter`, `-11800 AVErrorUnknown` (unwrap its `NSUnderlyingError`)
  - Unknown codes: print the raw number plus "look up in VTErrors.h / CMFormatDescriptionBridge.h".
- Wrap every AVFoundation error: recursively walk `NSUnderlyingError` and print the whole chain, one line per level.
- Verify: unit-call with known codes, check output strings.

### Step 3 — `encode` video pipeline
- `AVAssetReader` with `AVAssetReaderTrackOutput` on the video track, output settings `[kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]`.
- `AVAssetWriter` with `AVAssetWriterInput`, settings:
  - `AVVideoCodecKey`: `.hevc` or `.h264` from `--codec`
  - `AVVideoWidthKey`/`AVVideoHeightKey` from flags, default source dimensions (never upscale: clamp to source, matching avconvert)
  - `AVVideoCompressionPropertiesKey`: `AVVideoAverageBitRateKey` (parse `8M`/`8000k`/`8000000`), `AVVideoMaxKeyFrameIntervalKey` if given
- Pump loop: `requestMediaDataWhenReady` on a serial queue, `copyNextSampleBuffer` → `append`. On `append` returning false, read `writer.error`, pass through `Errors.describe`, cancel reader, exit non-zero.
- `--start`/`--duration` → `reader.timeRange`.
- Audio: `AVAssetReaderTrackOutput` with `outputSettings: nil` (passthrough) into a passthrough writer input; re-encode to AAC only when `--audio-bitrate` set.
- Progress: print `%` from last appended PTS / asset duration, single line, `\r`.
- Verify: encode a known file at `--bitrate 4M`, then `avc probe` the output and check data rate ≈ 4 Mb/s.

### Step 4 — `remux`
- Multiple `-i` inputs → one `AVAssetReader` per input.
- Default mapping: first video track found across inputs in order + first audio track. `--map INDEX:v` / `--map INDEX:a` overrides (index = position of `-i` flag, 0-based).
- All writer inputs use `outputSettings: nil` (passthrough).
- Before starting: check each source format description is writable to the target container via `AVAssetWriter.canApply`/`canAdd`; on failure, error message must name the input file, track type, codec FourCC, and target container.
- Verify: `avc remux -i video_only.mp4 -i audio_only.m4a -o out.mov` produces a playable file; `avc probe out.mov` shows both tracks with original codecs.

### Step 5 — polish
- Exit codes: 0 success, 1 usage error, 2 media error.
- `--verbose`: print chosen writer settings, per-track mapping decisions, and full error chains even on success paths where AVFoundation logged recoverable issues.
- Handle SIGINT: cancel writer (`cancelWriting`) so no half-written file is left, delete partial output.

## Error message format (contract)

```
error: encode failed while appending video sample at 44.2s
  AVFoundationErrorDomain -11800 (AVErrorUnknown)
  └─ NSOSStatusErrorDomain -12902 (kVTParameterErr: a parameter passed to VideoToolbox was invalid)
hint: this often means the compression settings are incompatible with the source format; run `avc probe` on the input and check pixel format / dimensions
```

Every failure prints: what operation, at what media time when known, the full domain/code chain with symbolic names, and one hint line when the code has a known common cause.

## Testing

- No test framework. A single `test.sh` that:
  1. Generates fixtures with `avconvert` or `ffmpeg` if present (skip gracefully if neither).
  2. Runs encode/remux/probe against fixtures, asserts exit codes and greps probe output.
- Manual case to keep: 8K AV1 → 1080p HEVC (the known avconvert `--multiPass` failure input) must succeed single-pass with a real error if anything fails.

## v2 (implemented)

- **Multipass** — `encode --multi-pass` via `AVAssetWriterInput.performsMultiPassEncodingIfSupported` + `respondToEachPassDescription`; each extra pass re-reads the encoder-requested time ranges with a fresh `AVAssetReader`. Falls back to single pass when the encoder declines. Not combinable with `--hls`.
- **HDR** — `encode` auto-detects PQ/HLG source transfer, preserves color primaries/transfer/matrix (`AVVideoColorPropertiesKey`), reads 10-bit (`x420`) and writes HEVC Main10. HDR source + `--codec h264` is a usage error. `probe` prints primaries/transfer and an `HDR` marker. Dolby Vision RPU regeneration is not possible with public APIs; DoVi sources come out as their HDR10/HLG base layer.
- **Fragmented MP4 / HLS** — `encode --hls [--segment-duration N]` writes `init.mp4` + `segN.m4s` + `index.m3u8` into the output directory (`AVAssetWriter` segment delegate, `.mpeg4AppleHLS` profile). Segment output rejects passthrough audio, so `--hls` always re-encodes audio to AAC (128k default, `--audio-bitrate` overrides).
- **Subtitles** — tx3g passthrough everywhere: `probe` lists subtitle tracks, `remux` maps them (`--map INDEX:s`, and includes all subtitle tracks by default), `encode` passes them through (except `--hls`). Unwritable subtitle codecs are dropped with a note in `--verbose`.

Fixtures for all of the above are generated by `gen-fixtures.swift` (invoked from `test.sh`; no ffmpeg needed for video/HDR/subtitle fixtures).

## Explicitly out of scope (do not build)

- Raw `VTCompressionSession` multipass (the AVAssetWriter API covers it)
- Dolby Vision RPU generation / HDR10+ dynamic metadata
- HDR→SDR tonemapping
- Subtitle format conversion (SRT/WebVTT import), closed captions
- Metadata/timecode tracks (drop silently, note in `--verbose`)
