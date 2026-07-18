<img width="720" alt="dd6fbeca-4876-478a-b744-fc914f216afc" src="https://github.com/user-attachments/assets/e6a66eeb-4b2b-4086-a9a2-5e8d35ec8052" />


# avc

A macOS command-line replacement for `avconvert` that does what it can't: custom bitrate
control, remuxing multiple sources into one file, and real error messages instead of `error:1`.

Swift + AVFoundation/VideoToolbox only. One dependency (Apple's swift-argument-parser). macOS 14+.

## Install

```sh
swift build -c release
cp .build/release/avc /usr/local/bin/
```

## Usage

### probe — inspect a file

```sh
avc probe -i input.mp4
```

```
input.mp4: duration 151.068s
  track #1 [vide] codec=av01 7680x4320 23.976fps ITU_R_2020/ITU_R_2100_HLG HDR 18932.2kb/s duration 151.068s
  track #2 [soun] codec=aac 44100Hz 2ch 128.0kb/s duration 151.116s
```

### encode — re-encode with explicit settings

```sh
avc encode -i input.mp4 [-i audio.m4a ...] -o out.mov --codec hevc (--bitrate 8M | --quality 0.75) \
  [--max-bitrate 12M] [--width 1920] [--height 1080] [--keyframe-interval 60] \
  [--start 3.5] [--duration 30] [--audio-bitrate 128k] \
  [--multi-pass] [--replace] [--verbose]
```

- `-i` is repeatable: video is re-encoded from the first input that has a video track,
  audio comes from the first input with audio, subtitle tracks from all inputs.
  `.srt` inputs become tx3g subtitle tracks (`-i movie.mp4 -i subs.srt`; not with `--hls`).
  (For full per-track control without re-encoding, use `remux`.)
- Codecs: `hevc` (default), `h264`. Bitrate accepts `8M`, `8000k`, `8000000`.
- `--bitrate` is a long-run average target; instantaneous rate can spike well above it.
  `--max-bitrate 22M` adds a peak cap (VBV over a 1s window). Note: Apple's hardware
  encoder derates aggressively under a tight cap — keep it at 1.5-2x the average, and only
  use it when a target device or streaming spec actually requires one (HEVC Level 4.1
  already guarantees 50 Mb/s peaks decode anywhere at 1080p).
- `--quality 0.0-1.0` replaces `--bitrate` with constant-quality rate control: uniform
  visual quality, bits spent where scenes need them. The best choice for "high quality"
  when file size is flexible. ~0.5 is visually decent, ~0.75 high, ~0.9 near-transparent.
  Constant quality is single-pass by nature; `--multi-pass` only applies to `--bitrate`
  (and is rejected otherwise — VideoToolbox's multipass path ignores the quality key and
  produces bloated output).
- Dimensions clamp to the source (never upscales); one dimension implies the other by aspect.
- Audio passes through untouched unless `--audio-bitrate` re-encodes it to AAC.
- `--multi-pass` uses encoder-driven multipass when supported, silently single-pass otherwise.
- HDR (PQ/HLG) sources are detected automatically and come out as 10-bit HEVC Main10 with
  color properties preserved. HDR + `--codec h264` is an error.
- Subtitle tracks (tx3g) pass through.

### encode --hls — fragmented MP4 / HLS

```sh
avc encode -i input.mp4 -o outdir --bitrate 4M --hls --segment-duration 6
```

Writes `init.mp4`, `segN.m4s`, and a VOD `index.m3u8` into `outdir`. Audio is always
re-encoded to AAC (128k default) — segment output does not support passthrough audio.

### remux — combine without re-encoding

```sh
avc remux -i video.mp4 -i audio.m4a -o out.mov [--map 0:v] [--map 1:a] [--map 0:s]
```

Default mapping: first video + first audio track found across inputs, plus all subtitle
tracks. `--map INDEX:v|a|s` overrides (index = position of the `-i` flag, 0-based).
Never re-encodes; if a codec can't be written to the target container, the error names
the file, track type, codec, and container.

`.srt` inputs are converted to a tx3g subtitle track (the one exception to
"never re-encodes" — SRT is not a media container):

```sh
avc remux -i movie-h265.mp4 -i subs.srt -o out.mp4
```

Raw Annex B elementary streams (`.h265`/`.hevc`/`.h264`/`.264`/`.265`, e.g. extracted
from an mkv) can be wrapped losslessly. They carry no timing, so frame timestamps must
come from the source container:

```sh
mkvextract movie.mkv tracks 0:video.h265
mkvextract movie.mkv timestamps_v2 0:ts.txt
avc remux -i video.h265 --timestamps ts.txt -o out.mp4
```

B-frame reordering is reconstructed from the timestamps (PTS from the container, DTS
derived), so streams with any GOP structure wrap correctly.

## Errors

Every failure prints the operation, the media time when known, the full error chain with
symbolic names, and a hint when the cause is common:

```
error: appending video sample at 44.2s
  AVFoundationErrorDomain -11800 (AVErrorUnknown: unknown AVFoundation error; ...)
  └─ NSOSStatusErrorDomain -12902 (kVTParameterErr: a parameter passed to VideoToolbox was invalid)
hint: this often means the compression settings are incompatible with the source format; run `avc probe` on the input and check pixel format / dimensions
```

Exit codes: `0` success, `1` usage error, `2` media error. Ctrl-C cancels the writer and
removes the partial output file.

## Testing

```sh
./test.sh        # unit tests + integration matrix
```

Unit tests use Swift Testing. With Command Line Tools only (no Xcode), the
framework paths must be passed explicitly (`test.sh` does this for you):

```sh
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
L=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
swift test -Xswiftc -F$F -Xlinker -F$F -Xlinker -rpath -Xlinker $F -Xlinker -rpath -Xlinker $L
```

Generates its own fixtures (SDR/HDR video and tx3g subtitles via `gen-fixtures.swift`,
audio via `avconvert` or `ffmpeg` if available) and runs the full matrix: encode, remux,
probe, HDR preservation, HLS output, subtitles, and the error paths.

## Out of scope

Dolby Vision RPU generation, HDR→SDR tonemapping, subtitle format conversion (SRT/WebVTT),
closed captions, metadata/timecode tracks.
