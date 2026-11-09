#!/bin/sh
# Self test of the olddv analysis / merge / split (Linux or Mac).
# Needs ffmpeg (to make a test DV file) and python3.
#   tests/run_tests.sh [path/to/olddv]
set -e
cd "$(dirname "$0")/.."
OLDDV=${1:-build/olddv}
if [ ! -x "$OLDDV" ]; then
  mkdir -p build
  cc -std=gnu99 -O2 -D_FILE_OFFSET_BITS=64 -o build/olddv src/cli/olddv.c src/core/*.c -lm
  OLDDV=build/olddv
fi
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
fail=0
check() { if eval "$2"; then echo "ok   - $1"; else echo "FAIL - $1"; fail=1; fi; }

ffmpeg -loglevel error -y -f lavfi -i testsrc=size=720x480:rate=30000/1001 -f lavfi -i sine=frequency=440:sample_rate=48000 \
  -t 6 -c:v dvvideo -pix_fmt yuv411p -c:a pcm_s16le -ac 2 -timecode 01:00:00:00 -f dv "$W/clean.dv"

"$OLDDV" -s "$W/clean.dv" > "$W/s.txt"
check "clean NTSC file: 179 frames, no issue" "grep -q 'Frames: *179' $W/s.txt && grep -q 'Frames with issues: *0' $W/s.txt"
"$OLDDV" "$W/clean.dv" -x "$W/clean.xml"
check "XML report written" "grep -q '<frames count=\"179\"' $W/clean.xml"
if command -v xmllint >/dev/null 2>&1; then
  check "XML well formed" "xmllint --noout $W/clean.xml"
fi

python3 tests/inject.py "$W/clean.dv" "$W/take1.dv" 11
python3 tests/inject.py "$W/clean.dv" "$W/take2.dv" 22
python3 tests/inject.py "$W/clean.dv" "$W/take3.dv" 33
"$OLDDV" -s "$W/take1.dv" > "$W/t1.txt"
check "damaged take has issues" "! grep -q 'Frames with issues: *0' $W/t1.txt"

"$OLDDV" "$W/take1.dv" "$W/take2.dv" "$W/take3.dv" -m "$W/merged.dv" --merge-log "$W/merge.log" -s > "$W/m.txt"
check "merge keeps all 179 frames" "grep -q 'Frames: *179' $W/m.txt"
b1=$("$OLDDV" --csv "$W/take1.dv" | awk -F, 'NR>1{s+=$11+$13} END{print s+0}')
bm=$("$OLDDV" --csv "$W/merged.dv" | awk -F, 'NR>1{s+=$11+$13} END{print s+0}')
check "merge reduces bad blocks ($b1 -> $bm)" "[ $bm -lt $b1 ]"

# two recordings: split
cat "$W/clean.dv" "$W/clean.dv" > "$W/two.dv"
"$OLDDV" "$W/two.dv" --split "$W/part" --by tc > "$W/parts.txt"
check "split at time code break gives 2 parts" "[ \$(wc -l < $W/parts.txt) -eq 2 ]"

[ $fail = 0 ] && echo "All tests passed." || { echo "Some tests failed."; exit 1; }
