#!/bin/sh
# Self test of the olddv analysis / merge / split (Linux or Mac).
# Needs ffmpeg (to make a test DV file) and python3.
#   tests/run_tests.sh [path/to/olddv]
set -e
cd "$(dirname "$0")/.."
OLDDV=${1:-build/olddv}
if [ ! -x "$OLDDV" ]; then
  mkdir -p build
  cc -std=gnu99 -O2 -D_FILE_OFFSET_BITS=64 -o build/olddv src/cli/olddv.c src/core/*.c -lm -lpthread
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

# lossless QuickTime rewrap: video and audio identical to the DV
"$OLDDV" "$W/clean.dv" --mov "$W/clean.mov" 2>/dev/null
v1=$(ffmpeg -v error -i "$W/clean.dv" -map 0:v -f framemd5 - | grep -v '^#' | awk -F, '{print $6}' | md5sum)
v2=$(ffmpeg -v error -i "$W/clean.mov" -map 0:v -f framemd5 - | grep -v '^#' | awk -F, '{print $6}' | md5sum)
a1=$(ffmpeg -v error -i "$W/clean.dv" -map 0:a:0 -f s16le - | md5sum)
a2=$(ffmpeg -v error -i "$W/clean.mov" -map 0:a:0 -f s16le - | md5sum)
check ".mov rewrap keeps DV video bit-exact" "[ \"$v1\" = \"$v2\" ]"
check ".mov rewrap audio identical to ffmpeg's DV decode" "[ \"$a1\" = \"$a2\" ]"

# lossless Matroska rewrap: same video frames, same audio as the .mov
"$OLDDV" "$W/clean.dv" --mkv "$W/clean.mkv" 2>/dev/null
v3=$(ffmpeg -v error -i "$W/clean.mkv" -map 0:v -f framemd5 - | grep -v '^#' | awk -F, '{print $6}' | md5sum)
a5=$(ffmpeg -v error -i "$W/clean.mkv" -map 0:a:0 -f s16le - | md5sum)
check ".mkv rewrap keeps DV video bit-exact" "[ \"$v1\" = \"$v3\" ]"
check ".mkv rewrap audio identical to the .mov" "[ \"$a2\" = \"$a5\" ]"
check ".mkv can be seeked (cues)" "ffmpeg -v error -ss 4 -i $W/clean.mkv -frames:v 1 -f null - 2>&1 | wc -c | grep -q '^ *0$'"

# closed captions: pop-on captions in field 1, roll-up in field 2
python3 tests/ccinject.py "$W/clean.dv" "$W/cc.dv"
"$OLDDV" "$W/cc.dv" --scc "$W/cc.scc" --srt "$W/cc.srt" --vtt "$W/cc.vtt" 2>/dev/null
"$OLDDV" "$W/cc.dv" --cc-field 2 --srt "$W/cc2.srt" 2>/dev/null
check "captions: .scc has the raw data" "grep -q '^00:00:00;20.9420 9420 94ae 94ae 9440 9440 c845 4c4c' $W/cc.scc"
check "captions: pop-on text and timing in .srt" "grep -A2 '00:00:01,335 --> 00:00:02,669' $W/cc.srt | tr '\n' '|' | grep -q 'HELLO THERE|SECOND LINE'"
check "captions: extended character" "grep -q 'CAFÉ' $W/cc.srt"
check "captions: WebVTT" "head -1 $W/cc.vtt | grep -q WEBVTT && grep -q '00:00:01.335 --> 00:00:02.669' $W/cc.vtt"
check "captions: roll-up in field 2" "grep -A2 ' --> 00:00:04,004' $W/cc2.srt | tr '\n' '|' | grep -q 'ROLL ONE|ROLL TWO'"
if "$OLDDV" "$W/clean.dv" --srt "$W/none.srt" 2>/dev/null; then nocc=0; else nocc=1; fi
check "captions: a file without captions gives no .srt" "[ $nocc = 1 ] && [ ! -e $W/none.srt ]"

# merge of a tape whose time code restarts (same time codes twice): the
# first take is the timeline, nothing may be lost or reordered
python3 tests/inject.py "$W/two.dv" "$W/two_a.dv" 5
python3 tests/inject.py "$W/two.dv" "$W/two_b.dv" 6
"$OLDDV" "$W/two.dv" "$W/two_a.dv" -m "$W/two_m.dv" 2>/dev/null
check "merge with a clean first take returns it unchanged" "cmp -s $W/two.dv $W/two_m.dv"
"$OLDDV" "$W/two_a.dv" "$W/two_b.dv" "$W/two.dv" -m "$W/two_m2.dv" -s 2>/dev/null > "$W/m2.txt"
# a take that was cut off in the middle of a frame (interrupted capture)
head -c 12050000 "$W/take2.dv" > "$W/cut.dv"
"$OLDDV" "$W/take1.dv" "$W/cut.dv" -m "$W/cut_m.dv" > /dev/null 2>&1
check "merge ignores the incomplete last frame of a cut-off take" "[ \$(( \$(wc -c < $W/cut_m.dv) % 120000 )) -eq 0 ]"

check "merge with repeated time codes keeps all 358 frames" "grep -q 'Frames: *358' $W/m2.txt"
check "merge with repeated time codes repairs everything" "grep -q 'Frames with issues: *0' $W/m2.txt || grep -q 'video errors: *0 frames' $W/m2.txt"

# audio repair: error codes on every other track (one head cannot read the
# audio) must be interpolated, not played as silence
python3 - "$W/clean.dv" "$W/audbad.dv" <<'PY'
import sys
d = bytearray(open(sys.argv[1], 'rb').read())
for fr in range(0, len(d), 120000):
    for dseq in range(1, 10, 2):
        for blk in range(150):
            o = fr + dseq * 12000 + blk * 80
            if d[o] & 0xE0 == 0x60:
                d[o + 8:o + 80] = b"\x80\x00" * 36
open(sys.argv[2], 'wb').write(d)
PY
"$OLDDV" "$W/clean.dv" --wav "$W/ref.wav" 2>/dev/null
"$OLDDV" "$W/audbad.dv" --wav "$W/fixed.wav" 2>/dev/null
"$OLDDV" "$W/audbad.dv" --wav "$W/silent.wav" --no-audio-repair 2>/dev/null
ratio=$(python3 - "$W/ref.wav" "$W/fixed.wav" "$W/silent.wav" <<'PY'
import sys, array
def rd(p):
    a = array.array('h'); a.frombytes(open(p, 'rb').read()[44:]); return a
r, f, s = rd(sys.argv[1]), rd(sys.argv[2]), rd(sys.argv[3])
ef = sum((x - y) ** 2 for x, y in zip(r, f)); es = sum((x - y) ** 2 for x, y in zip(r, s))
print(int(100 * ef / es) if es and len(r) == len(f) == len(s) else 999)
PY
)
check "audio repair: error is ${ratio}% of the error left by silence (must be under 5%)" "[ $ratio -lt 5 ]"
a3=$(ffmpeg -v error -i "$W/audbad.dv" -map 0:a:0 -f s16le - | md5sum)
a4=$(tail -c +45 "$W/silent.wav" | md5sum)
check "without repair the audio is ffmpeg's decode" "[ \"$a3\" = \"$a4\" ]"

# background copy: the source is still growing and the destination folder
# does not exist at first (a share that is not there yet)
( : > "$W/grow.dv"
  for i in 0 1 2 3 4 5; do dd if="$W/clean.dv" bs=3000000 skip=$i count=1 2>/dev/null >> "$W/grow.dv"; sleep 0.3; done
  tail -c +18000001 "$W/clean.dv" >> "$W/grow.dv"; touch "$W/grow.done" ) &
( sleep 1; mkdir -p "$W/share" ) &
"$OLDDV" "$W/grow.dv" --copy-to "$W/share/grow.dv" --copy-until "$W/grow.done" > "$W/copy.txt" 2>&1 || true
wait
check "copy of a growing file to a late destination is complete" "cmp -s $W/clean.dv $W/share/grow.dv"
check "copy reports the interruption" "grep -q 'verified: 21480000 bytes, 1 interruption' $W/copy.txt"

[ $fail = 0 ] && echo "All tests passed." || { echo "Some tests failed."; exit 1; }
