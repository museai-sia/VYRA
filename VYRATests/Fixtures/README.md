# Test fixtures

`pot-challenge-fixture.json` — a real BotGuard challenge captured
from the youtube.com homepage (program, global name, interpreter JS,
and the page's ytcfg subset): an offline test vector for the
on-device PO token provider's VM machinery (`PotOnDeviceTests` —
reset/load/snapshot in the app's real JS environments). It contains
no credentials; the visitor data in it is an unauthenticated,
ephemeral session value. Not part of the app bundle.

`player-b485e332-tv.js.gz` — gzipped copy of YouTube's tv-variant
player JS (player b485e332, `tv-player-ias.vflset/tv-player-ias.js`),
used ONLY as an offline test vector for the embedded yt-dlp-ejs
challenge solver (`EmbeddedPythonRuntimeTests`). It lets CI verify
that the real JSC provider path solves n/sig challenges without any
network access. Not part of the app bundle.

`remux-video-only.mp4` / `remux-audio-only.m4a` — a 2-second
320x240 H.264 video-only MP4 (13 KB) and a 2-second 440 Hz AAC
audio-only M4A (19 KB), generated with ffmpeg's lavfi test sources.
Used by `FFmpegRemuxTests` to run the real in-process FFmpeg remux
in the simulator and verify the merged MP4 with AVAsset. Test
fixtures only, not part of the app bundle.

`transcode-video-only.webm` (28 KB) / `transcode-audio-only.webm`
(15 KB) / `transcode-combined.webm` (42 KB) — 2-second 320x240
VP9 video and 440 Hz Opus audio, generated with ffmpeg's lavfi
test sources (`testsrc` / `sine`) encoded with libvpx-vp9 /
libopus on 2026-11-25. Used by `FFmpegTranscodeTests` to run the
real in-process FFmpeg transcode (VP9/Opus → H.264/AAC) in the
simulator and verify the output MP4 with AVAsset. Test fixtures
only, not part of the app bundle.
- `hls/playlist.m3u8` + `hls/seg00.bin` + `hls/seg01.bin`: a tiny
  (the segments carry a `.bin` extension on purpose: Xcode
  classifies `.ts` files as TypeScript sources in the
  filesystem-synchronized test target and silently leaves them
  out of the test bundle's resources. The playlist and the
  fixture server still refer to them as `seg00.ts` / `seg01.ts`
  URLs — only the on-disk fixture names differ.)
  two-segment HLS stream (H.264 + AAC in MPEG-TS, ~2 s total)
  generated from `remux-video-only.mp4` + `remux-audio-only.m4a`
  (video re-encoded with a forced keyframe at 1 s so the HLS
  muxer cuts two segments). The simulator suite serves this
  directory over localhost HTTP and downloads it with yt-dlp's
  native HLS downloader through the bridge, then remuxes the
  resulting MPEG-TS bytes to MP4 in-process.
