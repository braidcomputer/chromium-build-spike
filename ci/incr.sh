#!/usr/bin/env bash
# Incremental build measurements on an existing src+out tree.
# usage: incr.sh <noop|dry|cc|header> [cap-minutes]
set -uo pipefail
. "$(dirname "$0")/lib.sh"
WHAT=$1; CAP=${2:-300}
cd "$SRC"
CC=content/browser/renderer_host/render_widget_host_impl.cc
HDR=content/public/browser/web_contents.h
SISO=third_party/siso/cipd/siso
case $WHAT in
  dry)
    $SISO ninja --offline -n -C out/Default chrome > "$LOGS/incr-dry.log" 2>&1
    echo "RESULT dry rc=$? $(grep -E '^noexec:|Build|up-to-date' "$LOGS/incr-dry.log" | tr '\n' ' ')"
    exit 0;;
  noop) ;;
  cc) echo "// build-spike touch $(date -u +%FT%TZ)" >> $CC;;
  header) echo "// build-spike touch $(date -u +%FT%TZ)" >> $HDR;;
esac
statf(){ if [ "$OSN" = Linux ]; then stat -c '%y %N' "$@"; else stat -f '%Sm %N -> %Y' "$@"; fi; }
echo "== before $WHAT"; statf out/Default/build.ninja out/Default/toolchain.ninja out/Default/args.gn 2>&1; [ -d out/Default/sdk/xcode_links ] && statf out/Default/sdk/xcode_links/* 2>&1 | head -8
[ "$OSN" = Darwin ] && xcodebuild -version | tr '\n' ' '
mon_start; trap mon_stop EXIT
ts "incr_${WHAT}_begin"
s=$(date +%s)
run_until $((s + CAP*60)) autoninja -C out/Default chrome > "$LOGS/incr-$WHAT.log" 2>&1
rc=$?; e=$(date +%s)
ts "incr_${WHAT}_end rc=$rc"
echo "RESULT $WHAT rc=$rc secs=$((e-s)) $(grep -E '^noexec:|Build|up-to-date' "$LOGS/incr-$WHAT.log" | tr '\n' ' ')"
grep -E ' [SF] (LINK|SOLINK|SOLINK_MODULE|ACTION //chrome:|STAMP|COPY).*(chrome|Chromium)' "$LOGS/incr-$WHAT.log" | grep -E 'LINK' | tail -20 | cut -c1-200
tail -3 "$LOGS/incr-$WHAT.log" | cut -c1-300
echo "== after $WHAT"; statf out/Default/build.ninja out/Default/toolchain.ninja 2>&1; [ -d out/Default/sdk/xcode_links ] && statf out/Default/sdk/xcode_links/* 2>&1 | head -8
grep -a -m3 'Regenerating' "$LOGS/incr-$WHAT.log" | cut -c1-200
save_build_logs "incr-$WHAT" Default
[ "$rc" = 0 ] || [ "$rc" = 124 ]
