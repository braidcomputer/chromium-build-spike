#!/usr/bin/env bash
# Fresh shallow checkout + hooks. usage: setup.sh <revision or empty>
set -uo pipefail
REV=${1:-}
. "$(dirname "$0")/lib.sh"
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
gclient sync --nohooks --no-history ${REV:+--revision "src@$REV"} 2>&1 | grep -v 'Still working on\|^\[.*\]   ' | tail -40
rc=${PIPESTATUS[0]}; echo "sync rc=$rc"; [ "$rc" = 0 ] || exit 1
ts sync_end
cd "$SRC"
echo "REVISION $(git rev-parse HEAD) $(tr '\n' ' ' < chrome/VERSION)"
if [ "$OSN" = Linux ]; then
  ts deps_begin
  sudo ./build/install-build-deps.sh --no-prompt --no-arm --no-chromeos-fonts --no-nacl --unsupported 2>&1 | tail -15 || echo "install-build-deps failed (continuing)"
  sudo apt-get install -y -q gperf 2>&1 | tail -2
  ts deps_end
fi
ts hooks_begin
gclient runhooks 2>&1 | tail -20
rc=${PIPESTATUS[0]}; echo "hooks rc=$rc"; [ "$rc" = 0 ] || exit 1
ts hooks_end
du -sh "$W/chromium"; df -h "$W"
