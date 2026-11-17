#!/bin/sh
# 监视所有 switch port 的 link，外加网口列表变化
. "${V150_LIB:-$(dirname "$0")/../scripts/v150_sw.sh}" 2>/dev/null
SECS=${1:-180}
prev=""; prevn=$(ls /sys/class/net | tr '\n' ' ')
echo "port_watch start ($SECS s), ports 0-10"
while [ $(( $(date +%s) )) -lt $(( start + SECS )) ] 2>/dev/null || [ -z "$start" ]; do
  [ -z "$start" ] && start=$(date +%s)
  cur=""
  for p in 0 1 2 3 4 5 6 7 8 9 10; do
    s=$(sw_r $p 0x00 2>/dev/null) || continue
    [ $(( (s >> 11) & 1 )) -eq 1 ] && cur="$cur $p"
  done
  now=$(ls /sys/class/net | tr '\n' ' ')
  if [ "$cur" != "$prev" ]; then
    echo "$(date +%H:%M:%S)  linked ports:$cur"
    prev="$cur"
  fi
  if [ "$now" != "$prevn" ]; then
    echo "$(date +%H:%M:%S)  NETDEV CHANGE: $now"
    prevn="$now"
  fi
  sleep 1
done
echo "port_watch done"
