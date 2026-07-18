#!/bin/zsh
# avc integration tests. Generates fixtures, runs encode/remux/probe, checks exit codes + output.
set -u
setopt null_glob
cd "$(dirname "$0")"
AVC=.build/debug/avc
FIX=fixtures
PASS=0; FAIL=0

check() { # check <desc> <expected-exit> <cmd...>
  local desc=$1 want=$2; shift 2
  "$@" >/tmp/avc-test-out 2>&1
  local got=$?
  if [[ $got == $want ]]; then echo "ok   $desc"; ((PASS++))
  else echo "FAIL $desc (exit $got, want $want)"; sed 's/^/     /' /tmp/avc-test-out; ((FAIL++)); fi
}

grepout() { # grepout <desc> <pattern> <cmd...>
  local desc=$1 pat=$2; shift 2
  if "$@" 2>/dev/null | grep -q "$pat"; then echo "ok   $desc"; ((PASS++))
  else echo "FAIL $desc (no match: $pat)"; ((FAIL++)); fi
}

swift build 2>/dev/null || { echo "build failed"; exit 1; }
mkdir -p $FIX

# fixtures: video/hdr/subtitle via gen-fixtures.swift, audio via avconvert/ffmpeg
if [[ ! -f $FIX/video.mp4 || ! -f $FIX/hdr.mov || ! -f $FIX/subbed.mov ]]; then
  swift gen-fixtures.swift $FIX >/dev/null || { echo "fixture generation failed"; exit 1; }
fi
if [[ ! -f $FIX/audio.m4a ]]; then
  if command -v avconvert >/dev/null; then
    avconvert --preset PresetAppleM4A --source /System/Library/Sounds/Basso.aiff --output $FIX/audio.m4a >/dev/null 2>&1
  elif command -v ffmpeg >/dev/null; then
    ffmpeg -f lavfi -i sine=d=1 -c:a aac $FIX/audio.m4a >/dev/null 2>&1
  else
    echo "skip: no avconvert/ffmpeg to generate audio fixture"
  fi
fi

rm -rf $FIX/t-*

# probe
grepout "probe video shows codec+size" "avc1 640x360" $AVC probe -i $FIX/video.mp4
check "probe missing file exits 1" 1 $AVC probe -i nope.mp4
check "probe non-media exits 2" 2 $AVC probe -i PLAN.md

# encode
check "encode hevc" 0 $AVC encode -i $FIX/video.mp4 -o $FIX/t-enc.mov --codec hevc --bitrate 1M
grepout "encoded output is hevc" "hvc1" $AVC probe -i $FIX/t-enc.mov
check "encode refuses overwrite" 1 $AVC encode -i $FIX/video.mp4 -o $FIX/t-enc.mov --bitrate 1M
check "encode --replace overwrites" 0 $AVC encode -i $FIX/video.mp4 -o $FIX/t-enc.mov --bitrate 1M --replace
check "encode bad extension exits 1" 1 $AVC encode -i $FIX/video.mp4 -o $FIX/t-bad.xyz --bitrate 1M
check "encode bad bitrate exits 1" 1 $AVC encode -i $FIX/video.mp4 -o $FIX/t-b.mov --bitrate lots
check "encode downscale" 0 $AVC encode -i $FIX/video.mp4 -o $FIX/t-small.mp4 --bitrate 500k --width 320
grepout "downscaled to 320x180" "320x180" $AVC probe -i $FIX/t-small.mp4
check "encode never upscales" 0 $AVC encode -i $FIX/video.mp4 -o $FIX/t-up.mp4 --bitrate 1M --width 4000
grepout "upscale clamped to source" "640x360" $AVC probe -i $FIX/t-up.mp4
check "encode trim" 0 $AVC encode -i $FIX/video.mp4 -o $FIX/t-trim.mp4 --bitrate 1M --start 0.5 --duration 1
grepout "trimmed duration 1s" "duration 1.000s" $AVC probe -i $FIX/t-trim.mp4

# remux
if [[ -f $FIX/audio.m4a ]]; then
  check "remux video+audio" 0 $AVC remux -i $FIX/video.mp4 -i $FIX/audio.m4a -o $FIX/t-mux.mov
  grepout "muxed has video" "vide" $AVC probe -i $FIX/t-mux.mov
  grepout "muxed has audio" "soun" $AVC probe -i $FIX/t-mux.mov
  check "remux bad map exits 1" 1 $AVC remux -i $FIX/video.mp4 -o $FIX/t-m2.mov --map 5:v
  check "encode audio passthrough" 0 $AVC encode -i $FIX/t-mux.mov -o $FIX/t-pt.mp4 --bitrate 1M
  grepout "passthrough kept aac" "aac" $AVC probe -i $FIX/t-pt.mp4
  check "encode audio reencode" 0 $AVC encode -i $FIX/t-mux.mov -o $FIX/t-aac.mp4 --bitrate 1M --audio-bitrate 96k
  grepout "reencoded audio 44100Hz" "44100Hz" $AVC probe -i $FIX/t-aac.mp4
fi

# v2: multipass
check "encode multipass" 0 $AVC encode -i $FIX/video.mp4 -o $FIX/t-mp.mov --bitrate 1M --multi-pass
grepout "multipass output is hevc" "hvc1" $AVC probe -i $FIX/t-mp.mov

# v2: HDR
grepout "probe detects HDR" "ITU_R_2020/ITU_R_2100_HLG HDR" $AVC probe -i $FIX/hdr.mov
check "encode preserves HDR" 0 $AVC encode -i $FIX/hdr.mov -o $FIX/t-hdr.mov --bitrate 1M
grepout "re-encoded output still HDR" "ITU_R_2020/ITU_R_2100_HLG HDR" $AVC probe -i $FIX/t-hdr.mov
check "HDR to h264 rejected" 1 $AVC encode -i $FIX/hdr.mov -o $FIX/t-h264.mp4 --codec h264 --bitrate 1M

# v2: HLS / fragmented mp4
check "encode HLS" 0 $AVC encode -i $FIX/video.mp4 -o $FIX/t-hls --bitrate 1M --hls --segment-duration 1
[[ -f $FIX/t-hls/init.mp4 && -f $FIX/t-hls/seg0.m4s ]] && { echo "ok   HLS segments written"; ((PASS++)); } || { echo "FAIL HLS segments missing"; ((FAIL++)); }
grepout "HLS playlist valid" "EXT-X-ENDLIST" cat $FIX/t-hls/index.m3u8
check "HLS+multipass rejected" 1 $AVC encode -i $FIX/video.mp4 -o $FIX/t-hls2 --bitrate 1M --hls --multi-pass

# v2: subtitles
grepout "probe shows subtitle track" "sbtl.*tx3g" $AVC probe -i $FIX/subbed.mov
check "remux carries subtitles" 0 $AVC remux -i $FIX/subbed.mov -o $FIX/t-sub.mp4
grepout "remuxed subtitle intact" "sbtl.*tx3g" $AVC probe -i $FIX/t-sub.mp4
check "encode passes subtitles through" 0 $AVC encode -i $FIX/subbed.mov -o $FIX/t-sube.mov --bitrate 1M
grepout "encoded subtitle intact" "sbtl.*tx3g" $AVC probe -i $FIX/t-sube.mov

echo "----"
echo "$PASS passed, $FAIL failed"
exit $((FAIL > 0))
