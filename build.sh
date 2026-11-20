#!/bin/sh
# Build "OldDV Rescue.app" and the "olddv" command line tool on a Mac.
#
# Works with:
#   - Mac OS X 10.6 + Xcode 3.2.6 (or Xcode 4.2)       -> QTKit engine
#   - OS X 10.11 + Xcode 7/8 or the Command Line Tools  -> QTKit + AVFoundation engines
# The resulting app runs on 10.6 and later (64-bit Intel).
#   - macOS 10.15 and later (no QTKit)                   -> build/modern: the app
#     without capture, to analyze, merge and export on a current Mac
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
FRAMEWORKS="-framework Cocoa -framework QTKit -framework IOKit -framework QuartzCore"
MODERN=""
if [ ! -f "$SDK/System/Library/Frameworks/QTKit.framework/Headers/QTKit.h" ]; then
  # macOS 10.15 and later: no QTKit, so no capture on this Mac. The app is
  # built for this machine only, to analyze, merge and export captures
  # made on an older Mac. It does not run on the old Mac.
  MODERN=1
  OUT=build/modern
  APP="$OUT/OldDV Rescue.app"
  FLAGS="-arch $(uname -m) -mmacosx-version-min=11.0 -isysroot $SDK -O2 -DOLDDV_MODERN -fno-objc-arc"
  FRAMEWORKS="-framework Cocoa -framework AVFoundation -framework CoreMedia -framework IOKit -framework QuartzCore"
  echo "No QTKit in this SDK: building the version without capture (analyze, merge, export) for this Mac"
fi
CFLAGS="$FLAGS -std=gnu99 -Wall -Wno-deprecated-declarations -Isrc/core -D_FILE_OFFSET_BITS=64"
rm -rf "$OUT/obj" "$APP"
mkdir -p "$OUT/obj" "$APP/Contents/MacOS" "$APP/Contents/Resources"

OBJS=""
for f in src/core/dvanalyze.c src/core/dvreport.c src/core/dvmerge.c src/core/dvsplit.c src/core/dvmov.c src/core/dvwriter.c src/core/dvmirror.c src/core/dvmkv.c src/core/dvcc.c src/core/dvcapture.c; do
  o="$OUT/obj/$(basename "$f" .c).o"
  $CC $CFLAGS -c "$f" -o "$o"
  OBJS="$OBJS $o"
done
APPOBJS=""
for f in OVApp OVCapture OVDeck OVEngine OVViews OVPlayer OVMovie OVShare; do
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

$CC $FLAGS $APPOBJS $OBJS $FRAMEWORKS \
    -o "$APP/Contents/MacOS/OldDV Rescue"
$CC $CFLAGS src/cli/olddv.c $OBJS -o "$OUT/olddv"
cp "$OUT/olddv" "$APP/Contents/Resources/olddv"
cp mac/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
[ -f mac/OldDV.icns ] && cp mac/OldDV.icns "$APP/Contents/Resources/"
if [ -n "$MODERN" ]; then
  # this build is for the Mac it was made on
  /usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion 11.0" -c "Delete :LSArchitecturePriority" "$APP/Contents/Info.plist"
  codesign --force -s - "$APP" 2>/dev/null || true
fi
echo "Built: $APP"
echo "Command line tool: $OUT/olddv"

if [ "$1" = "install" ]; then
  rm -rf "/Applications/OldDV Rescue.app"
  cp -R "$APP" /Applications/
  echo "Installed in /Applications"
fi
