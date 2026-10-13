#!/usr/bin/env bash
set -Eeuo pipefail

# PVE NETWORK PRO - Proxmox VE 網路架構設定工具
# Version: 2.0.60
# Updated: 2026-10-13

SCRIPT_VERSION="2.0.60"
UPDATED="2026-10-13"
REPOSITORY_RAW="https://raw.githubusercontent.com/sungshu/Pve-Toolkits/main/src/pve/pve_network.sh"
LATEST_VERSION=""
UPDATE_STATUS="尚未檢查"
NETWORK_SCRIPT_PATH="/root/pve_network.sh"
GENERATED_INTERFACES_FILE=""
NETWORK_UPDATE_GUARD="${PVE_NETWORK_UPDATED:-0}"
BOND_MODE=""
BOND_DEVICE=""
BOND_PRIMARY_NIC=""
BOND_XMIT_HASH_POLICY=""
BOND_LACP_RATE=""

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
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
        # PVE VM Firewall / Runtime Bridge 不是使用者可管理的 Virtual Switch。
        # 例如 fwbr100200i0、fwpr100200p0、fwln100200i0 皆屬 VM Runtime 網路物件。
        [[ "${bridge}" =~ ^fwbr[0-9]+i[0-9]+$ ]] && continue
        [[ "${bridge}" =~ ^fwpr[0-9]+p[0-9]+$ ]] && continue
        [[ "${bridge}" =~ ^fwln[0-9]+i[0-9]+$ ]] && continue
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

get_vss_switch_bridges()
{
    local state_type state_key state_value bridge

    [[ -f "${STATE_FILE}" ]] || return 0

    # 明確註冊的 VSS Bridge 是主要來源。
    # 若舊版曾建立 Port Group、但沒有登錄其父 Virtual Switch，
    # 以 VSS_PORT_GROUP_BRIDGE 的父 Bridge 關係補足，絕不把 Port Group 自身當成 Switch。
    while IFS=$'\t' read -r state_type state_key state_value; do
        case "${state_type}:${state_key}" in
            VSS:bridge|VSS_PORT_GROUP_BRIDGE:*)
                bridge="${state_value}"
                ;;
            *)
                continue
                ;;
        esac
        [[ -n "${bridge}" && "${bridge}" =~ ^[A-Za-z0-9_.:-]+$ ]] || continue
        [[ -d "/sys/class/net/${bridge}/bridge" ]] || continue
        printf '%s\n' "${bridge}"
    done < "${STATE_FILE}" | sort -uV
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
    target_bond="$(awk -v bridge="${target_bridge}" 'BEGIN{RS=""} $0~"(^|\n)auto[[:space:]]+" bridge "[[:space:]]*(\n|$)"{n=split($0,a,"\n");for(i=1;i<=n;i++)if(a[i]~/^[[:space:]]*bridge-ports[[:space:]]+bond[0-9]+/){sub(/^[[:space:]]*bridge-ports[[:space:]]+/,"",a[i]);print a[i];exit}}' /etc/network/interfaces 2>/dev/null || true)"
    awk -v nic="${nic}" -v target="${target_bridge}" -v target_bond="${target_bond}" 'BEGIN{RS=""}{
        is_target=($0~"(^|\n)auto[[:space:]]+" target "[[:space:]]*(\n|$)")
        is_target_bond=(target_bond!="" && $0~"(^|\n)auto[[:space:]]+" target_bond "[[:space:]]*(\n|$)")
        if(is_target||is_target_bond)next
        if($0~"(^|\n)bridge-ports[[:space:]]+[^\n]*([[:space:]]|^)" nic "([[:space:]]|$)")found=1
        if($0~"(^|\n)bond-slaves[[:space:]]+[^\n]*([[:space:]]|^)" nic "([[:space:]]|$)")found=1
        if($0~"(^|\n)iface[[:space:]]+" nic "[[:space:]]+inet[[:space:]]+(static|dhcp)")found=1
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
    echo "Linux Bond 模式"
    echo ""
    echo "  1) balance-rr    — 逐封包輪詢"
    echo "  2) active-backup — 主備切換"
    echo "  3) balance-xor   — Hash 流量分配"
    echo "  4) broadcast     — 全介面廣播傳送"
    echo "  5) 802.3ad       — LACP 動態聚合"
    echo "  6) balance-tlb   — 自適應傳送負載分散"
    echo "  7) balance-alb   — 自適應傳送／IPv4 接收負載分散"
    echo "  0) 返回"
    echo ""

    while true; do
        read -r -p "請選擇： " choice
        case "${choice}" in
            1)
                BOND_MODE="balance-rr"
                echo ""
                echo "已選擇：balance-rr"
                echo "模式說明：逐封包輪流使用不同 NIC，負載分散與備援。"
                echo "交換器端注意：通常需設定靜態聚合。"
                echo "另外仍需確認交換器 VLAN、Trunk 與網路連通性設定。"
                echo ""
                return 0
                ;;
            2)
                BOND_MODE="active-backup"
                echo ""
                echo "已選擇：active-backup"
                echo "模式說明：一張 NIC 工作，其餘 NIC 作為備援。"
                echo "交換器端注意：不需要聚合設定。"
                echo "但交換器 VLAN、Trunk 與網路連通性設定仍需正確。"
                echo ""
                return 0
                ;;
            3)
                BOND_MODE="balance-xor"
                echo ""
                echo "已選擇：balance-xor"
                echo "模式說明：依 Hash 分配流量，提供負載分散與備援。"
                echo "交換器端注意：通常需設定靜態聚合。"
                echo "另外仍需確認交換器 VLAN、Trunk 與網路連通性設定。"
                echo ""
                BOND_XMIT_HASH_POLICY="$(select_bond_hash_policy)"
                return 0
                ;;
            4)
                BOND_MODE="broadcast"
                echo ""
                echo "已選擇：broadcast"
                echo "模式說明：同一封包從所有成員 NIC 送出。"
                echo "交換器端注意：通常需設定靜態聚合。"
                echo "另外仍需確認交換器 VLAN、Trunk 與網路連通性設定。"
                echo ""
                return 0
                ;;
            5)
                BOND_MODE="802.3ad"
                echo ""
                echo "已選擇：802.3ad / LACP"
                echo "模式說明：動態鏈路聚合，依流量分配到成員 NIC。"
                echo "交換器端注意：必須設定 LACP。"
                echo "另外仍需確認交換器 VLAN、Trunk 與網路連通性設定。"
                echo ""
                BOND_LACP_RATE="$(select_lacp_rate)"
                BOND_XMIT_HASH_POLICY="$(select_bond_hash_policy)"
                return 0
                ;;
            6)
                BOND_MODE="balance-tlb"
                echo ""
                echo "已選擇：balance-tlb"
                echo "模式說明：自適應傳送負載分散。"
                echo "交換器端注意：不需要特殊聚合設定。"
                echo "但交換器 VLAN、Trunk 與網路連通性設定仍需正確。"
                echo ""
                return 0
                ;;
            7)
                BOND_MODE="balance-alb"
                echo ""
                echo "已選擇：balance-alb"
                echo "模式說明：自適應傳送，加上 IPv4 接收負載分散。"
                echo "交換器端注意：不需要特殊聚合設定。"
                echo "但交換器 VLAN、Trunk 與網路連通性設定仍需正確。"
                echo ""
                return 0
                ;;
            0)
                BOND_MODE=""
                BOND_PRIMARY_NIC=""
                BOND_XMIT_HASH_POLICY=""
                BOND_LACP_RATE=""
                return 1
                ;;
            *) log_error "選擇無效，請輸入 0～7。" ;;
        esac
    done
}

select_bond_hash_policy()
{
    local choice
    echo "" >&2
    echo "Xmit Hash Policy" >&2
    echo "  1) layer2" >&2
    echo "  2) layer2+3" >&2
    echo "  3) layer3+4" >&2
    echo "" >&2
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
    echo "" >&2
    echo "LACP Rate" >&2
    echo "  1) slow" >&2
    echo "  2) fast" >&2
    echo "" >&2
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

baseline_artifacts_exist()
{
    [[ -e "${BASELINE_DIR}/interfaces.orig" ||
       -e "${BASELINE_DIR}/objects.conf.orig" ||
       -e "${BASELINE_DIR}/pvecm-status.orig" ||
       -e "${BASELINE_DIR}/pvecm-nodes.orig" ||
       -e "${BASELINE_DIR}/ip-address.orig" ||
       -e "${BASELINE_DIR}/ip-route.orig" ]]
}

baseline_missing_files()
{
    local file
    for file in interfaces.orig objects.conf.orig pvecm-status.orig pvecm-nodes.orig ip-address.orig ip-route.orig; do
        case "${file}" in
            interfaces.orig|pvecm-status.orig|pvecm-nodes.orig|ip-address.orig)
                [[ -s "${BASELINE_DIR}/${file}" ]] || printf '  - %s\n' "${file}"
                ;;
            *)
                [[ -f "${BASELINE_DIR}/${file}" ]] || printf '  - %s\n' "${file}"
                ;;
        esac
    done
}

baseline_exists()
{
    [[ -s "${BASELINE_DIR}/interfaces.orig" &&
       -f "${BASELINE_DIR}/objects.conf.orig" &&
       -s "${BASELINE_DIR}/pvecm-status.orig" &&
       -s "${BASELINE_DIR}/pvecm-nodes.orig" &&
       -s "${BASELINE_DIR}/ip-address.orig" &&
       -f "${BASELINE_DIR}/ip-route.orig" ]]
}

ensure_network_backup()
{
    if baseline_exists; then return 0; fi
    echo ""
    if baseline_artifacts_exist; then
        log_error "偵測到不完整的 Baseline；為避免覆蓋原始救援資料，停止網路變更。"
        echo "缺少的檔案："
        baseline_missing_files
        echo "請先檢查並修復 Baseline，不能以一般 Backup 取代初始救援點。"
        pause_screen
        return 1
    fi
    echo "尚未建立初始 Baseline。"
    echo "請先確認目前管理 IP、Gateway、SSH 與 PVE 管理介面正常。"
    if ! confirm "是否現在建立 Baseline？"; then
        log_info "未建立 Baseline，取消此次網路變更。"
        pause_screen
        return 1
    fi
    if ! create_baseline || ! baseline_exists; then
        log_error "Baseline 建立或完整性驗證失敗，取消此次網路變更。"
        pause_screen
        return 1
    fi
    return 0
}

create_baseline()
{
    ensure_dirs
    if baseline_exists; then
        log_info "Baseline 已存在，不會自動覆蓋。"
        echo "保存位置：${BASELINE_DIR}"
        return 0
    fi
    if baseline_artifacts_exist; then
        log_error "Baseline 檔案不完整，為避免覆蓋原始救援資料，拒絕重新建立。"
        echo "缺少的檔案："
        baseline_missing_files
        echo "請先檢查並修復缺失項目；不可直接覆蓋既有 Baseline。"
        return 1
    fi

    log_step "建立 Network Baseline"
    echo "建立前請確認管理 IP、Gateway、SSH 與 PVE 管理介面正常。"
    local staging="${BASE_DIR}/.baseline.tmp.${BASHPID}"
    rm -rf -- "${staging}"
    if ! mkdir -m 0700 -- "${staging}"; then
        log_error "無法建立 Baseline 暫存目錄。"
        return 1
    fi
    if ! cp -a /etc/network/interfaces "${staging}/interfaces.orig" ||
       ! cp -a "${STATE_FILE}" "${staging}/objects.conf.orig" ||
       ! ip -details address show > "${staging}/ip-address.orig" ||
       ! ip route show table all > "${staging}/ip-route.orig" ||
       ! date '+%Y-%m-%d %H:%M:%S %z' > "${staging}/created-at"; then
        rm -rf -- "${staging}"
        log_error "Baseline 擷取失敗；未提交新的 Baseline。"
        return 1
    fi
    if ! pvecm status > "${staging}/pvecm-status.orig" 2>&1; then
        printf '\n[INFO] Cluster status command was unavailable during Baseline capture.\n' >> "${staging}/pvecm-status.orig"
    fi
    if ! pvecm nodes > "${staging}/pvecm-nodes.orig" 2>&1; then
        printf '\n[INFO] Cluster node list command was unavailable during Baseline capture.\n' >> "${staging}/pvecm-nodes.orig"
    fi
    if [[ ! -s "${staging}/interfaces.orig" ||
          ! -s "${staging}/pvecm-status.orig" ||
          ! -s "${staging}/pvecm-nodes.orig" ||
          ! -s "${staging}/ip-address.orig" ]]; then
        rm -rf -- "${staging}"
        log_error "Baseline 必要檔案為空；拒絕提交不完整 Baseline。"
        return 1
    fi
    local file
    for file in interfaces.orig objects.conf.orig pvecm-status.orig pvecm-nodes.orig ip-address.orig ip-route.orig created-at; do
        if ! mv -- "${staging}/${file}" "${BASELINE_DIR}/${file}"; then
            rm -rf -- "${staging}"
            log_error "Baseline 提交失敗，現有檔案不會被覆蓋：${file}"
            return 1
        fi
    done
    rmdir -- "${staging}" 2>/dev/null || true
    if ! baseline_exists; then
        log_error "Baseline 建立後完整性驗證失敗。"
        return 1
    fi
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
        echo "狀態：完整"
        echo "位置：${BASELINE_DIR}"
        [[ -f "${BASELINE_DIR}/created-at" ]] && echo "建立時間：$(cat "${BASELINE_DIR}/created-at")"
        echo ""
        echo "保存檔案："
        find "${BASELINE_DIR}" -maxdepth 1 -type f -printf '  - %f\n' | sort
    elif baseline_artifacts_exist; then
        echo "狀態：不完整（禁止覆蓋）"
        echo "位置：${BASELINE_DIR}"
        echo "缺少的檔案："
        baseline_missing_files
        echo ""
        echo "請先檢查原始救援資料，再決定如何修復。"
    else
        echo "狀態：尚未建立"
    fi
}

save_interfaces_copy()
{
    local target="$1"
    cp -a /etc/network/interfaces "${target}"
}

prepare_vss_recovery()
{
    ensure_dirs
    cp -a /etc/network/interfaces "${VSS_DIR}/interfaces.before"
    cp -a "${STATE_FILE}" "${VSS_DIR}/objects.before"
    network_snapshot "${VSS_DIR}/network.before"
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
    local old_bond_name=""
    local bridge_port="${nic1}"

    ensure_dirs
    GENERATED_INTERFACES_FILE="$(mktemp /tmp/pve-network-interfaces.XXXXXX)"
    local generated_file="${GENERATED_INTERFACES_FILE}"
    local temp

    cp -a /etc/network/interfaces "${generated_file}"

    # 第一版已驗證的核心生命週期：
    # Physical NIC → Bond（可選）→ Linux Bridge。
    # 2.0.17 只將既有 CLI 實作包進 VMware 風格 VSS / Physical Uplink UI。

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
        old_bond_name="${bridge_port}"
    fi

    if [[ -n "${bond_mode}" ]]; then
        if [[ -n "${old_bond_name}" ]]; then
            bond_name="${old_bond_name}"
        else
            local n=0
            while true; do
                local candidate="bond${n}"
                local candidate_defined candidate_in_use candidate_has_slaves
                candidate_defined="$(awk -v b="${candidate}" '
                    BEGIN { RS="" }
                    $0 ~ ("(^|\n)iface[[:space:]]+" b "[[:space:]]") ||
                    $0 ~ ("(^|\n)(auto|allow-[^[:space:]]+)[[:space:]]+" b "([[:space:]]|$)") { found=1 }
                    END { print found+0 }
                ' "${generated_file}")"
                candidate_in_use="$(awk -v b="${candidate}" '
                    BEGIN { RS="" }
                    {
                        n=split($0, lines, "\n")
                        for (i=1; i<=n; i++) {
                            if (lines[i] ~ /^[[:space:]]*bridge-ports[[:space:]]+/) {
                                sub(/^[[:space:]]*bridge-ports[[:space:]]+/, "", lines[i])
                                m=split(lines[i], ports, /[[:space:]]+/)
                                for (j=1; j<=m; j++) {
                                    if (ports[j]==b || index(ports[j], b ".")==1) found=1
                                }
                            }
                        }
                    }
                    END { print found+0 }
                ' "${generated_file}")"
                candidate_has_slaves="$(awk -v b="${candidate}" '
                    BEGIN { RS="" }
                    $0 ~ ("(^|\n)iface[[:space:]]+" b "[[:space:]]") {
                        n=split($0, lines, "\n")
                        for (i=1; i<=n; i++) {
                            if (lines[i] ~ /^[[:space:]]*bond-slaves[[:space:]]+/) {
                                sub(/^[[:space:]]*bond-slaves[[:space:]]+/, "", lines[i])
                                if (lines[i] != "" && lines[i] != "none") found=1
                            }
                        }
                    }
                    END { print found+0 }
                ' "${generated_file}")"
                # 重用未被 Bridge 引用、且沒有既有 Slave 的空 Bond，避免重複空白 Bond。
                if ((candidate_in_use == 0)) && { ((candidate_defined == 0)) || ((candidate_has_slaves == 0)); }; then
                    bond_name="${candidate}"
                    break
                fi
                n=$((n + 1))
                if ((n > 127)); then
                    log_error "找不到可安全使用的 Linux Bond 名稱。"
                    return 1
                fi
            done
        fi
        BOND_DEVICE="${bond_name}"
        bridge_port="${bond_name}"
    else
        # Single NIC 模式：若原 VSS 使用 Bond，移除舊 Bond，避免留下孤立 bond0。
        bridge_port="${nic1}"
        bond_name=""
    fi

    temp="$(mktemp /tmp/pve-network-interfaces.XXXXXX)"

    awk -v bridge="${bridge}" \
        -v bridge_port="${bridge_port}" \
        -v bond="${bond_name}" \
        -v old_bond="${old_bond_name}" \
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
            # Bond options belong to iface, not an auto-only paragraph.
            is_bond = (bond != "" && $0 ~ ("(^|\n)iface[[:space:]]+" bond "[[:space:]]"))
            is_bond_auto_only = (bond != "" &&
                                 $0 ~ ("(^|\n)(auto|allow-[^[:space:]]+)[[:space:]]+" bond "([[:space:]]|$)") &&
                                 $0 !~ ("(^|\n)iface[[:space:]]+" bond "[[:space:]]"))
            is_old_bond = (old_bond != "" && old_bond != bond &&
                           ($0 ~ ("(^|\n)iface[[:space:]]+" old_bond "[[:space:]]") ||
                            $0 ~ ("(^|\n)(auto|allow-[^[:space:]]+)[[:space:]]+" old_bond "([[:space:]]|$)")))

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

            if (is_old_bond)
                next

            if (is_bond_auto_only) {
                # 舊版可能把 Bond options 寫在 auto-only paragraph；清除錯位欄位，
                # 讓下一個 iface stanza 成為 Bond 設定的唯一來源。
                n=split($0,a,"\n")
                out=""
                for(i=1;i<=n;i++) {
                    if(a[i] ~ /^[[:space:]]*(bond-slaves|bond-miimon|bond-mode|bond-primary|bond-xmit-hash-policy|bond-lacp-rate)[[:space:]]+/)
                        continue
                    out=out (out=="" ? "" : "\n") a[i]
                }
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
    # 自動 Backup ID 包含變更用途，方便直接從 Backup History 辨識來源。
    # 格式：CHG-<用途>-YYYYMMDD-HHMMSS-<nanoseconds>-<random>
    local label="${1:-network}" timestamp suffix
    label="$(printf '%s' "${label}" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_-]+/-/g; s/^-+//; s/-+$//')"
    [[ -n "${label}" ]] || label="network"
    timestamp="$(date '+%Y%m%d-%H%M%S-%N')"
    suffix="${RANDOM}${RANDOM}"
    printf 'CHG-%s-%s-%s' "${label}" "${timestamp}" "${suffix}"
}

create_manual_backup_id()
{
    # 手動 Backup 使用獨立前綴，方便在目錄與 Backup History 直接辨識。
    local timestamp suffix
    timestamp="$(date '+%Y%m%d-%H%M%S-%N')"
    suffix="${RANDOM}${RANDOM}"
    printf 'MANUAL-%s-%s' "${timestamp}" "${suffix}"
}

create_change_backup()
{
    local change_id="$1"
    local target="${BACKUP_DIR}/${change_id}"
    local staging="${BACKUP_DIR}/.${change_id}.tmp.$$"
    ensure_dirs

    if [[ -z "${change_id}" || -e "${target}" ]]; then
        log_error "Backup Change ID 無效或已存在：${change_id}"
        return 1
    fi
    rm -rf -- "${staging}"
    if ! mkdir -m 0700 -- "${staging}"; then
        log_error "無法建立 Backup 暫存目錄：${staging}"
        return 1
    fi
    if ! cp -a /etc/network/interfaces "${staging}/interfaces" || [[ ! -s "${staging}/interfaces" ]]; then
        rm -rf -- "${staging}"
        log_error "無法建立有效的 /etc/network/interfaces Backup。"
        return 1
    fi
    if [[ -f "${STATE_FILE}" ]] && ! cp -a "${STATE_FILE}" "${staging}/state"; then
        rm -rf -- "${staging}"
        log_error "無法備份 PVE NETWORK PRO State。"
        return 1
    fi
    if ! ip -details address show > "${staging}/ip-address" ||
       ! ip route show table all > "${staging}/ip-route" ||
       ! ip -details link show > "${staging}/ip-link"; then
        rm -rf -- "${staging}"
        log_error "無法完整擷取 Runtime 網路狀態，取消 Backup。"
        return 1
    fi
    pvecm status > "${staging}/cluster-status" 2>&1 || true
    # 同一筆 Backup 也保存 SDN 設定快照，讓 VDS 變更前的 Zone / VNet 有可查證的來源資料。
    if [[ -r /etc/pve/sdn.cfg ]]; then
        if ! cp -a /etc/pve/sdn.cfg "${staging}/sdn.cfg"; then
            rm -rf -- "${staging}"
            log_error "無法備份 Proxmox SDN 設定檔 /etc/pve/sdn.cfg。"
            return 1
        fi
        : > "${staging}/sdn-config-present"
    else
        : > "${staging}/sdn-config-absent"
    fi
    if command -v pvesh >/dev/null 2>&1; then
        pvesh get /cluster/sdn/zones --output-format json > "${staging}/sdn-zones.json" 2>/dev/null || true
        pvesh get /cluster/sdn/vnets --output-format json > "${staging}/sdn-vnets.json" 2>/dev/null || true
    fi
    date '+%Y-%m-%d %H:%M:%S %z' > "${staging}/created-at" || {
        rm -rf -- "${staging}"
        log_error "無法寫入 Backup 時間資訊。"
        return 1
    }
    # 建立完整性清單；驗證失敗的備份不得留下來冒充有效 Backup。
    if ! ( cd "${staging}" && sha256sum interfaces ip-address ip-route ip-link created-at > SHA256SUMS ); then
        rm -rf -- "${staging}"
        log_error "無法建立 Backup SHA256 完整性清單。"
        return 1
    fi
    if [[ -f "${staging}/state" ]] && ! ( cd "${staging}" && sha256sum state >> SHA256SUMS ); then
        rm -rf -- "${staging}"
        log_error "無法驗證 Backup State。"
        return 1
    fi
    if [[ -f "${staging}/sdn.cfg" ]] && ! ( cd "${staging}" && sha256sum sdn.cfg >> SHA256SUMS ); then
        rm -rf -- "${staging}"
        log_error "無法驗證 Backup SDN 設定。"
        return 1
    fi
    if ! mv -- "${staging}" "${target}"; then
        rm -rf -- "${staging}"
        log_error "無法完成 Backup 提交：${target}"
        return 1
    fi
    if ! validate_change_backup "${target}"; then
        rm -rf -- "${target}"
        log_error "Backup 完整性驗證失敗，已移除無效自動 Backup；停止網路變更。"
        return 1
    fi
    log_ok "Backup 建立完成且完整性驗證通過：${target}"
    if [[ "${change_id}" == CHG-vss-* || "${change_id}" == CHG-vds-* ]]; then
        prune_previous_direction_backups "${change_id}"
    fi
    return 0
}

validate_change_backup()
{
    local backup_dir="$1"
    local required

    [[ -d "${backup_dir}" && ! -L "${backup_dir}" ]] || return 1
    for required in interfaces ip-address ip-route ip-link created-at; do
        [[ -s "${backup_dir}/${required}" ]] || {
            log_error "自動 Backup 缺少必要檔案或內容為空：${required}"
            return 1
        }
    done
    # State 可以是合法的空檔：代表工具尚未記錄任何受管理物件。
    # 只拒絕非一般檔案，避免把目錄或特殊檔案當成可還原 State。
    if [[ -e "${backup_dir}/state" && ! -f "${backup_dir}/state" ]]; then
        log_error "Backup State 不是一般檔案。"
        return 1
    fi
    if [[ -e "${backup_dir}/sdn-config-present" && -e "${backup_dir}/sdn-config-absent" ]]; then
        log_error "Backup 同時標示 SDN 設定存在與不存在，資料互相矛盾。"
        return 1
    elif [[ -e "${backup_dir}/sdn-config-present" ]]; then
        [[ -s "${backup_dir}/sdn.cfg" ]] || {
            log_error "Backup 標示有 SDN 設定，但 sdn.cfg 不存在或為空。"
            return 1
        }
    elif [[ -e "${backup_dir}/sdn-config-absent" ]]; then
        [[ ! -e "${backup_dir}/sdn.cfg" ]] || {
            log_error "Backup 標示沒有 SDN 設定，但 sdn.cfg 卻存在。"
            return 1
        }
    elif [[ -f "${backup_dir}/SHA256SUMS" ]]; then
        log_error "新版 Backup 缺少 SDN 設定存在性標記。"
        return 1
    fi
    # 舊版 Backup 若沒有 SDN 標記，代表當時未保存 SDN 快照；只驗證可用的網路設定資料。
    # 有 SHA256SUMS 的新版 Backup 必須保留 SDN 存在性標記。
    if [[ -f "${backup_dir}/SHA256SUMS" ]]; then
        ( cd "${backup_dir}" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ) || {
            log_error "Backup SHA256 完整性驗證失敗：${backup_dir}"
            return 1
        }
    fi
    return 0
}

prune_previous_direction_backups()
{
    local new_id="$1"
    local prefix=""
    local candidate candidate_id

    case "${new_id}" in
        CHG-vss-*) prefix="CHG-vss-" ;;
        CHG-vds-*) prefix="CHG-vds-" ;;
        *) return 0 ;;
    esac

    # 每個大方向僅保留最新一筆已驗證的自動 Backup；手動 Backup 永不參與清理。
    # 新 Backup 已完整建立並通過 SHA256 驗證後才清理舊檔，避免先刪掉唯一可用復原點。
    while IFS= read -r candidate; do
        [[ -n "${candidate}" ]] || continue
        candidate_id="${candidate##*/}"
        [[ "${candidate_id}" == "${new_id}" ]] && continue
        [[ "${candidate_id}" == "${prefix}"* ]] || continue
        [[ "${candidate}" == "${BACKUP_DIR}/${candidate_id}" && -d "${candidate}" && ! -L "${candidate}" ]] || {
            log_error "舊自動 Backup 路徑安全檢查失敗，保留不刪：${candidate}"
            continue
        }
        if rm -rf -- "${candidate}" && [[ ! -e "${candidate}" && ! -L "${candidate}" ]]; then
            log_info "依大方向保留規則清理舊自動 Backup：${candidate_id}"
        else
            log_error "舊自動 Backup 清理失敗：${candidate_id}"
        fi
    done < <(find "${BACKUP_DIR}" -mindepth 2 -maxdepth 2 -type f -name interfaces -printf '%h\n' 2>/dev/null | sort -u)
}

create_vds_change_backup()
{
    local purpose="$1"
    local change_id
    change_id="$(create_change_id "vds-${purpose}")"
    if ! create_change_backup "${change_id}"; then
        log_error "VDS 變更前 Backup 建立失敗，拒絕繼續操作：${purpose}"
        return 1
    fi
    VDS_CHANGE_BACKUP_ID="${change_id}"
    log_info "VDS 變更前 SDN 快照已保存：${BACKUP_DIR}/${change_id}"
    return 0
}

validate_recovery_state()
{
    local management_dev management_ip gateway

    log_step "驗證 Recovery 後管理網路與 Cluster 狀態"
    get_management_info
    management_dev="${DEV_WITH_GW:-}"
    management_ip="${CURRENT_IP:-}"
    gateway="${CURRENT_GW:-}"

    if [[ -z "${management_dev}" || -z "${management_ip}" ]]; then
        log_error "Recovery 後無法確認管理網路介面或 IPv4 位址。"
        return 1
    fi

    if [[ -z "${gateway}" ]]; then
        log_error "Recovery 後無法確認 Default Gateway。"
        return 1
    fi

    if ! ip route show default 2>/dev/null | grep -Fq "default via ${gateway} dev ${management_dev}"; then
        log_error "Recovery 後 Default Route 與管理介面不一致：${management_dev} / ${gateway}"
        return 1
    fi

    if cluster_joined; then
        if ! cluster_quorate; then
            log_error "Recovery 後 Cluster Quorum 不正常。"
            return 1
        fi
        log_ok "Recovery 驗證完成：${management_dev} / ${management_ip} / ${gateway} / Cluster Quorum 正常。"
    else
        log_ok "Recovery 管理網路驗證完成：${management_dev} / ${management_ip} / ${gateway}；此節點未加入可驗證的 Cluster。"
    fi
    return 0
}

restore_change_backup()
{
    local change_id="$1"
    local source="${2:-${BACKUP_DIR}/${change_id}/interfaces}"
    local state_source="${3:-}"
    local recovery_path="${RECOVERY_DIR}/${change_id}"
    local rollback_path="" rollback_state="" had_state=0

    [[ -f "${source}" && -s "${source}" ]] || {
        log_error "找不到有效 Recovery Source：${source}"
        return 1
    }
    if [[ -z "${state_source}" && -f "${BACKUP_DIR}/${change_id}/state" ]]; then
        state_source="${BACKUP_DIR}/${change_id}/state"
    fi
    if [[ -n "${state_source}" && ! -f "${state_source}" ]]; then
        log_error "找不到 Recovery State Source：${state_source}"
        return 1
    fi
    ensure_dirs
    mkdir -p "${recovery_path}" || { log_error "無法建立 Recovery 記錄目錄：${recovery_path}"; return 1; }

    rollback_path="$(mktemp "${recovery_path}/interfaces.before.XXXXXX")" || { log_error "無法建立 Recovery 前設定快照。"; return 1; }
    if ! cp -a /etc/network/interfaces "${rollback_path}"; then
        rm -f -- "${rollback_path}"
        log_error "無法保存 Recovery 前的 interfaces，停止還原。"
        return 1
    fi
    if [[ -f "${STATE_FILE}" ]]; then
        rollback_state="$(mktemp "${recovery_path}/state.before.XXXXXX")" || { rm -f -- "${rollback_path}"; log_error "無法建立 Recovery 前 State 快照。"; return 1; }
        if ! cp -a "${STATE_FILE}" "${rollback_state}"; then
            rm -f -- "${rollback_path}" "${rollback_state}"
            log_error "無法保存 Recovery 前 State，停止還原。"
            return 1
        fi
        had_state=1
    fi

    if ! install -m 0644 "${source}" /etc/network/interfaces; then
        cp -a "${rollback_path}" /etc/network/interfaces
        rm -f -- "${rollback_path}" "${rollback_state:-}"
        log_error "無法安裝 Recovery 設定檔；已保留原設定。"
        return 1
    fi

    # 關鍵：在 ifreload 前，依目前 State 找出工具管理、但目標 Backup 已不再定義的
    # Port Group / VLAN Interface，先清除其 Runtime 殘留與過期 State 參照。
    # 避免 ifupdown2 在套用目標設定時仍沿用舊 Port Group，因不存在的 brif 目錄而失敗。
    log_step "Recovery 前同步清理過期 VSS Port Group / VLAN Runtime Object"
    if ! vss_reconcile_state_after_recovery "${source}"; then
        log_error "Recovery 前 Port Group 狀態同步失敗，停止套用。"
        cp -a "${rollback_path}" /etc/network/interfaces || true
        if ((had_state)); then
            cp -a "${rollback_state}" "${STATE_FILE}" || true
        else
            rm -f -- "${STATE_FILE}" || true
        fi
        rm -f -- "${rollback_path}" "${rollback_state:-}"
        return 1
    fi

    # Recovery 使用已安裝的目標設定作為唯一依據，不沿用 ifupdown2 儲存的舊介面狀態。
    # 已確認一般 Dry-run 會從舊狀態引用不存在的 vLan050/brif 並失敗；-u Dry-run
    # 則只解析目前設定。這裡只更改 Recovery 路徑，不改一般 Apply 的行為。
    if ! ifreload -a -u; then
        local failure_stamp
        failure_stamp="$(date '+%Y%m%d-%H%M%S-%N')"
        log_error "Recovery Apply 失敗；保留失敗目標與 Recovery 前快照，停止自動重試 ifreload。"

        # 保留本次嘗試套用的設定及 Recovery 前快照，供後續人工比對。
        if ! cp -a /etc/network/interfaces "${recovery_path}/interfaces.failed-target.${failure_stamp}"; then
            log_error "無法保存 Recovery 失敗目標設定：${recovery_path}"
        fi
        if ! cp -a "${rollback_path}" "${recovery_path}/interfaces.before-recovery.${failure_stamp}"; then
            log_error "無法保存 Recovery 前設定快照：${rollback_path}"
        fi
        if ((had_state)); then
            if ! cp -a "${rollback_state}" "${recovery_path}/state.before-recovery.${failure_stamp}"; then
                log_error "無法保存 Recovery 前 State 快照：${rollback_state}"
            fi
        fi

        # 先將磁碟上的設定與 State 寫回 Recovery 前版本，但不再盲目重試
        # ifreload -a；相同的系統層錯誤可能再次發生，且可能改動 Runtime。
        if ! cp -a "${rollback_path}" /etc/network/interfaces; then
            log_error "嚴重：Recovery 前 interfaces 寫回失敗；快照仍保留於 ${rollback_path}"
        fi
        if ((had_state)); then
            if ! cp -a "${rollback_state}" "${STATE_FILE}"; then
                log_error "嚴重：Recovery 前 State 寫回失敗；快照仍保留於 ${rollback_state}"
            fi
        else
            if ! rm -f -- "${STATE_FILE}"; then
                log_error "無法移除 Recovery 期間產生的 State：${STATE_FILE}"
            fi
        fi

        log_error "Recovery 未成功；磁碟設定已嘗試還原為 Recovery 前版本，但 Runtime 未重新套用或驗證。"
        log_error "Recovery 診斷檔案位置：${recovery_path}"
        log_error "請勿將本次結果視為網路已恢復。"
        rm -f -- "${rollback_path}" "${rollback_state:-}"
        return 1
    fi

    if [[ -n "${state_source}" ]]; then
        if ! cp -a "${state_source}" "${STATE_FILE}"; then
            local failure_stamp
            failure_stamp="$(date '+%Y%m%d-%H%M%S-%N')"
            log_error "Recovery State 還原失敗；保存診斷快照並停止自動重試 ifreload。"
            cp -a /etc/network/interfaces "${recovery_path}/interfaces.failed-state-restore.${failure_stamp}" || log_error "無法保存 State 還原失敗時的 interfaces。"
            cp -a "${rollback_path}" "${recovery_path}/interfaces.before-recovery.${failure_stamp}" || log_error "無法保存 Recovery 前 interfaces 快照。"
            if ((had_state)); then
                cp -a "${rollback_state}" "${recovery_path}/state.before-recovery.${failure_stamp}" || log_error "無法保存 Recovery 前 State 快照。"
                cp -a "${rollback_state}" "${STATE_FILE}" || log_error "Recovery 前 State 寫回失敗；快照仍保留於 ${rollback_state}"
            else
                rm -f -- "${STATE_FILE}" || log_error "無法移除 Recovery 期間產生的 State。"
            fi
            cp -a "${rollback_path}" /etc/network/interfaces || log_error "Recovery 前 interfaces 寫回失敗；快照仍保留於 ${rollback_path}"
            log_error "Recovery 未成功；Runtime 未重新套用或驗證，診斷檔案位於：${recovery_path}"
            rm -f -- "${rollback_path}" "${rollback_state:-}"
            return 1
        fi
        cp -a "${state_source}" "${recovery_path}/state.restored" || log_error "無法保存 State Recovery 紀錄。"
        # State 還原後再同步一次，移除 Backup State 中仍不屬於目標設定的過期 Port Group。
        if ! vss_reconcile_state_after_recovery "${source}"; then
            log_error "Recovery State 與目標設定同步失敗。"
            cp -a "${rollback_path}" /etc/network/interfaces || true
            if ((had_state)); then cp -a "${rollback_state}" "${STATE_FILE}" || true; else rm -f -- "${STATE_FILE}" || true; fi
            rm -f -- "${rollback_path}" "${rollback_state:-}"
            return 1
        fi
    fi

    if ! validate_recovery_state; then
        local failure_stamp
        failure_stamp="$(date '+%Y%m%d-%H%M%S-%N')"
        log_error "Recovery 驗證失敗；保存前後快照並停止自動重試 ifreload。"
        cp -a /etc/network/interfaces "${recovery_path}/interfaces.validation-failed.${failure_stamp}" || log_error "無法保存驗證失敗時的 interfaces。"
        cp -a "${rollback_path}" "${recovery_path}/interfaces.before-recovery.${failure_stamp}" || log_error "無法保存 Recovery 前 interfaces 快照。"
        if ((had_state)); then
            cp -a "${rollback_state}" "${recovery_path}/state.before-recovery.${failure_stamp}" || log_error "無法保存 Recovery 前 State 快照。"
            cp -a "${rollback_state}" "${STATE_FILE}" || log_error "Recovery 前 State 寫回失敗；快照仍保留於 ${rollback_state}"
        else
            rm -f -- "${STATE_FILE}" || log_error "無法移除 Recovery 期間產生的 State。"
        fi
        cp -a "${rollback_path}" /etc/network/interfaces || log_error "Recovery 前 interfaces 寫回失敗；快照仍保留於 ${rollback_path}"
        log_error "Recovery 未成功；Runtime 未重新套用或驗證，診斷檔案位於：${recovery_path}"
        rm -f -- "${rollback_path}" "${rollback_state:-}"
        return 1
    fi

    if ! cp -a "${source}" "${recovery_path}/interfaces.restored"; then
        log_error "Recovery 已套用並驗證，但無法保存 Recovery 記錄。"
        rm -f -- "${rollback_path}" "${rollback_state:-}"
        return 1
    fi
    cp -a "${rollback_path}" "${recovery_path}/interfaces.before-recovery" || log_error "無法保存 Recovery 前設定紀錄。"
    if ((had_state)); then cp -a "${rollback_state}" "${recovery_path}/state.before-recovery" || log_error "無法保存 Recovery 前 State 紀錄。"; fi
    rm -f -- "${rollback_path}" "${rollback_state:-}"
    log_ok "Recovery 設定、State 與管理網路驗證完成。"
    return 0
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

    if ! create_change_backup "${change_id}"; then
        log_error "變更前 Backup 建立失敗，拒絕套用網路設定。"
        return 1
    fi
    log_step "套用網路設定：${change_id}"
    if ! install -m 0644 "${source}" /etc/network/interfaces; then
        log_error "無法寫入待套用的網路設定，嘗試還原原始設定：${change_id}"
        if ! install -m 0644 "${BACKUP_DIR}/${change_id}/interfaces" /etc/network/interfaces; then
            log_error "原始 interfaces 還原失敗：${BACKUP_DIR}/${change_id}/interfaces"
        fi
        return 1
    fi
    # ifquery --list 只能確認介面清單可讀；用 ifreload parser 檢查 bond/bridge
    # 等完整設定關係。ifupdown2 對 bridge-fd 0 會回報範圍警告；
    # 僅當預檢輸出全部都是這一種警告時允許繼續，其他錯誤仍拒絕套用。
    local preflight_output=""
    local preflight_status=0
    if preflight_output="$(ifreload -a -s 2>&1)"; then
        if [[ -n "${preflight_output}" ]]; then printf '%s\n' "${preflight_output}"; fi
    else
        preflight_status=$?
        if [[ -n "${preflight_output}" ]] &&
           awk '
               /^warning: [^:]+: bridge-fd: value of out range "0": valid attribute range: 2-255$/ { seen=1; next }
               NF { unexpected=1 }
               END { exit (seen && !unexpected) ? 0 : 1 }
           ' <<<"${preflight_output}"; then
            log_info "已忽略 bridge-fd 0 相容性警告（bridge-stp off 時有效），繼續套用。"
        else
            printf '%s\n' "${preflight_output}" >&2
            log_error "網路設定預檢失敗；尚未套用 Runtime，還原原始 interfaces：${change_id}"
            if ! install -m 0644 "${BACKUP_DIR}/${change_id}/interfaces" /etc/network/interfaces; then
                log_error "原始 interfaces 還原失敗：${BACKUP_DIR}/${change_id}/interfaces"
            fi
            return 1
        fi
    fi
    # ifupdown2 的舊 Runtime State 可能引用已不存在的 Bridge（例如 vLan050/brif）。
    # 已在本節點觀察到 ifreload -a 因舊狀態失敗，而 -a -u Dry-run 可通過；
    # 一般 Apply 與 Recovery 統一使用目前設定重建介面狀態，避免重用過期 Runtime State。
    if ! ifreload -a -u; then
        log_error "套用失敗，開始 Recovery：${change_id}"
        if restore_change_backup "${change_id}"; then
            log_ok "原網路設定 Recovery 完成：${change_id}"
        else
            log_error "Recovery 失敗：${change_id}"
            log_error "目前 /etc/network/interfaces 與 Runtime 網路狀態需要人工確認。"
        fi
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
    local temp

    ensure_dirs

    temp="$(mktemp "${STATE_FILE}.tmp.XXXXXX")" || {
        log_error "無法建立 State 暫存檔：${STATE_FILE}"
        return 1
    }

    if [[ -f "${STATE_FILE}" ]]; then
        if ! awk -F '\t' -v t="${type}" -v k="${key}" '!($1==t && $2==k)' "${STATE_FILE}" > "${temp}"; then
            rm -f "${temp}"
            log_error "無法整理既有 State：${STATE_FILE}"
            return 1
        fi
    fi

    if ! printf '%s\t%s\t%s\n' "${type}" "${key}" "${value}" >> "${temp}"; then
        rm -f "${temp}"
        log_error "無法寫入 State：${type} / ${key}"
        return 1
    fi

    if ! mv -f "${temp}" "${STATE_FILE}"; then
        rm -f "${temp}"
        log_error "無法提交 State：${STATE_FILE}"
        return 1
    fi

    return 0
}
valid_vlan_id()
{
    local vlan_id="${1:-}"
    [[ "${vlan_id}" =~ ^[0-9]+$ ]] || return 1
    (( 10#${vlan_id} >= 1 && 10#${vlan_id} <= 4094 ))
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
    local temp

    [[ -f "${STATE_FILE}" ]] || return 0
    temp="$(mktemp "${STATE_FILE}.tmp.XXXXXX")" || {
        log_error "無法建立 State 暫存檔：${STATE_FILE}"
        return 1
    }

    if ! awk -F '\t' -v t="${type}" -v k="${key}" '!( $1==t && $2==k )' "${STATE_FILE}" > "${temp}"; then
        rm -f "${temp}"
        log_error "無法整理 State：${STATE_FILE}"
        return 1
    fi
    if ! mv -f "${temp}" "${STATE_FILE}"; then
        rm -f "${temp}"
        log_error "無法提交 State：${STATE_FILE}"
        return 1
    fi
    return 0
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

validate_vss_port_group_runtime()
{
    local port_group="$1"
    local vlan_dev="$2"

    if ! ip link show "${port_group}" >/dev/null 2>&1; then
        log_error "VSS Port Group Runtime Bridge 不存在：${port_group}"
        return 1
    fi
    if ! ip link show "${vlan_dev}" >/dev/null 2>&1; then
        log_error "VSS Port Group VLAN Interface 不存在：${vlan_dev}"
        return 1
    fi
    if ! ip link show "${port_group}" | grep -q 'state UP\|state UNKNOWN'; then
        log_error "VSS Port Group Runtime Bridge 狀態異常：${port_group}"
        return 1
    fi
    log_ok "VSS Port Group Runtime 驗證完成：${port_group} / ${vlan_dev}"
    return 0
}

validate_network_after_change()
{
    local bridge="$1"
    local before_cluster after_cluster
    local management_dev management_ip gateway

    log_step "驗證網路與 Cluster 狀態"

    if ! ip link show "${bridge}" >/dev/null 2>&1; then
        log_error "Bridge ${bridge} 不存在。"
        return 1
    fi

    if ! ip link show "${bridge}" | grep -q 'state UP\|state UNKNOWN'; then
        log_error "Bridge ${bridge} 狀態異常。"
        return 1
    fi

    get_management_info
    management_dev="${DEV_WITH_GW:-}"
    management_ip="${CURRENT_IP:-}"
    gateway="${CURRENT_GW:-}"

    if [[ -z "${management_dev}" || -z "${management_ip}" ]]; then
        log_error "管理網路介面或 IPv4 位址無法確認。"
        return 1
    fi

    if [[ -z "${gateway}" ]]; then
        log_error "Default Gateway 無法確認。"
        return 1
    fi

    if ! ip route show default 2>/dev/null | grep -Fq "default via ${gateway} dev ${management_dev}"; then
        log_error "Default Route 與管理介面不一致：${management_dev} / ${gateway}"
        return 1
    fi

    before_cluster="$(cluster_status_text)"
    if ! cluster_quorate; then
        log_error "變更後 Cluster Quorum 不正常：${before_cluster}"
        return 1
    fi
    after_cluster="$(cluster_status_text)"

    log_ok "Bridge ${bridge} 驗證完成。"
    log_ok "Management：${management_dev} / ${management_ip}"
    log_ok "Default Gateway：${gateway}"
    log_ok "Cluster：${after_cluster}"
    return 0
}

validate_vss_bond_runtime()
{
    local bridge="$1" bond="$2" nic1="$3" nic2="$4" expected_mode="$5"
    local bonding_dir="/sys/class/net/${bond}/bonding"
    local actual_mode=""
    local -a actual_slaves=()

    if [[ ! -d "${bonding_dir}" ]]; then
        log_error "Bond Runtime 不存在或尚未啟用：${bond}"
        return 1
    fi
    if [[ ! -e "/sys/class/net/${bridge}/brif/${bond}" ]]; then
        log_error "Bridge ${bridge} 未將 ${bond} 設為 Uplink。"
        return 1
    fi

    actual_mode="$(awk '{print $1}' "${bonding_dir}/mode" 2>/dev/null || true)"
    if [[ "${actual_mode}" != "${expected_mode}" ]]; then
        log_error "Bond 模式不符：預期 ${expected_mode}，實際 ${actual_mode:-未讀取}"
        return 1
    fi

    read -r -a actual_slaves < "${bonding_dir}/slaves" || true
    if [[ "${actual_slaves[*]}" != "${nic1} ${nic2}" &&
          "${actual_slaves[*]}" != "${nic2} ${nic1}" ]]; then
        log_error "Bond 成員不符：預期 ${nic1} ${nic2}，實際 ${actual_slaves[*]:-無}"
        return 1
    fi

    log_ok "Bond Runtime 驗證完成：${bond} / ${expected_mode} / ${actual_slaves[*]}"
    return 0
}


ensure_bridge_vlan_aware()
{
    local bridge="$1"
    local source temp change_id

    [[ -e "/sys/class/net/${bridge}/bridge" ]] || {
        log_error "PVE Bridge 不存在：${bridge}"
        return 1
    }

    if awk -v bridge="${bridge}" '
        BEGIN { RS=""; ok=0 }
        $0 ~ "(^|\n)auto[[:space:]]+" bridge "[[:space:]]*(\n|$)" {
            aware=($0 ~ /(^|\n)[[:space:]]*bridge-vlan-aware[[:space:]]+yes([[:space:]]*\n|$)/)
            vids=($0 ~ /(^|\n)[[:space:]]*bridge-vids[[:space:]]+2-4094([[:space:]]*\n|$)/)
            if(aware && vids) ok=1
        }
        END { exit(ok ? 0 : 1) }
    ' /etc/network/interfaces 2>/dev/null; then
        return 0
    fi

    source="$(mktemp /tmp/pve-network-interfaces.XXXXXX)"
    temp="$(mktemp /tmp/pve-network-interfaces.XXXXXX)"
    cp -a /etc/network/interfaces "${source}"

    awk -v bridge="${bridge}" '
        BEGIN { RS=""; ORS="\n\n"; found=0 }
        {
            is_bridge = ($0 ~ "(^|\n)auto[[:space:]]+" bridge "[[:space:]]*(\n|$)")
            if (is_bridge) {
                found=1
                n=split($0,a,"\n")
                out=""
                aware=0
                vids=0
                for(i=1;i<=n;i++) {
                    line=a[i]
                    if(line ~ /^[[:space:]]*bridge-vlan-aware[[:space:]]+/) {
                        line="    bridge-vlan-aware yes"
                        aware=1
                    }
                    if(line ~ /^[[:space:]]*bridge-vids[[:space:]]+/) {
                        line="    bridge-vids 2-4094"
                        vids=1
                    }
                    out=out (out=="" ? "" : "\n") line
                }
                if(!aware) out=out "\n    bridge-vlan-aware yes"
                if(!vids) out=out "\n    bridge-vids 2-4094"
                print out
                next
            }
            print
        }
        END {
            if(!found) exit 2
        }
    ' "${source}" > "${temp}" || {
        rm -f "${source}" "${temp}"
        log_error "無法定位 Bridge 設定：${bridge}"
        return 1
    }

    change_id="$(create_change_id "vss-vlan-aware-${bridge}")"
    if ! apply_interfaces_file "${change_id}" "${temp}"; then
        rm -f "${source}" "${temp}"
        return 1
    fi

    rm -f "${source}" "${temp}"
    return 0
}

apply_interfaces()
{
    local source="$1"
    local purpose="${2:-network-apply}"
    local change_id
    change_id="$(create_change_id "${purpose}")"
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
    prepare_vss_recovery

    if [[ -e "/sys/class/net/${bridge}" ]]; then
        if ! ensure_bridge_vlan_aware "${bridge}"; then
            pause_screen
            return 1
        fi
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

    if ! apply_interfaces "${generated_file}" "vss-${bridge}"; then
        log_error "VSS ${bridge} 建立 / 套用失敗。"
        cp -a "${VSS_DIR}/interfaces.before" /etc/network/interfaces
        ifreload -a || true
        pause_screen
        return 1
    fi
    rm -f "${GENERATED_INTERFACES_FILE}"
    GENERATED_INTERFACES_FILE=""

    if ! validate_network_after_change "${bridge}"; then
        log_error "VSS ${bridge} 驗證失敗，開始 Recovery。"
        local recovery_change_id
        recovery_change_id="$(create_change_id "recovery-vss-${bridge}")"
        if restore_change_backup "${recovery_change_id}" "${VSS_DIR}/interfaces.before"; then
            log_ok "VSS ${bridge} 已依變更前設定完成 Recovery。"
        else
            log_error "VSS ${bridge} 自動 Recovery 失敗。"
            log_error "變更前設定保存於：${VSS_DIR}/interfaces.before"
        fi
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
    local uplink_type="${1:-bond}"
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

    # Physical Uplink 只能選已註冊的 Virtual Switch，或由既有 Port Group
    # 明確記錄的父 Virtual Switch；不可把 vlan050 等 Port Group Bridge 當成 Switch。
    while read -r bridge; do
        [[ -n "${bridge}" ]] || continue
        bridges+=( "${bridge}" )
    done < <(get_vss_switch_bridges)

    if (("${#bridges[@]}" == 0)); then
        log_error "找不到已註冊的 VSS Virtual Switch。請先建立 VSS。"
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

    if [[ "${uplink_type}" == "single" ]]; then
        BOND_MODE=""
        BOND_XMIT_HASH_POLICY=""
        BOND_LACP_RATE=""
    else
        if ! select_bond_mode; then
            log_info "已取消 Linux Bond 設定。"
            pause_screen
            return 0
        fi
    fi
    if nic_used_elsewhere "${first_nic}" "${bridge}"; then
        log_error "NIC ${first_nic} 已被其他 Bridge / Bond 使用，停止 Uplink 變更。"
        pause_screen
        return 0
    fi
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
    echo " Management IP ：${CURRENT_IP:-未偵測}"
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
    prepare_vss_recovery
    save_interfaces_copy "${VSS_DIR}/interfaces.before-uplink"
    network_snapshot "${VSS_DIR}/network.before-uplink"

    if ! write_vss_interfaces "${bridge}" "${first_nic}" "${second_nic}" "${BOND_MODE}"; then
        rm -f "${GENERATED_INTERFACES_FILE:-}"
        GENERATED_INTERFACES_FILE=""
        log_error "VSS Uplink 設定檔建立失敗。"
        pause_screen
        return 1
    fi

    if ! apply_interfaces "${GENERATED_INTERFACES_FILE}" "vss-uplink-${bridge}"; then
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
        recovery_change_id="$(create_change_id "recovery-uplink-${bridge}")"
        if apply_interfaces_file "${recovery_change_id}" "${VSS_DIR}/interfaces.before-uplink"; then
            log_ok "VSS Uplink 已依變更前設定完成 Recovery。"
        else
            log_error "VSS Uplink 自動 Recovery 套用失敗。"
        fi
        echo "變更前設定保存於：${VSS_DIR}/interfaces.before-uplink"
        pause_screen
        return 1
    fi

    if [[ -n "${BOND_MODE}" ]] &&
       ! validate_vss_bond_runtime "${bridge}" "${BOND_DEVICE}" "${first_nic}" "${second_nic}" "${BOND_MODE}"; then
        log_error "VSS Bond 實際狀態驗證失敗，開始 Recovery。"
        local bond_recovery_id
        bond_recovery_id="$(create_change_id "recovery-bond-${bridge}")"
        if apply_interfaces_file "${bond_recovery_id}" "${VSS_DIR}/interfaces.before-uplink"; then
            log_ok "Bond 驗證失敗，已依變更前設定完成 Recovery。"
        else
            log_error "Bond 驗證失敗且自動 Recovery 未完成；請檢查網路狀態。"
        fi
        echo "變更前設定保存於：${VSS_DIR}/interfaces.before-uplink"
        pause_screen
        return 1
    fi


    if ! save_state "VSS" "bridge" "${bridge}" ||
         ! save_state "VSS" "nic1" "${first_nic}" ||
         ! remove_state_entry "VSS" "nic2" ||
         { [[ -n "${second_nic}" ]] && ! save_state "VSS" "nic2" "${second_nic}"; } ||
         ! save_state "VSS" "bond_mode" "${BOND_MODE:-none}" ||
         ! save_state "VSS" "bond_hash" "${BOND_XMIT_HASH_POLICY:-none}" ||
         ! save_state "VSS" "bond_lacp_rate" "${BOND_LACP_RATE:-none}"; then
        log_error "VSS Uplink 已套用，但 State 寫入失敗。"
        local state_recovery_id
        state_recovery_id="$(create_change_id "recovery-uplink-state-${bridge}")"
        if apply_interfaces_file "${state_recovery_id}" "${VSS_DIR}/interfaces.before-uplink"; then
            log_ok "VSS Uplink State 失敗後已完成 Runtime Recovery。"
        else
            log_error "VSS Uplink State 失敗後 Recovery 不完整。"
        fi
        pause_screen
        return 1
    fi
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

    echo -e "${CYAN}Virtual Switch / VSS：${NC}"
    echo ""

    local bridge uplink
    while read -r bridge; do
        [[ -n "${bridge}" ]] || continue
        echo -e "  ${CYAN}Virtual Switch：${NC}${GREEN}$(get_vswitch_name "${bridge}")${NC}"
        echo -e "  ${CYAN}PVE Bridge     ：${NC}${GREEN}${bridge}${NC}"
        echo -e "  ${CYAN}Physical Uplink：${NC}"

        local -a ports=()
        if [[ -d "/sys/class/net/${bridge}/brif" ]]; then
            while read -r uplink; do
                [[ -n "${uplink}" ]] || continue
                ports+=("${uplink}")
            done < <(find "/sys/class/net/${bridge}/brif" -maxdepth 1 -mindepth 1 -type l -printf "%f\n" 2>/dev/null | sort -V)
        fi

        if (("${#ports[@]}" == 0)); then
            echo -e "    狀態：${YELLOW}尚未設定 Physical Uplink${NC}"
        else
            for uplink in "${ports[@]}"; do
                if [[ -f "/proc/net/bonding/${uplink}" ]]; then
                    echo -e "    ${BLUE}${bridge} → ${uplink}${NC}"
                    echo -e "    模式：${MAGENTA}Bond / NIC Teaming${NC}"
                    grep -E 'Bonding Mode|MII Status|Currently Active Slave|Slave Interface' "/proc/net/bonding/${uplink}" | while IFS= read -r detail; do
                        echo -e "      ${BLUE}${detail}${NC}"
                    done || true
                else
                    echo -e "    ${BLUE}${bridge} → ${uplink}${NC}"
                    echo -e "    模式：${GREEN}單 NIC，未使用 Bond${NC}"
                fi
            done
        fi
        echo ""
    done < <(get_vss_switch_bridges)

    echo -e "${CYAN}Port Group：${NC}"
    port_group_list_vss
    echo ""
    echo -e "${CYAN}Management / Host Network：${NC}"
    get_management_info
    echo -e "  Device ：${GREEN}${DEV_WITH_GW:-未偵測}${NC}"
    echo -e "  IP     ：${GREEN}${CURRENT_IP:-未偵測}${NC}"
    echo -e "  Gateway：${GREEN}${CURRENT_GW:-未偵測}${NC}"
    pause_screen
}

vss_vmkernel_menu()
{
    show_header
    echo "============================================================"
    echo " Management / Host Network"
    echo "============================================================"
    echo ""
    echo "目前僅提供 PVE 主機管理網路資訊檢視。"
    echo "Management IP、Gateway 與 Cluster Network 不在此處直接修改。"
    echo ""

    get_management_info

    echo " Device ：${DEV_WITH_GW:-未偵測}"
    echo " IP     ：${CURRENT_IP:-未偵測}"
    echo " Gateway：${CURRENT_GW:-未偵測}"

    pause_screen
}

vss_add_network_menu()
{
    while true; do
        show_header
        echo "============================================================"
        echo " 新增網路"
        echo "============================================================"
        echo ""
        echo "VMware 操作方式：先選擇「連線類型」，再進入該類型的設定流程。"
        echo "PVE 底層的 Bridge、VLAN Interface、Bond 等由程式自動處理。"
        echo ""
        echo " 選取連線類型："
        echo ""
        echo "  1) 標準交換器的虛擬機器連接埠群組"
        echo "     Port Group — 建立名稱與 VLAN ID，供虛擬機器使用"
        echo ""
        echo "  2) 實體網路介面卡"
        echo "     Physical Uplink — 將實體 NIC / NIC Teaming 連接到 Virtual Switch"
        echo ""
        echo "  0) 返回"
        echo ""
        local choice
        read -r -p "請選擇連線類型：" choice
        case "${choice}" in
            1) vss_port_group_create || true ;;
            2) vss_uplink_add wizard ;;
            0) return 0 ;;
            *) log_error "選擇無效，請輸入上方數字。"; sleep 1 ;;
        esac
    done
}

vss_physical_uplink_menu()
{
    while true; do
        show_header
        echo "============================================================"
        echo " Physical Uplink 管理"
        echo "============================================================"
        echo ""
        echo "VMware：Virtual Switch → Physical Uplink。"
        echo "PVE：由程式自動處理 Physical NIC 與 Linux Bond。"
        echo ""
        echo "  1) 單一實體網路介面卡"
        echo "     不建立 NIC Teaming，直接使用一張 NIC"
        echo ""
        echo "  2) NIC Teaming / Linux Bond"
        echo "     使用兩張以上實體 NIC 進行主備或聚合"
        echo ""
        echo "  3) 查看目前 Uplink"
        echo "  0) 返回"
        echo ""
        local choice
        read -r -p "請選擇：" choice
        case "${choice}" in
            1) vss_uplink_add single ;;
            2) vss_uplink_add bond ;;
            3) vss_show ;;
            0) return 0 ;;
            *) log_error "選擇無效，請輸入上方數字。"; sleep 1 ;;
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
        echo "VMware 操作模型：Virtual Switch → Port Group / Physical Uplink。"
        echo "PVE 實作細節由 Backend 自動處理；使用者不需要操作 vmbr0、VLAN"
        echo "Sub-interface、Bridge Port 或 Linux Bond 的底層設定。"
        echo ""
        echo "============================================================"
        echo " 操作"
        echo "============================================================"
        echo "  1) 新增網路..."
        echo "     VMware：新增網路 → 選取連線類型"
        echo "     （Port Group / Physical Uplink）"
        echo ""
        echo "  2) 查看目前設定"
        echo "     顯示 Virtual Switch、Port Group、VLAN ID 與 Physical Uplink"
        echo "  0) 返回"
        echo ""
        local choice
        read -r -p "請選擇：" choice
        case "${choice}" in
            1) vss_add_network_menu ;;
            2) vss_show ;;

            0) return 0 ;;
            *) log_error "選擇無效，請輸入上方數字。"; sleep 1 ;;
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

vds_apply()
{
    log_step "套用 SDN 設定"
    if ! pvesh set /cluster/sdn; then
        log_error "SDN Apply 失敗。"
        return 1
    fi
    log_ok "SDN Apply 完成。"
    return 0
}

vds_delete_vnet()
{
    local vnet="$1"
    if ! pvesh get "/cluster/sdn/vnets/${vnet}" >/dev/null 2>&1; then
        log_info "SDN VNet 不存在，視為已刪除：${vnet}"
        return 0
    fi
    if ! pvesh delete "/cluster/sdn/vnets/${vnet}"; then
        log_error "SDN VNet 刪除失敗：${vnet}"
        return 1
    fi
    if pvesh get "/cluster/sdn/vnets/${vnet}" >/dev/null 2>&1; then
        log_error "SDN VNet 刪除指令回報成功，但實際物件仍存在：${vnet}"
        return 1
    fi
    return 0
}

vds_delete_zone()
{
    local zone="$1"
    if ! pvesh get "/cluster/sdn/zones/${zone}" >/dev/null 2>&1; then
        log_info "SDN Zone 不存在，視為已刪除：${zone}"
        return 0
    fi
    if ! pvesh delete "/cluster/sdn/zones/${zone}"; then
        log_error "SDN Zone 刪除失敗：${zone}"
        return 1
    fi
    if pvesh get "/cluster/sdn/zones/${zone}" >/dev/null 2>&1; then
        log_error "SDN Zone 刪除指令回報成功，但實際物件仍存在：${zone}"
        return 1
    fi
    return 0
}

vds_restore_vnet()
{
    local zone="$1" vnet="$2" tag="$3"
    if pvesh get "/cluster/sdn/vnets/${vnet}" >/dev/null 2>&1; then return 0; fi
    log_step "還原 SDN VNet：${vnet} / Zone ${zone} / VLAN ${tag}"
    if ! pvesh create /cluster/sdn/vnets --vnet "${vnet}" --zone "${zone}" --tag "${tag}"; then
        log_error "SDN VNet 還原建立失敗：${vnet}"
        return 1
    fi
    pvesh get "/cluster/sdn/vnets/${vnet}" >/dev/null 2>&1 || {
        log_error "SDN VNet 還原後無法確認實際物件：${vnet}"
        return 1
    }
}

vds_verify_vnet()
{
    local vnet="$1" zone="$2" tag="$3" detail
    detail="$(pvesh get "/cluster/sdn/vnets/${vnet}" 2>/dev/null || true)"
    [[ -n "${detail}" ]] || {
        log_error "找不到 SDN VNet：${vnet}"
        return 1
    }
    if [[ -n "${zone}" ]] && ! grep -qE "(^|[[:space:]])zone[=:][[:space:]]*${zone}([[:space:]]|$)" <<<"${detail}"; then
        log_error "SDN VNet ${vnet} 的 Zone 與 State 不一致：${zone}"
        return 1
    fi
    if [[ -n "${tag}" ]] && ! grep -qE "(^|[[:space:]])tag[=:][[:space:]]*${tag}([[:space:]]|$)" <<<"${detail}"; then
        log_error "SDN VNet ${vnet} 的 VLAN Tag 與 State 不一致：${tag}"
        return 1
    fi
}
# VDS VNet existence check：此函式必須保持在函式作用域內，不得在啟動階段執行參數驗證。
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

    if ! ensure_bridge_vlan_aware "${SDN_BRIDGE}"; then
        pause_screen
        return 1
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
        if ! create_vds_change_backup "zone-${SDN_ZONE}"; then
            pause_screen
            return 1
        fi
        if ! vds_create_zone "${SDN_ZONE}" "${SDN_BRIDGE}"; then
            log_error "SDN Zone 建立失敗：${SDN_ZONE}"
            pause_screen
            return 1
        fi
        zone_was_created=1
    else
        log_info "使用現有 SDN Zone：${SDN_ZONE}"
    fi

    echo ""
    echo "Port Group / VNet 可以稍後由選單建立。"
    echo ""
    if confirm "現在立即 Apply SDN？"; then
        if ! vds_apply; then
            if ((zone_was_created == 1)); then
                log_step "SDN Apply 失敗，嘗試刪除本次建立的 Zone。"
                if vds_delete_zone "${SDN_ZONE}" && vds_apply && ! pvesh get "/cluster/sdn/zones/${SDN_ZONE}" >/dev/null 2>&1; then
                    log_ok "失敗的 SDN Zone 已完成 Recovery。"
                else
                    log_error "SDN Zone Recovery 不完整：實際 Zone / SDN Apply 狀態仍需人工確認：${SDN_ZONE}"
                fi
            else
                log_error "現有 SDN Zone Apply 失敗，未修改 State：${SDN_ZONE}"
            fi
            pause_screen
            return 1
        fi
    fi

    if ((zone_was_created == 1)); then
        if ! pvesh get "/cluster/sdn/zones/${SDN_ZONE}" >/dev/null 2>&1; then
            log_error "SDN Zone Apply 後無法確認實際物件：${SDN_ZONE}"
            pause_screen
            return 1
        fi
        if ! save_state "VDS_ZONE" "${SDN_ZONE}" "${SDN_BRIDGE}"; then
            log_error "SDN Zone 已建立，但 State 寫入失敗：${SDN_ZONE}"
            log_error "請勿再次建立同名 Zone；請先確認 /etc/pve-toolkit/net/state/objects.conf。"
            pause_screen
            return 1
        fi
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
            echo "  - ${name}"
            echo "      VLAN ID : ${value}"
            echo "      Virtual Switch：$(get_vswitch_name "${bridge}")"
            echo "      PVE Bridge     ：${bridge:-未知}"
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

    # GUI Pending Configuration 必須在進入 Port Group 建立流程前攔截，避免使用者完成輸入後才被阻擋。
    # apply_interfaces_file() 仍保留第二道 Guard，防止檢查後才出現 Pending。
    if ! network_pending_guard; then
        pause_screen
        return 0
    fi

    if ! ensure_network_backup; then return 0; fi

    local -a bridges=()
    local bridge choice
    while read -r bridge; do
        [[ -n "${bridge}" ]] || continue
        # Port Group 本身也是 Linux Bridge，但它不是可供建立下一個 Port Group 的 Virtual Switch。
        # 只排除本工具 State 明確記錄為 VSS_PORT_GROUP 的 Bridge，避免把一般/外部 Linux Bridge 誤判成 Port Group.
        if state_has "VSS_PORT_GROUP" "${bridge}"; then
            continue
        fi
        bridges+=("${bridge}")
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

    prepare_vss_recovery

    if ! ensure_bridge_vlan_aware "${bridge}"; then
        pause_screen
        return 1
    fi

    local vnet vlan vlan_dev
    while true; do
        read -r -p "Port Group 名稱：" vnet
        [[ "${vnet}" =~ ^[A-Za-z0-9_-]+$ ]] || { log_error "名稱只能使用英數、底線、連字號。"; continue; }
        local state_exists=0
        local runtime_exists=0
        local config_exists=0
        local stale_bridge="" stale_vlan="" stale_vlan_dev=""
        local stale_vlan_used=0

        if state_has "VSS_PORT_GROUP" "${vnet}"; then
            state_exists=1
            stale_vlan="$(awk -F '\t' -v n="${vnet}" '$1=="VSS_PORT_GROUP" && $2==n {print $3; exit}' "${STATE_FILE}")"
            stale_bridge="$(awk -F '\t' -v n="${vnet}" '$1=="VSS_PORT_GROUP_BRIDGE" && $2==n {print $3; exit}' "${STATE_FILE}")"
            stale_vlan_dev="$(awk -F '\t' -v n="${vnet}" '$1=="VSS_PORT_GROUP_VLAN_DEV" && $2==n {print $3; exit}' "${STATE_FILE}")"
            [[ -n "${stale_vlan_dev}" ]] || stale_vlan_dev="${stale_bridge}.${stale_vlan}"
        fi
        if [[ -e "/sys/class/net/${vnet}" ]]; then runtime_exists=1; fi
        if grep -qE "^(auto|allow-[^[:space:]]+)[[:space:]]+${vnet}([[:space:]]|$)|^iface[[:space:]]+${vnet}([[:space:]]|$)" /etc/network/interfaces /etc/network/interfaces.new 2>/dev/null; then
            config_exists=1
        fi

        if ((state_exists == 1 && config_exists == 0)); then
            if ((runtime_exists == 1)); then
                log_error "State 記錄此工具管理的 Port Group，但 Runtime Bridge 仍存在：${vnet}"
                log_error "為避免中斷仍在使用的 VM 網路，不會自動刪除 Runtime Bridge。請先確認使用狀態並清理後重試。"
                continue
            fi

            if [[ -n "${stale_vlan_dev}" ]] &&
               grep -qF "${stale_vlan_dev}" /etc/network/interfaces /etc/network/interfaces.new 2>/dev/null; then
                log_error "VLAN Interface 仍被 PVE 設定引用，拒絕清理 State：${stale_vlan_dev}"
                continue
            fi

            if [[ -n "${stale_vlan_dev}" ]] && ip link show "${stale_vlan_dev}" >/dev/null 2>&1; then
                stale_vlan_used="$(awk -F '\t' -v d="${stale_vlan_dev}" '$1=="VSS_PORT_GROUP_VLAN_DEV" && $3==d {n++} END{print n+0}' "${STATE_FILE}")"
                if ((stale_vlan_used > 1)); then
                    log_error "殘留 VLAN Interface 被多個 State 物件引用，拒絕自動刪除：${stale_vlan_dev}"
                    continue
                fi
                echo "偵測到 GUI 刪除後仍存在的工具管理 VLAN Runtime Interface：${stale_vlan_dev}"
                if ! confirm "確認只清理此孤立 VLAN Interface，讓 Port Group 可以重新建立？"; then
                    log_info "保留 Runtime Interface 與 State，取消本次建立。"
                    continue
                fi
                if ! ip link delete dev "${stale_vlan_dev}" || ip link show "${stale_vlan_dev}" >/dev/null 2>&1; then
                    log_error "無法清理殘留 VLAN Interface：${stale_vlan_dev}"
                    continue
                fi
            fi

            log_info "PVE 設定與 Port Group Runtime 均不存在，清理過期的工具 State：${vnet}"
            if ! remove_state_entry "VSS_PORT_GROUP" "${vnet}" ||
               ! remove_state_entry "VSS_PORT_GROUP_BRIDGE" "${vnet}" ||
               ! remove_state_entry "VSS_PORT_GROUP_VLAN_DEV" "${vnet}"; then
                log_error "過期 State 清理未完成，停止建立：${vnet}"
                continue
            fi
            state_exists=0
        fi

        if ((runtime_exists == 1 || config_exists == 1)); then
            log_error "VSS Port Group / PVE Bridge ${vnet} 已存在。"
            continue
        fi
        break
    done

    while true; do
        read -r -p "VLAN ID：" vlan
        valid_vlan_id "${vlan}" || { log_error "VLAN ID 必須為 1～4094。"; continue; }
        vlan_dev="${bridge}.${vlan}"
        if ip link show "${vlan_dev}" >/dev/null 2>&1 ||
           grep -qE "^(auto|allow-[^[:space:]]+)[[:space:]]+${vlan_dev}([[:space:]]|$)|^iface[[:space:]]+${vlan_dev}([[:space:]]|$)" /etc/network/interfaces /etc/network/interfaces.new 2>/dev/null; then
            log_error "VLAN 子介面已存在或仍被 PVE 設定引用：${vlan_dev}"
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
    change_id="$(create_change_id "vss-${vnet}")"
    log_step "已完成設定整理，準備 Backup 並套用網路設定。"
    if ! apply_interfaces_file "${change_id}" "${generated_file}"; then
        rm -f "${generated_file}"
        if network_pending_configuration_exists; then
            log_error "VSS Port Group ${vnet} 未建立：GUI Pending Configuration 阻擋了變更；本次未修改 /etc/network/interfaces，未執行 Recovery。"
        else
            log_error "VSS Port Group ${vnet} 建立失敗；套用流程已處理 Recovery，請檢查上方錯誤。"
        fi
        pause_screen
        return 1
    fi
    rm -f "${generated_file}"

    if ! validate_network_after_change "${bridge}"; then
        log_error "VSS Port Group ${vnet} 建立後驗證失敗，開始 Recovery。"
        if restore_change_backup "${change_id}"; then
            log_ok "VSS Port Group ${vnet} 已完成 Recovery。"
        else
            log_error "VSS Port Group ${vnet} Recovery 失敗。"
        fi
        pause_screen
        return 1
    fi

    if ! validate_vss_port_group_runtime "${vnet}" "${vlan_dev}"; then
        log_error "VSS Port Group ${vnet} Runtime Object 驗證失敗，開始 Recovery。"
        if restore_change_backup "${change_id}"; then
            log_ok "VSS Port Group ${vnet} Runtime Recovery 完成。"
        else
            log_error "VSS Port Group ${vnet} Runtime Recovery 失敗。"
        fi
        pause_screen
        return 1
    fi

    if ! save_state "VSS" "bridge" "${bridge}" ||
         ! save_state "VSS_PORT_GROUP" "${vnet}" "${vlan}" ||
         ! save_state "VSS_PORT_GROUP_BRIDGE" "${vnet}" "${bridge}" ||
         ! save_state "VSS_PORT_GROUP_VLAN_DEV" "${vnet}" "${vlan_dev}"; then
        log_error "VSS Port Group 已套用，但 State 寫入失敗：${vnet}"
        if restore_change_backup "${change_id}"; then
            log_ok "VSS Port Group State / Runtime 已 Recovery：${vnet}"
        else
            log_error "VSS Port Group State / Runtime Recovery 失敗：${vnet}"
        fi
        pause_screen
        return 1
    fi

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
    if ! create_vds_change_backup "portgroup-${vnet}"; then
        pause_screen
        return 1
    fi
    if ! vds_create_vnet "${zone}" "${vnet}" "${tag}"; then
        log_error "VDS Port Group 建立失敗。"
        pause_screen
        return 1
    fi

    if ! vds_apply; then
        log_error "VDS Port Group 建立後 SDN Apply 失敗，開始 Recovery：${vnet}"
        if vds_delete_vnet "${vnet}" && vds_apply && ! pvesh get "/cluster/sdn/vnets/${vnet}" >/dev/null 2>&1; then
            log_ok "VDS Port Group Recovery 完成：${vnet}"
        else
            log_error "VDS Port Group Recovery 不完整：實際 VNet / SDN Apply 狀態仍需人工確認：${vnet}"
        fi
        pause_screen
        return 1
    fi
    if ! vds_verify_vnet "${vnet}" "${zone}" "${tag}"; then
        log_error "VDS Port Group 建立後實際物件驗證失敗：${vnet}"
        if vds_delete_vnet "${vnet}" && vds_apply && ! pvesh get "/cluster/sdn/vnets/${vnet}" >/dev/null 2>&1; then
            log_ok "VDS Port Group 驗證失敗後已完成 Recovery：${vnet}"
        else
            log_error "VDS Port Group 驗證失敗後 Recovery 不完整：${vnet}"
        fi
        pause_screen
        return 1
    fi
    if ! save_state "PORT_GROUP" "${vnet}" "${tag}" ||
         ! save_state "PORT_GROUP_ZONE" "${vnet}" "${zone}"; then
        log_error "VDS Port Group 已建立，但 State 寫入失敗：${vnet}"
        if vds_delete_vnet "${vnet}" && vds_apply && ! pvesh get "/cluster/sdn/vnets/${vnet}" >/dev/null 2>&1; then
            log_ok "VDS Port Group State / Runtime Recovery 完成：${vnet}"
        else
            log_error "VDS Port Group State / Runtime Recovery 不完整：${vnet}"
        fi
        pause_screen
        return 1
    fi
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
    if ! create_vds_change_backup "portgroup-delete-${vnet}"; then
        pause_screen
        return 1
    fi
    if ! vds_delete_vnet "${vnet}"; then
        log_error "VDS Port Group 刪除失敗：${vnet}"
        pause_screen
        return 1
    fi
    if ! vds_apply; then
        log_error "VDS Port Group 刪除後 SDN Apply 失敗，開始 Recovery：${vnet}"
        if vds_restore_vnet "${zone}" "${vnet}" "${tag}" && vds_apply && vds_verify_vnet "${vnet}" "${zone}" "${tag}"; then
            log_ok "VDS Port Group Delete / Apply Recovery 完成：${vnet}"
        else
            log_error "VDS Port Group Delete / Apply Recovery 不完整：${vnet}"
            log_error "State 保持未刪除；實際 SDN VNet / Apply 狀態需要人工確認。"
        fi
        pause_screen
        return 1
    fi
    if pvesh get "/cluster/sdn/vnets/${vnet}" >/dev/null 2>&1; then
        log_error "VDS Port Group Delete 後實際 VNet 仍存在，State 不會刪除：${vnet}"
        pause_screen
        return 1
    fi
    if ! remove_state_entry "PORT_GROUP" "${vnet}" ||
       ! remove_state_entry "PORT_GROUP_ZONE" "${vnet}"; then
        log_error "VDS Port Group Runtime 已刪除，但 State 清理失敗：${vnet}"
        pause_screen
        return 1
    fi
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
    change_id="$(create_change_id "vss-portgroup-delete")"
    if ! apply_interfaces_file "${change_id}" "${generated_file}"; then
        rm -f "${generated_file}"
        log_error "VSS Port Group 刪除失敗，已嘗試 Recovery。"
        pause_screen
        return 1
    fi
    rm -f "${generated_file}"

    local -a validation_bridges=()
    local target_name validation_bridge bridge bridge_seen
    for target_name in "${targets[@]}"; do
        validation_bridge="$(awk -F "\t" -v n="${target_name}" '$1=="VSS_PORT_GROUP_BRIDGE" && $2==n {print $3; exit}' "${STATE_FILE}" 2>/dev/null || true)"
        [[ -n "${validation_bridge}" ]] || continue

        bridge_seen=0
        for bridge in "${validation_bridges[@]}"; do
            [[ "${bridge}" == "${validation_bridge}" ]] && { bridge_seen=1; break; }
        done
        ((bridge_seen == 0)) && validation_bridges+=("${validation_bridge}")
    done

    if ((${#validation_bridges[@]} == 0)); then
        log_error "無法確認 VSS Port Group Recovery 驗證所需的 Bridge。"
        pause_screen
        return 1
    fi

    for validation_bridge in "${validation_bridges[@]}"; do
        if ! validate_network_after_change "${validation_bridge}"; then
            log_error "VSS Port Group 刪除後驗證失敗，開始 Recovery：${validation_bridge}"
            if restore_change_backup "${change_id}"; then
                log_ok "VSS Port Group 刪除 Recovery 完成。"
            else
                log_error "VSS Port Group 刪除 Recovery 失敗。"
            fi
            pause_screen
            return 1
        fi
    done

    for target_name in "${targets[@]}"; do
        local target_vlan_dev
        target_vlan_dev="$(awk -F '\t' -v n="${target_name}" '$1=="VSS_PORT_GROUP_VLAN_DEV" && $2==n {print $3; exit}' "${STATE_FILE}" 2>/dev/null || true)"
        if [[ -z "${target_vlan_dev}" ]]; then
            local target_vlan target_bridge
            target_vlan="$(awk -F '\t' -v n="${target_name}" '$1=="VSS_PORT_GROUP" && $2==n {print $3; exit}' "${STATE_FILE}" 2>/dev/null || true)"
            target_bridge="$(awk -F '\t' -v n="${target_name}" '$1=="VSS_PORT_GROUP_BRIDGE" && $2==n {print $3; exit}' "${STATE_FILE}" 2>/dev/null || true)"
            target_vlan_dev="${target_bridge}.${target_vlan}"
        fi
        if ip link show "${target_name}" >/dev/null 2>&1 ||
           { [[ -n "${target_vlan_dev}" ]] && ip link show "${target_vlan_dev}" >/dev/null 2>&1; }; then
            log_error "VSS Port Group Delete 後 Runtime Object 仍存在：${target_name}"
            log_error "開始 Recovery。"
            if restore_change_backup "${change_id}"; then
                log_ok "VSS Port Group Delete Runtime Recovery 完成。"
            else
                log_error "VSS Port Group Delete Runtime Recovery 失敗。"
            fi
            pause_screen
            return 1
        fi
    done

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
            1) vss_port_group_create || true ;;
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
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN} 目前網路設定 / Network Topology${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo ""

    get_management_info
    echo -e "${CYAN}管理連線：${NC}"
    echo -e "  Device ：${GREEN}${DEV_WITH_GW:-未偵測}${NC}"
    echo -e "  IP     ：${GREEN}${CURRENT_IP:-未偵測}${NC}"
    echo -e "  Gateway：${GREEN}${CURRENT_GW:-未偵測}${NC}"

    echo ""
    echo -e "${CYAN}------------------------------------------------------------${NC}"
    echo -e "${CYAN} 實體 NIC${NC}"
    echo -e "${CYAN}------------------------------------------------------------${NC}"
    while read -r nic; do
        [[ -n "${nic}" ]] || continue
        local nic_state
        nic_state="$(get_link_state "${nic}")"
        if [[ "${nic_state}" == "up" ]]; then
            printf "  ${BLUE}%-12s${NC} %-12s ${GREEN}%s${NC}\n" "${nic}" "$(get_link_speed "${nic}")" "${nic_state}"
        else
            printf "  ${BLUE}%-12s${NC} %-12s ${YELLOW}%s${NC}\n" "${nic}" "$(get_link_speed "${nic}")" "${nic_state}"
        fi
    done < <(get_physical_nics)

    echo ""
    echo -e "${CYAN}------------------------------------------------------------${NC}"
    echo -e "${CYAN} Linux Bridge / vSwitch${NC}"
    echo -e "${CYAN}------------------------------------------------------------${NC}"
    ip -br link show type bridge 2>/dev/null | while IFS= read -r line; do
        case "${line}" in
            *UP*)   echo -e "${GREEN}${line}${NC}" ;;
            *DOWN*) echo -e "${YELLOW}${line}${NC}" ;;
            *)      echo -e "${BLUE}${line}${NC}" ;;
        esac
    done || true
    echo ""
    ip -br addr show 2>/dev/null | while IFS= read -r line; do
        case "${line}" in
            *UP*)   echo -e "${GREEN}${line}${NC}" ;;
            *DOWN*) echo -e "${YELLOW}${line}${NC}" ;;
            *)      echo -e "${BLUE}${line}${NC}" ;;
        esac
    done || true

    echo ""
    echo -e "${CYAN}------------------------------------------------------------${NC}"
    echo -e "${CYAN} Bond / NIC Teaming${NC}"
    echo -e "${CYAN}------------------------------------------------------------${NC}"
    if ls /proc/net/bonding/* >/dev/null 2>&1; then
        for file in /proc/net/bonding/*; do
            [[ -f "${file}" ]] || continue
            echo -e "${MAGENTA}[$(basename "${file}")]${NC}"
            grep -E 'Bonding Mode|MII Status|Currently Active Slave|Slave Interface' "${file}" | while IFS= read -r line; do echo -e "  ${BLUE}${line}${NC}"; done || true
            echo ""
        done
    else
        echo -e "${YELLOW}目前沒有 Bond。${NC}"
    fi

    echo -e "${CYAN}------------------------------------------------------------${NC}"
    echo -e "${CYAN} SDN / VDS${NC}"
    echo -e "${CYAN}------------------------------------------------------------${NC}"
    pvesh get /cluster/sdn/zones 2>/dev/null | while IFS= read -r line; do echo -e "${MAGENTA}${line}${NC}"; done || true
    echo ""
    pvesh get /cluster/sdn/vnets 2>/dev/null | while IFS= read -r line; do echo -e "${BLUE}${line}${NC}"; done || true

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

    if [[ ! -s "${VSS_DIR}/interfaces.before" ]]; then
        log_error "找不到有效的 VSS 變更前設定：${VSS_DIR}/interfaces.before"
        log_error "不會猜測或自動套用其他時間點的 Backup。"
        echo ""
        echo "請返回 Backup / Recovery，使用 Backup History 選擇已知 Change ID，"
        echo "或在確認內容後使用 Baseline Recovery。"
        pause_screen
        return 0
    fi

    echo "將還原：${VSS_DIR}/interfaces.before"
    [[ -f "${VSS_DIR}/objects.before" ]] && echo "State：${VSS_DIR}/objects.before"
    echo ""
    if ! confirm "確認還原 VSS？"; then
        pause_screen
        return 0
    fi

    if ! ensure_network_backup; then return 0; fi

    local change_id
    change_id="$(create_change_id "vss-recovery")"
    cp -a /etc/network/interfaces "${VSS_DIR}/interfaces.current-before-rollback"
    if ! apply_interfaces_file "${change_id}" "${VSS_DIR}/interfaces.before"; then
        log_error "VSS Recovery 套用失敗。"
        log_error "目前變更前版本仍保存於：${VSS_DIR}/interfaces.current-before-rollback"
        pause_screen
        return 1
    fi

    # 先依 Recovery 前的 State 清理本次 VSS 變更產生、而在還原檔中不存在的 Runtime Object。
    vss_reconcile_state_after_recovery "${VSS_DIR}/interfaces.before"

    if [[ -f "${VSS_DIR}/objects.before" ]]; then
        cp -a "${VSS_DIR}/objects.before" "${STATE_FILE}"
        log_ok "VSS State 已同步還原。"
    fi

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
        if ! vds_delete_vnet "${vnet}"; then
            log_error "VDS Rollback 中止：無法刪除 VNet ${vnet}"
            pause_screen
            return 1
        fi
    done

    if ! vds_delete_zone "${zone}"; then
        log_error "VDS Rollback 中止：無法刪除 Zone ${zone}"
        pause_screen
        return 1
    fi

    if ! vds_apply; then
        log_error "VDS Rollback 後 SDN Apply 失敗：${zone}"
        log_step "嘗試恢復 Rollback 前的 SDN Zone / VNet。"

        local zone_bridge
        zone_bridge="$(awk -F '\t' -v z="${zone}" '$1=="VDS_ZONE" && $2==z {print $3; exit}' "${STATE_FILE}" 2>/dev/null || true)"
        local recovery_ok=1

        if [[ -z "${zone_bridge}" ]]; then
            log_error "找不到 Zone 原始 Bridge，無法安全完成 VDS Rollback Recovery：${zone}"
            recovery_ok=0
        else
            if ! pvesh get "/cluster/sdn/zones/${zone}" >/dev/null 2>&1; then
                if ! vds_create_zone "${zone}" "${zone_bridge}"; then
                    log_error "VDS Rollback Recovery 無法重新建立 Zone：${zone}"
                    recovery_ok=0
                fi
            fi

            if ((recovery_ok == 1)); then
                for vnet in "${vnets[@]}"; do
                    local recovery_tag
                    recovery_tag="$(awk -F '\t' -v n="${vnet}" '$1=="PORT_GROUP" && $2==n {print $3; exit}' "${STATE_FILE}" 2>/dev/null || true)"
                    if [[ -z "${recovery_tag}" ]] || ! vds_restore_vnet "${zone}" "${vnet}" "${recovery_tag}"; then
                        recovery_ok=0
                        log_error "VDS Rollback Recovery 無法恢復 VNet：${vnet}"
                    fi
                done
            fi

            if ((recovery_ok == 1)) && ! vds_apply; then
                recovery_ok=0
            fi
        fi

        if ((recovery_ok == 1)); then
            log_ok "VDS Rollback Recovery 完成，State 保持不變：${zone}"
        else
            log_error "VDS Rollback Recovery 不完整：${zone}"
            log_error "實際 SDN Zone / VNet / Apply 狀態需要人工確認。"
        fi

        pause_screen
        return 1
    fi

    for vnet in "${vnets[@]}"; do
        remove_state_entry "PORT_GROUP" "${vnet}"
        remove_state_entry "PORT_GROUP_ZONE" "${vnet}"
    done
    remove_state_entry "VDS_ZONE" "${zone}"

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
    echo "本操作使用最初建立的 Baseline，不是 Backup History 中最近一筆備份。"
    echo ""
    echo "還原來源與目的："
    echo "  Network 設定：${BASELINE_DIR}/interfaces.orig"
    echo "              → /etc/network/interfaces"
    echo "  工具 State ：${BASELINE_DIR}/objects.conf.orig"
    echo "              → ${STATE_FILE}"
    if [[ -s "${BASELINE_DIR}/created-at" ]]; then
        echo "  建立時間    ：$(cat "${BASELINE_DIR}/created-at")"
    fi
    echo "  SDN         ：Baseline 未保存 SDN 設定；本操作不變更目前 SDN。"
    echo ""

    if ! baseline_exists; then
        log_error "尚未建立 Baseline。"
        pause_screen
        return 0
    fi

    if ! confirm "確認使用上述 Baseline 檔案覆蓋目前網路設定並還原工具 State？"; then
        pause_screen
        return 0
    fi

    # Baseline Recovery 是最後的網路救援程序。
    # 與一般 VSS / VDS 網路變更不同，不受 /etc/network/interfaces.new
    # 的 GUI Pending Configuration Guard 阻擋。
    if network_pending_configuration_exists; then
        echo ""
        echo "============================================================"
        echo " 偵測到 PVE GUI Pending Network Configuration"
        echo "============================================================"
        echo ""
        echo "目前存在："
        echo "  /etc/network/interfaces.new"
        echo ""
        echo "Baseline Recovery 屬於最後的網路救援程序。"
        echo "本次 Recovery 不會因 GUI Pending Configuration 而停止。"
        echo ""
        echo "Recovery 將直接還原："
        echo "  /etc/network/interfaces"
        echo ""
    fi

    local change_id
    change_id="$(create_change_id "baseline-recovery")"
    cp -a /etc/network/interfaces "${BASELINE_DIR}/interfaces.before-baseline-rollback.$(date '+%Y%m%d-%H%M%S-%N')"

    # Recovery 必須繞過一般 apply_interfaces_file() 的 Pending Guard，
    # 否則最後救援機制會在網路故障時被自己阻擋。
    if ! restore_change_backup "${change_id}" "${BASELINE_DIR}/interfaces.orig" "${BASELINE_DIR}/objects.conf.orig"; then
        log_error "Baseline Recovery 套用失敗。"
        log_error "目前網路設定未宣告為 Recovery 成功，請檢查 /etc/network/interfaces 與 Runtime 網路狀態。"
        pause_screen
        return 0
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
    while true; do
        show_header
        echo "============================================================"
        echo " Backup History"
        echo "============================================================"
        echo ""

        local -a backups=()
        local backup choice i
        if [[ -d "${BACKUP_DIR}" ]]; then
            while read -r backup; do
                [[ -n "${backup}" ]] || continue
                backups+=( "${backup}" )
            done < <(find "${BACKUP_DIR}" -mindepth 2 -maxdepth 2 -type f -name interfaces -printf '%T@ %h\n' 2>/dev/null | sort -nr | cut -d' ' -f2- | awk '!seen[$0]++')
        fi

        if ((${#backups[@]} == 0)); then
            echo "目前沒有 Backup。"
            pause_screen
            return 0
        fi

        i=1
        for backup in "${backups[@]}"; do
            local backup_id="${backup##*/}"
            case "${backup_id}" in
                CHG-vss-*) printf "  %2d) ${CYAN}%s${NC}  ${BLUE}[VSS 自動備份]${NC}\n" "${i}" "${backup_id}" ;;
                CHG-vds-*) printf "  %2d) ${CYAN}%s${NC}  ${MAGENTA}[VDS 自動備份]${NC}\n" "${i}" "${backup_id}" ;;
                CHG-*)     printf "  %2d) ${CYAN}%s${NC}  ${YELLOW}[網路變更自動備份]${NC}\n" "${i}" "${backup_id}" ;;
                MANUAL-*)  printf "  %2d) ${GREEN}%s${NC}  [手動備份]\n" "${i}" "${backup_id}" ;;
                *)         printf "  %2d) %s\n" "${i}" "${backup_id}" ;;
            esac
            i=$((i + 1))
        done
        echo "   A) 全部刪除 CHG-* 自動 Backup"
        echo "   0) 返回"
        echo ""
        echo "CHG-vss-* / CHG-vds-* 分別代表 VSS / VDS 自動備份；同一大方向僅保留最新一筆已驗證備份。"
        echo "MANUAL-* 為手動備份，不受自動清理影響；可在此逐筆選取 d 刪除。"
        echo "A 全部刪除只清除 CHG-* 自動備份；MANUAL-*、Baseline 與 Recovery 不會被批次刪除。"
        echo "選擇 Backup 後可執行 Recovery 或刪除該筆 Backup。"
        echo "全部刪除只處理符合安全條件的 CHG-* 自動 Backup；不會刪除 MANUAL-*、Baseline 或 Recovery。"

        read -r -p "請選擇 Backup 編號（A 全部刪除，0 返回）：" choice
        if [[ "${choice}" == "0" ]]; then
            return 0
        fi
        if [[ "${choice}" =~ ^[aA]$ ]]; then
            local -a auto_backups=()
            local invalid_backup="" invalid_reason="" candidate candidate_id
            for candidate in "${backups[@]}"; do
                candidate_id="${candidate##*/}"
                # 全部刪除僅涵蓋 CHG-* 自動備份；MANUAL-* 永遠不會進入批次刪除清單。
                [[ "${candidate_id}" == CHG-* ]] || continue
                auto_backups+=( "${candidate}" )

                # 分項回報拒絕原因；保留「先驗證全部、再開始刪除」的原子性安全流程。
                if [[ "${candidate}" != "${BACKUP_DIR}/${candidate_id}" ]]; then
                    invalid_backup="${candidate}"
                    invalid_reason="不是 BACKUP_DIR 下的直接子目錄路徑"
                elif [[ ! ( "${candidate_id}" =~ ^CHG-[a-z0-9_-]+-[0-9]{8}-[0-9]{6}-[0-9]+-[0-9]+$ || "${candidate_id}" =~ ^CHG-[0-9]{8}-[0-9]{6}-[0-9]+-[0-9]+$ ) ]]; then
                    invalid_backup="${candidate}"
                    invalid_reason="Backup ID 格式不符合新格式或舊版 CHG 格式"
                elif [[ ! -d "${candidate}" ]]; then
                    invalid_backup="${candidate}"
                    invalid_reason="Backup 目錄不存在或不是目錄"
                elif [[ -L "${candidate}" ]]; then
                    invalid_backup="${candidate}"
                    invalid_reason="Backup 路徑是符號連結，基於安全性拒絕批次刪除"
                fi

                if [[ -n "${invalid_backup}" ]]; then
                    break
                fi
            done
            if [[ -n "${invalid_backup}" ]]; then
                log_error "發現不符合安全條件的自動 Backup：${invalid_backup}"
                log_error "拒絕原因：${invalid_reason}"
                log_error "為避免部分刪除，已取消全部刪除；未刪除任何 Backup。"
                pause_screen
                continue
            fi
            if (("${#auto_backups[@]}" == 0)); then
                log_info "目前沒有可批次刪除的 CHG-* 自動 Backup；MANUAL-* 手動備份需逐筆刪除。"
                pause_screen
                continue
            fi
            echo ""
            echo "即將永久刪除全部 ${#auto_backups[@]} 個 CHG-* 自動 Backup："
            printf '  - %s\n' "${auto_backups[@]##*/}"
            echo "MANUAL-* 手動 Backup 不會被刪除；Baseline、Recovery 及其他目錄也不會被刪除。"
            if confirm "確定永久刪除全部 ${#auto_backups[@]} 個自動 Backup？"; then
                local delete_failed=0
                for candidate in "${auto_backups[@]}"; do
                    candidate_id="${candidate##*/}"
                    if [[ "${candidate}" == "${BACKUP_DIR}/${candidate_id}" &&
                          ( "${candidate_id}" =~ ^CHG-[a-z0-9_-]+-[0-9]{8}-[0-9]{6}-[0-9]+-[0-9]+$ || "${candidate_id}" =~ ^CHG-[0-9]{8}-[0-9]{6}-[0-9]+-[0-9]+$ ) &&
                          -d "${candidate}" && ! -L "${candidate}" ]]; then
                        if rm -rf -- "${candidate}" && [[ ! -e "${candidate}" && ! -L "${candidate}" ]]; then
                            log_ok "已刪除自動 Backup：${candidate_id}"
                        else
                            log_error "刪除失敗：${candidate_id}"
                            delete_failed=1
                        fi
                    else
                        log_error "刪除前安全檢查未通過：${candidate_id}"
                        delete_failed=1
                    fi
                done
                if ((delete_failed == 0)); then
                    log_ok "全部 ${#auto_backups[@]} 個自動 Backup 已刪除；MANUAL-* 手動備份已保留。"
                else
                    log_error "自動 Backup 批次刪除未完整完成，請檢查上方結果；不會自動重試。"
                fi
            else
                log_info "已取消全部刪除。"
            fi
            pause_screen
            continue
        fi
        if ! [[ "${choice}" =~ ^[0-9]+$ ]] || ((choice < 1 || choice > ${#backups[@]})); then
            log_error "選擇無效。"
            sleep 1
            continue
        fi

        backup="${backups[$((choice - 1))]}"
        local change_id="${backup##*/}"
        local action
        echo ""
        echo "  r) 還原此 Backup"
        echo "  d) 刪除此 Backup"
        echo "  0) 返回 Backup History"
        read -r -p "請選擇操作：" action
        case "${action}" in
            0) continue ;;
            d|D)
                # 僅允許刪除 BACKUP_DIR 下符合工具 Backup ID 格式的單一直接子目錄。
                local single_delete_reason=""
                if [[ "${backup}" != "${BACKUP_DIR}/${change_id}" ]]; then
                    single_delete_reason="不是 BACKUP_DIR 下的直接子目錄路徑"
                elif [[ ! ( "${change_id}" =~ ^CHG-[a-z0-9_-]+-[0-9]{8}-[0-9]{6}-[0-9]+-[0-9]+$ || "${change_id}" =~ ^CHG-[0-9]{8}-[0-9]{6}-[0-9]+-[0-9]+$ || "${change_id}" =~ ^MANUAL-[0-9]{8}-[0-9]{6}-[0-9]+-[0-9]+$ ) ]]; then
                    single_delete_reason="Backup ID 格式不符合允許格式"
                elif [[ ! -d "${backup}" ]]; then
                    single_delete_reason="Backup 目錄不存在或不是目錄"
                elif [[ -L "${backup}" ]]; then
                    single_delete_reason="Backup 路徑是符號連結，基於安全性拒絕刪除"
                fi
                if [[ -n "${single_delete_reason}" ]]; then
                    log_error "Backup 刪除安全檢查未通過：${change_id}"
                    log_error "拒絕原因：${single_delete_reason}"
                    pause_screen
                    continue
                fi
                echo ""
                echo "即將刪除單一 Backup：${backup}"
                echo "不會刪除 Baseline、Recovery 或其他 Backup。"
                if confirm "確定永久刪除此 Backup？"; then
                    if [[ "${backup}" == "${BACKUP_DIR}/${change_id}" && -d "${backup}" && ! -L "${backup}" ]]; then
                        rm -rf -- "${backup}"
                        if [[ ! -e "${backup}" ]]; then
                            log_ok "Backup 已刪除：${change_id}"
                        else
                            log_error "Backup 刪除未完成：${change_id}"
                        fi
                    else
                        log_error "刪除前路徑安全檢查未通過，拒絕刪除。"
                    fi
                else
                    log_info "已取消刪除。"
                fi
                pause_screen
                continue
                ;;
            r|R) ;;
            *) log_error "操作無效。"; sleep 1; continue ;;
        esac

        echo ""
        echo "------------------------------------------------------------"
        echo " Backup Recovery 確認"
        echo "------------------------------------------------------------"
        echo " Backup ID：${change_id}"
        if [[ "${change_id}" == MANUAL-* ]]; then
            echo " 備份類型：手動 Backup"
        else
            echo " 備份類型：變更前自動 Backup"
        fi
        echo " 還原來源：${backup}/interfaces"
        echo " 還原目的：/etc/network/interfaces"
        if [[ -f "${backup}/state" ]]; then
            echo " State    ：${backup}/state → ${STATE_FILE}"
        else
            echo " State    ：此 Backup 沒有 State；還原後保留目前 ${STATE_FILE}"
        fi
        if [[ -e "${backup}/sdn-config-present" && -s "${backup}/sdn.cfg" ]]; then
            echo " SDN 快照 ：有，${backup}/sdn.cfg（$(stat -c '%s' "${backup}/sdn.cfg") bytes）"
            echo " SDN 目的 ：本次 Recovery 不套用 SDN 快照；目前 /etc/pve/sdn.cfg 保持不變"
        elif [[ -e "${backup}/sdn-config-absent" ]]; then
            echo " SDN 快照 ：建立此 Backup 時沒有 /etc/pve/sdn.cfg"
            echo " SDN 目的 ：目前 SDN 保持不變"
        elif [[ ! -f "${backup}/SHA256SUMS" ]]; then
            echo " SDN 快照 ：舊版 Backup 未記錄，無法判定"
            echo " SDN 目的 ：目前 SDN 保持不變"
        else
            echo " SDN 快照 ：標記缺失或不完整，Backup 驗證將拒絕還原"
        fi
        if ! validate_change_backup "${backup}"; then
            log_error "此 Backup 完整性驗證失敗，拒絕還原。"
            pause_screen
            continue
        fi
        echo "------------------------------------------------------------"
        echo ""
        echo "這是高風險操作，會覆蓋目前 /etc/network/interfaces。"
        if ! confirm "確認使用此 Backup 還原？"; then
            continue
        fi

        local current_backup
        current_backup="$(create_change_id "recovery-safety")"
        if ! create_change_backup "${current_backup}"; then
            log_error "無法保存目前網路設定，停止 Backup Recovery。"
            pause_screen
            return 1
        fi
        log_info "目前設定已先保存：${BACKUP_DIR}/${current_backup}"

        if restore_change_backup "${change_id}"; then
            log_ok "Backup Recovery 完成：${change_id}"
        else
            log_error "Backup Recovery 失敗：${change_id}"
        fi
        pause_screen
        return 0
    done
}

backup_now()
{
    show_header
    echo "============================================================"
    echo " Backup Now - 備份目前網路狀態"
    echo "============================================================"
    echo ""
    echo "將保存目前的網路設定、工具 State、Runtime IP / Route / Link 與 Cluster 狀態。"
    echo "本操作不會套用或變更網路設定，也不會覆寫 Baseline 或既有 Backup。"
    echo ""

    if [[ ! -s /etc/network/interfaces ]]; then
        log_error "目前 /etc/network/interfaces 不存在或為空，取消 Backup。"
        pause_screen
        return 1
    fi

    if ! confirm "確認備份目前網路設定與 Runtime 快照？"; then
        log_info "已取消 Backup；未建立新備份。"
        return 0
    fi

    local change_id target
    change_id="$(create_manual_backup_id)"
    target="${BACKUP_DIR}/${change_id}"

    if ! create_change_backup "${change_id}"; then
        log_error "手動 Backup 失敗。"
        pause_screen
        return 1
    fi

    echo ""
    echo "------------------------------------------------------------"
    echo " Backup 驗證"
    echo "------------------------------------------------------------"
    echo " Backup ID：${change_id}"
    echo " 備份類型 ：手動 Backup"
    echo " 路徑     ：${target}"
    echo ""
    local file
    for file in interfaces state ip-address ip-route ip-link cluster-status created-at; do
        if [[ -f "${target}/${file}" ]]; then
            printf "  %-16s %s bytes\n" "${file}" "$(stat -c '%s' "${target}/${file}")"
        else
            printf "  %-16s %s\n" "${file}" "未產生（State 可能尚不存在）"
        fi
    done
    echo ""
    if [[ -s "${target}/interfaces" ]] &&
       [[ -f "${target}/ip-address" ]] &&
       [[ -f "${target}/ip-route" ]] &&
       [[ -f "${target}/ip-link" ]] &&
       [[ -f "${target}/created-at" ]]; then
        sha256sum "${target}/interfaces" "${target}/ip-address" "${target}/ip-route" "${target}/ip-link"
        log_ok "手動 Backup 完成，必要檔案驗證通過。"
    else
        log_error "Backup 已建立，但必要檔案驗證未通過，請檢查目錄：${target}"
        pause_screen
        return 1
    fi

    pause_screen
    return 0
}

rollback_menu()
{
    while true; do
        show_header
        echo "============================================================"
        echo " Backup / Recovery"
        echo "============================================================"
        echo ""
        echo "  1) Backup 建立手動備份"
        echo "  2) Recovery 從既有備份還原網路設定"
        echo "  3) VDS 刪除本工具建立的 SDN Zone / VNet"
        echo "  4) Baseline 還原最初設定"
        echo "  0) 返回"
        echo ""

        local choice
        read -r -p "請選擇（1 建立手動備份，2 從既有 Backup 還原）：" choice
        case "${choice}" in
            1) backup_now ;;
            2) backup_history ;;
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
        echo "  1) VSS — Standard Virtual Switch"
        echo "  2) VDS — Distributed Virtual Switch"
        echo "  3) 備份與還原管理（含歷史備份還原）"
        echo "  0) 離開"
        echo ""
        echo "------------------------------------------------------------"
        echo ""

        local choice
        read -r -p "請選擇：" choice
        case "${choice}" in
            1) vss_setup ;;
            2) vds_setup ;;
            3) rollback_menu ;;
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