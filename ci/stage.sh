#!/usr/bin/env bash
# One stage of the first build. usage: stage.sh <stage-number> <revision or empty>
# Writes status=running|finished to $GITHUB_OUTPUT.
set -uo pipefail
STAGE=$1; REV=${2:-}
JOB_START=${JOB_START:-$(date +%s)}
BUDGET_MIN=${BUDGET_MIN:-295}
. "$(dirname "$0")/lib.sh"
VARIANT=${VARIANT:-plain}
GN_ARGS='is_debug=false symbol_level=0 blink_symbol_level=0'
if [ "$VARIANT" = ccache ]; then
  if [ "$OSN" = Linux ]; then sudo apt-get update -q >/dev/null; sudo apt-get install -y -q ccache >/dev/null; else brew install ccache >/dev/null; fi
  export CCACHE_CONFIGPATH=$W/ccache.conf
  [ -f "$CCACHE_CONFIGPATH" ] || printf 'cache_dir = %s/ccache\nmax_size = 9G\nsloppiness = modules,time_macros,include_file_mtime,include_file_ctime\ndepend_mode = true\ncompiler_check = %%compiler%% --version\n' "$W" > "$CCACHE_CONFIGPATH"
  cat "$CCACHE_CONFIGPATH"; ccache --version | head -1
  GN_ARGS="$GN_ARGS cc_wrapper=\"$(command -v ccache)\""
fi
ts "stage${STAGE}_begin"
hw
mon_start
trap mon_stop EXIT

if [ "$STAGE" = 1 ]; then
  cd "$W"
  ts depot_tools_begin
  git clone -q --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git
  export DEPOT_TOOLS_UPDATE=1; gclient --version; export DEPOT_TOOLS_UPDATE=0
  mkdir -p chromium && cd chromium
  cat > .gclient <<'G'
solutions = [
  {
    "name": "src",
    "url": "https://chromium.googlesource.com/chromium/src.git",
    "managed": False,
    "custom_deps": {},
    "custom_vars": {},
  },
]
G
  ts sync_begin
  if [ -n "$REV" ]; then
    gclient sync --nohooks --no-history --revision "src@$REV" 2>&1 | grep -v 'Still working on\|^\[.*\]   ' | tail -100
  else
    gclient sync --nohooks --no-history 2>&1 | grep -v 'Still working on\|^\[.*\]   ' | tail -100
  fi
  rc=${PIPESTATUS[0]}; echo "sync rc=$rc"; [ "$rc" = 0 ] || exit 1
  ts sync_end
  cd "$SRC"
  echo "REVISION $(git rev-parse HEAD) $(tr '\n' ' ' < chrome/VERSION)"
  du -sh "$W/chromium" ; df -h "$W"
  if [ "$OSN" = Linux ]; then
    ts deps_begin
    sudo ./build/install-build-deps.sh --no-prompt --no-arm --no-chromeos-fonts --no-nacl --unsupported 2>&1 | tail -30 || echo "install-build-deps failed (continuing)"
    sudo apt-get install -y -q gperf 2>&1 | tail -2
    ts deps_end
  fi
  ts hooks_begin
  gclient runhooks 2>&1 | tail -60
  rc=${PIPESTATUS[0]}; echo "hooks rc=$rc"; [ "$rc" = 0 ] || exit 1
  ts hooks_end
  du -sh "$W/chromium"; df -h "$W"
  ts gn_begin
  gn gen out/Default --args="$GN_ARGS" || exit 1
  ts gn_end
fi

cd "$SRC"
cat out/Default/args.gn
DEADLINE=$((JOB_START + BUDGET_MIN*60))
echo "build deadline in $(( (DEADLINE - $(date +%s)) / 60 )) min"
ts "build${STAGE}_begin"
run_until "$DEADLINE" autoninja -C out/Default chrome
rc=$?
ts "build${STAGE}_end rc=$rc"
save_build_logs "stage$STAGE" Default
du -sh out/Default; df -h "$W"
if [ "$rc" = 124 ]; then
  echo "status=running" >> "$GITHUB_OUTPUT"
elif [ "$rc" = 0 ]; then
  echo "status=finished" >> "$GITHUB_OUTPUT"
  ls -la out/Default | head -80
  if [ "$OSN" = Linux ]; then ls -la out/Default/chrome; out/Default/chrome --version || true
  else du -sh out/Default/Chromium.app; out/Default/Chromium.app/Contents/MacOS/Chromium --version || true; fi
  du -sh "$W/chromium" "$SRC/out/Default" "$SRC/third_party" 2>/dev/null
else
  echo "status=failed" >> "$GITHUB_OUTPUT"
  echo "BUILD FAILED rc=$rc"
fi
PACK="chromium depot_tools"
if [ "$VARIANT" = ccache ]; then ccache -s -v; du -sh "$W/ccache"; PACK="$PACK ccache ccache.conf"; fi
ts pack_begin
pack "$W/pack" $PACK
if [ "$VARIANT" = ccache ] && [ "$rc" = 0 ]; then pack "$W/ccpack" ccache ccache.conf; fi
ts pack_end
mon_stop
echo "== monitor summary"
if [ "$OSN" = Linux ]; then
  awk '{for(i=1;i<=NF;i++){split($i,a,"="); if(a[2]+0>m[a[1]]) m[a[1]]=a[2]+0}} END{for(k in m) print "peak "k"="m[k]}' "$LOGS/monitor.log"
  awk '{for(i=1;i<=NF;i++){split($i,a,"="); if(a[1]=="avail_mb"||a[1]=="disk_free_mb"){ if(!(a[1] in m)||a[2]+0<m[a[1]]) m[a[1]]=a[2]+0}}} END{for(k in m) print "min "k"="m[k]}' "$LOGS/monitor.log"
else
  awk '{for(i=1;i<=NF;i++){split($i,a,"="); if(a[2]+0>m[a[1]]) m[a[1]]=a[2]+0}} END{for(k in m) print "peak "k"="m[k]}' "$LOGS/monitor.log"
  awk '{for(i=1;i<=NF;i++){split($i,a,"="); if(a[1]=="free_mb"||a[1]=="disk_free_mb"){ if(!(a[1] in m)||a[2]+0<m[a[1]]) m[a[1]]=a[2]+0}}} END{for(k in m) print "min "k"="m[k]}' "$LOGS/monitor.log"
fi
ts "stage${STAGE}_end"
[ "$rc" = 0 ] || [ "$rc" = 124 ]
