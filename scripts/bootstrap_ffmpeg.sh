#!/bin/bash
# Build VYRA's bundled FFmpeg libraries from source into Vendor/.
#
#   Vendor/FFmpeg.xcframework   libavformat + libavcodec + libavfilter
#                               + libswscale + libswresample + libavutil,
#                               merged into one static library per slice
#                               (device arm64 + simulator arm64)
#   Vendor/FFmpeg/include/      the matching public headers
#
# The build is deliberately minimal and LGPL-only (FFmpeg's default
# license when no --enable-gpl / --enable-nonfree / external libraries
# are involved). VYRA does two things with FFmpeg, both in-process:
#   * remux (stream copy) of avc1 MP4 + AAC M4A split pairs, and
#   * transcode of everything else yt-dlp returns (VP9/AV1/WebM
#     video, Opus audio, ...) to H.264 + AAC MP4: native decoders
#     (h264/vp9/av1/aac/opus/mp3/vorbis), format conversion via
#     libavfilter (format/aformat) + libswscale/libswresample, the
#     h264_videotoolbox hardware encoder and FFmpeg's native AAC
#     encoder. No GPL/nonfree components, no external libraries,
#     no programs, no network.
#
# Vendor/ is gitignored: this script runs in CI before xcodebuild
# (after the Xcode selection step, so xcrun resolves the right SDKs),
# and can be run locally on a Mac the same way. The version is pinned;
# bump FFMPEG_VERSION to update (and THIRD_PARTY_LICENSES.md with it).
set -euo pipefail

FFMPEG_VERSION="${FFMPEG_VERSION:-9.1}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor"
mkdir -p "$VENDOR"

if [ -d "$VENDOR/FFmpeg.xcframework" ] && [ -d "$VENDOR/FFmpeg/include" ]; then
    echo "==> FFmpeg $FFMPEG_VERSION already present in Vendor/, skipping"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Downloading FFmpeg $FFMPEG_VERSION source"
curl -fL --progress-bar \
    "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" \
    | tar -xJ -C "$WORK"
SRC="$WORK/ffmpeg-$FFMPEG_VERSION"

CONFIGURE_FLAGS=(
    --enable-cross-compile
    --target-os=darwin
    --disable-autodetect
    --disable-programs
    --disable-doc
    --disable-debug
    --disable-avdevice
    --enable-avfilter
    --enable-swscale
    --enable-swresample
    --disable-network
    --disable-asm
    --disable-everything
    --enable-static
    --disable-shared
    --enable-pic
    --enable-avformat
    --enable-avcodec
    --enable-avutil
    --enable-protocol=file
    --enable-demuxer=mov,matroska,aac,mp3,mpegts
    --enable-muxer=mp4
    --enable-decoder=h264,vp9,av1,aac,opus,mp3float,vorbis
    --enable-encoder=aac,h264_videotoolbox
    --enable-parser=h264,aac,vp9,av1,opus,vorbis,mpegaudio
    --enable-bsf=aac_adtstoasc
    --enable-filter=buffer,buffersink,abuffer,abuffersink,format,aformat,scale,aresample,null,anull
    --enable-videotoolbox
    --disable-audiotoolbox
    --disable-iconv
    --disable-zlib
    --disable-bzlib
    --disable-lzma
)

build_slice() {
    local sdk="$1" min_flag="$2" name="$3" arch="${4:-arm64}"
    local sdk_path cc build_dir install_dir
    sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
    cc="$(xcrun --sdk "$sdk" --find clang)"
    build_dir="$WORK/build-$name"
    install_dir="$WORK/install-$name"
    mkdir -p "$build_dir"
    echo "==> Configuring FFmpeg for $sdk ($arch)"
    (cd "$build_dir" && "$SRC/configure" \
        --prefix="$install_dir" \
        --cc="$cc" \
        --arch="$arch" \
        --extra-cflags="-arch $arch $min_flag -isysroot $sdk_path" \
        --extra-ldflags="-arch $arch $min_flag -isysroot $sdk_path" \
        "${CONFIGURE_FLAGS[@]}")
    echo "==> Building FFmpeg for $sdk ($arch)"
    make -C "$build_dir" -j"$(sysctl -n hw.ncpu)"
    make -C "$build_dir" install
    # Merge the libraries into one static archive per slice so
    # the app links a single FFmpeg.xcframework.
    libtool -static -o "$WORK/libFFmpeg-$name.a" \
        "$install_dir/lib/libavformat.a" \
        "$install_dir/lib/libavcodec.a" \
        "$install_dir/lib/libavfilter.a" \
        "$install_dir/lib/libswscale.a" \
        "$install_dir/lib/libswresample.a" \
        "$install_dir/lib/libavutil.a"
}

build_slice iphoneos "-mios-version-min=26.0" device
build_slice iphonesimulator "-mios-simulator-version-min=26.0" simulator
# The generic iOS Simulator build destination links x86_64 as well
# (Rosetta), so the simulator slice must be a fat arm64+x86_64
# archive — the same coverage BeeWare's Python.xcframework ships.
build_slice iphonesimulator "-mios-simulator-version-min=26.0" simulator-x86_64 x86_64
lipo -create "$WORK/libFFmpeg-simulator.a" "$WORK/libFFmpeg-simulator-x86_64.a" \
    -output "$WORK/libFFmpeg-simulator-fat.a"
mv "$WORK/libFFmpeg-simulator-fat.a" "$WORK/libFFmpeg-simulator.a"

echo "==> Collecting headers"
mkdir -p "$WORK/headers"
cp -R "$WORK/install-device/include/libavformat" "$WORK/headers/"
cp -R "$WORK/install-device/include/libavcodec" "$WORK/headers/"
cp -R "$WORK/install-device/include/libavfilter" "$WORK/headers/"
cp -R "$WORK/install-device/include/libswscale" "$WORK/headers/"
cp -R "$WORK/install-device/include/libswresample" "$WORK/headers/"
cp -R "$WORK/install-device/include/libavutil" "$WORK/headers/"

rm -rf "$VENDOR/FFmpeg"
mkdir -p "$VENDOR/FFmpeg"
cp -R "$WORK/headers" "$VENDOR/FFmpeg/include"

echo "==> Creating FFmpeg.xcframework"
rm -rf "$VENDOR/FFmpeg.xcframework"
xcodebuild -create-xcframework \
    -library "$WORK/libFFmpeg-device.a" -headers "$WORK/headers" \
    -library "$WORK/libFFmpeg-simulator.a" -headers "$WORK/headers" \
    -output "$VENDOR/FFmpeg.xcframework"

echo "==> Done. FFmpeg $FFMPEG_VERSION ready in Vendor/"
du -sh "$VENDOR/FFmpeg.xcframework" "$VENDOR/FFmpeg/include"
grep -m1 "License:" "$WORK/build-device/config.log" 2>/dev/null || true
