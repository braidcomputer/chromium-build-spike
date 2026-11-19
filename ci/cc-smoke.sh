#!/usr/bin/env bash
# Does a compiler cache get hits on Chromium's current (clang modules) build?
# Builds a small target cold then again from an empty out dir, per variant.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
SMOKE_TARGET=${SMOKE_TARGET:-base}
cd "$SRC"
BASE='is_debug=false symbol_level=0 blink_symbol_level=0'
CCACHE=$(command -v ccache); SCCACHE=$(command -v sccache)
ccache --version | head -1; sccache --version
mkdir -p ~/.config/ccache
run(){ # run <name> <extra gn args>
  local name=$1 args=$2
  for pass in cold warm; do
    rm -rf out/S
    gn gen out/S --args="$BASE $args" >/dev/null || { echo "RESULT $name gn failed"; return; }
    local s=$(date +%s)
    autoninja -C out/S "$SMOKE_TARGET" > "$LOGS/smoke-$name-$pass.log" 2>&1
    local rc=$? e=$(date +%s)
    echo "RESULT $name $pass rc=$rc secs=$((e-s)) $(tail -5 "$LOGS/smoke-$name-$pass.log" | grep -E 'local:|Build' | tr '\n' ' ')"
    [ "$rc" = 0 ] || tail -30 "$LOGS/smoke-$name-$pass.log"
  done
}
# 0. baseline, no wrapper
run none ''
# 1. ccache, default config
printf 'max_size = 9G\n' > ~/.config/ccache/ccache.conf
ccache -C >/dev/null; ccache -z >/dev/null
run ccache-default "cc_wrapper=\"$CCACHE\""
ccache -s -v | sed 's/^/  ccache-default: /'
# 2. ccache, modules sloppiness + depend mode
printf 'max_size = 9G\nsloppiness = modules,time_macros,include_file_mtime,include_file_ctime\ndepend_mode = true\n' > ~/.config/ccache/ccache.conf
ccache -C >/dev/null; ccache -z >/dev/null
run ccache-modules "cc_wrapper=\"$CCACHE\""
ccache -s -v | sed 's/^/  ccache-modules: /'
# 3. ccache, clang modules off
printf 'max_size = 9G\nsloppiness = time_macros,include_file_mtime,include_file_ctime\n' > ~/.config/ccache/ccache.conf
ccache -C >/dev/null; ccache -z >/dev/null
run ccache-nomodules "cc_wrapper=\"$CCACHE\" use_clang_modules=false"
ccache -s -v | sed 's/^/  ccache-nomodules: /'
run none-nomodules 'use_clang_modules=false'
# 4. sccache with modules
export SCCACHE_DIR=$W/sccache SCCACHE_CACHE_SIZE=9G
sccache --stop-server >/dev/null 2>&1; sccache --start-server
run sccache "cc_wrapper=\"$SCCACHE\""
sccache --show-stats | sed 's/^/  sccache: /'
# 5. sccache, modules off
sccache --stop-server >/dev/null 2>&1; rm -rf "$SCCACHE_DIR"; sccache --start-server
run sccache-nomodules "cc_wrapper=\"$SCCACHE\" use_clang_modules=false"
sccache --show-stats | sed 's/^/  sccache-nomodules: /'
