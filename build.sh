#!/bin/sh
# Build "OldDV Rescue.app" and the "olddv" command line tool on a Mac.
#
# Works with:
#   - Mac OS X 10.6 + Xcode 3.2.6 (or Xcode 4.2)       -> QTKit engine
#   - OS X 10.11 + Xcode 7/8 or the Command Line Tools  -> QTKit + AVFoundation engines
# The resulting app runs on 10.6 and later (64-bit Intel).
#
#   ./build.sh              build into build/
#   ./build.sh install      also copy the app to /Applications
set -e
cd "$(dirname "$0")"

CC=${CC:-cc}
SDK=${SDK:-}
if [ -z "$SDK" ]; then
  SDK=$(xcrun --show-sdk-path 2>/dev/null || true)
fi
if [ -z "$SDK" ] || [ ! -d "$SDK" ]; then
  for s in /Developer/SDKs/MacOSX10.6.sdk /Developer/SDKs/MacOSX10.7.sdk /; do
    [ -d "$s/System/Library/Frameworks/Cocoa.framework" ] && SDK=$s && break
  done
fi
echo "Using SDK: $SDK"
echo "Using compiler: $($CC --version 2>&1 | head -1)"

OUT=build
APP="$OUT/OldDV Rescue.app"
FLAGS="-arch x86_64 -mmacosx-version-min=10.6 -isysroot $SDK -O2"
CFLAGS="$FLAGS -std=gnu99 -Wall -Wno-deprecated-declarations -Isrc/core -D_FILE_OFFSET_BITS=64"
rm -rf "$OUT/obj" "$APP"
mkdir -p "$OUT/obj" "$APP/Contents/MacOS" "$APP/Contents/Resources"

OBJS=""
for f in src/core/dvanalyze.c src/core/dvreport.c src/core/dvmerge.c src/core/dvsplit.c; do
  o="$OUT/obj/$(basename "$f" .c).o"
  $CC $CFLAGS -c "$f" -o "$o"
  OBJS="$OBJS $o"
done
APPOBJS=""
for f in OVApp OVCapture OVDeck OVEngine OVViews; do
  $CC $CFLAGS -fobjc-exceptions -c "src/mac/$f.m" -o "$OUT/obj/$f.o"
  APPOBJS="$APPOBJS $OUT/obj/$f.o"
done
if [ -d "$SDK/System/Library/Frameworks/AVFoundation.framework/Headers" ] && \
   grep -q AVCaptureVideoDataOutput "$SDK/System/Library/Frameworks/AVFoundation.framework/Headers/"*.h 2>/dev/null; then
  $CC $CFLAGS -fobjc-exceptions -DOLDDV_HAVE_AVF -c src/mac/OVCaptureAVF.m -o "$OUT/obj/OVCaptureAVF.o"
  APPOBJS="$APPOBJS $OUT/obj/OVCaptureAVF.o"
  echo "AVFoundation engine: included"
else
  echo "AVFoundation engine: not included (SDK has no AVFoundation capture; QTKit will be used)"
fi

$CC $FLAGS $APPOBJS $OBJS -framework Cocoa -framework QTKit -framework IOKit -framework QuartzCore \
    -o "$APP/Contents/MacOS/OldDV Rescue"
$CC $CFLAGS src/cli/olddv.c $OBJS -o "$OUT/olddv"
cp "$OUT/olddv" "$APP/Contents/Resources/olddv"
cp mac/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
[ -f mac/OldDV.icns ] && cp mac/OldDV.icns "$APP/Contents/Resources/"
echo "Built: $APP"
echo "Command line tool: $OUT/olddv"

if [ "$1" = "install" ]; then
  rm -rf "/Applications/OldDV Rescue.app"
  cp -R "$APP" /Applications/
  echo "Installed in /Applications"
fi
