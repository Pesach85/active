#!/usr/bin/env bash
# Deterministic process pressure analysis for Linux (ProcessPressureReport.v1 subset).
set -euo pipefail

DURATION_SEC="${1:-6}"
TOP="${2:-8}"
OUTPUT_JSON="${3:-}"
CATALOG_PATH="${4:-}"

if [[ "$DURATION_SEC" -lt 2 ]]; then DURATION_SEC=2; fi
if [[ "$DURATION_SEC" -gt 30 ]]; then DURATION_SEC=30; fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HUB_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
if [[ -z "$CATALOG_PATH" ]]; then
  CATALOG_PATH="$HUB_ROOT/config/process-intelligence.json"
fi

LOGICAL_CPUS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 1)"

declare -A VITAL_EXACT=(
  [systemd]=1 [kthreadd]=1 [ksoftirqd]=1 [rcu_sched]=1 [rcu_bh]=1
  [migration]=1 [watchdog]=1 [sshd]=1 [dbus-daemon]=1 [NetworkManager]=1
)
declare -A SECURITY_EXACT=([clamd]=1 [freshclam]=1 [fail2ban-server]=1)

classify_process() {
  local name="$1"
  local lower
  lower="$(echo "$name" | tr '[:upper:]' '[:lower:]')"
  if [[ -n "${VITAL_EXACT[$name]:-}" ]] || [[ "$lower" == *"systemd"* ]] || [[ "$name" == kworker* ]]; then
    echo "CriticalSystem|Keep|OSCore|Linux core/kernel/worker — never terminate."
    return
  fi
  if [[ -n "${SECURITY_EXACT[$name]:-}" ]] || [[ "$lower" == *"firewall"* ]]; then
    echo "Security|Keep|Security|Security component — tune scope only."
    return
  fi
  case "$lower" in
    chrome|chromium|firefox|code|node|docker|containerd)
      echo "KnownApplication|Tune|UserApp|Known app — review mitigations for dominant pressure."
      ;;
    *)
      echo "Unknown|Review|Unknown|Not in catalog — classify before action."
      ;;
  esac
}

dominant_pressure() {
  local cpu="$1" mem="$2" io="$3"
  local cpu_n mem_n io_n
  cpu_n=$(awk -v c="$cpu" 'BEGIN{ if(c>100) c=100; if(c<0) c=0; print c/100 }')
  mem_n=$(awk -v m="$mem" 'BEGIN{ cap=8192; if(m>cap) m=cap; if(m<0) m=0; print m/cap }')
  io_n=$(awk -v i="$io" 'BEGIN{ cap=400; if(i>cap) i=cap; if(i<0) i=0; print i/cap }')
  awk -v cn="$cpu_n" -v mn="$mem_n" -v in_="$io_n" 'BEGIN{
    if(cn>=mn && cn>=in_) print "CPUBound";
    else if(mn>=cn && mn>=in_) print "MemoryHeavy";
    else if(in_>=cn && in_>=mn) print "IOHeavy";
    else print "Mixed";
  }'
}

pressure_score() {
  local cpu="$1" mem="$2" io="$3"
  awk -v c="$cpu" -v m="$mem" -v i="$io" 'BEGIN{
    if(c>100) c=100; if(c<0) c=0;
    if(m>8192) m=8192; if(m<0) m=0;
    if(i>400) i=400; if(i<0) i=0;
    s = c*0.50 + (m/8192)*100*0.30 + (i/400)*100*0.20;
    if(s>100) s=100; printf "%.2f", s;
  }'
}

read_snapshot() {
  ps -eo pid=,comm=,rss= --no-headers 2>/dev/null | while read -r pid comm rss; do
    [[ -z "$pid" ]] && continue
    local stat io_r io_w utime stime key
    if [[ -r "/proc/$pid/stat" ]]; then
      read -r _ _ _ _ _ _ _ _ _ _ _ utime stime _ < "/proc/$pid/stat" || continue
    else
      utime=0; stime=0
    fi
    io_r=0; io_w=0
    if [[ -r "/proc/$pid/io" ]]; then
      io_r=$(awk '/^read_bytes:/ {print $2}' "/proc/$pid/io" 2>/dev/null || echo 0)
      io_w=$(awk '/^write_bytes:/ {print $2}' "/proc/$pid/io" 2>/dev/null || echo 0)
    fi
    key="${pid}:${comm}"
    echo "${key}|${comm}|${pid}|${rss}|$((utime+stime))|${io_r}|${io_w}"
  done
}

mapfile -t SNAP1 < <(read_snapshot)
sleep "$DURATION_SEC"
mapfile -t SNAP2 < <(read_snapshot)

declare -A FIRST
for row in "${SNAP1[@]}"; do
  key="${row%%|*}"
  FIRST["$key"]="$row"
done

TMP_ROWS="$(mktemp)"
for row in "${SNAP2[@]}"; do
  key="${row%%|*}"
  [[ -z "${FIRST[$key]:-}" ]] && continue
  IFS='|' read -r _ comm pid rss cpu_ticks io_r io_w <<< "$row"
  IFS='|' read -r _ _ _ rss1 cpu1 io_r1 io_w1 <<< "${FIRST[$key]}"
  cpu_delta=$((cpu_ticks - cpu1))
  io_delta=$(( (io_r + io_w) - (io_r1 + io_w1) ))
  cpu_pct=$(awk -v d="$cpu_delta" -v dur="$DURATION_SEC" -v lp="$LOGICAL_CPUS" 'BEGIN{
    if(d<0) d=0; print (d/(dur* (lp>0?lp:1))) * 100;
  }')
  mem_mb=$(awk -v r="$rss" 'BEGIN{ printf "%.2f", r/1024 }')
  io_mbps=$(awk -v d="$io_delta" -v dur="$DURATION_SEC" 'BEGIN{
    if(d<0) d=0; printf "%.3f", (d/1048576)/dur;
  }')
  score=$(pressure_score "$cpu_pct" "$mem_mb" "$io_mbps")
  dom=$(dominant_pressure "$cpu_pct" "$mem_mb" "$io_mbps")
  IFS='|' read -r necessity priority category notes <<< "$(classify_process "$comm")"
  rec="Normal"
  awk -v s="$score" -v d="$dom" 'BEGIN{
    if(s>=75){ if(d=="CPUBound") print "ThrottlePriority"; else if(d=="MemoryHeavy") print "InvestigateMemory"; else if(d=="IOHeavy") print "CheckDiskContention"; else print "InvestigateImmediately"; }
    else if(s>=45) print "Observe";
    else print "Normal";
  }' > /tmp/rec.$$
  rec=$(cat /tmp/rec.$$); rm -f /tmp/rec.$$
  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "$score" "$comm" "$pid" "$cpu_pct" "$mem_mb" "$io_mbps" "$dom" \
    "$necessity" "$priority" "$category" "$notes" "$rec" >> "$TMP_ROWS"
done

GENERATED_AT="$(date '+%Y-%m-%d %H:%M:%S')"
TOTAL=$(wc -l < "$TMP_ROWS" | tr -d ' ')

JSON='{'
JSON+="\"SchemaVersion\":\"ProcessPressureReport.v1\","
JSON+="\"GeneratedAt\":\"$GENERATED_AT\","
JSON+="\"Platform\":\"Linux\","
JSON+="\"DurationSec\":$DURATION_SEC,"
JSON+="\"LogicalProcessors\":$LOGICAL_CPUS,"
JSON+="\"TotalProcessesObserved\":$TOTAL,"
JSON+="\"CatalogPath\":\"$CATALOG_PATH\","
JSON+="\"Summary\":{\"HighPressureCount\":0,\"VitalPreserved\":0,\"AutoEligibleCount\":0,\"HitlRequiredCount\":0},"
JSON+='"TopProcesses":['

first=1
sort -t'|' -k1,1nr "$TMP_ROWS" | head -n "$TOP" | while IFS='|' read -r score comm pid cpu_pct mem_mb io_mbps dom necessity priority category notes rec; do
  if [[ $first -eq 1 ]]; then first=0; else printf ','; fi
  printf '{"Score":%s,"ProcessName":"%s","PID":%s,"CpuPercent":%s,"WorkingSetMB":%s,"IoMBps":%s,"DominantPressure":"%s","Necessity":"%s","Priority":"%s","Category":"%s","Notes":"%s","Recommendation":"%s"}' \
    "$score" "$comm" "$pid" "$cpu_pct" "$mem_mb" "$io_mbps" "$dom" "$necessity" "$priority" "$category" "$notes" "$rec"
done > /tmp/top.$$
TOP_JSON=$(cat /tmp/top.$$); rm -f /tmp/top.$$

JSON+="$TOP_JSON"
JSON+='], "ResearchNotes":[]}'
rm -f "$TMP_ROWS"

if [[ -n "$OUTPUT_JSON" ]]; then
  mkdir -p "$(dirname "$OUTPUT_JSON")"
  printf '%s\n' "$JSON" > "$OUTPUT_JSON"
fi
printf '%s\n' "$JSON"
