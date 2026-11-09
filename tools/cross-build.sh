#!/bin/sh
# Cross-compile OldDV Rescue.app for Mac OS X 10.6+ (x86_64) on Linux with
# clang + ld64.lld. Needs the MacOSX10.6.sdk (and optionally a 10.7+ SDK,
# e.g. MacOSX10.11.sdk, for the AVFoundation capture engine).
#
#   SDK106=/path/MacOSX10.6.sdk SDK_AVF=/path/MacOSX10.11.sdk tools/cross-build.sh
#
# On a Mac, use ./build.sh instead (native compiler, no patching needed).
set -e
cd "$(dirname "$0")/.."
: "${SDK106:?set SDK106 to a MacOSX10.6.sdk}"
OUT=${OUT:-build/mac}
APP="$OUT/OldDV Rescue.app"
CC=${CC:-clang}
TARGET="-target x86_64-apple-macosx10.6"
CFLAGS="$TARGET -isysroot $SDK106 -O2 -Wall -Wno-deprecated-declarations -Wno-unused-parameter -fno-objc-arc -Isrc/core -D_FILE_OFFSET_BITS=64"
rm -rf "$OUT/obj" "$APP"
mkdir -p "$OUT/obj" "$APP/Contents/MacOS" "$APP/Contents/Resources"

for f in src/core/*.c; do
  $CC $CFLAGS -std=gnu99 -c "$f" -o "$OUT/obj/$(basename "$f" .c).o"
done
$CC $CFLAGS -c tools/crt_start_10_6.c -o "$OUT/obj/crt.o"
for f in OVApp OVCapture OVDeck OVEngine OVViews; do
  $CC $CFLAGS -std=gnu99 -fobjc-exceptions -c "src/mac/$f.m" -o "$OUT/obj/$f.o"
done

AVF_LINK=""
if [ -n "$SDK_AVF" ] && [ -d "$SDK_AVF/System/Library/Frameworks/AVFoundation.framework" ]; then
  # compiled against the newer SDK, deployment target stays 10.6
  $CC -target x86_64-apple-macosx10.6 -isysroot "$SDK_AVF" -O2 -Wno-deprecated-declarations -Wno-unguarded-availability \
      -Wno-objc-method-access -fno-objc-arc -Isrc/core -DOLDDV_HAVE_AVF -c src/mac/OVCaptureAVF.m -o "$OUT/obj/OVCaptureAVF.o"
  # AVFoundation / CoreMedia are dlopen()ed at run time: nothing to link
  AVF_LINK="$OUT/obj/OVCaptureAVF.o"
  echo "AVFoundation engine: included"
else
  echo "AVFoundation engine: not included (set SDK_AVF to a 10.7+ SDK)"
fi

LDFLAGS="$TARGET -isysroot $SDK106 -fuse-ld=lld -nostartfiles -Wl,-e,start -Wl,-headerpad,0x2000"
$CC $LDFLAGS "$OUT/obj/crt.o" "$OUT/obj/OVApp.o" "$OUT/obj/OVCapture.o" "$OUT/obj/OVDeck.o" "$OUT/obj/OVEngine.o" "$OUT/obj/OVViews.o" "$OUT"/obj/dv*.o $AVF_LINK \
    -framework Cocoa -framework QTKit -framework IOKit -framework QuartzCore \
    -o "$APP/Contents/MacOS/OldDV Rescue"
$CC $CFLAGS -std=gnu99 -c src/cli/olddv.c -o "$OUT/obj/olddv_cli.o"
$CC $LDFLAGS "$OUT/obj/crt.o" "$OUT/obj/olddv_cli.o" "$OUT"/obj/dv*.o -o "$APP/Contents/Resources/olddv"
python3 tools/macho_unixthread.py "$APP/Contents/MacOS/OldDV Rescue" "$APP/Contents/Resources/olddv"

cp mac/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
[ -f mac/OldDV.icns ] && cp mac/OldDV.icns "$APP/Contents/Resources/"
echo "Built $APP"
