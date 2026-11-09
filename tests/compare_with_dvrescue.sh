#!/bin/sh
# Compare OldDV Rescue XML output with the original dvrescue on damaged files.
# usage: tests/compare_with_dvrescue.sh /path/to/dvrescue OLDDV_BIN WORKDIR SRC.dv [SRC2.dv ...]
# Seeds can be set with SEEDS="1 2 3".
REF=$1; MY=$2; W=$3; shift 3
SEEDS=${SEEDS:-"1 2 3 4 5 6 7 8 9 10"}
mkdir -p "$W"; fail=0; total=0
for src in "$@"; do for seed in $SEEDS; do
  python3 "$(dirname "$0")/inject.py" "$src" "$W/t.dv" "$seed"
  "$REF" "$W/t.dv" 2>/dev/null | sed -e '/<creator>/,/<\/creator>/d' -e '1,2d' > "$W/ref.xml"
  "$MY" "$W/t.dv" | sed -e '/<creator>/,/<\/creator>/d' -e '1,2d' > "$W/my.xml"
  total=$((total+1))
  if ! cmp -s "$W/ref.xml" "$W/my.xml"; then
    fail=$((fail+1)); echo "DIFF: $(basename "$src") seed $seed ($(diff "$W/ref.xml" "$W/my.xml" | grep -c '^[<>]') lines)"
    cp "$W/t.dv" "$W/fail_$(basename "$src" .dv)_$seed.dv"
  fi
done; done
echo "$((total-fail))/$total identical"
