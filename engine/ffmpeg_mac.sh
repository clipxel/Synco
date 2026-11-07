#!/bin/sh
# Builds the ffmpeg that goes inside Synco.app: it reads the audio of whatever Apple's own reader
# can't open (MKV, AVI, WebM, MTS, WMV, FLV, MPEG-2…). Only what reading needs: every demuxer
# and decoder, no encoders but raw output, no network, no outside libraries (LGPL).
#   OUT=dir ./ffmpeg_mac.sh            this Mac's architecture
#   UNIVERSAL=1 OUT=dir ./ffmpeg_mac.sh  Apple silicon and Intel in one file
set -e
cd "$(dirname "$0")"
VER=8.1.3
SHA=${FFMPEG_SHA256:-}
OUT=${OUT:-.build/ffmpeg-mac}
WORK=${WORK:-.build/ffmpeg-src}
mkdir -p "$WORK" "$OUT"
OUT=$(cd "$OUT" && pwd)
cd "$WORK"
if [ ! -f "ffmpeg-$VER.tar.xz" ]; then
  curl -fsSL -o "ffmpeg-$VER.tar.xz.part" "https://ffmpeg.org/releases/ffmpeg-$VER.tar.xz"
  mv "ffmpeg-$VER.tar.xz.part" "ffmpeg-$VER.tar.xz"
fi
GOT=$(shasum -a 256 "ffmpeg-$VER.tar.xz" | cut -d' ' -f1)
EXPECTED=$(cat "$OLDPWD/ffmpeg_mac.sha256" 2>/dev/null || true)
[ -n "$SHA" ] && EXPECTED=$SHA
if [ -n "$EXPECTED" ] && [ "$GOT" != "$EXPECTED" ]; then echo "ffmpeg-$VER.tar.xz: suma distinta ($GOT)"; exit 1; fi

build() {
  ARCH=$1
  rm -rf "src-$ARCH" && mkdir "src-$ARCH" && tar -xJf "ffmpeg-$VER.tar.xz" -C "src-$ARCH" --strip-components=1
  cd "src-$ARCH"
  FLAGS="-arch $ARCH -mmacosx-version-min=13.0"
  CROSS=""
  [ "$ARCH" != "$(uname -m)" ] && CROSS="--enable-cross-compile --target-os=darwin"
  ./configure --cc=clang --arch="$ARCH" $CROSS --extra-cflags="$FLAGS" --extra-ldflags="$FLAGS" \
    --disable-everything --disable-autodetect --disable-network --disable-doc --disable-debug \
    --disable-ffplay --disable-ffprobe --disable-x86asm --enable-pthreads \
    --enable-demuxers --enable-parsers --enable-decoders --enable-bsfs \
    --enable-protocol=file,pipe \
    --enable-muxer=pcm_f32le,rawvideo,null --enable-encoder=pcm_f32le,rawvideo,wrapped_avframe \
    --enable-filter=amix,aresample,aformat,anull,null,format,scale,pan,atrim,trim,copy,acopy,setpts,asetpts \
    --enable-swresample --enable-swscale >/dev/null
  make -j"$(sysctl -n hw.ncpu)" ffmpeg >/dev/null
  strip ffmpeg
  cp ffmpeg "../ffmpeg-$ARCH"
  cp COPYING.LGPLv2.1 "$OUT/ffmpeg-LICENSE.txt"
  cd ..
}

if [ -n "$UNIVERSAL" ]; then
  build arm64
  build x86_64
  lipo -create ffmpeg-arm64 ffmpeg-x86_64 -output "$OUT/ffmpeg"
else
  build "$(uname -m)"
  cp "ffmpeg-$(uname -m)" "$OUT/ffmpeg"
fi
"$OUT/ffmpeg" -hide_banner -version | head -1
echo "ffmpeg: $OUT/ffmpeg"
