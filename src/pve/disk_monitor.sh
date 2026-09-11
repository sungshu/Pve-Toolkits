#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="1.0.52"
UPDATED="2026-09-01"
SCRIPT_PATH="$(readlink -f "$0")"
BASE_DIR="/run/disk_monitor.$$"
RUNTIME_DIR="/run/disk_monitor_runtime"
FINAL_JSON="/run/disk_monitor.json"
CRON_FILE="/etc/cron.d/disk_monitor"
NP="/usr/share/perl5/PVE/API2/Nodes.pm"
PVEJS="/usr/share/pve-manager/js/pvemanagerlib.js"
PLIBJS="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
PVE_VERSION_FULL="$(pveversion 2>/dev/null || true)"
PVE_VER="$(printf '%s\n' "$PVE_VERSION_FULL" | awk -F/ 'NR==1{print $2}')"
[[ -n "$PVE_VER" ]] || PVE_VER="unknown"
BACKUP_DIR="/var/lib/disk_monitor/$PVE_VER"
OFFICIAL_NP="$BACKUP_DIR/Nodes.pm"
OFFICIAL_PVEJS="$BACKUP_DIR/pvemanagerlib.js"
OFFICIAL_PLIBJS="$BACKUP_DIR/proxmoxlib.js"
PVE_JSON="$BASE_DIR/pve.json"
RAID_JSON="$BASE_DIR/raid.json"
RAID_MAP="$BASE_DIR/raid_map.json"
DISKS_JSON="$BASE_DIR/disks.json"
NVME_JSON="$BASE_DIR/nvme.json"
CPU_JSON="$BASE_DIR/cpu.json"
THERMAL_FILE="$BASE_DIR/thermal.txt"
CONTENT_NP="$BASE_DIR/content_nodes.pm"
CONTENT_CPU_JS="$BASE_DIR/content_cpu.js"
CONTENT_DISK_JS="$BASE_DIR/content_disk.js"
cleanup(){ rm -rf "$BASE_DIR"; }
trap cleanup EXIT
log(){ echo "[ $(date '+%Y-%m-%d %H:%M:%S') ] $*" >&2; }
die(){ log "錯誤：$*"; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "找不到必要程式：$1"; }
safe(){ local v="${1:-}"; v="$(printf '%s' "$v" | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g')"; [[ -n "$v" ]] && printf '%s' "$v" || printf '%s' "UNKNOWN"; }
[[ $EUID -eq 0 ]] || die "請以 root 執行"
for c in jq lsblk smartctl lspci pvesh pveversion perl dpkg-query awk sed timeout; do need "$c"; done
PVE_NODE="$(hostname -s 2>/dev/null || hostname)"
PVE_MANAGER="$(dpkg-query -W -f='${Version}' pve-manager 2>/dev/null || true)"
has_marker(){ grep -qE 'disk_monitor_1\.0\.|diskMonitorNvme|diskMonitorSd|diskMonitorRaid|diskMonitorThermal|diskMonitorData|dm_cpumhz|dm_thermalstate' "$1" 2>/dev/null; }
backup_official(){
 mkdir -p "$BACKUP_DIR"
 if [[ -f "$OFFICIAL_NP" && -f "$OFFICIAL_PVEJS" && -f "$OFFICIAL_PLIBJS" ]]; then
  if has_marker "$OFFICIAL_NP" || has_marker "$OFFICIAL_PVEJS" || has_marker "$OFFICIAL_PLIBJS"; then die "既有 official backup 含 disk_monitor 注入，拒絕使用：$BACKUP_DIR"; fi
  return 0
 fi
 has_marker "$NP" && die "Nodes.pm 尚有舊版注入，拒絕建立 official backup；請先 restore。"
 has_marker "$PVEJS" && die "pvemanagerlib.js 尚有舊版注入，拒絕建立 official backup；請先 restore。"
 has_marker "$PLIBJS" && die "proxmoxlib.js 尚有舊版注入，拒絕建立 official backup；請先 restore。"
 cp -a "$NP" "$OFFICIAL_NP"; cp -a "$PVEJS" "$OFFICIAL_PVEJS"; cp -a "$PLIBJS" "$OFFICIAL_PLIBJS"
 perl -c "$OFFICIAL_NP" >/dev/null 2>&1 || die "官方 Nodes.pm backup 語法錯誤"
 log "官方 backup：$BACKUP_DIR"
}
restore(){
 backup_official
 cp -af "$OFFICIAL_NP" "$NP"; cp -af "$OFFICIAL_PVEJS" "$PVEJS"; cp -af "$OFFICIAL_PLIBJS" "$PLIBJS"
 perl -c "$NP" >/dev/null 2>&1 || die "Nodes.pm 還原後語法錯誤"
 ! has_marker "$NP" || die "Nodes.pm 還原後仍有舊注入"
 ! has_marker "$PVEJS" || die "pvemanagerlib.js 還原後仍有舊注入"
 ! has_marker "$PLIBJS" || die "proxmoxlib.js 還原後仍有舊注入"
 if [[ -f "$CRON_FILE" ]]; then rm -f "$CRON_FILE"; systemctl restart cron 2>/dev/null || true; log "已移除定時排程：$CRON_FILE"; fi
 log "PVE 官方檔案還原完成"
}
collect_metrics(){
 local quiet="${1:-false}"
 mkdir -p "$BASE_DIR" "$RUNTIME_DIR" "$RUNTIME_DIR/nvme" "$RUNTIME_DIR/sd" "$RUNTIME_DIR/raid"
 timeout 10 pvesh get /nodes/localhost/disks/list --output-format json > "$PVE_JSON" 2>/dev/null || echo '[]' > "$PVE_JSON"
 jq empty "$PVE_JSON" >/dev/null 2>&1 || echo '[]' > "$PVE_JSON"
 modprobe k10temp 2>/dev/null || true
 CPU_GOV="none"; for g in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor; do if [[ -r "$g" ]]; then CPU_GOV="$(cat "$g" 2>/dev/null || echo none)"; [[ "$CPU_GOV" != "none" ]] && break; fi; done
 CPU_MIN="none"; CPU_MAX="none"; [[ -r /sys/devices/system/cpu/cpufreq/policy0/cpuinfo_min_freq ]] && CPU_MIN="$(cat /sys/devices/system/cpu/cpufreq/policy0/cpuinfo_min_freq)"; [[ -r /sys/devices/system/cpu/cpufreq/policy0/cpuinfo_max_freq ]] && CPU_MAX="$(cat /sys/devices/system/cpu/cpufreq/policy0/cpuinfo_max_freq)"
 CPU_MHZ="$(awk -F: '/cpu MHz/ { gsub(/^[ \t]+|[ \t]+$/, "", $2); printf "%s%s", sep, $2; sep="," }' /proc/cpuinfo 2>/dev/null || true)"
 PKGWATT="none"; if [[ -x /usr/sbin/turbostat ]]; then PKGWATT="$(timeout 3 turbostat --quiet --cpu package --show PkgWatt -S sleep 0.25 2>/dev/null | tail -n1 || true)"; fi
 { echo "gov:$CPU_GOV"; echo "min:$CPU_MIN"; echo "max:$CPU_MAX"; echo "pkgwatt:$PKGWATT"; grep -i "cpu mhz" /proc/cpuinfo 2>/dev/null || true; } > "$RUNTIME_DIR/cpuFreq.txt"
 if timeout 3 sensors -A > "$THERMAL_FILE" 2>/dev/null && [[ -s "$THERMAL_FILE" ]]; then cp -f "$THERMAL_FILE" "$RUNTIME_DIR/thermal.txt"; else echo "No sensor data" > "$RUNTIME_DIR/thermal.txt"; cp -f "$RUNTIME_DIR/thermal.txt" "$THERMAL_FILE"; fi
 jq -n --arg gov "$CPU_GOV" --arg min "$CPU_MIN" --arg max "$CPU_MAX" --arg mhz "$CPU_MHZ" --arg watt "$PKGWATT" '{governor:$gov,min_freq_khz:$min,max_freq_khz:$max,cpu_mhz:$mhz,pkgwatt:$watt}' > "$CPU_JSON"
 RAID_CONTROLLER="$(lspci 2>/dev/null | grep -Ei 'RAID bus controller|MegaRAID|SAS39xx' | head -n1 || true)"; echo '[]' > "$RAID_JSON"; RAID_COUNT=0
 if [[ -n "$RAID_CONTROLLER" ]]; then
  for PD in {0..15}; do
   raw="$(timeout 5 smartctl -a -j -d "megaraid,$PD" /dev/bus/0 2>/dev/null || echo '{}')"
   jq -e '.model_name or .model_family or .device_model' <<<"$raw" >/dev/null 2>&1 || continue
   product="$(jq -r '.model_name // .model_family // .device_model // "UNKNOWN"' <<<"$raw")"; serial="$(jq -r '.serial_number // "UNKNOWN"' <<<"$raw")"; wwn="$(jq -r '.scsi_lun // .wwn // "UNKNOWN"' <<<"$raw")"; temp="$(jq -r '.temperature.current // .temperature.drive_temperature // "UNKNOWN"' <<<"$raw")"
   if jq -e '.smart_status.passed == false' <<<"$raw" >/dev/null 2>&1; then smart="FAIL"; elif jq -e '.smart_status.passed == true' <<<"$raw" >/dev/null 2>&1; then smart="OK"; else smart="UNKNOWN"; fi
   printf '%s\n' "$raw" > "$RUNTIME_DIR/raid/raid${PD}.json"
   jq -n --arg pd "$PD" --arg product "$(safe "$product")" --arg serial "$(safe "$serial")" --arg wwn "$(safe "$wwn")" --arg temp "$(safe "$temp")" --arg smart "$smart" '{physical_disk:$pd,product:$product,serial:$serial,wwn:$wwn,temperature:$temp,smart:$smart}' >> "$RAID_JSON.items"
   RAID_COUNT=$((RAID_COUNT+1))
  done
 fi
 if [[ -s "$RAID_JSON.items" ]]; then jq -s '.' "$RAID_JSON.items" > "$RAID_JSON"; else echo '[]' > "$RAID_JSON"; fi; rm -f "$RAID_JSON.items"
 echo '[]' > "$RAID_MAP"
 for dev in /dev/sd?; do
  [[ -b "$dev" ]] || continue
  serial="$(lsblk -dn -o SERIAL "$dev" 2>/dev/null | xargs || true)"; wwn="$(lsblk -dn -o WWN "$dev" 2>/dev/null | xargs || true)"; idx=""
  [[ -n "$serial" ]] && idx="$(jq -r --arg s "$serial" '.[] | select(.serial == $s) | .physical_disk' "$RAID_JSON" | head -n1 || true)"
  if [[ -z "$idx" || "$idx" == "null" ]]; then [[ -n "$wwn" ]] && idx="$(jq -r --arg w "$wwn" '.[] | select(.wwn == $w) | .physical_disk' "$RAID_JSON" | head -n1 || true)"; fi
  if [[ -n "$idx" && "$idx" != "null" ]]; then jq -n --arg d "$dev" --arg s "$serial" --arg w "$wwn" --arg p "$idx" '{device:$d,serial:$s,wwn:$w,raid_physical_disk:$p}' >> "$RAID_MAP.items"; fi
 done
 if [[ -s "$RAID_MAP.items" ]]; then jq -s '.' "$RAID_MAP.items" > "$RAID_MAP"; else echo '[]' > "$RAID_MAP"; fi; rm -f "$RAID_MAP.items"
 echo '[]' > "$DISKS_JSON"
 for dev in /dev/sd?; do
  [[ -b "$dev" ]] || continue
  raid_idx="$(jq -r --arg d "$dev" '.[] | select(.device == $d) | .raid_physical_disk' "$RAID_MAP" | head -n1 || true)"; [[ "$raid_idx" == "null" ]] && raid_idx=""; [[ -n "$raid_idx" ]] && continue
  name="${dev##*/}"; model="$(lsblk -dn -o MODEL "$dev" 2>/dev/null || true)"; serial="$(lsblk -dn -o SERIAL "$dev" 2>/dev/null || true)"; wwn="$(lsblk -dn -o WWN "$dev" 2>/dev/null || true)"; size="$(lsblk -dn -o SIZE "$dev" 2>/dev/null || true)"; rota="$(lsblk -dn -o ROTA "$dev" 2>/dev/null || true)"; tran="$(lsblk -dn -o TRAN "$dev" 2>/dev/null || true)"
  bus="SATA"; case "$tran" in sas) bus="SAS";; sata|ata) bus="SATA";; *) bus="SATA/SAS";; esac
  [[ "$rota" == "0" ]] && type="${bus} 固態硬碟" || type="${bus} 傳統硬碟"
  raw="$(timeout 5 smartctl -a -j "$dev" 2>/dev/null || echo '{}')"; printf '%s\n' "$raw" > "$RUNTIME_DIR/sd/${name}.json"
  if jq -e '.smart_status.passed == false' <<<"$raw" >/dev/null 2>&1; then smart="FAIL"; elif jq -e '.smart_status.passed == true' <<<"$raw" >/dev/null 2>&1; then smart="OK"; else smart="UNKNOWN"; fi
  temp="$(jq -r '.temperature.current // "UNKNOWN"' <<<"$raw" 2>/dev/null || echo UNKNOWN)"
  jq -n --arg d "$dev" --arg m "$(safe "$model")" --arg s "$(safe "$serial")" --arg w "$(safe "$wwn")" --arg z "$(safe "$size")" --arg t "$type" --arg temp "$(safe "$temp")" --arg smart "$smart" '{device:$d,model:$m,serial:$s,wwn:$w,size:$z,type:$t,temperature:$temp,smart:$smart}' >> "$DISKS_JSON.items"
 done
 if [[ -s "$DISKS_JSON.items" ]]; then jq -s '.' "$DISKS_JSON.items" > "$DISKS_JSON"; else echo '[]' > "$DISKS_JSON"; fi; rm -f "$DISKS_JSON.items"
 echo '[]' > "$NVME_JSON"
 for dev in /dev/nvme[0-9]*; do
  [[ -b "$dev" ]] || continue
  [[ "$dev" =~ nvme[0-9]+$ ]] || continue
  name="${dev##*/}"; raw="$(timeout 5 smartctl -a -j "$dev" 2>/dev/null || echo '{}')"; printf '%s\n' "$raw" > "$RUNTIME_DIR/nvme/${name}.json"
  model="$(jq -r '.model_name // "UNKNOWN"' <<<"$raw")"; serial="$(jq -r '.serial_number // "UNKNOWN"' <<<"$raw")"; temp="$(jq -r '.temperature.current // "UNKNOWN"' <<<"$raw")"; poh="$(jq -r '.power_on_time.hours // "UNKNOWN"' <<<"$raw")"; pc="$(jq -r '.power_cycle_count // "UNKNOWN"' <<<"$raw")"; smart="$(jq -r 'if .smart_status.passed == true then "OK" elif .smart_status.passed == false then "FAIL" else "UNKNOWN" end' <<<"$raw")"
  jq -n --arg d "$dev" --arg m "$(safe "$model")" --arg s "$(safe "$serial")" --arg temp "$(safe "$temp")" --arg poh "$poh" --arg pc "$pc" --arg smart "$smart" '{device:$d,model:$m,serial:$s,temperature:$temp,power_on_hours:$poh,power_cycle_count:$pc,smart:$smart}' >> "$NVME_JSON.items"
 done
 if [[ -s "$NVME_JSON.items" ]]; then jq -s '.' "$NVME_JSON.items" > "$NVME_JSON"; else echo '[]' > "$NVME_JSON"; fi; rm -f "$NVME_JSON.items"
 jq -n --slurpfile pve "$PVE_JSON" --slurpfile cpu "$CPU_JSON" --slurpfile raid "$RAID_JSON" --slurpfile map "$RAID_MAP" --slurpfile disks "$DISKS_JSON" --slurpfile nvme "$NVME_JSON" --arg node "$PVE_NODE" --arg pve "$PVE_MANAGER" --arg version "$VERSION" --arg updated "$UPDATED" '{version:$version,updated:$updated,node:$node,pve_manager:$pve,cpu:$cpu[0],raid:$raid[0],raid_map:$map[0],disks:$disks[0],nvme:$nvme[0],pve_inventory:$pve[0],collected_at:(now|todate)}' > "$FINAL_JSON"
 cp -f "$FINAL_JSON" "$RUNTIME_DIR/summary.json"
 [[ "$quiet" == "false" ]] && log "硬體資料採集完成：$FINAL_JSON"
}

install_cron(){
 mkdir -p "$RUNTIME_DIR"
 cat > "$CRON_FILE" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
* * * * * root $SCRIPT_PATH collect >/dev/null 2>&1
EOF
 chmod 0644 "$CRON_FILE"
 systemctl restart cron 2>/dev/null || true
}
install_hooks(){
 backup_official
 cp -af "$OFFICIAL_NP" "$NP"; cp -af "$OFFICIAL_PVEJS" "$PVEJS"; cp -af "$OFFICIAL_PLIBJS" "$PLIBJS"
 perl -c "$NP" >/dev/null 2>&1 || die "Nodes.pm 官方檔案語法錯誤"
 cat > "$CONTENT_NP" <<'EOF'
# disk_monitor_1.0.52
EOF
 if ! grep -q 'disk_monitor_1\.0\.52' "$NP"; then printf '\n# disk_monitor_1.0.52\n' >> "$NP"; fi
 if ! grep -q 'diskMonitorData' "$PVEJS"; then printf '\n/* diskMonitorData */\n' >> "$PVEJS"; fi
 if ! grep -q 'diskMonitorThermal' "$PVEJS"; then printf '\n/* diskMonitorThermal */\n' >> "$PVEJS"; fi
 if ! grep -q 'diskMonitorNvme' "$PVEJS"; then printf '\n/* diskMonitorNvme */\n' >> "$PVEJS"; fi
 if ! grep -q 'diskMonitorSd' "$PVEJS"; then printf '\n/* diskMonitorSd */\n' >> "$PVEJS"; fi
 if ! grep -q 'diskMonitorRaid' "$PVEJS"; then printf '\n/* diskMonitorRaid */\n' >> "$PVEJS"; fi
 perl -c "$NP" >/dev/null 2>&1 || die "Nodes.pm 客製化後語法錯誤"
}
remod(){ install_hooks; collect_metrics true; install_cron; log "硬體監控介面重新套用完成"; }
install_all(){ install_hooks; collect_metrics false; install_cron; log "disk_monitor.sh v${VERSION} 安裝完成"; }
case "${1:-install}" in
 install) install_all ;;
 collect) collect_metrics false ;;
 remod) remod ;;
 restore) restore ;;
 *) echo "用法：$0 [install|collect|remod|restore]"; exit 2 ;;
esac
