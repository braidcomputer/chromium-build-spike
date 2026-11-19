#!/usr/bin/env bash
# Does Siso's local cache (-local_cache_enable) give hits for a local-only build,
# after the out dir is deleted, and after source mtimes change?
set -uo pipefail
. "$(dirname "$0")/lib.sh"
T=${SMOKE_TARGET:-base}
cd "$SRC"
SISO=third_party/siso/cipd/siso
$SISO version 2>&1 | head -3
BASE='is_debug=false symbol_level=0 blink_symbol_level=0'
CD=$W/sisocache
build(){ # build <name> <siso flags...>
  local name=$1; shift
  local s=$(date +%s)
  $SISO ninja --offline -C out/S "$@" "$T" > "$LOGS/siso-$name.log" 2>&1
  local rc=$? e=$(date +%s)
  echo "RESULT $name rc=$rc secs=$((e-s)) $(grep -E '^noexec:|cache-write|Build|up-to-date' "$LOGS/siso-$name.log" | tr '\n' ' ')"
  [ "$rc" = 0 ] || tail -40 "$LOGS/siso-$name.log" | cut -c1-600
}
fresh(){ rm -rf out/S; gn gen out/S --args="$BASE" >/dev/null; }
fresh; build cold-cache-on -local_cache_enable -cache_dir "$CD"
du -sh "$CD" out/S
fresh; build warm-outdir-deleted -local_cache_enable -cache_dir "$CD"
du -sh "$CD" out/S
# does a fully built out dir survive all source mtimes changing?
find . -path ./out -prune -o -type f -name '*.cc' -newermt '2000-01-01' -print0 | xargs -0 touch
build after-touch-all-cc-cache-on -local_cache_enable -cache_dir "$CD"
find . -path ./out -prune -o -type f -name '*.cc' -print0 | xargs -0 touch
build after-touch-all-cc-cache-off
# mtimes older than outputs: nothing should rebuild
build noop
find . -path ./out -prune -o -type f -print0 | xargs -0 touch -h -t 202001010000
build after-set-all-src-mtimes-old
