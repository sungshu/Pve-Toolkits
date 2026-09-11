#!/usr/bin/env bash
# =========================================================
# PVE DISK MONITOR PRO
# Proxmox VE 9.x Hardware & Disk Monitoring Customization
#
# Author:   sungshu
# GitHub:   https://github.com/sungshu
# Project:  https://github.com/sungshu/Pve-Toolkits
# License:  GPL-3.0
#
# Version:  1.3.6-Pro
# Updated:  2026-09-11
# Support:  Proxmox VE 9.x / Debian 13 Trixie
# ⚠ WARNING: 本工具會修改 Proxmox VE Web UI 原生檔案。
# =========================================================
set -Eeuo pipefail

VERSION="1.3.6-Pro"
UPDATED="2026-09-11"
SCRIPT_PATH="$(readlink -f "$0")"

UPDATE_URL="https://raw.githubusercontent.com/sungshu/Pve-Toolkits/main/src/pve/disk_monitor.sh"

# =========================================================
# 終端機 UI 顏色與日誌設定
# =========================================================
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${CYAN}[ $(date '+%H:%M:%S') ] INFO${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[ $(date '+%H:%M:%S') ] OK${NC}    $*"; }
log_step()  { echo -e "${YELLOW}[ $(date '+%H:%M:%S') ] STEP${NC}  $*"; }
log_error() { echo -e "${RED}[ $(date '+%H:%M:%S') ] ERROR${NC} $*" >&2; }
die()       { log_error "$*"; exit 1; }
need()      { command -v "$1" >/dev/null 2>&1 || die "找不到必要程式：$1"; }

# =========================================================
# 程式碼內嵌說明選單 (--help )
# =========================================================
show_help() {
    cat <<EOF
PVE DISK MONITOR PRO (${VERSION})
支援環境: Proxmox VE 9.x / Debian 13 Trixie
作者: sungshu (https://github.com/sungshu)
專案: https://github.com/sungshu/Pve-Toolkits

⚠ 警告：本工具會修改 Proxmox VE Web UI 原生檔案。

使用方式：
  disk_monitor.sh install    安裝並套用 PVE Web UI 客製化
  disk_monitor.sh remod      還原官方檔案後重新套用客製化
  disk_monitor.sh restore    還原 PVE 官方乾淨檔案
  disk_monitor.sh collect    重新採集硬體監控資料
  disk_monitor.sh --help     顯示本說明
EOF
}

wait_for_service() {
    local service="$1"
    local timeout="${2:-10}"

    echo -e "${YELLOW}⏳ 等待 ${service} 服務恢復 (最長 ${timeout} 秒)...${NC}"

    for ((i=timeout; i>=1; i--)); do
        if systemctl is-active --quiet "$service"; then
            echo -ne "\r\033[K"
            echo -e "${GREEN}✓ ${service} 已正常啟動${NC}"
            return 0
        fi
        echo -ne "\r   倒數等待 [${i} 秒]..."
        sleep 1
    done

    echo -ne "\r\033[K"
    if systemctl is-active --quiet "$service"; then
        echo -e "${GREEN}✓ ${service} 已正常啟動${NC}"
        return 0
    fi

    echo -e "${RED}✗ ${service} 未在預期時間內恢復${NC}"
    return 1
}

check_update() {
    local latest_version=""
    latest_version=$(curl -s --max-time 3 "$UPDATE_URL" 2>/dev/null | grep -m1 '^VERSION=' | awk -F'"' '{print $2}' || true)
    
    if [[ -z "$latest_version" || "$latest_version" == "404"* ]]; then
        latest_version="$VERSION" 
    fi

    if [[ "$VERSION" == "$latest_version" ]]; then
        echo -e "  目前版本: ${CYAN}${VERSION}${NC} | GitHub 最新版本: ${CYAN}${latest_version}${NC} (已是最新版)"
    else
        if dpkg --compare-versions "$VERSION" lt "$latest_version" 2>/dev/null; then
            echo -e "  目前版本: ${YELLOW}${VERSION}${NC} | GitHub 最新版本: ${GREEN}${latest_version}${NC} ${RED}(發現新版本！)${NC}"
        else
            echo -e "  目前版本: ${GREEN}${VERSION}${NC} | GitHub 最新版本: ${YELLOW}${latest_version}${NC} ${YELLOW}(本地版本較新)${NC}"
        fi
    fi
}

show_header() {
    clear
    echo -e "${CYAN}██████╗ ██╗   ██╗███████╗    ██████╗ ██╗███████╗██╗  ██╗    ██████╗ ██████╗  ██████╗${NC}"
    echo -e "${CYAN}██╔══██╗██║   ██║██╔════╝    ██╔══██╗██║██╔════╝██║ ██╔╝    ██╔══██╗██╔══██╗██╔═══██╗${NC}"
    echo -e "${CYAN}██████╔╝██║   ██║█████╗      ██║  ██║██║███████╗█████╔╝     ██████╔╝██████╔╝██║   ██║${NC}"
    echo -e "${CYAN}██╔═══╝ ╚██╗ ██╔╝██╔══╝      ██║  ██║██║╚════██║██╔═██╗     ██╔═══╝ ██╔══██╗██║   ██║${NC}"
    echo -e "${CYAN}██║      ╚████╔╝ ███████╗    ██████╔╝██║███████║██║  ██╗    ██║     ██║  ██║╚██████╔╝${NC}"
    echo -e "${CYAN}╚═╝       ╚═══╝  ╚══════╝    ╚═════╝ ╚═╝╚══════╝╚═╝  ╚═╝    ╚═╝     ╚═╝  ╚═╝ ╚═════╝${NC}"
    echo -e "════════════════════════════════════════════════════════════════════════════════════════════"
    echo -e "  PVE DISK MONITOR PRO | Support PVE 9.x.x / Debian 13 Trixie"
    echo -e "  全面監控 PVE 節點硬體與硬碟資訊"
    echo -e "  作者: sungshu"
    echo -e "  GitHub: https://github.com/sungshu"
    echo -e "  專案: https://github.com/sungshu/Pve-Toolkits"
    check_update
    echo -e "════════════════════════════════════════════════════════════════════════════════════════════"
    echo ""
}

# =========================================================
# 系統變數與路徑
# =========================================================
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

cleanup() { rm -rf "$BASE_DIR"; }
trap cleanup EXIT

safe() {
    local v="${1:-}"
    v="$(printf '%s' "$v" | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g')"
    [[ -n "$v" ]] && printf '%s' "$v" || printf '%s' "UNKNOWN"
}

[[ $EUID -eq 0 ]] || die "請以 root 執行"

for c in jq lsblk smartctl lspci pvesh pveversion perl dpkg-query awk sed timeout; do
    need "$c"
done

PVE_NODE="$(hostname -s 2>/dev/null || hostname)"
PVE_MANAGER="$(dpkg-query -W -f='${Version}' pve-manager 2>/dev/null || true)"

has_marker() {
    grep -qE \
        'disk_monitor_1\.0\.|diskMonitorNvme|diskMonitorSd|diskMonitorRaid|diskMonitorThermal|diskMonitorData|dm_cpumhz|dm_thermalstate' \
        "$1" 2>/dev/null
}

backup_official() {
    mkdir -p "$BACKUP_DIR"
    if [[ -f "$OFFICIAL_NP" && -f "$OFFICIAL_PVEJS" && -f "$OFFICIAL_PLIBJS" ]]; then
        if has_marker "$OFFICIAL_NP" || has_marker "$OFFICIAL_PVEJS" || has_marker "$OFFICIAL_PLIBJS"; then
            die "既有 official backup 含 disk_monitor 注入，拒絕使用：$BACKUP_DIR"
        fi
        return 0
    fi

    has_marker "$NP" && die "Nodes.pm 尚有舊版注入，拒絕建立 backup；請先 restore。"
    has_marker "$PVEJS" && die "pvemanagerlib.js 尚有舊版注入，拒絕建立 backup；請先 restore。"
    has_marker "$PLIBJS" && die "proxmoxlib.js 尚有舊版注入，拒絕建立 backup；請先 restore。"

    cp -a "$NP" "$OFFICIAL_NP"
    cp -a "$PVEJS" "$OFFICIAL_PVEJS"
    cp -a "$PLIBJS" "$OFFICIAL_PLIBJS"

    perl -c "$OFFICIAL_NP" >/dev/null 2>&1 || die "官方 Nodes.pm backup 語法錯誤"
    log_ok "已建立乾淨的 PVE 系統檔案備份：$BACKUP_DIR"
}

restore() {
    backup_official
    log_step "正在還原 PVE 官方檔案..."

    cp -af "$OFFICIAL_NP" "$NP"
    echo -e "  ${GREEN}✓${NC} Nodes.pm"
    cp -af "$OFFICIAL_PVEJS" "$PVEJS"
    echo -e "  ${GREEN}✓${NC} pvemanagerlib.js"
    cp -af "$OFFICIAL_PLIBJS" "$PLIBJS"
    echo -e "  ${GREEN}✓${NC} proxmoxlib.js"

    perl -c "$NP" >/dev/null 2>&1 || die "Nodes.pm 還原後語法錯誤"

    ! has_marker "$NP" || die "Nodes.pm 還原後仍有舊注入"
    ! has_marker "$PVEJS" || die "pvemanagerlib.js 還原後仍有舊注入"
    ! has_marker "$PLIBJS" || die "proxmoxlib.js 還原後仍有舊注入"

    if [[ -f "$CRON_FILE" ]]; then
        rm -f "$CRON_FILE"
        systemctl restart cron 2>/dev/null || true
        log_info "已移除定時排程：$CRON_FILE"
    fi

    wait_for_service pvedaemon 5
    wait_for_service pvestatd 5

    log_ok "PVE 官方檔案還原完成。"
}

# =========================================================
# 硬體數據採集核心
# =========================================================
collect_metrics() {
    local quiet="${1:-false}"

    mkdir -p "$BASE_DIR" "$RUNTIME_DIR" "$RUNTIME_DIR/nvme" "$RUNTIME_DIR/sd" "$RUNTIME_DIR/raid"

    [[ "$quiet" == "false" ]] && log_step "正在取得 PVE Disk Inventory..."
    if ! timeout 10 pvesh get /nodes/localhost/disks/list --output-format json > "$PVE_JSON" 2>/dev/null; then
        echo '[]' > "$PVE_JSON"
    fi
    jq empty "$PVE_JSON" >/dev/null 2>&1 || echo '[]' > "$PVE_JSON"

    # CPU / thermal
    modprobe k10temp 2>/dev/null || true

    CPU_GOV="none"
    for g in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor; do
        if [[ -r "$g" ]]; then
            CPU_GOV="$(cat "$g" 2>/dev/null || echo none)"
            [[ "$CPU_GOV" != "none" ]] && break
        fi
    done

    CPU_MIN="none"
    CPU_MAX="none"
    MIN_FILE="/sys/devices/system/cpu/cpufreq/policy0/cpuinfo_min_freq"
    MAX_FILE="/sys/devices/system/cpu/cpufreq/policy0/cpuinfo_max_freq"
    [[ -r "$MIN_FILE" ]] && CPU_MIN="$(cat "$MIN_FILE" 2>/dev/null || echo none)"
    [[ -r "$MAX_FILE" ]] && CPU_MAX="$(cat "$MAX_FILE" 2>/dev/null || echo none)"

    CPU_MHZ="$(awk -F: '/cpu MHz/ { gsub(/^[ \t]+|[ \t]+$/, "", $2); printf "%s%s", sep, $2; sep="," }' /proc/cpuinfo 2>/dev/null || true)"

    PKGWATT="none"
    if [[ -x /usr/sbin/turbostat ]]; then
        PKGWATT="$(timeout 3 turbostat --quiet --cpu package --show PkgWatt -S sleep 0.25 2>/dev/null | tail -n1 || true)"
    fi

    {
        echo "gov:$CPU_GOV"
        echo "min:$CPU_MIN"
        echo "max:$CPU_MAX"
        echo "pkgwatt:$PKGWATT"
        grep -i "cpu mhz" /proc/cpuinfo 2>/dev/null || true
    } > "$RUNTIME_DIR/cpuFreq.txt"

    if timeout 3 sensors -A > "$THERMAL_FILE" 2>/dev/null && [[ -s "$THERMAL_FILE" ]]; then
        cp -f "$THERMAL_FILE" "$RUNTIME_DIR/thermal.txt"
    else
        echo "No sensor data" > "$RUNTIME_DIR/thermal.txt"
        cp -f "$RUNTIME_DIR/thermal.txt" "$THERMAL_FILE"
    fi

    jq -n \
        --arg gov "$CPU_GOV" \
        --arg min "$CPU_MIN" \
        --arg max "$CPU_MAX" \
        --arg mhz "$CPU_MHZ" \
        --arg watt "$PKGWATT" \
        '{governor:$gov, min_freq_khz:$min, max_freq_khz:$max, cpu_mhz:$mhz, pkgwatt:$watt}' \
        > "$CPU_JSON"

    # RAID
    RAID_CONTROLLER="$(lspci 2>/dev/null | grep -Ei 'RAID bus controller|MegaRAID|SAS39xx' | head -n1 || true)"
    echo '[]' > "$RAID_JSON"
    RAID_COUNT=0

    if [[ -n "$RAID_CONTROLLER" ]]; then
        [[ "$quiet" == "false" ]] && log_step "正在偵測 RAID Physical Disk..."
        for PD in {0..15}; do
            raw="$(timeout 5 smartctl -a -j -d "megaraid,$PD" /dev/bus/0 2>/dev/null || echo '{}')"
            if ! jq -e '.model_name or .model_family or .device_model' <<<"$raw" >/dev/null 2>&1; then
                continue
            fi

            product="$(jq -r '.model_name // .model_family // .device_model // "UNKNOWN"' <<<"$raw" 2>/dev/null || echo UNKNOWN)"
            serial="$(jq -r '.serial_number // "UNKNOWN"' <<<"$raw" 2>/dev/null || echo UNKNOWN)"
            wwn="$(jq -r '.scsi_lun // .wwn // "UNKNOWN"' <<<"$raw" 2>/dev/null || echo UNKNOWN)"
            temp="$(jq -r '.temperature.current // .temperature.drive_temperature // "UNKNOWN"' <<<"$raw" 2>/dev/null || echo UNKNOWN)"

            if jq -e '.smart_status.passed == false' <<<"$raw" >/dev/null 2>&1; then
                smart="FAIL"
            elif jq -e '.smart_status.passed == true' <<<"$raw" >/dev/null 2>&1; then
                smart="OK"
            else
                health="$(jq -r '.smart_status.message // ""' <<<"$raw" 2>/dev/null || true)"
                if printf '%s' "$health" | grep -Eiq 'fail|failed|critical|bad|error'; then
                    smart="FAIL"
                elif printf '%s' "$health" | grep -Eiq 'ok|passed|pass'; then
                    smart="OK"
                else
                    smart="UNKNOWN"
                fi
            fi

            printf '%s\n' "$raw" > "$RUNTIME_DIR/raid/raid${PD}.json"

            jq -n \
                --arg pd "$PD" \
                --arg product "$(safe "$product")" \
                --arg serial "$(safe "$serial")" \
                --arg wwn "$(safe "$wwn")" \
                --arg temp "$(safe "$temp")" \
                --arg smart "$smart" \
                '{physical_disk:$pd, product:$product, serial:$serial, wwn:$wwn, temperature:$temp, smart:$smart}' \
                >> "$RAID_JSON.items"

            RAID_COUNT=$((RAID_COUNT + 1))
            [[ "$quiet" == "false" ]] && log_info "RAID Physical Disk ${PD}：$(safe "$product") / $(safe "$serial") / SMART=${smart} / TEMP=$(safe "$temp")"
        done
    fi

    if [[ -s "$RAID_JSON.items" ]]; then jq -s '.' "$RAID_JSON.items" > "$RAID_JSON"; else echo '[]' > "$RAID_JSON"; fi
    rm -f "$RAID_JSON.items"
    [[ "$quiet" == "false" ]] && log_ok "偵測到 RAID Physical Disk：${RAID_COUNT} 顆"

    # RAID Map
    echo '[]' > "$RAID_MAP"
    for dev in /dev/sd?; do
        [[ -b "$dev" ]] || continue
        serial="$(lsblk -dn -o SERIAL "$dev" 2>/dev/null || true)"
        wwn="$(lsblk -dn -o WWN "$dev" 2>/dev/null || true)"
        idx=""

        if [[ -n "$serial" ]]; then idx="$(jq -r --arg s "$serial" '.[] | select(.serial == $s) | .physical_disk' "$RAID_JSON" | head -n1 || true)"; fi
        if [[ -z "$idx" || "$idx" == "null" ]]; then
            if [[ -n "$wwn" ]]; then idx="$(jq -r --arg w "$wwn" '.[] | select(.wwn == $w) | .physical_disk' "$RAID_JSON" | head -n1 || true)"; fi
        fi

        if [[ -n "$idx" && "$idx" != "null" ]]; then
            jq -n --arg d "$dev" --arg s "$serial" --arg w "$wwn" --arg p "$idx" '{device:$d, serial:$s, wwn:$w, raid_physical_disk:$p}' >> "$RAID_MAP.items"
            [[ "$quiet" == "false" ]] && log_info "RAID 對應：${dev} → Physical Disk ${idx}"
        fi
    done

    if [[ -s "$RAID_MAP.items" ]]; then jq -s '.' "$RAID_MAP.items" > "$RAID_MAP"; else echo '[]' > "$RAID_MAP"; fi
    rm -f "$RAID_MAP.items"

    # SATA/SAS 直通硬碟
    echo '[]' > "$DISKS_JSON"
    SATA_COUNT=0
    sdi=0

    for dev in /dev/sd?; do
        [[ -b "$dev" ]] || continue
        name="${dev##*/}"
        raid_idx="$(jq -r --arg d "$dev" '.[] | select(.device == $d) | .raid_physical_disk' "$RAID_MAP" | head -n1 || true)"
        [[ "$raid_idx" == "null" ]] && raid_idx=""
        [[ -n "$raid_idx" ]] && continue

        model="$(lsblk -dn -o MODEL "$dev" 2>/dev/null || true)"
        serial="$(lsblk -dn -o SERIAL "$dev" 2>/dev/null || true)"
        wwn="$(lsblk -dn -o WWN "$dev" 2>/dev/null || true)"
        size="$(lsblk -dn -o SIZE "$dev" 2>/dev/null || true)"
        rot="$(cat "/sys/block/$name/queue/rotational" 2>/dev/null || echo 1)"
        tran="$(lsblk -dn -o TRAN "$dev" 2>/dev/null || true)"

        smartopt=""
        bus="SATA"
        case "$tran" in
            sas) smartopt="-d scsi"; bus="SAS" ;;
            sata|ata) smartopt=""; bus="SATA" ;;
            *) smartopt="-d scsi"; bus="SATA/SAS" ;;
        esac

        if [[ "$rot" == "0" ]]; then type="${bus} 固態硬碟"; else type="${bus} 傳統硬碟"; fi

        raw="$(timeout 5 smartctl $smartopt -a -j "$dev" 2>/dev/null || echo '{}')"
        printf '%s\n' "$raw" > "$RUNTIME_DIR/sd/${name}.json"

        smart="UNKNOWN"
        jq -e '.smart_status.passed == false' <<<"$raw" >/dev/null 2>&1 && smart="FAIL"
        jq -e '.smart_status.passed == true' <<<"$raw" >/dev/null 2>&1 && smart="OK"

        model2="$(jq -r '.model_name // .model_family // "UNKNOWN"' <<<"$raw" 2>/dev/null || echo UNKNOWN)"
        serial2="$(jq -r '.serial_number // "UNKNOWN"' <<<"$raw" 2>/dev/null || echo UNKNOWN)"
        temp="$(jq -r '.temperature.current // .temperature.drive_temperature // "UNKNOWN"' <<<"$raw" 2>/dev/null || echo UNKNOWN)"
        hours="$(jq -r '.power_on_time.hours // "UNKNOWN"' <<<"$raw" 2>/dev/null || echo UNKNOWN)"

        [[ "$model2" == "UNKNOWN" ]] && model2="$model"
        [[ "$serial2" == "UNKNOWN" ]] && serial2="$serial"

        jq -n \
            --arg type "$type" --arg device "$dev" --arg name "$name" \
            --arg model "$(safe "$model2")" --arg serial "$(safe "$serial2")" \
            --arg wwn "$(safe "$wwn")" --arg size "$(safe "$size")" \
            --arg smart "$smart" --arg temp "$temp" --arg hours "$hours" \
            '{type:$type, device:$device, name:$name, model:$model, serial:$serial, wwn:$wwn, size:$size, smart:$smart, temperature:$temp, power_on_hours:$hours}' \
            >> "$DISKS_JSON.items"

        SATA_COUNT=$((SATA_COUNT + 1))
        sdi=$((sdi + 1))
        [[ "$quiet" == "false" ]] && log_info "${type} ${name}：$(safe "$model2") / $(safe "$serial2") / SMART=${smart} / TEMP=$(safe "$temp")"
    done

    if [[ -s "$DISKS_JSON.items" ]]; then jq -s '.' "$DISKS_JSON.items" > "$DISKS_JSON"; else echo '[]' > "$DISKS_JSON"; fi
    rm -f "$DISKS_JSON.items"

    # NVMe
    echo '[]' > "$NVME_JSON"
    NVME_COUNT=0
    nvi=0

    for dev in /dev/nvme*n1; do
        [[ -b "$dev" ]] || continue
        name="${dev##*/}"
        raw="$(timeout 5 smartctl -a -j "$dev" 2>/dev/null || echo '{}')"
        printf '%s\n' "$raw" > "$RUNTIME_DIR/nvme/${name}.json"

        smart="UNKNOWN"
        jq -e '.smart_status.passed == false' <<<"$raw" >/dev/null 2>&1 && smart="FAIL"
        jq -e '.smart_status.passed == true' <<<"$raw" >/dev/null 2>&1 && smart="OK"

        if [[ "$smart" == "UNKNOWN" ]]; then
            health="$(jq -r '.smart_status.message // ""' <<<"$raw" 2>/dev/null || true)"
            if printf '%s' "$health" | grep -Eiq 'fail|failed|critical|bad|error'; then smart="FAIL";
            elif printf '%s' "$health" | grep -Eiq 'ok|passed|pass'; then smart="OK"; fi
        fi

        model="$(jq -r '.model_name // "UNKNOWN"' <<<"$raw" 2>/dev/null || echo UNKNOWN)"
        serial="$(jq -r '.serial_number // "UNKNOWN"' <<<"$raw" 2>/dev/null || echo UNKNOWN)"
        
        jq -n \
            --arg type "NVMe" --arg device "$dev" --arg name "$name" \
            --arg model "$(safe "$model")" --arg serial "$(safe "$serial")" \
            --arg smart "$smart" \
            '{type:$type, device:$device, name:$name, model:$model, serial:$serial, smart:$smart}' \
            >> "$NVME_JSON.items"

        NVME_COUNT=$((NVME_COUNT + 1))
        nvi=$((nvi + 1))
        [[ "$quiet" == "false" ]] && log_info "NVMe ${name}：$(safe "$model") / $(safe "$serial") / SMART=${smart}"
    done

    if [[ -s "$NVME_JSON.items" ]]; then jq -s '.' "$NVME_JSON.items" > "$NVME_JSON"; else echo '[]' > "$NVME_JSON"; fi
    rm -f "$NVME_JSON.items"

    TOTAL_COUNT=$((NVME_COUNT + SATA_COUNT + RAID_COUNT))

    # Final JSON
    jq -n \
        --arg version "$VERSION" --arg updated "$UPDATED" --arg pve "$PVE_VERSION_FULL" \
        --arg node "$PVE_NODE" --arg controller "$RAID_CONTROLLER" --arg thermal "$(cat "$THERMAL_FILE")" \
        --arg nvme "$NVME_COUNT" --arg sata "$SATA_COUNT" --arg raid "$RAID_COUNT" --arg total "$TOTAL_COUNT" \
        --argjson cpu "$(cat "$CPU_JSON")" --argjson nvme_disks "$(cat "$NVME_JSON")" \
        --argjson disks "$(cat "$DISKS_JSON")" --argjson raid_disks "$(cat "$RAID_JSON")" \
        --argjson inventory "$(cat "$PVE_JSON")" \
        '{monitor:{script:"disk_monitor.sh", version:$version, updated:$updated}, pve:{version:$pve, node:$node}, raid_controller:$controller, cpu:$cpu, thermal:$thermal, summary:{nvme:$nvme, sata_sas:$sata, raid_physical_disk:$raid, total:$total}, nvme_disks:$nvme_disks, disks:$disks, raid_physical_disks:$raid_disks, pve_disk_inventory:$inventory}' \
        > "$BASE_DIR/final.json"

    jq empty "$BASE_DIR/final.json" >/dev/null 2>&1 || die "JSON 驗證失敗"
    install -m 0644 "$BASE_DIR/final.json" "$FINAL_JSON"
}

# =========================================================
# CLI 引數處理 (優先處理 --help ，直接印出說明並 exit 0)
# =========================================================
case "${1:-}" in
    --help)
        show_help
        exit 0
        ;;
    restore)
        show_header
        restore
        systemctl restart pveproxy
        wait_for_service pveproxy 10
        echo -e "${GREEN}════════════════════════════════════════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}  PVE Web UI 已還原至官方乾淨狀態${NC}"
        echo -e "${GREEN}════════════════════════════════════════════════════════════════════════════════════════════${NC}"
        echo -e "${YELLOW}請按 Ctrl + F5 重新整理瀏覽器${NC}"
        exit 0
        ;;
    remod|install|"")
        ;;
    collect|cron)
        collect_metrics true
        exit 0
        ;;
    *)
        die "未知參數：$1 (請執行 disk_monitor.sh --help 查看說明)"
        ;;
esac

# =========================================================
# 安裝 / 完整套用流程
# =========================================================
[[ -f "$NP" ]] || die "找不到 $NP"
[[ -f "$PVEJS" ]] || die "找不到 $PVEJS"
[[ -f "$PLIBJS" ]] || die "找不到 $PLIBJS"

show_header
log_info "PVE 版本：$PVE_VERSION_FULL"
log_info "PVE 節點：$PVE_NODE"
log_info "pve-manager：$PVE_MANAGER"
echo

backup_official
restore

# 執行首次資料收集
collect_metrics false
echo

# =========================================================
# Backend: Nodes.pm
# =========================================================
cat > "$CONTENT_NP" <<'PERL'
# disk_monitor_1.0.52

my $dm_read = sub {
    my ($file) = @_;
    return '' unless -r $file;

    if (open(my $fh, '<:encoding(UTF-8)', $file)) {
        local $/;
        my $data = <$fh> // '';
        close($fh);
        return $data;
    }

    return '';
};

$res->{thermalstate} = $dm_read->('/run/disk_monitor_runtime/thermal.txt');
$res->{cpuFreq} = $dm_read->('/run/disk_monitor_runtime/cpuFreq.txt');
PERL

nvi_backend=0
for dev in /dev/nvme*n1; do
    [[ -b "$dev" ]] || continue
    name="${dev##*/}"
    printf '$res->{nvme%s} = $dm_read->("/run/disk_monitor_runtime/nvme/%s.json");\n' "$nvi_backend" "$name" >> "$CONTENT_NP"
    nvi_backend=$((nvi_backend + 1))
done

sdi_backend=0
for dev in /dev/sd?; do
    [[ -b "$dev" ]] || continue
    idx="$(jq -r --arg d "$dev" '.[] | select(.device == $d) | .raid_physical_disk' "$RAID_MAP" | head -n1 || true)"
    [[ "$idx" == "null" ]] && idx=""
    [[ -n "$idx" ]] && continue
    name="${dev##*/}"
    printf '$res->{sd%s} = $dm_read->("/run/disk_monitor_runtime/sd/%s.json");\n' "$sdi_backend" "$name" >> "$CONTENT_NP"
    sdi_backend=$((sdi_backend + 1))
done

raidi_backend=0
while IFS= read -r pd; do
    [[ -n "$pd" ]] || continue
    printf '$res->{raid%s} = $dm_read->("/run/disk_monitor_runtime/raid/raid%s.json");\n' "$raidi_backend" "$pd" >> "$CONTENT_NP"
    raidi_backend=$((raidi_backend + 1))
done < <(jq -r '.[].physical_disk' "$RAID_JSON")

# =========================================================
# Frontend: 區塊 1 - CPU 狀態與溫度
# =========================================================
cat > "$CONTENT_CPU_JS" <<'JS'
// disk_monitor_1.0.52_cpu

{
    itemId: 'dm_cpumhz',
    colspan: 2,
    printBar: false,
    title: gettext('CPU 運作狀態'),
    textField: 'cpuFreq',
    renderer: function(v){
        if (!v) return '無法取得 CPU 資訊';

        let m = v.match(/cpu MHz\s*:\s*[\d.]+/ig) || [];
        let f = [];

        m.forEach(function(x){
            let z = x.match(/[\d.]+$/);
            if (z) f.push(Number(z[0]) / 1000);
        });

        let text = '';

        if (f.length) {
            let avg = f.reduce(function(a,b){ return a + b; }, 0) / f.length;
            text = '平均: ' + avg.toFixed(2) + ' GHz (' +
                Math.min.apply(null, f).toFixed(1) + ' ~ ' +
                Math.max.apply(null, f).toFixed(1) + ' GHz)';
        }

        let g = v.match(/(?<=^gov:).+/im);
        let govName = (g && g[0].trim() !== '') ? g[0].trim().toUpperCase() : 'NONE';
        text += ' | 調速器模式: ' + govName;

        return text;
    }
},

{
    itemId: 'dm_thermalstate',
    colspan: 2,
    printBar: false,
    title: gettext('CPU溫度 (°C)'),
    textField: 'thermalstate',
    renderer: function(value){
        if (!value || value === 'No sensor data') return '無感測器資料';

        let wrapColor = function(t) {
            let num = Number(t);
            let c = (num < 60) ? '#27ae60' : (num < 80) ? '#f39c12' : '#e74c3c';
            let weight = (num >= 80) ? 'font-weight:bold;' : '';
            return '<span style="color:' + c + ';' + weight + '">' + t + '</span>';
        };

        let cpuList = [];
        let otherList = [];
        let nicCount = 0;
        let blocks = value.trim().split(/\n\s*\n/);

        blocks.forEach(function(block){
            let lines = block.split('\n');
            let chip = (lines[0] || '').trim();

            if (/nvme/i.test(chip)) {
                return;
            }

            if (/coretemp|k10temp|zenpower/i.test(chip)) {
                let pkgTemp = '';
                let pkgMatch = block.match(/(?:Package id \d+|Tctl|Tdie):\s*([+-]?\d+(?:\.\d+)?)\s*°C/i);
                if (pkgMatch) {
                    pkgTemp = Math.round(Number(pkgMatch[1]));
                }

                let coreTemps = [];
                let coreRegex = /(?:Core \d+|Tccd\d+):\s*([+-]?\d+(?:\.\d+)?)\s*°C/ig;
                let cMatch;
                while ((cMatch = coreRegex.exec(block)) !== null) {
                    coreTemps.push(Math.round(Number(cMatch[1])));
                }

                let str = '';
                if (pkgTemp !== '' && coreTemps.length > 0) {
                    let avgCore = Math.round(coreTemps.reduce((a,b)=>a+b,0)/coreTemps.length);
                    let minCore = Math.min.apply(null, coreTemps);
                    let maxCore = Math.max.apply(null, coreTemps);
                    str = '封裝: ' + wrapColor(pkgTemp) + '°C | 核心: 平均 ' + wrapColor(avgCore) + '°C (' + wrapColor(minCore) + '°C~' + wrapColor(maxCore) + '°C)';
                } else if (pkgTemp !== '') {
                    str = '封裝: ' + wrapColor(pkgTemp) + '°C';
                } else if (coreTemps.length > 0) {
                    let avgCore = Math.round(coreTemps.reduce((a,b)=>a+b,0)/coreTemps.length);
                    let minCore = Math.min.apply(null, coreTemps);
                    let maxCore = Math.max.apply(null, coreTemps);
                    str = '核心: 平均 ' + wrapColor(avgCore) + '°C (' + wrapColor(minCore) + '°C~' + wrapColor(maxCore) + '°C)';
                }

                if (str) {
                    cpuList.push(str);
                }
            } else {
                let devName = chip.split('-')[0].toUpperCase();
                let devMatch = block.match(/(?:temp1|Composite|Board|Sensor \d+):\s*([+-]?\d+(?:\.\d+)?)\s*°C/i);

                if (devMatch) {
                    if (/BNXT|TG3|E1000|IXGBE|I40E|ICE|MLX/i.test(devName)) {
                        nicCount++;
                        devName = '網卡' + nicCount;
                    }

                    let tNum = Math.round(Number(devMatch[1]));
                    let tempVal = wrapColor(tNum) + '°C';
                    otherList.push(devName + ': ' + tempVal);
                }
            }
        });

        let linesOut = [];

        if (cpuList.length > 0) {
            let numCpus = cpuList.length;
            let rows = [];

            for (let i = 0; i < numCpus; i++) {
                rows.push(['CPU' + i + ': ' + cpuList[i]]);
            }

            for (let j = 0; j < otherList.length; j++) {
                let targetRow = (j < numCpus) ? j : (numCpus - 1);
                rows[targetRow].push(otherList[j]);
            }

            rows.forEach(function(r){
                linesOut.push(r.join(' | '));
            });
        } else {
            let matches = value.match(/[+-]?\d+(?:\.\d+)?\s*°C/g);
            if (matches && matches.length) {
                linesOut.push('感測器: ' + matches.join(' | '));
            } else {
                linesOut.push('正常');
            }
        }

        return linesOut.join('<br>');
    }
},
JS

# =========================================================
# Frontend: 區塊 2 - 磁碟列表 (硬碟專用門檻: <50綠, 50~69橘, >=70紅)
# =========================================================
cat > "$CONTENT_DISK_JS" <<'JS'
// disk_monitor_1.0.52_disk
JS

nvi_js=0
for dev in /dev/nvme*n1; do
    [[ -b "$dev" ]] || continue

    cat >> "$CONTENT_DISK_JS" <<JS
{
    itemId: 'nvme${nvi_js}0',
    colspan: 2,
    printBar: false,
    title: gettext('NVMe 硬碟 ${nvi_js}'),
    textField: 'nvme${nvi_js}',
    renderer: function(value){
        try {
            let v = JSON.parse(value || '{}');
            let s = v.model_name || v.model_family || '未知型號';
            
            let colorT = function(t) {
                let num = Number(t);
                let c = (num < 50) ? '#27ae60' : (num < 70) ? '#f39c12' : '#e74c3c';
                let weight = (num >= 70) ? 'font-weight:bold;' : '';
                return '<span style="color:' + c + ';' + weight + '">' + t + '°C</span>';
            };

            let curTemp = undefined;
            if (v.temperature && v.temperature.current !== undefined) {
                curTemp = v.temperature.current;
            } else if (v.temperature && v.temperature.drive_temperature !== undefined) {
                curTemp = v.temperature.drive_temperature;
            } else if (v.nvme_smart_health_information_log && v.nvme_smart_health_information_log.temperature !== undefined) {
                curTemp = v.nvme_smart_health_information_log.temperature;
            } else if (v.data && v.data.temperature !== undefined) {
                curTemp = v.data.temperature;
            }

            if (curTemp !== undefined) {
                s += ' | 溫度: ' + colorT(curTemp);
            }

            let log = v.nvme_smart_health_information_log || {};

            if (log.percentage_used !== undefined && log.percentage_used !== null) {
                let h = Math.max(0, 100 - Number(log.percentage_used));
                s += ' | 健康度: ' + h + '%';
            }

            if (log.data_units_read !== undefined && log.data_units_written !== undefined &&
                log.data_units_read !== null && log.data_units_written !== null) {
                let r = Number(log.data_units_read) * 512000 / 1000000000000;
                let w = Number(log.data_units_written) * 512000 / 1000000000000;
                s += ' | 讀寫: ' + r.toFixed(1) + 'T / ' + w.toFixed(1) + 'T';
            }

            let hours = (v.power_on_time && v.power_on_time.hours !== undefined) ? v.power_on_time.hours : log.power_on_hours;
            let cycles = (v.power_cycle_count !== undefined) ? v.power_cycle_count : log.power_cycles;
            let unsafe = (log.unsafe_shutdowns !== undefined && log.unsafe_shutdowns !== null) ? Number(log.unsafe_shutdowns) : undefined;

            if (hours !== undefined && hours !== null) {
                let cVal = (cycles !== undefined && cycles !== null) ? cycles : '0';
                let uVal = (unsafe !== undefined) ? unsafe : '0';
                let uColor = Number(uVal) > 0 ? '#e74c3c' : '#27ae60';
                let uWeight = Number(uVal) > 0 ? 'font-weight:bold;' : '';
                s += ' | ' + hours + ' 小時 (正常/異常:' + cVal + '/<span style="color:' + uColor + ';' + uWeight + '">' + uVal + '</span> 次)';
            }

            let p = v.smart_status && v.smart_status.passed;
            if (p === false) {
                s += ' | SMART: <span style="color:#e74c3c;font-weight:bold;">FAIL</span>';
            } else if (p === true) {
                s += ' | SMART: <span style="color:#27ae60;font-weight:bold;">正常</span>';
            } else {
                s += ' | SMART: <span style="color:#888;font-weight:bold;">未判定</span>';
            }

            return s;
        } catch(e) {
            return '資料解析失敗';
        }
    }
},
JS
    nvi_js=$((nvi_js + 1))
done

# RAID 控制器
RAID_SHORT="$(printf '%s\n' "$RAID_CONTROLLER" | sed -E -e 's/^[0-9A-Fa-f:.]+[[:space:]]+//' -e 's/^RAID bus controller:[[:space:]]*//' -e 's/[[:space:]]+\(rev[[:space:]]+[^)]*\)$//' -e 's/[[:space:]]+/ /g' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | cut -c1-120)"
[[ -n "$RAID_SHORT" ]] || RAID_SHORT="未偵測到 RAID Controller"
RAID_SHORT_JS="$(printf '%s' "$RAID_SHORT" | sed -e 's/\\/\\\\/g' -e "s/'/\\\\'/g" -e ':a;N;$!ba;s/\n/ /g')"

if (( RAID_COUNT > 0 )); then
    cat >> "$CONTENT_DISK_JS" <<JS
{
    itemId: 'raid-controller',
    colspan: 2,
    printBar: false,
    title: gettext('RAID 控制器'),
    textField: 'pveversion',
    renderer: function(){
        return '${RAID_SHORT_JS}';
    }
},
JS
fi

raidi_js=0
while IFS= read -r pd; do
    [[ -n "$pd" ]] || continue
    cat >> "$CONTENT_DISK_JS" <<JS
{
    itemId: 'raid${raidi_js}0',
    colspan: 2,
    printBar: false,
    title: gettext('RAID 硬碟 ${pd}'),
    textField: 'raid${raidi_js}',
    renderer: function(value){
        try {
            let v = JSON.parse(value || '{}');
            let s = v.model_name || v.model_family || v.product || '未知型號';

            let colorT = function(t) {
                let num = Number(t);
                let c = (num < 50) ? '#27ae60' : (num < 70) ? '#f39c12' : '#e74c3c';
                let weight = (num >= 70) ? 'font-weight:bold;' : '';
                return '<span style="color:' + c + ';' + weight + '">' + t + '°C</span>';
            };

            if (v.temperature && v.temperature.current !== undefined) {
                s += ' | 溫度: ' + colorT(v.temperature.current);
            } else if (v.temperature &&
                v.temperature.drive_temperature !== undefined) {
                s += ' | 溫度: ' +
                    colorT(v.temperature.drive_temperature);
            }

            if (v.power_on_time &&
                v.power_on_time.hours !== undefined) {
                s += ' | 通電: ' + Number(v.power_on_time.hours).toLocaleString() + ' 小時';
            }

            let p = v.smart_status && v.smart_status.passed;
            if (p === false) {
                s += ' | SMART: <span style="color:#e74c3c;font-weight:bold;">FAIL</span>';
            } else if (p === true) {
                s += ' | SMART: <span style="color:#27ae60;font-weight:bold;">正常</span>';
            } else {
                s += ' | SMART: <span style="color:#888;font-weight:bold;">未判定</span>';
            }

            return s;
        } catch(e) {
            return '資料解析失敗';
        }
    }
},
JS
    raidi_js=$((raidi_js + 1))
done < <(jq -r '.[].physical_disk' "$RAID_JSON")

# SATA/SAS 直通硬碟
sdi_js=0
for dev in /dev/sd?; do
    [[ -b "$dev" ]] || continue
    idx="$(jq -r --arg d "$dev" '.[] | select(.device == $d) | .raid_physical_disk' "$RAID_MAP" | head -n1 || true)"
    [[ "$idx" == "null" ]] && idx=""
    [[ -n "$idx" ]] && continue

    name="${dev##*/}"
    rot="$(cat "/sys/block/$name/queue/rotational" 2>/dev/null || echo 1)"
    tran="$(lsblk -dn -o TRAN "$dev" 2>/dev/null || true)"

    if [[ "$tran" == "sas" ]]; then
        bus="SAS"
    elif [[ "$tran" == "sata" || "$tran" == "ata" ]]; then
        bus="SATA"
    else
        bus="SATA/SAS"
    fi

    if [[ "$rot" == "0" ]]; then
        typ="${bus} 固態硬碟"
    else
        typ="${bus} 傳統硬碟"
    fi

    cat >> "$CONTENT_DISK_JS" <<JS
{
    itemId: 'sd${sdi_js}0',
    colspan: 2,
    printBar: false,
    title: gettext('${typ} ${sdi_js}'),
    textField: 'sd${sdi_js}',
    renderer: function(value){
        try {
            let v = JSON.parse(value || '{}');
            let s = v.model_name || v.model_family || '未知型號';

            let colorT = function(t) {
                let num = Number(t);
                let c = (num < 50) ? '#27ae60' : (num < 70) ? '#f39c12' : '#e74c3c';
                let weight = (num >= 70) ? 'font-weight:bold;' : '';
                return '<span style="color:' + c + ';' + weight + '">' + t + '°C</span>';
            };

            if (v.temperature && v.temperature.current !== undefined)
                s += ' | 溫度: ' + colorT(v.temperature.current);

            if (v.power_on_time &&
                v.power_on_time.hours !== undefined)
            {
                s += ' | 通電: ' + v.power_on_time.hours + ' 小時';
            }

            let p = v.smart_status && v.smart_status.passed;
            if (p === false) {
                s += ' | SMART: <span style="color:#e74c3c;font-weight:bold;">FAIL</span>';
            } else if (p === true) {
                s += ' | SMART: <span style="color:#27ae60;font-weight:bold;">正常</span>';
            } else {
                s += ' | SMART: <span style="color:#888;font-weight:bold;">未判定</span>';
            }

            return s;
        } catch(e) {
            return '資料解析失敗';
        }
    }
},
JS
    sdi_js=$((sdi_js + 1))
done

# =========================================================
# Backend injection
# =========================================================
log_step "正在注入 Nodes.pm..."
sed -i "/PVE::pvecfg::version_text()/r $CONTENT_NP" "$NP"

log_step "正在注入 pvemanagerlib.js..."

# 1. 插入 CPU 狀態與溫度到 render_cpu_model 結尾之後
awk -v file="$CONTENT_CPU_JS" '
    BEGIN { armed=0; found=0 }
    /render_cpu_model/ && !found {
        armed=1
    }
    armed {
        print
        if ($0 ~ /^[[:space:]]*},[[:space:]]*$/) {
            while ((getline line < file) > 0) print line
            close(file)
            found=1
            armed=0
            next
        }
        next
    }
    { print }
    END { if (!found) exit 2 }
' "$PVEJS" > "$BASE_DIR/pvemanagerlib.cpu.js" || {
    restore
    systemctl restart pveproxy 2>/dev/null || true
    die "找不到 render_cpu_model 插入位置"
}

# 2. 插入磁碟列表到 pveversion 結尾之後
awk -v file="$CONTENT_DISK_JS" '
    BEGIN { armed=0; found=0 }
    /textField:[[:space:]]*'\''pveversion'\''/ && !found {
        armed=1
    }
    armed {
        print
        if ($0 ~ /^[[:space:]]*},[[:space:]]*$/) {
            while ((getline line < file) > 0) print line
            close(file)
            found=1
            armed=0
            next
        }
        next
    }
    { print }
    END { if (!found) exit 2 }
' "$BASE_DIR/pvemanagerlib.cpu.js" > "$BASE_DIR/pvemanagerlib.final.js" || {
    restore
    systemctl restart pveproxy 2>/dev/null || true
    die "找不到 pveversion 插入位置"
}

mv -f "$BASE_DIR/pvemanagerlib.final.js" "$PVEJS"

# =========================================================
# Dynamic Node Summary height
# =========================================================
log_step "設定 Node Summary 為原生自動適應高度..."

awk -v marker='widget.pveNodeStatus' -v repl='height: "auto", minHeight: 300' '
    BEGIN { armed=0; left=0; changed=0 }
    {
        if (!armed && index($0, marker) > 0) { armed=1; left=80 }
        if (armed && $0 ~ /height:[[:space:]]*[0-9]+/) {
            sub(/height:[[:space:]]*[0-9]+/, repl)
            changed=1; armed=0; left=0
        }
        if (armed) { left--; if (left <= 0) armed=0 }
        print
    }
    END { if (!changed) exit 2 }
' "$PVEJS" > "$BASE_DIR/pvemanagerlib.height.js" || {
    rm -f "$BASE_DIR/pvemanagerlib.height.js"
    restore
    systemctl restart pveproxy 2>/dev/null || true
    die "找不到 widget.pveNodeStatus height"
}

mv -f "$BASE_DIR/pvemanagerlib.height.js" "$PVEJS"
log_ok "Node Summary 高度已成功交由前端引擎自動適應 (auto)。"

# =========================================================
# Subscription popup
# =========================================================
if ! grep -q 'disk_monitor_1.0.52_subscription' "$PLIBJS"; then
    if grep -q '/nodes/localhost/subscription' "$PLIBJS"; then
        if ! sed -E -i '
            /\/nodes\/localhost\/subscription/,+15{
                / if \(/,/Ext\.Msg\.show/{
                    H
                    /Ext\.Msg\.show/!d
                    x
                    s/(.* if \().*(\).*)/\1false\2/
                    i\/\/disk_monitor_1.0.52_subscription
                }
            }
        ' "$PLIBJS"
        then
            restore
            systemctl restart pveproxy 2>/dev/null || true
            die "proxmoxlib.js subscription 注入失敗"
        fi
    fi
fi

# =========================================================
# Validation
# =========================================================
log_step "驗證 Nodes.pm 與注入內容..."

if ! perl -c "$NP" >/dev/null 2>&1; then
    restore
    systemctl restart pveproxy 2>/dev/null || true
    die "Nodes.pm Perl syntax error"
fi

if grep -nE 'smartctl|sensors|turbostat' "$CONTENT_NP" >/dev/null 2>&1; then
    restore
    systemctl restart pveproxy 2>/dev/null || true
    die "注入內容包含禁止的硬體 command"
fi

grep -q 'disk_monitor_1.0.52' "$NP" || {
    restore
    systemctl restart pveproxy 2>/dev/null || true
    die "Nodes.pm 注入標記不存在"
}

grep -q 'disk_monitor_1.0.52_cpu' "$PVEJS" || {
    restore
    systemctl restart pveproxy 2>/dev/null || true
    die "pvemanagerlib.js CPU 注入標記不存在"
}

jq empty "$FINAL_JSON" >/dev/null 2>&1 || die "監控 JSON 驗證失敗"
log_ok "程式碼注入與驗證皆通過。"

# =========================================================
# 自動配置定時排程 (Cron)
# =========================================================
log_step "設定自動定時採集排程 (Cron)..."
cat <<EOF > "$CRON_FILE"
* * * * * root ${SCRIPT_PATH} collect >/dev/null 2>&1
EOF
chmod 0644 "$CRON_FILE"
systemctl restart cron 2>/dev/null || true
log_ok "Cron 排程已建立 (${CRON_FILE})。"

# =========================================================
# API test BEFORE proxy restart
# =========================================================
log_step "套用後測試 PVE API (重啟前)..."
if ! timeout 10 pvesh get /nodes/localhost/status --output-format json > "$BASE_DIR/api_before.json" 2>/dev/null; then
    restore
    systemctl restart pveproxy 2>/dev/null || true
    die "套用後 PVE API 失敗"
fi

jq empty "$BASE_DIR/api_before.json" >/dev/null 2>&1 || {
    restore
    systemctl restart pveproxy 2>/dev/null || true
    die "套用後 PVE API JSON 失敗"
}

if ! jq -e '.cpuFreq != null and .thermalstate != null' "$BASE_DIR/api_before.json" >/dev/null 2>&1; then
    restore
    systemctl restart pveproxy 2>/dev/null || true
    die "PVE API 缺少 backend fields"
fi
log_ok "API 測試通過。"

# =========================================================
# Restart proxy + 動態倒數等待服務恢復 + API test AFTER
# =========================================================
log_step "重新啟動 pveproxy..."
systemctl restart pveproxy
wait_for_service pveproxy 10

log_step "重新測試 PVE API (重啟後)..."
if ! timeout 10 pvesh get /nodes/localhost/status --output-format json > "$BASE_DIR/api_after.json" 2>/dev/null; then
    restore
    systemctl restart pveproxy 2>/dev/null || true
    die "pveproxy restart 後 PVE API 失敗"
fi

jq empty "$BASE_DIR/api_after.json" >/dev/null 2>&1 || {
    restore
    systemctl restart pveproxy 2>/dev/null || true
    die "pveproxy restart 後 PVE API JSON 失敗"
}

if ! jq -e '.cpuFreq != null and .thermalstate != null' "$BASE_DIR/api_after.json" >/dev/null 2>&1; then
    restore
    systemctl restart pveproxy 2>/dev/null || true
    die "pveproxy restart 後缺少 backend fields"
fi
log_ok "重新啟動完成，API 測試通過。"

# =========================================================
# Final Summary Output (已修正 Subscription 語意)
# =========================================================
echo
echo -e "${GREEN}════════════════════════════════════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  部署完畢！PVE DISK MONITOR PRO (${VERSION}) 已成功套用。${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════════════════════════════════════${NC}"
echo
echo -e "${CYAN}▶ 硬體偵測結果：${NC}"
echo -e "  NVMe 硬碟: ${YELLOW}${NVME_COUNT}${NC} 顆"
echo -e "  SATA/SAS:  ${YELLOW}${SATA_COUNT}${NC} 顆"
echo -e "  RAID 硬碟: ${YELLOW}${RAID_COUNT}${NC} 顆"
echo -e "  總計硬碟:  ${YELLOW}${TOTAL_COUNT}${NC} 顆"
echo
echo -e "${CYAN}▶ 網頁端 UI 實際修改明細：${NC}"
echo -e "  - ${GREEN}CPU 運作狀態：${NC}新增平均/最低/最高 CPU 頻率與調速器模式顯示。"
echo -e "  - ${GREEN}CPU 溫度：${NC}新增 CPU 封裝、核心平均值、最低值與最高值，依專用門檻套用綠/橘/紅色階 (<60 綠, 60~79 橘, >=80 紅)。"
echo -e "  - ${GREEN}網卡溫度：${NC}自動辨識支援的網卡感測器，並整合至 CPU 溫度列顯示。"
echo -e "  - ${GREEN}硬碟分軌溫控色階：${NC}NVMe、RAID 與 SATA/SAS 硬碟改採專用門檻 (<50 綠, 50~69 橘, >=70 紅加粗)，更符合硬碟散熱保護需求。"
echo -e "  - ${GREEN}NVMe 硬碟：${NC}新增 Model、溫度、健康度、讀寫 TB、動態通電時數、Power Cycle、Unsafe Shutdown 與 SMART 狀態。"
echo -e "  - ${GREEN}RAID 控制器：${NC}新增 RAID Controller 資訊顯示。"
echo -e "  - ${GREEN}RAID Physical Disk：${NC}新增實體硬碟 Model、溫度、通電時間與 SMART 狀態。"
echo -e "  - ${GREEN}SATA/SAS 直通硬碟：${NC}新增介面類型、SSD/HDD、溫度、通電時間與 SMART 狀態。"
echo -e "  - ${GREEN}硬碟健康資訊：${NC}異常 SMART 與 Unsafe Shutdown 會以紅色／粗體強化提示。"
echo -e "  - ${GREEN}Node Summary 高度：${NC}由原生固定高度改為 height:auto，硬體資訊增加時自動延伸。"
echo -e "  - ${GREEN}Subscription Popup：${NC}抑制 PVE Subscription 提示視窗，避免影響管理介面操作。"
echo -e "  - ${GREEN}Backend API：${NC}新增 thermalstate、cpuFreq、NVMe、SATA/SAS 與 RAID Physical Disk 資料供 Web UI 顯示。"
echo
echo -e "${CYAN}▶ 常用操作指令快速參考：${NC}"
echo -e "  - ${YELLOW}disk_monitor.sh install${NC}      (安裝並套用客製化)"
echo -e "  - ${YELLOW}disk_monitor.sh remod${NC}        (還原後重新套用)"
echo -e "  - ${YELLOW}disk_monitor.sh restore${NC}      (還原官方原廠狀態)"
echo -e "  - ${YELLOW}disk_monitor.sh collect${NC}      (手動重新採集數據)"
echo -e "  - ${YELLOW}disk_monitor.sh --help${NC}       (顯示完整說明)"
echo
echo -e "${YELLOW}👉 請在 PVE 網頁介面按下 Ctrl + F5 強制重新整理快取。${NC}"
echo

exit 0
