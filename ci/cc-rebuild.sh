#!/usr/bin/env bash
# Full build from an empty out dir on a fresh checkout, with a warm ccache.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
cd "$SRC"
export CCACHE_CONFIGPATH=$W/ccache.conf
cat "$CCACHE_CONFIGPATH"; ccache -z >/dev/null; du -sh "$W/ccache"
mon_start; trap mon_stop EXIT
gn gen out/Default --args="is_debug=false symbol_level=0 blink_symbol_level=0 cc_wrapper=\"$(command -v ccache)\"" || exit 1
ts ccrebuild_begin
s=$(date +%s)
run_until $((s + ${1:-300}*60)) autoninja -C out/Default chrome > "$LOGS/cc-rebuild.log" 2>&1
rc=$?; e=$(date +%s)
ts "ccrebuild_end rc=$rc"
echo "RESULT cc-rebuild rc=$rc secs=$((e-s)) $(grep -E '^noexec:|Build' "$LOGS/cc-rebuild.log" | tr '\n' ' ')"
tail -5 "$LOGS/cc-rebuild.log" | cut -c1-300
ccache -s -v
save_build_logs cc-rebuild Default
du -sh out/Default
