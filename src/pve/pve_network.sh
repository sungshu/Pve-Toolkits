#!/usr/bin/env bash
set -Eeuo pipefail

# PVE NETWORK PRO - Proxmox VE 網路架構設定工具
# Version: 2.0.17
# Updated: 2026-10-01

SCRIPT_VERSION="2.0.17"
UPDATED="2026-10-01"
REPOSITORY_RAW="https://raw.githubusercontent.com/sungshu/Pve-Toolkits/main/src/pve/pve_network.sh"
LATEST_VERSION=""
UPDATE_STATUS="尚未檢查"
NETWORK_SCRIPT_PATH="/root/pve_network.sh"
GENERATED_INTERFACES_FILE=""
NETWORK_UPDATE_GUARD="${PVE_NETWORK_UPDATED:-0}"
BOND_MODE=""
BOND_PRIMARY_NIC=""
BOND_XMIT_HASH_POLICY=""
BOND_LACP_RATE=""

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_NAME="pve_network.sh"
BASE_DIR="/etc/pve-toolkit/net"
BASELINE_DIR="${BASE_DIR}/baseline"
STATE_DIR="${BASE_DIR}/state"
VSS_DIR="${STATE_DIR}/vss"
VDS_DIR="${STATE_DIR}/vds"
STATE_FILE="${STATE_DIR}/objects.conf"
BACKUP_DIR="${BASE_DIR}/backup"
RECOVERY_DIR="${BASE_DIR}/recovery"

log_info()  { echo -e "${CYAN}[ $(date '+%H:%M:%S') ] INFO${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[ $(date '+%H:%M:%S') ] OK${NC}    $*"; }
log_step()  { echo -e "${YELLOW}[ $(date '+%H:%M:%S') ] STEP${NC}  $*"; }
log_error() { echo -e "${RED}[ $(date '+%H:%M:%S') ] ERROR${NC} $*" >&2; }
die()       { log_error "$*"; exit 1; }
need()      { command -v "$1" >/dev/null 2>&1 || die "找不到必要程式：$1"; }

trap 'log_error "發生未預期錯誤，行號：${LINENO}，請檢查目前網路狀態。"' ERR

show_header()
{
    clear

    echo -e "${CYAN}██████╗ ██╗   ██╗███████╗    ███╗   ██╗███████╗████████╗██╗    ██╗ ██████╗ ██████╗ ██╗  ██╗${NC}"
    echo -e "${CYAN}██╔══██╗██║   ██║██╔════╝    ████╗  ██║██╔════╝╚══██╔══╝██║    ██║██╔═══██╗██╔══██╗██║ ██╔╝${NC}"
    echo -e "${CYAN}██████╔╝██║   ██║█████╗      ██╔██╗ ██║█████╗     ██║   ██║ █╗ ██║██║   ██║██████╔╝█████╔╝${NC}"
    echo -e "${CYAN}██╔═══╝ ╚██╗ ██╔╝██╔══╝      ██║╚██╗██║██╔══╝     ██║   ██║███╗██║██║   ██║██╔══██╗██╔═██╗${NC}"
    echo -e "${CYAN}██║      ╚████╔╝ ███████╗    ██║ ╚████║███████╗   ██║   ╚███╔███╔╝╚██████╔╝██║  ██║██║  ██╗${NC}"
    echo -e "${CYAN}╚═╝       ╚═══╝  ╚══════╝    ╚═╝  ╚═══╝╚══════╝   ╚═╝    ╚══╝╚══╝  ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝${NC}"
    echo -e "════════════════════════════════════════════════════════════════════════════════════════════"
    echo -e "  ${CYAN}PVE NETWORK PRO | Support PVE 9.x.x / Debian 13 Trixie${NC}"
    echo -e "  Proxmox VE 網路架構管理工具 | 仿 VMware 網路設定模式"
    echo -e "  作者: sungshu"
    echo -e "  GitHub: https://github.com/sungshu"
    echo -e "  專案: https://github.com/sungshu/Pve-Toolkits"
    echo -e "  目前版本: ${CYAN}${SCRIPT_VERSION}${NC} | GitHub 最新版本: ${CYAN}${LATEST_VERSION:-未檢查}${NC} (${UPDATE_STATUS})"
    echo -e "════════════════════════════════════════════════════════════════════════════════════════════"
    echo ""
}

pause_screen()
{
    echo ""
    read -r -p "按 Enter 繼續..." _
}

confirm()
{
    local prompt="$1"
    local answer
    read -r -p "${prompt} [y/N]: " answer
    [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]]
}

require_root()
{
    [[ "$(id -u)" -eq 0 ]] || die "請使用 root 執行此工具。"
}

check_environment()
{
    need awk
    need sed
    need grep
    need ip
    need pvesh
    need pvecm
    need ifreload
    need hostname
    need cmp

    [[ -d /etc/pve ]] || die "/etc/pve 不存在，這不是有效的 PVE 環境。"
    [[ -f /etc/network/interfaces ]] || die "/etc/network/interfaces 不存在。"
}

update_network_script()
{
    LATEST_VERSION=""
    UPDATE_STATUS="無法檢查"

    if [[ "${NETWORK_UPDATE_GUARD}" == "1" ]]; then
        # 第二次執行是由更新流程 exec 進來。
        # 此時目前腳本本身就是剛從 GitHub 寫入 /root 的版本，
        # 因此直接以 SCRIPT_VERSION 作為 GitHub 最新版本顯示。
        LATEST_VERSION="${SCRIPT_VERSION}"
        UPDATE_STATUS="已完成更新"
        return 0
    fi

    if ! command -v curl >/dev/null 2>&1; then
        UPDATE_STATUS="未安裝 curl"
        return 0
    fi

    local latest_tmp
    local actual_version
    local latest_url
    latest_tmp="/root/.pve_network.sh.latest.$$"
    latest_url="${REPOSITORY_RAW}?v=$(date +%s)"

    if ! curl -fsSL --connect-timeout 5 --max-time 20 "${latest_url}" -o "${latest_tmp}" 2>/dev/null; then
        rm -f "${latest_tmp}"
        UPDATE_STATUS="無法取得 GitHub 最新版本"
        return 0
    fi

    actual_version="$(grep -m1 '^SCRIPT_VERSION="[^"]*"' "${latest_tmp}" | cut -d'=' -f2- | tr -d '"' | tr -d '\r')"

    if [[ -z "${actual_version}" ]]; then
        rm -f "${latest_tmp}"
        UPDATE_STATUS="無法解析 GitHub 版本"
        return 0
    fi

    LATEST_VERSION="${actual_version}"

    if [[ "${actual_version}" == "${SCRIPT_VERSION}" ]]; then
        rm -f "${latest_tmp}"
        UPDATE_STATUS="已是最新版"
        return 0
    fi
    if ! printf "%s\n%s\n" "${SCRIPT_VERSION}" "${actual_version}" | sort -V | tail -n 1 | grep -qx "${actual_version}"; then
        rm -f "${latest_tmp}"
        UPDATE_STATUS="GitHub 版本較舊：v${actual_version}"
        return 0
    fi
    UPDATE_STATUS="有新版可用：v${actual_version}"
    if ! confirm "偵測到 GitHub 新版 v${actual_version}，是否更新本機腳本？"; then
        rm -f "${latest_tmp}"
        UPDATE_STATUS="有新版可用但未更新"
        return 0
    fi
    chmod 0755 "${latest_tmp}"
    if ! bash -n "${latest_tmp}" >/dev/null 2>&1; then
        rm -f "${latest_tmp}"
        UPDATE_STATUS="GitHub 腳本語法驗證失敗"
        return 0
    fi
    if ! mv -f "${latest_tmp}" "${NETWORK_SCRIPT_PATH}"; then
        rm -f "${latest_tmp}"
        UPDATE_STATUS="無法寫入 ${NETWORK_SCRIPT_PATH}"
        return 0
    fi
    chmod 0755 "${NETWORK_SCRIPT_PATH}"
    UPDATE_STATUS="已下載並寫入 /root：v${actual_version}"


    export PVE_NETWORK_UPDATED=1
    exec "${NETWORK_SCRIPT_PATH}" "$@"
}

get_pve_version()
{
    if command -v pveversion >/dev/null 2>&1; then
        pveversion | awk -F'/' 'NR==1 {print $2}'
    else
        echo "未知"
    fi
}

get_node_name()
{
    hostname -s
}

cluster_joined()
{
    [[ -f /etc/pve/corosync.conf ]] && pvecm status >/dev/null 2>&1
}

cluster_quorate()
{
    local status
    status="$(pvecm status 2>/dev/null || true)"
    grep -qE 'Quorate:\s+Yes|Quorate:\s+1' <<<"${status}"
}

cluster_status_text()
{
    if ! cluster_joined; then
        echo -e "${RED}未加入${NC}"
    elif cluster_quorate; then
        echo -e "已加入 / Quorum ${GREEN}正常${NC}"
    else
        echo -e "已加入 / Quorum ${RED}異常${NC}"
    fi
}

get_management_info()
{
    CURRENT_GW="$(ip route show default 2>/dev/null | awk 'NR==1 {print $3}')"
    DEV_WITH_GW="$(ip route show default 2>/dev/null | awk 'NR==1 {print $5}')"
    CURRENT_IP=""

    if [[ -n "${DEV_WITH_GW}" ]]; then
        CURRENT_IP="$(ip -4 -o addr show dev "${DEV_WITH_GW}" scope global 2>/dev/null | awk 'NR==1 {print $4}')"
    fi
}

is_physical_nic()
{
    local nic="$1"
    [[ -d "/sys/class/net/${nic}" ]] || return 1
    [[ "${nic}" != "lo" ]] || return 1
    [[ -e "/sys/class/net/${nic}/device" ]] || return 1
    return 0
}

get_physical_nics()
{
    local path nic
    for path in /sys/class/net/*; do
        [[ -e "${path}" ]] || continue
        nic="${path##*/}"
        if is_physical_nic "${nic}"; then
            echo "${nic}"
        fi
    done | sort
}

get_link_state()
{
    local nic="$1"
    cat "/sys/class/net/${nic}/operstate" 2>/dev/null || echo "unknown"
}

get_link_speed()
{
    local nic="$1"
    local speed
    speed="$(cat "/sys/class/net/${nic}/speed" 2>/dev/null || true)"
    if [[ -z "${speed}" || "${speed}" == "-1" ]]; then
        echo "Unknown"
    else
        echo "${speed}Mb/s"
    fi
}

get_linux_bridges()
{
    local path bridge
    for path in /sys/class/net/*/bridge; do
        [[ -d "${path}" ]] || continue
        bridge="${path%/bridge}"
        bridge="${bridge##*/}"
        [[ -n "${bridge}" && "${bridge}" != "lo" ]] || continue
        echo "${bridge}"
    done | sort -V
}

get_vswitch_name()
{
    local bridge="$1"

    if [[ "${bridge}" =~ ^vmbr([0-9]+)$ ]]; then
        echo "vSwitch${BASH_REMATCH[1]}"
    else
        echo "${bridge}"
    fi
}
show_nics()
{
    local index=1 nic state speed
    echo "============================================================"
    echo " 實體網卡（NIC）"
    echo "============================================================"
    echo ""
    echo "注意：只列出實體 NIC，不會自動選擇。"
    echo ""

    while read -r nic; do
        [[ -n "${nic}" ]] || continue
        state="$(get_link_state "${nic}")"
        speed="$(get_link_speed "${nic}")"
        printf "  %2d) %-12s %-12s %s\n" "${index}" "${nic}" "${speed}" "${state}"
        index=$((index + 1))
    done < <(get_physical_nics)

    [[ ${index} -gt 1 ]] || die "找不到可用的實體 NIC。"
    echo ""
}

nic_used_elsewhere()
{
    local nic="${1}" target_bridge="${2}" target_bond=""
    target_bond="$(awk -v bridge="${target_bridge}" 'BEGIN{RS=""} $0~"(^|\\n)auto[[:space:]]+" bridge "[[:space:]]*(\\n|$)"{n=split($0,a,"\\n");for(i=1;i<=n;i++)if(a[i]~/^[[:space:]]*bridge-ports[[:space:]]+bond[0-9]+/){sub(/^[[:space:]]*bridge-ports[[:space:]]+/,"",a[i]);print a[i];exit}}' /etc/network/interfaces 2>/dev/null || true)"
    awk -v nic="${nic}" -v target="${target_bridge}" -v target_bond="${target_bond}" 'BEGIN{RS=""}{
        is_target=($0~"(^|\\n)auto[[:space:]]+" target "[[:space:]]*(\\n|$)")
        is_target_bond=(target_bond!="" && $0~"(^|\\n)auto[[:space:]]+" target_bond "[[:space:]]*(\\n|$)")
        if(is_target||is_target_bond)next
        if($0~"(^|\\n)bridge-ports[[:space:]]+[^\\n]*([[:space:]]|^)" nic "([[:space:]]|$)")found=1
        if($0~"(^|\\n)bond-slaves[[:space:]]+[^\\n]*([[:space:]]|^)" nic "([[:space:]]|$)")found=1
        if($0~"(^|\\n)iface[[:space:]]+" nic "[[:space:]]+inet[[:space:]]+(static|dhcp)")found=1
    }END{exit(found?0:1)}' /etc/network/interfaces 2>/dev/null
}
select_nic()
{
    local prompt="$1"
    local exclude="${2:-}"
    local -a nics=()
    local nic choice

    while read -r nic; do
        [[ -n "${nic}" ]] || continue
        [[ "${nic}" == "${exclude}" ]] && continue
        nics+=("${nic}")
    done < <(get_physical_nics)

    ((${#nics[@]} > 0)) || die "沒有可供選擇的實體 NIC。"

    echo ""
    local i=1
    for nic in "${nics[@]}"; do
        printf "  %2d) %-12s %-12s %s\n" "$i" "$nic" "$(get_link_speed "$nic")" "$(get_link_state "$nic")"
        i=$((i + 1))
    done

    echo "   0) 返回"
    while true; do
        read -r -p "${prompt}：" choice
        if [[ "${choice}" == "0" ]]; then
            SELECTED_NIC=""
            return 1
        fi
        if [[ "${choice}" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#nics[@]})); then
            SELECTED_NIC="${nics[$((choice - 1))]}"
            return 0
        fi
        log_error "選擇無效，請輸入上方數字。"
    done
}

select_bridge()
{
    local -a bridges=()
    local bridge choice

    while read -r bridge; do
        [[ -n "${bridge}" ]] || continue
        bridges+=("${bridge}")
    done < <(get_linux_bridges)

    echo "============================================================"
    echo " Virtual Switch"
    echo "============================================================"
    echo ""
    echo "VMware 模型：Virtual Switch = Standard vSwitch / VSS。"
    echo "PVE 實作：Linux Bridge；名稱不強制使用 vmbrX。"
    echo ""

    if ((${#bridges[@]} > 0)); then
        local i=1
        for bridge in "${bridges[@]}"; do
            printf "  %2d) %-16s  PVE：%s\n" "$i" "$(get_vswitch_name "${bridge}")" "${bridge}"
            i=$((i + 1))
        done
    fi

    local new_index=$(( ${#bridges[@]} + 1 ))
    printf "  %2d) 建立新的 Virtual Switch\n" "${new_index}"
    echo "  0) 返回"

    while true; do
        read -r -p "請選擇：" choice
        if [[ "${choice}" == "0" ]]; then
            return 1
        fi
        if [[ "${choice}" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#bridges[@]})); then
            SELECTED_BRIDGE="${bridges[$((choice - 1))]}"
            return 0
        fi
        if [[ "${choice}" =~ ^[0-9]+$ ]] && ((choice == new_index)); then
            while true; do
                read -r -p "新的 Virtual Switch 名稱：" SELECTED_BRIDGE
                if [[ "${SELECTED_BRIDGE}" =~ ^[A-Za-z][A-Za-z0-9_]{0,9}$ ]] && [[ ! -e "/sys/class/net/${SELECTED_BRIDGE}" ]]; then
                    return 0
                fi
                log_error "Bridge 名稱必須以英文字母開頭，僅能使用英文字母、數字與底線，最多 10 字元，且目前未使用。"
            done
        fi
        log_error "選擇無效。"
    done
}


select_bond_mode()
{
    local choice

    BOND_MODE=""
    BOND_PRIMARY_NIC=""
    BOND_XMIT_HASH_POLICY=""
    BOND_LACP_RATE=""

    echo "============================================================"
    echo " NIC Teaming / Linux Bond"
    echo "============================================================"
    echo ""
    echo "VMware 模型：Physical Uplink → NIC Teaming。"
    echo "PVE 實作：Linux Bond → Virtual Switch / Linux Bridge。"
    echo ""
    echo "  1) balance-rr"
    echo "     逐封包輪流使用成員 NIC"
    echo "  2) active-backup"
    echo "     一張工作，其餘備援；不需要交換器聚合"
    echo "  3) balance-xor"
    echo "     Hash 分配流量；交換器需配合靜態聚合"
    echo "  4) broadcast"
    echo "     同一封包送至所有成員 NIC"
    echo "  5) 802.3ad / LACP"
    echo "     動態鏈路聚合；交換器必須設定 LACP"
    echo "  6) balance-tlb"
    echo "     自適應傳送負載分散；不需要特殊聚合"
    echo "  7) balance-alb"
    echo "     自適應傳送 + IPv4 接收負載分散；不需要特殊聚合"
    echo "  0) 不使用 Bond / 單一 NIC"
    echo ""

    while true; do
        read -r -p "請選擇：" choice
        case "${choice}" in
            1) BOND_MODE="balance-rr"; return 0 ;;
            2)
                BOND_MODE="active-backup"
                read -r -p "Primary NIC 將於選擇成員後設定。"
                return 0
                ;;
            3)
                BOND_MODE="balance-xor"
                BOND_XMIT_HASH_POLICY="$(select_bond_hash_policy)"
                return 0
                ;;
            4) BOND_MODE="broadcast"; return 0 ;;
            5)
                BOND_MODE="802.3ad"
                BOND_LACP_RATE="$(select_lacp_rate)"
                BOND_XMIT_HASH_POLICY="$(select_bond_hash_policy)"
                return 0
                ;;
            6) BOND_MODE="balance-tlb"; return 0 ;;
            7) BOND_MODE="balance-alb"; return 0 ;;
            0) BOND_MODE=""; return 0 ;;
            *) log_error "選擇無效，請輸入 0～7。" ;;
        esac
    done
}

select_bond_hash_policy()
{
    local choice
    echo ""
    echo "Xmit Hash Policy"
    echo "  1) layer2"
    echo "  2) layer2+3"
    echo "  3) layer3+4"
    echo ""
    while true; do
        read -r -p "請選擇：" choice
        case "${choice}" in
            1) echo "layer2"; return 0 ;;
            2) echo "layer2+3"; return 0 ;;
            3) echo "layer3+4"; return 0 ;;
            *) log_error "選擇無效，請輸入 1～3。" ;;
        esac
    done
}

select_lacp_rate()
{
    local choice
    echo ""
    echo "LACP Rate"
    echo "  1) slow"
    echo "  2) fast"
    echo ""
    while true; do
        read -r -p "請選擇：" choice
        case "${choice}" in
            1) echo "slow"; return 0 ;;
            2) echo "fast"; return 0 ;;
            *) log_error "選擇無效，請輸入 1～2。" ;;
        esac
    done
}


select_second_nic()
{
    local first="$1"
    local -a nics=()
    local nic choice

    while read -r nic; do
        [[ -n "${nic}" ]] || continue
        [[ "${nic}" == "${first}" ]] && continue
        nics+=("${nic}")
    done < <(get_physical_nics)

    echo "============================================================"
    echo " 第二張實體網卡（NIC）"
    echo "============================================================"
    echo ""

    local i=1
    for nic in "${nics[@]}"; do
        printf "  %2d) %-12s %-12s %s\n" "$i" "$nic" "$(get_link_speed "$nic")" "$(get_link_state "$nic")"
        i=$((i + 1))
    done
    echo "  0) 不使用第二張 NIC"
    echo ""

    while true; do
        read -r -p "請選擇：" choice
        if [[ "${choice}" == "0" ]]; then
            SECONDARY_NIC=""
            return 0
        fi
        if [[ "${choice}" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#nics[@]})); then
            SECONDARY_NIC="${nics[$((choice - 1))]}"
            return 0
        fi
        log_error "選擇無效。"
    done
}

ensure_dirs()
{
    mkdir -p "${BASELINE_DIR}" "${VSS_DIR}" "${VDS_DIR}" "${STATE_DIR}" "${BACKUP_DIR}" "${RECOVERY_DIR}"
    touch "${STATE_FILE}"
}

baseline_exists()
{
    [[ -f "${BASELINE_DIR}/interfaces.orig" && \
       -f "${BASELINE_DIR}/pvecm-status.orig" && \
       -f "${BASELINE_DIR}/pvecm-nodes.orig" && \
       -f "${BASELINE_DIR}/ip-address.orig" && \
       -f "${BASELINE_DIR}/ip-route.orig" ]]
}

network_backup_exists()
{
    baseline_exists && return 0
    find "${BACKUP_DIR}" -mindepth 2 -maxdepth 2 -type f -name interfaces -print -quit 2>/dev/null | grep -q .
}
ensure_network_backup()
{
    if network_backup_exists; then return 0; fi
    echo ""
    echo "尚未建立網路 Backup。"
    if ! confirm "是否現在建立 Backup？"; then
        log_info "未建立 Backup，取消此次網路變更。"
        pause_screen
        return 1
    fi
    create_baseline
    network_backup_exists
}

create_baseline()
{
    ensure_dirs

    if baseline_exists; then
        log_info "Baseline 已存在，不會自動覆蓋。"
        echo "保存位置：${BASELINE_DIR}"
        return 0
    fi

    log_step "建立 Network Baseline"
    echo ""
    echo "Baseline 是目前系統的原始退路。"
    echo ""
    echo "保存內容："
    echo "  - /etc/network/interfaces"
    echo "  - Cluster Status"
    echo "  - Cluster Nodes"
    echo "  - IP Address"
    echo "  - Routing"
    echo ""

    cp -a /etc/network/interfaces "${BASELINE_DIR}/interfaces.orig"
    pvecm status > "${BASELINE_DIR}/pvecm-status.orig" 2>&1 || true
    pvecm nodes > "${BASELINE_DIR}/pvecm-nodes.orig" 2>&1 || true
    ip -details address show > "${BASELINE_DIR}/ip-address.orig"
    ip route show table all > "${BASELINE_DIR}/ip-route.orig"
    date '+%Y-%m-%d %H:%M:%S %z' > "${BASELINE_DIR}/created-at"

    log_ok "Baseline 建立完成。"
    echo "保存位置：${BASELINE_DIR}"
}

show_baseline()
{
    echo "============================================================"
    echo " Network Baseline"
    echo "============================================================"
    echo ""
    if baseline_exists; then
        echo "狀態：已建立"
        echo "位置：${BASELINE_DIR}"
        [[ -f "${BASELINE_DIR}/created-at" ]] && echo "建立時間：$(cat "${BASELINE_DIR}/created-at")"
        echo ""
        echo "保存檔案："
        find "${BASELINE_DIR}" -maxdepth 1 -type f -printf '  - %f\n' | sort
    else
        echo "狀態：尚未建立"
    fi
}

save_interfaces_copy()
{
    local target="$1"
    cp -a /etc/network/interfaces "${target}"
}

write_vss_interfaces()
{
    local bridge="$1"
    local nic1="$2"
    local nic2="$3"
    local bond_mode="$4"
    local bond_hash="${BOND_XMIT_HASH_POLICY:-}"
    local lacp_rate="${BOND_LACP_RATE:-}"
    local bond_name=""
    local bridge_port="${nic1}"

    ensure_dirs
    GENERATED_INTERFACES_FILE="$(mktemp /tmp/pve-network-interfaces.XXXXXX)"
    local generated_file="${GENERATED_INTERFACES_FILE}"
    local temp

    cp -a /etc/network/interfaces "${generated_file}"

    # 第一版已驗證的核心生命週期：
    # Physical NIC → Bond（可選）→ Linux Bridge。
    # 2.0.17 只將既有 CLI 實作包進 VMware 風格 VSS / Physical Uplink UI。

    if [[ -n "${bond_mode}" ]]; then
        bridge_port="$(awk -v bridge="${bridge}" '
            BEGIN { RS=""; ORS="\n\n" }
            $0 ~ "(^|\n)auto[[:space:]]+" bridge "[[:space:]]*(\n|$)" {
                n=split($0,a,"\n")
                for(i=1;i<=n;i++)
                    if(a[i] ~ /^[[:space:]]*bridge-ports[[:space:]]+/) {
                        sub(/^[[:space:]]*bridge-ports[[:space:]]+/,"",a[i])
                        print a[i]
                        exit
                    }
            }
        ' "${generated_file}")"

        if [[ "${bridge_port}" =~ ^bond[0-9]+$ ]]; then
            bond_name="${bridge_port}"
        else
            local n=0
            while grep -qE "^auto bond${n}([[:space:]]|$)" "${generated_file}" 2>/dev/null; do
                n=$((n + 1))
            done
            bond_name="bond${n}"
            bridge_port="${bond_name}"
        fi
    fi

    temp="$(mktemp /tmp/pve-network-interfaces.XXXXXX)"

    awk -v bridge="${bridge}" \
        -v bridge_port="${bridge_port}" \
        -v bond="${bond_name}" \
        -v nic1="${nic1}" \
        -v nic2="${nic2}" \
        -v bond_mode="${bond_mode}" \
        -v bond_hash="${bond_hash}" \
        -v lacp_rate="${lacp_rate}" '
        BEGIN {
            RS=""
            ORS="\n\n"
            bridge_found=0
            bond_found=0
        }

        {
            is_bridge = ($0 ~ "(^|\n)auto[[:space:]]+" bridge "[[:space:]]*(\n|$)")
            is_bond = (bond != "" && $0 ~ "(^|\n)auto[[:space:]]+" bond "[[:space:]]*(\n|$)")

            if (is_bridge) {
                bridge_found=1
                n=split($0,a,"\n")
                out=""
                have_ports=0
                have_stp=0
                have_fd=0
                have_vlan_aware=0
                have_vlan_vids=0

                for(i=1;i<=n;i++) {
                    line=a[i]

                    if(line ~ /^[[:space:]]*bridge-ports[[:space:]]+/) {
                        line="    bridge-ports " bridge_port
                        have_ports=1
                    }
                    if(line ~ /^[[:space:]]*bridge-stp[[:space:]]+/) {
                        line="    bridge-stp off"
                        have_stp=1
                    }
                    if(line ~ /^[[:space:]]*bridge-fd[[:space:]]+/) {
                        line="    bridge-fd 0"
                        have_fd=1
                    }
                    if(line ~ /^[[:space:]]*bridge-vlan-aware[[:space:]]+/) {
                        line="    bridge-vlan-aware yes"
                        have_vlan_aware=1
                    }
                    if(line ~ /^[[:space:]]*bridge-vids[[:space:]]+/) {
                        line="    bridge-vids 2-4094"
                        have_vlan_vids=1
                    }

                    out=out (out=="" ? "" : "\n") line
                }

                if(!have_ports) out=out "\n    bridge-ports " bridge_port
                if(!have_stp) out=out "\n    bridge-stp off"
                if(!have_fd) out=out "\n    bridge-fd 0"
                if(!have_vlan_aware) out=out "\n    bridge-vlan-aware yes"
                if(!have_vlan_vids) out=out "\n    bridge-vids 2-4094"

                print out
                next
            }

            if (is_bond) {
                bond_found=1
                n=split($0,a,"\n")
                out=""
                have_slaves=0
                have_miimon=0
                have_mode=0
                have_primary=0
                have_hash=0
                have_lacp=0

                for(i=1;i<=n;i++) {
                    line=a[i]

                    if(line ~ /^[[:space:]]*bond-slaves[[:space:]]+/) {
                        line="    bond-slaves " nic1 " " nic2
                        have_slaves=1
                    }
                    if(line ~ /^[[:space:]]*bond-miimon[[:space:]]+/) {
                        line="    bond-miimon 100"
                        have_miimon=1
                    }
                    if(line ~ /^[[:space:]]*bond-mode[[:space:]]+/) {
                        line="    bond-mode " bond_mode
                        have_mode=1
                    }
                    if(line ~ /^[[:space:]]*bond-primary[[:space:]]+/) {
                        if(bond_mode=="active-backup") {
                            line="    bond-primary " nic1
                            have_primary=1
                        } else {
                            line=""
                        }
                    }
                    if(line ~ /^[[:space:]]*bond-xmit-hash-policy[[:space:]]+/) {
                        if(bond_hash!="") {
                            line="    bond-xmit-hash-policy " bond_hash
                            have_hash=1
                        } else {
                            line=""
                        }
                    }
                    if(line ~ /^[[:space:]]*bond-lacp-rate[[:space:]]+/) {
                        if(bond_mode=="802.3ad" && lacp_rate!="") {
                            line="    bond-lacp-rate " lacp_rate
                            have_lacp=1
                        } else {
                            line=""
                        }
                    }

                    if(line!="") out=out (out=="" ? "" : "\n") line
                }

                if(!have_slaves) out=out "\n    bond-slaves " nic1 " " nic2
                if(!have_miimon) out=out "\n    bond-miimon 100"
                if(!have_mode) out=out "\n    bond-mode " bond_mode
                if(bond_mode=="active-backup" && !have_primary) out=out "\n    bond-primary " nic1
                if(bond_hash!="" && !have_hash) out=out "\n    bond-xmit-hash-policy " bond_hash
                if(bond_mode=="802.3ad" && lacp_rate!="" && !have_lacp) out=out "\n    bond-lacp-rate " lacp_rate

                print out
                next
            }

            print
        }

        END {
            if(!bridge_found) {
                print "auto " bridge
                print "iface " bridge " inet manual"
                print "    bridge-ports " bridge_port
                print "    bridge-stp off"
                print "    bridge-fd 0"
                print "    bridge-vlan-aware yes"
                print "    bridge-vids 2-4094"
            }

            if(bond!="" && !bond_found) {
                print "auto " bond
                print "iface " bond " inet manual"
                print "    bond-slaves " nic1 " " nic2
                print "    bond-miimon 100"
                print "    bond-mode " bond_mode
                if(bond_mode=="active-backup")
                    print "    bond-primary " nic1
                if(bond_hash!="")
                    print "    bond-xmit-hash-policy " bond_hash
                if(bond_mode=="802.3ad" && lacp_rate!="")
                    print "    bond-lacp-rate " lacp_rate
            }
        }
    ' "${generated_file}" > "${temp}"

    install -m 0644 "${temp}" "${generated_file}"
    rm -f "${temp}"
}


create_change_id()
{
    printf 'CHG-%s' "$(date '+%Y%m%d-%H%M%S')"
}

create_change_backup()
{
    local change_id="$1"
    local target="${BACKUP_DIR}/${change_id}"
    ensure_dirs
    mkdir -p "${target}"
    cp -a /etc/network/interfaces "${target}/interfaces"
    [[ -f "${STATE_FILE}" ]] && cp -a "${STATE_FILE}" "${target}/state"
    ip -details address show > "${target}/ip-address"
    ip route show table all > "${target}/ip-route"
    ip -details link show > "${target}/ip-link"
    pvecm status > "${target}/cluster-status" 2>&1 || true
}

restore_change_backup()
{
    local change_id="$1"
    local source="${BACKUP_DIR}/${change_id}/interfaces"
    [[ -f "${source}" ]] || { log_error "找不到 Recovery Backup：${source}"; return 1; }
    install -m 0644 "${source}" /etc/network/interfaces
    if ! ifreload -a; then
        log_error "Recovery Apply 失敗。"
        return 1
    fi
    mkdir -p "${RECOVERY_DIR}/${change_id}"
    cp -a "${source}" "${RECOVERY_DIR}/${change_id}/interfaces.restored"
    if [[ -f "${BACKUP_DIR}/${change_id}/state" ]]; then
        cp -a "${BACKUP_DIR}/${change_id}/state" "${STATE_FILE}"
        cp -a "${BACKUP_DIR}/${change_id}/state" "${RECOVERY_DIR}/${change_id}/state.restored"
    fi
}

network_pending_configuration_exists()
{
    [[ -f /etc/network/interfaces.new && -s /etc/network/interfaces.new ]]
}

network_pending_guard()
{
    if ! network_pending_configuration_exists; then
        return 0
    fi

    echo ""
    echo "============================================================"
    echo " 偵測到 PVE GUI Pending Network Configuration"
    echo "============================================================"
    echo ""
    echo "目前存在尚未處理的 PVE GUI 網路設定："
    echo "  /etc/network/interfaces.new"
    echo ""
    echo "PVE NETWORK PRO 不會與 GUI Pending Configuration 同時修改網路。"
    echo "請先在 PVE GUI 完成："
    echo "  1) 套用設定"
    echo "  或"
    echo "  2) 取消 / 清除 Pending Configuration"
    echo ""
    echo "目前網路變更已停止。"
    echo "============================================================"
    return 1
}

apply_interfaces_file()
{
    local change_id="$1"
    local source="$2"

    network_pending_guard || return 1

    [[ -f "${source}" ]] || {
        log_error "找不到要套用的網路設定：${source}"
        return 1
    }

    if command -v ifquery >/dev/null 2>&1; then
        if ! ifquery --list -i "${source}" >/dev/null 2>&1; then
            log_error "網路設定語法驗證失敗。"
            return 1
        fi
    fi

    create_change_backup "${change_id}"
    log_step "套用網路設定：${change_id}"
    install -m 0644 "${source}" /etc/network/interfaces
    if ! ifreload -a; then
        log_error "套用失敗，開始 Recovery：${change_id}"
        restore_change_backup "${change_id}" || true
        return 1
    fi
    log_ok "網路設定套用完成：${change_id}"
}

validate_interfaces_syntax()
{
    if command -v ifquery >/dev/null 2>&1; then
        ifquery --list >/dev/null 2>&1 || return 1
    fi
    return 0
}

save_state()
{
    local type="$1"
    local key="$2"
    local value="$3"
    ensure_dirs
    remove_state_entry "${type}" "${key}" 2>/dev/null || true
    printf '%s\t%s\t%s\n' "${type}" "${key}" "${value}" >> "${STATE_FILE}"
}

state_has()
{
    local type="$1" key="$2"
    [[ -f "${STATE_FILE}" ]] || return 1
    awk -F '\t' -v t="${type}" -v k="${key}" '$1==t && $2==k {found=1} END{exit !found}' "${STATE_FILE}"
}

remove_state_entry()
{
    local type="$1" key="$2"
    [[ -f "${STATE_FILE}" ]] || return 0
    awk -F '\t' -v t="${type}" -v k="${key}" '!( $1==t && $2==k )' "${STATE_FILE}" > "${STATE_FILE}.tmp"
    mv -f "${STATE_FILE}.tmp" "${STATE_FILE}"
}

cluster_guard()
{
    if ! cluster_joined; then
        log_error "PVE Cluster 狀態無法確認，停止變更。"
        return 1
    fi
    if ! cluster_quorate; then
        log_error "Cluster Quorum 不正常，停止網路變更。"
        return 1
    fi
    return 0
}

network_snapshot()
{
    local file="$1"
    {
        echo "===== date ====="
        date
        echo "===== interfaces ====="
        ip -details address show
        echo "===== routes ====="
        ip route show table all
        echo "===== links ====="
        ip -details link show
    } > "${file}"
}

validate_network_after_change()
{
    local bridge="$1"
    local before_cluster after_cluster

    log_step "驗證網路與 Cluster 狀態"

    if ! ip link show "${bridge}" >/dev/null 2>&1; then
        log_error "Bridge ${bridge} 不存在。"
        return 1
    fi

    if ! ip link show "${bridge}" | grep -q 'state UP\|state UNKNOWN'; then
        log_error "Bridge ${bridge} 狀態異常。"
        return 1
    fi

    before_cluster="$(cluster_status_text)"
    if ! cluster_quorate; then
        log_error "變更後 Cluster Quorum 不正常：${before_cluster}"
        return 1
    fi
    after_cluster="$(cluster_status_text)"

    log_ok "Bridge ${bridge} 驗證完成。"
    log_ok "Cluster：${after_cluster}"
    return 0
}

apply_interfaces()
{
    local source="$1"
    local change_id
    change_id="$(create_change_id)"
    [[ -f "${source}" ]] || { log_error "找不到要套用的網路設定。"; return 1; }
    apply_interfaces_file "${change_id}" "${source}"
}

vss_create()
{
    show_header
    echo "============================================================"
    echo " VSS 管理 - 建立 Virtual Switch"
    echo "============================================================"
    echo ""
    echo "VMware 模型：先建立 Virtual Switch，再另外設定 Physical Uplink。"
    echo "PVE 對應：Virtual Switch = Linux Bridge；Bridge 名稱不強制使用 vmbrX。"
    echo ""

    cluster_guard || { pause_screen; return 0; }

    if ! ensure_network_backup; then return 0; fi


    if ! select_bridge; then
        pause_screen
        return 0
    fi

    local bridge="${SELECTED_BRIDGE}"

    echo ""
    echo "------------------------------------------------------------"
    echo " Virtual Switch 建立確認"
    echo "------------------------------------------------------------"
    echo " Virtual Switch ：$(get_vswitch_name "${bridge}")"
    echo " PVE Bridge     ：${bridge}"
    echo " Physical Uplink：稍後設定"
    echo " Port Group     ：稍後建立"
    echo " VMkernel       ：沿用現有管理介面，另行管理"
    echo "------------------------------------------------------------"
    echo ""

    if ! confirm "確認建立 / 註冊 Virtual Switch $(get_vswitch_name "${bridge}")？"; then
        log_info "已取消。"
        pause_screen
        return 0
    fi

    ensure_dirs

    if [[ -e "/sys/class/net/${bridge}" ]]; then
        remove_state_entry "VSS" "nic1"
        remove_state_entry "VSS" "nic2"
        remove_state_entry "VSS" "bond_mode"
        save_state "VSS" "bridge" "${bridge}"
        log_ok "Virtual Switch $(get_vswitch_name "${bridge}") 已建立 / 註冊。"
        echo "注意：本步驟不選 NIC、不建立 Bond、不變更 Uplink。"
        echo "下一步請使用「VSS Uplink 管理」設定 nic2 / nic3。"
        pause_screen
        return 0
    fi

    log_step "建立新的 Linux Bridge：${bridge}"
    save_interfaces_copy "${VSS_DIR}/interfaces.before"
    network_snapshot "${VSS_DIR}/network.before"

    local generated_file
    generated_file="$(mktemp /tmp/pve-network-interfaces.XXXXXX)"
    cp -a /etc/network/interfaces "${generated_file}"

    cat >> "${generated_file}" <<EOF

auto ${bridge}
iface ${bridge} inet manual
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
    bridge-vids 2-4094
EOF

    if ! apply_interfaces "${generated_file}"; then
        log_error "VSS ${bridge} 建立 / 套用失敗。"
        cp -a "${VSS_DIR}/interfaces.before" /etc/network/interfaces
        ifreload -a || true
        pause_screen
        return 1
    fi
    rm -f "${GENERATED_INTERFACES_FILE}"
    GENERATED_INTERFACES_FILE=""

    if ! validate_network_after_change "${bridge}"; then
        log_error "VSS ${bridge} 驗證失敗。"
        echo "變更前設定保存於：${VSS_DIR}/interfaces.before"
        pause_screen
        return 1
    fi

    save_state "VSS" "bridge" "${bridge}"
    cp -a /etc/network/interfaces "${VSS_DIR}/interfaces.vss"
    log_ok "VSS ${bridge} 建立完成。"
    echo "目前尚未設定 Uplink。"
    pause_screen
}

vss_uplink_add()
{
    show_header
    echo "============================================================"
    echo " Physical Uplink 管理 - 新增 / 設定 Uplink"
    echo "============================================================"
    echo ""
    echo "VMware 模型：Virtual Switch 建立後，再指定 Physical Uplink。"
    echo "PVE 對應：Physical NIC → Bond（可選）→ Linux Bridge。"
    echo ""

    cluster_guard || { pause_screen; return 0; }

    if ! ensure_network_backup; then return 0; fi


    local -a bridges=()
    local bridge choice
    while read -r bridge; do
        [[ -n "${bridge}" ]] && bridges+=("${bridge}")
    done < <(get_linux_bridges)

    if (("${#bridges[@]}" == 0)); then
        log_error "找不到 VSS / vmbr。請先建立 VSS。"
        pause_screen
        return 0
    fi

    echo "選擇 Virtual Switch："
    echo "（VMware 名稱為主，PVE Bridge 為註解）"
    local i=1
    for bridge in "${bridges[@]}"; do
        printf "  %2d) %-12s  PVE：%s\n" "${i}" "$(get_vswitch_name "${bridge}")" "${bridge}"
        i=$((i + 1))
    done
    echo "   0) 返回"
    while true; do
        read -r -p "請選擇：" choice
        if [[ "${choice}" == "0" ]]; then
            return 0
        fi
        if [[ "${choice}" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#bridges[@]})); then
            bridge="${bridges[$((choice - 1))]}"
            break
        fi
        log_error "選擇無效。"
    done

    if ! select_nic "請選擇第一張 Physical NIC"; then
        pause_screen
        return 0
    fi
    local first_nic="${SELECTED_NIC}"
    if nic_used_elsewhere "${first_nic}" "${bridge}"; then
        log_error "NIC ${first_nic} 已被其他 Bridge / Bond 使用，停止 Uplink 變更。"
        pause_screen
        return 0
    fi
    select_bond_mode
    local second_nic=""
    if [[ -n "${BOND_MODE}" ]]; then
        select_second_nic "${first_nic}"
        if [[ -z "${SECONDARY_NIC}" ]]; then
            log_error "選擇 Bond 模式時必須使用兩張實體 NIC。"
            pause_screen
            return 0
        fi
        second_nic="${SECONDARY_NIC}"
        if nic_used_elsewhere "${second_nic}" "${bridge}"; then
            log_error "NIC ${second_nic} 已被其他 Bridge / Bond 使用，停止 Uplink 變更。"
            pause_screen
            return 0
        fi
    fi
    get_management_info

    echo ""
    echo "------------------------------------------------------------"
    echo " Physical Uplink 確認"
    echo "------------------------------------------------------------"
    echo " Virtual Switch：$(get_vswitch_name "${bridge}")"
    echo " PVE Bridge    ：${bridge}"
    echo " Physical NIC 1：${first_nic}"
    echo " Physical NIC 2：${second_nic:-未使用}"
    echo " NIC Teaming    ：${BOND_MODE:-不使用 Bond}"
    echo " VMkernel IP   ：${CURRENT_IP:-未偵測}"
    echo " Gateway       ：${CURRENT_GW:-未偵測}"
    echo "------------------------------------------------------------"
    echo ""
    echo "PVE 實作：Physical NIC → Bond（可選）→ Linux Bridge；Bridge 名稱不固定為 vmbrX。"
    echo ""

    if ! confirm "確認套用 VSS Uplink？"; then
        log_info "已取消。"
        pause_screen
        return 0
    fi

    ensure_dirs
    save_interfaces_copy "${VSS_DIR}/interfaces.before-uplink"
    network_snapshot "${VSS_DIR}/network.before-uplink"

    if ! write_vss_interfaces "${bridge}" "${first_nic}" "${second_nic}" "${BOND_MODE}"; then
        rm -f "${GENERATED_INTERFACES_FILE:-}"
        GENERATED_INTERFACES_FILE=""
        log_error "VSS Uplink 設定檔建立失敗。"
        pause_screen
        return 1
    fi

    if ! apply_interfaces "${GENERATED_INTERFACES_FILE}"; then
        rm -f "${GENERATED_INTERFACES_FILE}"
        GENERATED_INTERFACES_FILE=""
        log_error "VSS Uplink 套用失敗，立即嘗試還原。"
        cp -a "${VSS_DIR}/interfaces.before-uplink" /etc/network/interfaces
        ifreload -a || true
        pause_screen
        return 1
    fi
    rm -f "${GENERATED_INTERFACES_FILE}"
    GENERATED_INTERFACES_FILE=""

    if ! validate_network_after_change "${bridge}"; then
        log_error "VSS Uplink 驗證失敗，開始 Recovery。"
        local recovery_change_id
        recovery_change_id="$(create_change_id)"
        if apply_interfaces_file "${recovery_change_id}" "${VSS_DIR}/interfaces.before-uplink"; then
            log_ok "VSS Uplink 已依變更前設定完成 Recovery。"
        else
            log_error "VSS Uplink 自動 Recovery 套用失敗。"
        fi
        echo "變更前設定保存於：${VSS_DIR}/interfaces.before-uplink"
        pause_screen
        return 1
    fi

    save_state "VSS" "bridge" "${bridge}"
    save_state "VSS" "nic1" "${first_nic}"
    remove_state_entry "VSS" "nic2"
    if [[ -n "${second_nic}" ]]; then
        save_state "VSS" "nic2" "${second_nic}"
    fi
    save_state "VSS" "bond_mode" "${BOND_MODE:-none}"
    cp -a /etc/network/interfaces "${VSS_DIR}/interfaces.vss"

    log_ok "Physical Uplink 設定生效完成。"
    echo "Virtual Switch $(get_vswitch_name "${bridge}") 現已具備 Physical Uplink。"
    echo "PVE Bridge：${bridge}"
    pause_screen
}

vss_show()
{
    show_header
    echo "============================================================"
    echo " VSS / vSwitch 目前設定"
    echo "============================================================"
    echo ""

    echo "Virtual Switch / VSS："
    echo ""

    local bridge uplink
    while read -r bridge; do
        [[ -n "${bridge}" ]] || continue
        echo "  Virtual Switch：$(get_vswitch_name "${bridge}")"
        echo "  PVE Bridge     ：${bridge}"
        echo "  Physical Uplink："

        local -a ports=()
        if [[ -d "/sys/class/net/${bridge}/brif" ]]; then
            while read -r uplink; do
                [[ -n "${uplink}" ]] || continue
                ports+=("${uplink}")
            done < <(find "/sys/class/net/${bridge}/brif" -maxdepth 1 -mindepth 1 -type l -printf "%f\n" 2>/dev/null | sort -V)
        fi

        if ((${#ports[@]} == 0)); then
            echo "    狀態：尚未設定 Physical Uplink"
        else
            for uplink in "${ports[@]}"; do
                if [[ -f "/proc/net/bonding/${uplink}" ]]; then
                    echo "    ${bridge} → ${uplink}"
                    echo "    模式：Bond"
                    grep -E "Bonding Mode|MII Status|Currently Active Slave|Slave Interface" "/proc/net/bonding/${uplink}" | sed "s/^/      /" || true
                else
                    echo "    ${bridge} → ${uplink}"
                    echo "    模式：單 NIC，未使用 Bond"
                fi
            done
        fi
        echo ""
    done < <(get_linux_bridges)

    echo "Port Group："
    port_group_list_vss
    echo ""
    echo "VMkernel / Management："
    get_management_info
    echo "  Device ：${DEV_WITH_GW:-未偵測}"
    echo "  IP     ：${CURRENT_IP:-未偵測}"
    echo "  Gateway：${CURRENT_GW:-未偵測}"
    pause_screen
}


vss_vmkernel_menu()
{
    show_header
    echo "============================================================"
    echo " VMkernel Adapter / Management"
    echo "============================================================"
    echo ""
    echo "目前僅提供管理介面資訊檢視。"
    echo "Management IP、Gateway 與 Cluster Network 不在此處直接修改。"
    echo ""

    get_management_info

    echo " Device ：${DEV_WITH_GW:-未偵測}"
    echo " IP     ：${CURRENT_IP:-未偵測}"
    echo " Gateway：${CURRENT_GW:-未偵測}"

    pause_screen
}

vss_physical_uplink_menu()
{
    while true; do
        show_header
        echo "============================================================"
        echo " Physical Uplink"
        echo "============================================================"
        echo ""
        echo "VMware 模型：VSS → Physical Uplink → NIC / NIC Teaming."
        echo "PVE 實作：NIC / Bond → Linux Bridge。"
        echo ""
        echo "  1) Single NIC"
        echo "  2) NIC Teaming / Linux Bond"
        echo "  3) 查看 Uplink"
        echo "  0) 返回"
        echo ""

        local choice
        read -r -p "請選擇：" choice
        case "${choice}" in
            1)
                BOND_MODE=""
                BOND_XMIT_HASH_POLICY=""
                BOND_LACP_RATE=""
                vss_uplink_add
                ;;
            2)
                vss_uplink_add
                ;;
            3)
                vss_show
                ;;
            0) return 0 ;;
            *) log_error "選擇無效。"; sleep 1 ;;
        esac
    done
}

vss_setup()
{
    while true; do
        show_header
        echo "============================================================"
        echo " Virtual Switch / VSS"
        echo "============================================================"
        echo ""
        echo "  1) Virtual Switch"
        echo "  2) Physical Uplink"
        echo "  3) Port Group"
        echo "  4) VMkernel Adapter / Management"
        echo "  5) 查看"
        echo "  0) 返回"
        echo ""
        local choice
        read -r -p "請選擇：" choice
        case "${choice}" in
            1) vss_create ;;
            2) vss_physical_uplink_menu ;;
            3) vss_port_group_menu ;;
            4) vss_vmkernel_menu ;;
            5) vss_show ;;
            0) return 0 ;;
            *) log_error "選擇無效。"; sleep 1 ;;
        esac
    done
}


show_vds_config()
{
    echo "============================================================"
    echo " VDS / SDN 目前設定"
    echo "============================================================"
    echo ""

    if ! pvesh get /cluster/sdn/zones 2>/dev/null; then
        echo "目前沒有可讀取的 SDN Zone，或 SDN 尚未初始化。"
    fi
    echo ""
    if ! pvesh get /cluster/sdn/vnets 2>/dev/null; then
        echo "目前沒有可讀取的 SDN VNet。"
    fi
}

select_sdn_zone()
{
    local choice
    echo "============================================================"
    echo " 分散式交換器（VDS / SDN）"
    echo "============================================================"    echo ""
    echo "  1) 建立新的 SDN Zone"
    echo "  2) 使用現有 SDN Zone"
    echo "  0) 返回"
    echo ""

    while true; do
        read -r -p "請選擇：" choice
        case "${choice}" in
            1)
                while true; do
                    read -r -p "SDN Zone 名稱：" SDN_ZONE
                    [[ "${SDN_ZONE}" =~ ^[A-Za-z0-9_-]+$ ]] || { log_error "Zone 名稱只能使用英數、底線、連字號。"; continue; }
                    if pvesh get "/cluster/sdn/zones/${SDN_ZONE}" >/dev/null 2>&1; then
                        log_error "Zone ${SDN_ZONE} 已存在。"
                    else
                        return 0
                    fi
                done
                ;;
            2)
                local -a zones=()
                local zone
                while read -r zone; do
                    [[ -n "${zone}" ]] && zones+=("${zone}")
                done < <(pvesh get /cluster/sdn/zones --output-format json 2>/dev/null | sed -n 's/.*"zone"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

                if ((${#zones[@]} == 0)); then
                    log_error "找不到現有 SDN Zone。"
                    continue
                fi

                local i=1
                for zone in "${zones[@]}"; do
                    printf "  %2d) %s\n" "$i" "$zone"
                    i=$((i + 1))
                done

                echo "  0) 返回"
                while true; do
                    read -r -p "請選擇：" choice
                    if [[ "${choice}" == "0" ]]; then
                        return 1
                    fi
                    if [[ "${choice}" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#zones[@]})); then
                        SDN_ZONE="${zones[$((choice - 1))]}"
                        return 0
                    fi
                    log_error "選擇無效。"
                done
                ;;
            0) return 1 ;;
            *) log_error "選擇無效。" ;;
        esac
    done
}

select_sdn_bridge()
{
    local -a bridges=()
    local bridge choice
    while read -r bridge; do
        [[ -n "${bridge}" ]] && bridges+=("${bridge}")
    done < <(get_linux_bridges)

    ((${#bridges[@]} > 0)) || die "找不到 vmbr Bridge。請先建立 VSS / Bridge。"

    echo ""
    echo "承載 VDS / SDN 的底層 Bridge："
    local i=1
    for bridge in "${bridges[@]}"; do
        printf "  %2d) %s\n" "$i" "$bridge"
        i=$((i + 1))
    done

    echo "  0) 返回"
    while true; do
        read -r -p "請選擇：" choice
        if [[ "${choice}" == "0" ]]; then
            return 1
        fi
        if [[ "${choice}" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#bridges[@]})); then
            SDN_BRIDGE="${bridges[$((choice - 1))]}"
            return 0
        fi
        log_error "選擇無效。"
    done
}

vds_create_zone()
{
    local zone="$1" bridge="$2"
    log_step "建立 SDN Zone：${zone}"
    pvesh create /cluster/sdn/zones --zone "${zone}" --type vlan --bridge "${bridge}"
}

vds_create_vnet()
{
    local zone="$1" vnet="$2" tag="$3"
    log_step "建立 VNet / Port Group：${vnet} / VLAN ${tag}"
    pvesh create /cluster/sdn/vnets --vnet "${vnet}" --zone "${zone}" --tag "${tag}"
}

valid_vlan_id()
{
    local vlan="$1"
    [[ "${vlan}" =~ ^[0-9]+$ ]] && ((vlan >= 1 && vlan <= 4094))
}

port_group_exists_sdn()
{
    local vnet="$1"
    pvesh get "/cluster/sdn/vnets/${vnet}" >/dev/null 2>&1
}

vds_configure()
{
    show_header
    echo "============================================================"
    echo " VDS 設定"
    echo " Distributed Virtual Switch / SDN"
    echo "============================================================"
    echo ""

    cluster_guard || { pause_screen; return 0; }

    if ! ensure_network_backup; then return 0; fi

    select_sdn_zone || { pause_screen; return 0; }
    if ! select_sdn_bridge; then
        pause_screen
        return 0
    fi

    echo ""
    echo "------------------------------------------------------------"
    echo " VDS / SDN 設定確認"
    echo "------------------------------------------------------------"
    echo " SDN Zone ：${SDN_ZONE}"
    echo " Bridge   ：${SDN_BRIDGE}"
    echo "------------------------------------------------------------"
    echo ""

    local zone_was_created=0
    if ! pvesh get "/cluster/sdn/zones/${SDN_ZONE}" >/dev/null 2>&1; then
        if ! confirm "確認建立 SDN Zone ${SDN_ZONE}？"; then
            pause_screen
            return 0
        fi
        vds_create_zone "${SDN_ZONE}" "${SDN_BRIDGE}"
        zone_was_created=1
        save_state "VDS_ZONE" "${SDN_ZONE}" "${SDN_BRIDGE}"
    else
        log_info "使用現有 SDN Zone：${SDN_ZONE}"
    fi

    echo ""
    echo "Port Group / VNet 可以稍後由選單建立。"
    echo ""
    if confirm "現在立即 Apply SDN？"; then
        pvesh set /cluster/sdn
        log_ok "SDN Apply 完成。"
    fi

    if ((zone_was_created == 1)); then
        log_ok "VDS / SDN Zone 建立完成。"
    fi
    pause_screen
}

vds_setup()
{
    while true; do
        show_header
        echo "============================================================"
        echo " Distributed Virtual Switch / VDS"
        echo "============================================================"
        echo ""
        echo "  1) Distributed Virtual Switch"
        echo "  2) Port Group"
        echo "  3) 查看"
        echo "  0) 返回"
        echo ""
        local choice
        read -r -p "請選擇：" choice
        case "${choice}" in
            1) vds_configure ;;
            2) vds_port_group_create ;;
            3) show_vds_config; pause_screen ;;
            0) return 0 ;;
            *) log_error "選擇無效。"; sleep 1 ;;
        esac
    done
}


port_group_list_vss()
{
    echo "============================================================"
    echo " Port Group"
    echo "============================================================"
    echo ""
    echo "VMware 模型：Port Group = 名稱 + VLAN ID + Virtual Switch。"
    echo "PVE 實作：VLAN Sub-interface + Linux Bridge；不建立 SDN VNet。"
    echo ""

    local found=0
    if [[ -f "${STATE_FILE}" ]]; then
        while IFS=$'\t' read -r type name value; do
            [[ "${type}" == "VSS_PORT_GROUP" ]] || continue
            found=1
            local bridge
            bridge="$(awk -F '\t' -v n="${name}" '$1=="VSS_PORT_GROUP_BRIDGE" && $2==n {print $3; exit}' "${STATE_FILE}")"
            printf "  - %-20s VLAN ID=%-5s Bridge=%s\n" "${name}" "${value}" "${bridge:-未知}"
        done < "${STATE_FILE}"
    fi

    ((found == 1)) || echo "目前沒有 VSS Port Group。"
}

port_group_list_vds()
{
    echo "============================================================"
    echo " VDS Port Group / VNet"
    echo "============================================================"
    echo ""

    pvesh get /cluster/sdn/vnets 2>/dev/null || true
    echo ""
    echo "目前記錄的本工具 VDS Port Group："
    if [[ -f "${STATE_FILE}" ]]; then
        awk -F '\t' '$1=="PORT_GROUP" {printf "  - %-20s VLAN ID=%s\n", $2, $3}' "${STATE_FILE}"
    fi
}

port_group_list()
{
    show_header
    echo "============================================================"
    echo " Port Group 管理 - 目前設定"
    echo "============================================================"
    echo ""
    port_group_list_vss
    echo ""
    port_group_list_vds
}

vss_port_group_create()
{
    show_header
    echo "============================================================"
    echo " VSS Port Group 建立"
    echo " Standard Virtual Switch / Linux Bridge"
    echo "============================================================"
    echo ""

    cluster_guard || { pause_screen; return 0; }

    if ! ensure_network_backup; then return 0; fi

    local -a bridges=()
    local bridge choice
    while read -r bridge; do
        [[ -n "${bridge}" ]] && bridges+=("${bridge}")
    done < <(get_linux_bridges)

    if (("${#bridges[@]}" == 0)); then
        log_error "找不到 vmbr Bridge。請先建立 VSS / Bridge。"
        pause_screen
        return 0
    fi

    echo "選擇 Virtual Switch："
    echo "（VMware 名稱為主，PVE Bridge 為註解）"
    local i=1
    for bridge in "${bridges[@]}"; do
        printf "  %2d) %-12s  PVE：%s\n" "${i}" "$(get_vswitch_name "${bridge}")" "${bridge}"
        i=$((i + 1))
    done
    echo "   0) 返回"

    while true; do
        read -r -p "請選擇：" choice
        if [[ "${choice}" == "0" ]]; then pause_screen; return 0; fi
        if [[ "${choice}" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#bridges[@]})); then
            bridge="${bridges[$((choice - 1))]}"
            break
        fi
        log_error "選擇無效，請輸入上方數字。"
    done

    local vnet vlan vlan_dev
    while true; do
        read -r -p "Port Group 名稱：" vnet
        [[ "${vnet}" =~ ^[A-Za-z0-9_-]+$ ]] || { log_error "名稱只能使用英數、底線、連字號。"; continue; }
        if state_has "VSS_PORT_GROUP" "${vnet}" || ip link show "${vnet}" >/dev/null 2>&1; then
            log_error "VSS Port Group / PVE Bridge ${vnet} 已存在。"
            continue
        fi
        break
    done

    while true; do
        read -r -p "VLAN ID：" vlan
        valid_vlan_id "${vlan}" || { log_error "VLAN ID 必須為 1～4094。"; continue; }
        vlan_dev="${bridge}.${vlan}"
        if ip link show "${vlan_dev}" >/dev/null 2>&1 || grep -qE "^auto[[:space:]]+${vlan_dev}([[:space:]]|$)" /etc/network/interfaces; then
            log_error "VLAN 子介面已存在：${vlan_dev}"
            continue
        fi
        break
    done

    echo ""
    echo "------------------------------------------------------------"
    echo " VSS Port Group 確認"
    echo "------------------------------------------------------------"
    echo " Port Group     ：${vnet}"
    echo " VLAN ID        ：${vlan}"
    echo " VLAN Interface ：${vlan_dev}"
    echo " Virtual Switch ：$(get_vswitch_name "${bridge}")"
    echo " PVE Bridge     ：${bridge}"
    echo "------------------------------------------------------------"
    echo ""

    if ! confirm "確認建立？"; then pause_screen; return 0; fi

    local generated_file
    generated_file="$(mktemp /tmp/pve-network-interfaces.XXXXXX)"
    cp -a /etc/network/interfaces "${generated_file}"

    cat >> "${generated_file}" <<EOF

auto ${vlan_dev}
iface ${vlan_dev} inet manual

auto ${vnet}
iface ${vnet} inet manual
    bridge-ports ${vlan_dev}
    bridge-stp off
    bridge-fd 0
EOF

    local change_id
    change_id="$(create_change_id)"
    log_step "已完成設定整理，準備 Backup 並套用網路設定。"
    if ! apply_interfaces_file "${change_id}" "${generated_file}"; then
        rm -f "${generated_file}"
        log_error "VSS Port Group ${vnet} 建立失敗，已嘗試 Recovery。"
        pause_screen
        return 1
    fi
    rm -f "${generated_file}"

    save_state "VSS_PORT_GROUP" "${vnet}" "${vlan}"
    save_state "VSS_PORT_GROUP_BRIDGE" "${vnet}" "${bridge}"
    save_state "VSS_PORT_GROUP_VLAN_DEV" "${vnet}" "${vlan_dev}"

    log_ok "Port Group 建立完成：${vnet} / VLAN ${vlan}"
    echo ""
    echo "PVE 實際網路物件已建立："
    echo "  VLAN Interface：${vlan_dev}"
    echo "  Bridge / Port Group：${vnet}"
    echo "  Virtual Switch：$(get_vswitch_name "${bridge}")"
    echo ""
    echo "VM 可直接使用 PVE Bridge：${vnet}"
    pause_screen
}


vds_port_group_create()
{
    show_header
    echo "============================================================"
    echo " VDS Port Group 建立"
    echo "============================================================"
    echo ""
    cluster_guard || { pause_screen; return 0; }
    if ! ensure_network_backup; then return 0; fi
    local zone="" vnet="" tag=""
    if ! select_sdn_zone; then pause_screen; return 0; fi
    zone="${SDN_ZONE}"
    while true; do
        read -r -p "Port Group / VNet 名稱：" vnet
        [[ "${vnet}" =~ ^[A-Za-z0-9_-]+$ ]] || { log_error "名稱只能使用英數、底線、連字號。"; continue; }
        port_group_exists_sdn "${vnet}" && { log_error "VNet 已存在：${vnet}"; continue; }
        break
    done
    while true; do
        read -r -p "VLAN ID：" tag
        valid_vlan_id "${tag}" || { log_error "VLAN ID 必須為 1～4094。"; continue; }
        break
    done
    if ! confirm "確認建立 VDS Port Group ${vnet} / VLAN ${tag}？"; then pause_screen; return 0; fi
    if ! vds_create_vnet "${zone}" "${vnet}" "${tag}"; then
        log_error "VDS Port Group 建立失敗。"
        pause_screen
        return 1
    fi
    save_state "PORT_GROUP" "${vnet}" "${tag}"
    save_state "PORT_GROUP_ZONE" "${vnet}" "${zone}"
    pvesh set /cluster/sdn
    log_ok "VDS Port Group 建立完成：${vnet} / VLAN ${tag}"
    pause_screen
}

vds_port_group_delete()
{
    show_header
    echo "============================================================"
    echo " VDS Port Group 刪除"
    echo "============================================================"
    echo ""
    cluster_guard || { pause_screen; return 0; }
    if ! ensure_network_backup; then return 0; fi
    local -a vnets=()
    local vnet choice
    while read -r vnet; do [[ -n "${vnet}" ]] && vnets+=("${vnet}"); done < <(awk -F '\t' '$1=="PORT_GROUP" {print $2}' "${STATE_FILE}" 2>/dev/null || true)
    if ((${#vnets[@]} == 0)); then
        echo "目前沒有本工具建立的 VDS Port Group。"
        pause_screen
        return 0
    fi
    local i=1
    for vnet in "${vnets[@]}"; do
        local tag zone
        tag="$(awk -F '\t' -v n="${vnet}" '$1=="PORT_GROUP" && $2==n {print $3; exit}' "${STATE_FILE}")"
        zone="$(awk -F '\t' -v n="${vnet}" '$1=="PORT_GROUP_ZONE" && $2==n {print $3; exit}' "${STATE_FILE}")"
        printf "  %2d) %-20s VLAN=%-5s Zone=%s\n" "${i}" "${vnet}" "${tag:-未知}" "${zone:-未知}"
        i=$((i + 1))
    done
    echo "  0) 返回"
    while true; do
        read -r -p "請選擇：" choice
        [[ "${choice}" == "0" ]] && { pause_screen; return 0; }
        if [[ "${choice}" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#vnets[@]})); then
            vnet="${vnets[$((choice - 1))]}"
            break
        fi
        log_error "選擇無效。"
    done
    if ! confirm "確認刪除 VDS Port Group ${vnet}？"; then pause_screen; return 0; fi
    if pvesh get "/cluster/sdn/vnets/${vnet}" >/dev/null 2>&1; then
        if ! pvesh delete "/cluster/sdn/vnets/${vnet}"; then
            log_error "VDS Port Group 刪除失敗：${vnet}"
            pause_screen
            return 1
        fi
    fi
    remove_state_entry "PORT_GROUP" "${vnet}"
    remove_state_entry "PORT_GROUP_ZONE" "${vnet}"
    pvesh set /cluster/sdn
    log_ok "VDS Port Group 已刪除：${vnet}"
    pause_screen
}


vss_port_group_delete()
{
    show_header
    echo "============================================================"
    echo " VSS Port Group 刪除"
    echo "============================================================"
    echo ""
    cluster_guard || { pause_screen; return 0; }
    if ! ensure_network_backup; then return 0; fi

    echo "刪除會實際移除 /etc/network/interfaces 中的 VLAN Interface 與 Port Group Bridge。"
    echo ""

    local -a names=()
    local name choice
    while read -r name; do [[ -n "${name}" ]] && names+=("${name}"); done < <(awk -F '\t' '$1=="VSS_PORT_GROUP" {print $2}' "${STATE_FILE}" 2>/dev/null || true)

    if (("${#names[@]}" == 0)); then
        echo "沒有本工具建立的 VSS Port Group。"
        pause_screen
        return 0
    fi

    local i=1
    for name in "${names[@]}"; do
        local vlan bridge
        vlan="$(awk -F '\t' -v n="${name}" '$1=="VSS_PORT_GROUP" && $2==n {print $3; exit}' "${STATE_FILE}")"
        bridge="$(awk -F '\t' -v n="${name}" '$1=="VSS_PORT_GROUP_BRIDGE" && $2==n {print $3; exit}' "${STATE_FILE}")"
        printf "  %2d) %-20s VLAN=%-5s Bridge=%s\n" "${i}" "${name}" "${vlan:-未知}" "${bridge:-未知}"
        i=$((i + 1))
    done
    echo "  A) 全部刪除"
    echo "  0) 返回"

    while true; do
        read -r -p "請選擇： " choice
        [[ "${choice}" == "0" ]] && { pause_screen; return 0; }
        [[ "${choice}" =~ ^[Aa]$ ]] && break
        if [[ "${choice}" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#names[@]})); then
            name="${names[$((choice - 1))]}"
            break
        fi
        log_error "選擇無效。"
    done

    local -a targets=()
    if [[ "${choice}" =~ ^[Aa]$ ]]; then
        targets=("${names[@]}")
        echo ""
        echo "即將刪除全部 ${#targets[@]} 個 VSS Port Group："
        printf "  - %s\n" "${targets[@]}"
        echo ""
        if ! confirm "確認全部刪除？"; then pause_screen; return 0; fi
    else
        targets=("${name}")
        local vlan bridge vlan_dev
        vlan="$(awk -F '\t' -v n="${name}" '$1=="VSS_PORT_GROUP" && $2==n {print $3; exit}' "${STATE_FILE}")"
        bridge="$(awk -F '\t' -v n="${name}" '$1=="VSS_PORT_GROUP_BRIDGE" && $2==n {print $3; exit}' "${STATE_FILE}")"
        vlan_dev="$(awk -F '\t' -v n="${name}" '$1=="VSS_PORT_GROUP_VLAN_DEV" && $2==n {print $3; exit}' "${STATE_FILE}")"
        [[ -n "${vlan_dev}" ]] || vlan_dev="${bridge}.${vlan}"
        [[ -n "${bridge}" && -n "${vlan}" ]] || {
            log_error "Port Group ${name} 的 State 不完整，無法安全刪除。"
            pause_screen
            return 1
        }
        if ! confirm "確認刪除 VSS Port Group ${name}？"; then pause_screen; return 0; fi
    fi

    local generated_file
    generated_file="$(mktemp /tmp/pve-network-interfaces.XXXXXX)"
    cp -a /etc/network/interfaces "${generated_file}"
    local temp target_name
    log_step "準備刪除 VSS Port Group：${targets[*]}"
    for target_name in "${targets[@]}"; do
        log_step "處理 Port Group：${target_name}"
        temp="$(mktemp /tmp/pve-network-interfaces.XXXXXX)"
        awk -v pg="${target_name}" '
            BEGIN { RS=""; ORS="\n\n" }
            {
                keep=1
                if ($0 ~ "(^|\n)auto[[:space:]]+" pg "[[:space:]]*(\n|$)") keep=0
                if (keep) print
            }
        ' "${generated_file}" > "${temp}"
        install -m 0644 "${temp}" "${generated_file}"
        rm -f "${temp}"
    done

    # VLAN Interface 可能被多個 Port Group 共用；只有確認沒有其他 Tool-owned Port Group 使用時才移除。
    local -a vlan_devs=()
    local target_vlan_dev other_name used
    for target_name in "${targets[@]}"; do
        target_vlan_dev="$(awk -F '\t' -v n="${target_name}" '$1=="VSS_PORT_GROUP_VLAN_DEV" && $2==n {print $3; exit}' "${STATE_FILE}")"
        if [[ -z "${target_vlan_dev}" ]]; then
            local target_vlan target_bridge
            target_vlan="$(awk -F '\t' -v n="${target_name}" '$1=="VSS_PORT_GROUP" && $2==n {print $3; exit}' "${STATE_FILE}")"
            target_bridge="$(awk -F '\t' -v n="${target_name}" '$1=="VSS_PORT_GROUP_BRIDGE" && $2==n {print $3; exit}' "${STATE_FILE}")"
            target_vlan_dev="${target_bridge}.${target_vlan}"
        fi
        [[ -n "${target_vlan_dev}" ]] || continue
        used=0
        while read -r other_name; do
            [[ -n "${other_name}" ]] || continue
            local is_target=0
            for target_check in "${targets[@]}"; do
                [[ "${other_name}" == "${target_check}" ]] && { is_target=1; break; }
            done
            ((is_target == 1)) && continue
            local other_vlan_dev
            other_vlan_dev="$(awk -F '\t' -v n="${other_name}" '$1=="VSS_PORT_GROUP_VLAN_DEV" && $2==n {print $3; exit}' "${STATE_FILE}")"
            if [[ "${other_vlan_dev}" == "${target_vlan_dev}" ]]; then
                used=1
                break
            fi
        done < <(awk -F '\t' '$1=="VSS_PORT_GROUP" {print $2}' "${STATE_FILE}" 2>/dev/null || true)
        if ((used == 0)); then
            temp="$(mktemp /tmp/pve-network-interfaces.XXXXXX)"
            awk -v vlan_dev="${target_vlan_dev}" '
                BEGIN { RS=""; ORS="\n\n" }
                {
                    keep=1
                    if ($0 ~ "(^|\n)auto[[:space:]]+" vlan_dev "[[:space:]]*(\n|$)") keep=0
                    if (keep) print
                }
            ' "${generated_file}" > "${temp}"
            install -m 0644 "${temp}" "${generated_file}"
            rm -f "${temp}"
        fi
    done

    local change_id
    change_id="$(create_change_id)"
    if ! apply_interfaces_file "${change_id}" "${generated_file}"; then
        rm -f "${generated_file}"
        log_error "VSS Port Group 刪除失敗，已嘗試 Recovery。"
        pause_screen
        return 1
    fi
    rm -f "${generated_file}"

    log_ok "VSS Port Group 網路設定已套用，開始同步 State。"
    for target_name in "${targets[@]}"; do
        remove_state_entry "VSS_PORT_GROUP" "${target_name}"
        remove_state_entry "VSS_PORT_GROUP_BRIDGE" "${target_name}"
        remove_state_entry "VSS_PORT_GROUP_VLAN_DEV" "${target_name}"
    done

    if [[ "${choice}" =~ ^[Aa]$ ]]; then
        log_ok "全部 ${#targets[@]} 個 VSS Port Group 已刪除。"
    else
        log_ok "VSS Port Group ${name} 已刪除。"
    fi
    pause_screen
}
vss_port_group_menu()
{
    while true; do
        show_header
        echo "============================================================"
        echo " VSS Port Group"
        echo "============================================================"
        echo ""
        echo "  1) 建立"
        echo "  2) 刪除"
        echo "  3) 查看"
        echo "  0) 返回"
        echo ""
        local choice
        read -r -p "請選擇：" choice
        case "${choice}" in
            1) vss_port_group_create ;;
            2) vss_port_group_delete ;;
            3) port_group_list_vss; pause_screen ;;
            0) return 0 ;;
            *) log_error "選擇無效。"; sleep 1 ;;
        esac
    done
}

show_current_network()
{
    show_header
    echo "============================================================"
    echo " 目前網路設定"
    echo "============================================================"
    echo ""

    get_management_info
    echo "管理連線："
    echo "  Device ：${DEV_WITH_GW:-未偵測}"
    echo "  IP     ：${CURRENT_IP:-未偵測}"
    echo "  Gateway：${CURRENT_GW:-未偵測}"
    echo ""

    echo "------------------------------------------------------------"
    echo " 實體 NIC"
    echo "------------------------------------------------------------"
    while read -r nic; do        [[ -n "${nic}" ]] || continue
        printf "  %-12s %-12s %s\n" "${nic}" "$(get_link_speed "${nic}")" "$(get_link_state "${nic}")"
    done < <(get_physical_nics)

    echo ""
    echo "------------------------------------------------------------"
    echo " Linux Bridge / vSwitch"
    echo "------------------------------------------------------------"
    ip -br link show type bridge 2>/dev/null || true
    echo ""
    ip -br addr show || true

    echo ""
    echo "------------------------------------------------------------"
    echo " Bond"
    echo "------------------------------------------------------------"
    if ls /proc/net/bonding/* >/dev/null 2>&1; then
        for file in /proc/net/bonding/*; do
            [[ -f "${file}" ]] || continue
            echo "[$(basename "${file}")]"
            grep -E 'Bonding Mode|MII Status|Currently Active Slave|Slave Interface' "${file}" || true
            echo ""
        done
    else
        echo "目前沒有 Bond。"
    fi

    echo "------------------------------------------------------------"
    echo " SDN / VDS"
    echo "------------------------------------------------------------"
    pvesh get /cluster/sdn/zones 2>/dev/null || true
    echo ""
    pvesh get /cluster/sdn/vnets 2>/dev/null || true
    echo ""

    pause_screen
}

vss_reconcile_state_after_recovery()
{
    local target="${1:-/etc/network/interfaces}"
    local name vlan_dev bridge

    [[ -f "${target}" ]] || return 0

    # Recovery 成功後，State 必須與還原後的 Native Network Configuration 同步。
    # 只處理 PVE NETWORK PRO 自己追蹤的 VSS Port Group，避免碰外部物件。
    while IFS=$'\t' read -r type name value; do
        [[ "${type}" == "VSS_PORT_GROUP" ]] || continue
        [[ -n "${name}" ]] || continue

        vlan_dev="$(awk -F '\t' -v n="${name}" '$1=="VSS_PORT_GROUP_VLAN_DEV" && $2==n {print $3; exit}' "${STATE_FILE}" 2>/dev/null || true)"
        bridge="$(awk -F '\t' -v n="${name}" '$1=="VSS_PORT_GROUP_BRIDGE" && $2==n {print $3; exit}' "${STATE_FILE}" 2>/dev/null || true)"
        [[ -n "${vlan_dev}" ]] || vlan_dev="${bridge}.${value}"

        # 還原後設定檔已不存在的 Tool-owned Port Group，必須同步清除 runtime object。
        if ! grep -qE "^auto[[:space:]]+${name}([[:space:]]|$)" "${target}" 2>/dev/null; then
            if ip link show "${name}" >/dev/null 2>&1; then
                log_step "清理 Recovery 後殘留 Port Group：${name}"
                ip link delete "${name}" 2>/dev/null || true
            fi
        fi

        # VLAN sub-interface 也必須同步清理，否則會留下孤兒 VLAN 介面。
        if [[ -n "${vlan_dev}" ]] && ! grep -qE "^auto[[:space:]]+${vlan_dev}([[:space:]]|$)" "${target}" 2>/dev/null; then
            if ip link show "${vlan_dev}" >/dev/null 2>&1; then
                log_step "清理 Recovery 後殘留 VLAN Interface：${vlan_dev}"
                ip link delete "${vlan_dev}" 2>/dev/null || true
            fi
        fi

        # 還原後不存在的 Port Group 不應繼續留在 State。
        if ! grep -qE "^auto[[:space:]]+${name}([[:space:]]|$)" "${target}" 2>/dev/null; then
            remove_state_entry "VSS_PORT_GROUP" "${name}"
            remove_state_entry "VSS_PORT_GROUP_BRIDGE" "${name}"
            remove_state_entry "VSS_PORT_GROUP_VLAN_DEV" "${name}"
        fi
    done < "${STATE_FILE}"
}

rollback_vss()
{
    show_header
    echo "============================================================"
    echo " Backup / Recovery - VSS"
    echo "============================================================"
    echo ""

    if [[ ! -f "${VSS_DIR}/interfaces.before" ]]; then
        log_error "找不到 VSS 變更前設定：${VSS_DIR}/interfaces.before"
        pause_screen
        return 0
    fi

    echo "將還原：${VSS_DIR}/interfaces.before"
    echo ""
    if ! confirm "確認還原 VSS？"; then
        pause_screen
        return 0
    fi

    if ! ensure_network_backup; then return 0; fi

    local change_id
    change_id="$(create_change_id)"
    cp -a /etc/network/interfaces "${VSS_DIR}/interfaces.current-before-rollback"
    if ! apply_interfaces_file "${change_id}" "${VSS_DIR}/interfaces.before"; then
        log_error "VSS Recovery 套用失敗。"
        log_error "目前變更前版本仍保存於：${VSS_DIR}/interfaces.current-before-rollback"
        pause_screen
        return 1
    fi

    vss_reconcile_state_after_recovery "${VSS_DIR}/interfaces.before"

    if cluster_quorate; then
        log_ok "VSS Recovery 完成，設定檔、Runtime Object 與 State 已同步。"
        log_ok "Cluster Quorum 正常。"
    else
        log_error "Rollback 後 Cluster Quorum 異常，請立即檢查。"
    fi
    pause_screen
}
rollback_vds()
{
    show_header
    echo "============================================================"
    echo " Backup / Recovery - VDS"
    echo "============================================================"
    echo ""
    echo "只處理本工具記錄建立的 SDN Zone / VNet。"
    echo "不會清除所有 SDN 設定。"
    echo ""

    local -a zones=()
    local zone
    while read -r zone; do
        [[ -n "${zone}" ]] && zones+=("${zone}")
    done < <(awk -F '\t' '$1=="VDS_ZONE" {print $2}' "${STATE_FILE}" 2>/dev/null || true)

    if ((${#zones[@]} == 0)); then
        echo "沒有本工具建立的 SDN Zone。"
        pause_screen
        return 0
    fi

    local i=1 choice
    for zone in "${zones[@]}"; do
        printf "  %2d) %s\n" "$i" "$zone"
        i=$((i + 1))
    done
    echo "  0) 返回"

    while true; do
        read -r -p "選擇要 Rollback 的 Zone：" choice
        [[ "${choice}" == "0" ]] && { pause_screen; return 0; }
        if [[ "${choice}" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#zones[@]})); then
            zone="${zones[$((choice - 1))]}"
            break
        fi
        log_error "選擇無效。"
    done

    if ! confirm "確認刪除本工具建立的 SDN Zone ${zone} 及其 VNet？"; then
        pause_screen
        return 0
    fi

    local -a vnets=()
    local vnet
    while read -r vnet; do
        [[ -n "${vnet}" ]] && vnets+=("${vnet}")
    done < <(awk -F '\t' -v z="${zone}" '$1=="PORT_GROUP_ZONE" && $3==z {print $2}' "${STATE_FILE}" 2>/dev/null || true)

    for vnet in "${vnets[@]}"; do
        if pvesh get "/cluster/sdn/vnets/${vnet}" >/dev/null 2>&1; then
            pvesh delete "/cluster/sdn/vnets/${vnet}"
        fi
        remove_state_entry "PORT_GROUP" "${vnet}"
        remove_state_entry "PORT_GROUP_ZONE" "${vnet}"
    done

    if pvesh get "/cluster/sdn/zones/${zone}" >/dev/null 2>&1; then
        pvesh delete "/cluster/sdn/zones/${zone}"
    fi
    remove_state_entry "VDS_ZONE" "${zone}"
    pvesh set /cluster/sdn

    log_ok "VDS Rollback 完成：${zone}"
    pause_screen
}

rollback_baseline()
{
    show_header
    echo "============================================================"
    echo " Backup / Recovery - Baseline"
    echo "============================================================"
    echo ""
    echo "這是高風險操作。"
    echo "Baseline 會直接覆蓋目前 /etc/network/interfaces。"
    echo ""

    if ! baseline_exists; then
        log_error "尚未建立 Baseline。"
        pause_screen
        return 0
    fi

    if ! confirm "確認使用最初 Baseline 還原網路設定？"; then
        pause_screen
        return 0
    fi

    local change_id
    change_id="$(create_change_id)"
    cp -a /etc/network/interfaces "${BASELINE_DIR}/interfaces.before-baseline-rollback.$(date +%Y%m%d%H%M%S)"
    if ! apply_interfaces_file "${change_id}" "${BASELINE_DIR}/interfaces.orig"; then
        log_error "Baseline Recovery 套用失敗。"
        pause_screen
        return 1
    fi

    if cluster_quorate; then
        log_ok "Baseline Rollback 完成。"
    else
        log_error "Baseline Rollback 後 Cluster Quorum 異常。"
    fi
    pause_screen
}

backup_history()
{
    show_header
    echo "============================================================"
    echo " Backup History"
    echo "============================================================"
    echo ""
    if [[ ! -d "${BACKUP_DIR}" ]]; then
        echo "目前沒有 Backup。"
    else
        find "${BACKUP_DIR}" -mindepth 2 -maxdepth 2 -type f -name interfaces -printf '  %h\n' 2>/dev/null | sort -u
    fi
    pause_screen
}

rollback_menu()
{
    while true; do
        show_header
        echo "============================================================"
        echo " Backup / Recovery"
        echo "============================================================"
        echo ""
        echo "  1) Backup History"
        echo "  2) VSS - 還原 VSS 變更前設定"
        echo "  3) VDS - 還原本工具建立的 SDN 物件"
        echo "  4) Baseline - 還原最初網路設定"
        echo "  0) 返回"
        echo ""

        local choice
        read -r -p "請選擇：" choice
        case "${choice}" in
            1) backup_history ;;
            2) rollback_vss ;;
            3) rollback_vds ;;
            4) rollback_baseline ;;
            0) return 0 ;;
            *) log_error "選擇無效。"; sleep 1 ;;
        esac
    done
}

baseline_menu()
{
    while true; do
        show_header
        echo "============================================================"
        echo " Baseline 管理"
        echo "============================================================"
        echo ""
        echo "  1) 查看 Baseline"
        echo "  2) 建立 Baseline"
        echo "  0) 返回"
        echo ""

        local choice
        read -r -p "請選擇：" choice
        case "${choice}" in
            1) show_header; show_baseline; pause_screen ;;
            2) show_header; create_baseline; pause_screen ;;
            0) return 0 ;;
            *) log_error "選擇無效。"; sleep 1 ;;
        esac
    done
}

network_objects_menu()
{
    while true; do
        show_header
        echo "============================================================"
        echo " Network Objects"
        echo "============================================================"
        echo ""
        echo "  1) Virtual Switch / VSS"
        echo "  2) Distributed Virtual Switch / VDS"
        echo "  0) 返回"
        echo ""
        local choice
        read -r -p "請選擇：" choice
        case "${choice}" in
            1) vss_setup ;;
            2) vds_setup ;;
            0) return 0 ;;
            *) log_error "選擇無效。"; sleep 1 ;;
        esac
    done
}

main_menu()
{
    while true; do
        show_header
        echo "  PVE 節點：$(get_node_name)"
        echo -e "  Cluster  ：$(cluster_status_text)"
        echo "  PVE 版本 ：$(get_pve_version)"
    if network_pending_configuration_exists; then
        echo -e "  GUI Pending：${YELLOW}存在 / 網路變更暫停${NC}"
    else
        echo "  GUI Pending：無"
    fi
        echo ""
        echo "------------------------------------------------------------"
        echo ""
        echo "  1) Network Objects"
        echo "     ├─ Virtual Switch / VSS"
        echo "     │  ├─ Physical Uplink"
        echo "     │  ├─ Port Group"
        echo "     │  └─ VMkernel Adapter / Management"
        echo "     └─ Distributed Virtual Switch / VDS"
        echo "        └─ Port Group"
        echo "  2) Backup / Recovery"
        echo "     ├─ Baseline"
        echo "     ├─ Backup History"
        echo "     └─ Recovery"
        echo "  3) Network Status"
        echo "     ├─ Current Configuration"
        echo "     ├─ Topology"
        echo "     ├─ Cluster"
        echo "     └─ Connectivity"
        echo "  0) 離開"
        echo ""
        echo "------------------------------------------------------------"
        echo ""

        local choice
        read -r -p "請選擇：" choice
        case "${choice}" in
            1) network_objects_menu ;;
            2) rollback_menu ;;
            3) show_current_network ;;
            0)
                echo "離開 PVE NETWORK PRO。"
                return 0
                ;;
            *) log_error "選擇無效，請輸入 0～3。"; sleep 1 ;;
        esac
    done
}

main()
{
    require_root
    check_environment
    ensure_dirs
    update_network_script "$@"
    main_menu
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi