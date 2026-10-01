#!/bin/bash
# mkpatch_v21.sh — port618/{orig,work} 의 차이로 0009 패치를 만든다.
# 경로 접두사를 a/ b/ 로 고쳐서 커널 트리에 -p1 로 적용되게 한다.
set -eu
OUT=~/lab/reports/patches/0009-v21.patch
cd ~/lab/kernel/port618
diff -urN --no-dereference orig work > "$OUT" || true
sed -i 's|^--- orig/|--- a/|; s|^+++ work/|+++ b/|' "$OUT"
# 순정 사본에 실제로 적용되는지 확인한다. 안 되면 패치를 내보내지 않는다.
T=$(mktemp -d)
cp -r orig "$T/t"
( cd "$T/t" && patch -p1 --dry-run -s < "$OUT" ) || { rm -rf "$T"; echo "FATAL dry-run 실패"; exit 1; }
rm -rf "$T"
echo "OK $OUT  ($(wc -l < "$OUT") lines, $(grep -c '^+++' "$OUT") files)"
