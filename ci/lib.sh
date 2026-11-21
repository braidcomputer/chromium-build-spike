# shared helpers; source me
W=$HOME/cbs
SRC=$W/chromium/src
LOGS=$W/logs
mkdir -p "$W" "$LOGS"
export PATH=$W/depot_tools:$PATH
export DEPOT_TOOLS_UPDATE=0
OSN=$(uname)
TAR=tar; command -v gtar >/dev/null && TAR=gtar
ts(){ echo "TS $1 $(date +%s) $(date -u +%FT%TZ)" | tee -a "$LOGS/ts.log"; }
hw(){
  echo "== hardware"
  if [ "$OSN" = Linux ]; then
    nproc; lscpu | grep -E 'Model name|^CPU\(s\)'; free -m; df -h /
  else
    sysctl -n hw.ncpu hw.memsize machdep.cpu.brand_string; sysctl vm.swapusage; df -h /System/Volumes/Data
    xcodebuild -version
  fi
}
mon_start(){
  (
    while true; do
      if [ "$OSN" = Linux ]; then
        m=$(free -m | awk '/Mem:/{u=$3; a=$7} /Swap:/{s=$3} END{print "used_mb="u" avail_mb="a" swap_mb="s}')
        d=$(df -m / | awk 'NR==2{print "disk_used_mb="$3" disk_free_mb="$4}')
      else
        m=$(vm_stat | awk '/Pages free/{f=$3} /Pages active/{a=$3} /Pages inactive/{i=$3} /Pages wired/{w=$4} /occupied by compressor/{c=$5} END{ps=16384/1048576; printf "free_mb=%d active_mb=%d inactive_mb=%d wired_mb=%d compressor_mb=%d", f*ps,a*ps,i*ps,w*ps,c*ps}')
        m="$m swap=$(sysctl -n vm.swapusage | awk '{print $6}')"
        d=$(df -m /System/Volumes/Data | awk 'NR==2{print "disk_used_mb="$3" disk_free_mb="$4}')
      fi
      echo "MON $(date +%s) load=$(uptime | sed 's/.*averages*: *//' | cut -d' ' -f1 | tr -d ,) $m $d"
      sleep 30
    done
  ) >> "$LOGS/monitor.log" 2>&1 &
  echo $! > "$W/mon.pid"
}
mon_stop(){ [ -f "$W/mon.pid" ] && kill "$(cat "$W/mon.pid")" 2>/dev/null || true; }
# run a command in its own process group until deadline (epoch); INT the group on timeout.
# returns 124 on timeout, else the command's status
run_until(){
  local deadline=$1; shift
  python3 -c 'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' "$@" &
  local pid=$!
  while kill -0 $pid 2>/dev/null; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "run_until: deadline reached, sending INT to group $pid"
      kill -INT -- -$pid 2>/dev/null
      for i in $(seq 1 60); do kill -0 $pid 2>/dev/null || break; sleep 5; done
      if kill -0 $pid 2>/dev/null; then echo "run_until: KILL"; kill -KILL -- -$pid 2>/dev/null; fi
      wait $pid 2>/dev/null
      return 124
    fi
    sleep 10
  done
  wait $pid
}
pack(){ # pack <outdir> <paths relative to $W ...>
  local o=$1; shift
  mkdir -p "$o"
  $TAR --format=posix -C "$W" -cf - "$@" | zstd -T0 -3 -q | split -b 1900m - "$o/part."
  ls -la "$o"; du -sh "$o"
}
unpack(){ # unpack <dir with parts>
  cat "$1"/part.* | zstd -d -q | $TAR -C "$W" -xf -
  rm -rf "$1"
}
save_build_logs(){ # copy small siso logs for later analysis
  local tag=$1 o=$SRC/out/$2
  mkdir -p "$LOGS/$tag"
  for f in .ninja_log siso_metrics.json siso_output siso_failed_commands.sh siso_localexec args.gn; do
    [ -f "$o/$f" ] && cp "$o/$f" "$LOGS/$tag/" || true
  done
  gzip -f "$LOGS/$tag"/siso_localexec 2>/dev/null || true
  if [ -f "$o/siso_explain" ]; then
    head -400 "$o/siso_explain" | cut -c1-600 > "$LOGS/$tag/siso_explain.head"
    echo "EXPLAIN $tag lines=$(wc -l < "$o/siso_explain")"; head -6 "$o/siso_explain" | cut -c1-500
    sed -E 's/[^ ]+\.(o|pcm|h|cc|a|rlib|dylib|json|py|ninja)//g' "$o/siso_explain" | cut -c1-100 | sort | uniq -c | sort -rn | head -8
  fi
}
pin_sdk_mtimes(){ # macOS: give Xcode SDK/toolchain files one fixed mtime so Siso state stays valid on another runner VM
  [ "$OSN" = Darwin ] || return 0
  local D; D=$(xcode-select -p)
  sudo find "$D/Platforms/MacOSX.platform" "$D/Toolchains/XcodeDefault.xctoolchain" \( -type f -o -type l \) -exec touch -h -t 202001010000 {} + 2>&1 | tail -3
}
