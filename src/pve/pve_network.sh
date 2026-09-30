#!/usr/bin/env bash
set -Eeuo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_NAME="pve_network.sh"
BASE_DIR="/etc/pve-poc"
BASELINE_DIR="${BASE_DIR}/baseline"
VSS_DIR="${BASE_DIR}/vss"
VDS_DIR="${BASE_DIR}/vds"
STATE_DIR="${BASE_DIR}/state"
STATE_FILE="${STATE_DIR}/objects.conf"

log_info()  { echo -e "${CYAN}[ \$(date '+%H:%M:%S') ] INFO${NC}  \$*"; }
log_ok()    { echo -e "${GREEN}[ \$(date '+%H:%M:%S') ] OK${NC}    \$*"; }
log_step()  { echo -e "${YELLOW}[ \$(date '+%H:%M:%S') ] STEP${NC}  \$*"; }
log_error() { echo -e "${RED}[ \$(date '+%H:%M:%S') ] ERROR${NC} \$*" >&2; }
die()       { log_error "\$*"; exit 1; }
need()      { command -v "\$1" >/dev/null 2>&1 || die "找不到必要程式：\$1"; }

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
    echo -e "  PVE NETWORK PRO"
    echo -e "  Proxmox VE 網路架構設定"
    echo -e "  VMware 網路架構模式"
    echo -e "  作者: sungshu"
    echo -e "  GitHub: https://github.com/sungshu"
    echo -e "  專案: https://github.com/sungshu/Pve-Toolkits"
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
    local prompt="\$1"
    local answer
    read -r -p "${prompt} [y/N]: " answer
    [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]]
}

require_root()
{
    [[ "\$(id -u)" -eq 0 ]] || die "請使用 root 執行此工具。"
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

    [[ -d /etc/pve ]] || die "/etc/pve 不存在，這不是有效的 PVE 環境。"
    [[ -f /etc/network/interfaces ]] || die "/etc/network/interfaces 不存在。"
}

get_pve_version()
{
    if command -v pveversion >/dev/null 2>&1; then
        pveversion | awk -F'/' 'NR==1 {print \$2}'
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
    status="\$(pvecm status 2>/dev/null || true)"
    grep -qE 'Quorate:\s+Yes|Quorate:\s+1' <<<"${status}"
}

cluster_status_text()
{
    if ! cluster_joined; then
        echo "未加入"
    elif cluster_quorate; then
        echo "已加入 / Quorum 正常"
    else
        echo "已加入 / Quorum 異常"
    fi
}

get_management_info()
{
    CURRENT_GW="\$(ip route show default 2>/dev/null | awk 'NR==1 {print \$3}')"
    DEV_WITH_GW="\$(ip route show default 2>/dev/null | awk 'NR==1 {print \$5}')"
    CURRENT_IP=""

    if [[ -n "${DEV_WITH_GW}" ]]; then
        CURRENT_IP="\$(ip -4 -o addr show dev "${DEV_WITH_GW}" scope global 2>/dev/null | awk 'NR==1 {print \$4}')"
    fi
}

is_physical_nic()
{
    local nic="\$1"
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
    local nic="\$1"
    cat "/sys/class/net/${nic}/operstate" 2>/dev/null || echo "unknown"
}

get_link_speed()
{
    local nic="\$1"
    local speed
    speed="\$(cat "/sys/class/net/${nic}/speed" 2>/dev/null || true)"
    if [[ -z "${speed}" || "${speed}" == "-1" ]]; then
        echo "Unknown"
    else
        echo "${speed}Mb/s"
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
        state="\$(get_link_state "${nic}")"
        speed="\$(get_link_speed "${nic}")"
        printf "  %2d) %-12s %-12s %s\n" "${index}" "${nic}" "${speed}" "${state}"
        index=\$((index + 1))
    done < <(get_physical_nics)

    [[ ${index} -gt 1 ]] || die "找不到可用的實體 NIC。"
    echo ""
}

select_nic()
{
    local prompt="\$1"
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
        printf "  %2d) %-12s %-12s %s\n" "\$i" "\$nic" "\$(get_link_speed "\$nic")" "\$(get_link_state "\$nic")"
        i=\$((i + 1))
    done

    while true; do
        read -r -p "${prompt}：" choice
        if [[ "${choice}" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#nics[@]})); then
            SELECTED_NIC="${nics[\$((choice - 1))]}"
            return 0
        fi
        log_error "選擇無效，請輸入上方數字。"
    done
}

select_bridge()
{
    local -a bridges=()
    local path bridge choice

    while read -r bridge; do
        [[ -n "${bridge}" ]] || continue
        bridges+=("${bridge}")
    done < <(find /sys/class/net -maxdepth 1 -type l -printf '%f\n' 2>/dev/null | awk '/^vmbr[0-9]+$/ {print}' | sort -V)

    echo "============================================================"
    echo " 虛擬交換器（vSwitch / Linux Bridge）"
    echo "============================================================"
    echo ""

    if ((${#bridges[@]} > 0)); then
        local i=1
        for bridge in "${bridges[@]}"; do
            printf "  %2d) 使用現有 %-12s\n" "\$i" "\$bridge"
            i=\$((i + 1))
        done
    fi

    local new_index=\$(( ${#bridges[@]} + 1 ))
    printf "  %2d) 建立新的 vmbr\n" "${new_index}"
    echo "  0) 返回"

    while true; do
        read -r -p "請選擇：" choice
        if [[ "${choice}" == "0" ]]; then
            return 1
        fi
        if [[ "${choice}" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#bridges[@]})); then
            SELECTED_BRIDGE="${bridges[\$((choice - 1))]}"
            return 0
        fi
        if [[ "${choice}" =~ ^[0-9]+$ ]] && ((choice == new_index)); then
            while true; do
                read -r -p "新的 Bridge 名稱（例如 vmbr1）：" SELECTED_BRIDGE
                if [[ "${SELECTED_BRIDGE}" =~ ^vmbr[0-9]+$ ]] && [[ ! -e "/sys/class/net/${SELECTED_BRIDGE}" ]]; then
                    return 0
                fi
                log_error "Bridge 名稱必須為未使用的 vmbrX。"
            done
        fi
        log_error "選擇無效。"
    done
}

select_bond_mode()
{
    local choice
    echo "============================================================"
    echo " 網卡綁定（NIC Teaming / Bond）"
    echo "============================================================"
    echo ""
    echo "  1) Active / Standby"
    echo "     PVE：bond-mode active-backup"
    echo "  2) LACP"
    echo "     PVE：bond-mode 802.3ad"
    echo "  3) Load Balance"
    echo "     PVE：bond-mode balance-xor"
    echo "  0) 不使用 Bond"
    echo ""

    while true; do
        read -r -p "請選擇：" choice
        case "${choice}" in
            1) BOND_MODE="active-backup"; return 0 ;;
            2) BOND_MODE="802.3ad"; return 0 ;;
            3) BOND_MODE="balance-xor"; return 0 ;;
            0) BOND_MODE=""; return 0 ;;
            *) log_error "選擇無效，請輸入 0～3。" ;;
        esac
    done
}

select_second_nic()
{
    local first="\$1"
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
        printf "  %2d) %-12s %-12s %s\n" "\$i" "\$nic" "\$(get_link_speed "\$nic")" "\$(get_link_state "\$nic")"
        i=\$((i + 1))
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
            SECONDARY_NIC="${nics[\$((choice - 1))]}"
            return 0
        fi
        log_error "選擇無效。"
    done
}

ensure_dirs()
{
    mkdir -p "${BASELINE_DIR}" "${VSS_DIR}" "${VDS_DIR}" "${STATE_DIR}"
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

create_baseline()
{
    ensure_dirs

    if baseline_exists; then
        log_info "Baseline 已存在，不會自動覆蓋。"
        echo "保存位置：${BASELINE_DIR}"
        return 0
    fi

    log_step "建立 POC Baseline"
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
    echo " POC Baseline"
    echo "============================================================"
    echo ""
    if baseline_exists; then
        echo "狀態：已建立"
        echo "位置：${BASELINE_DIR}"
        [[ -f "${BASELINE_DIR}/created-at" ]] && echo "建立時間：\$(cat "${BASELINE_DIR}/created-at")"
        echo ""
        echo "保存檔案："
        find "${BASELINE_DIR}" -maxdepth 1 -type f -printf '  - %f\n' | sort
    else
        echo "狀態：尚未建立"
    fi
}

save_interfaces_copy()
{
    local target="\$1"
    cp -a /etc/network/interfaces "${target}"
}

write_vss_interfaces()
{
    local bridge="\$1"
    local nic1="\$2"
    local nic2="\$3"
    local bond_mode="\$4"
    local bond_name="bond0"
    local temp

    get_management_info

    temp="\$(mktemp /etc/network/interfaces.pve-network.XXXXXX)"

    {
        echo "auto lo"
        echo "iface lo inet loopback"
        echo ""
        echo "iface ${nic1} inet manual"
        if [[ -n "${nic2}" ]]; then
            echo ""
            echo "iface ${nic2} inet manual"
        fi
        echo ""

        if [[ -n "${bond_mode}" ]]; then
            echo "auto ${bond_name}"
            echo "iface ${bond_name} inet manual"
            echo "    bond-slaves ${nic1}${nic2:+ ${nic2}}"
            echo "    bond-miimon 100"
            echo "    bond-mode ${bond_mode}"
            if [[ "${bond_mode}" == "active-backup" ]]; then
                echo "    bond-primary ${nic1}"
            fi
            echo ""
            local bridge_port="${bond_name}"
        else
            local bridge_port="${nic1}"
        fi

        echo "auto ${bridge}"
        if [[ -n "${CURRENT_IP}" ]]; then
            echo "iface ${bridge} inet static"
            echo "    address ${CURRENT_IP}"
            [[ -n "${CURRENT_GW}" ]] && echo "    gateway ${CURRENT_GW}"
        else
            echo "iface ${bridge} inet manual"
        fi
        echo "    bridge-ports ${bridge_port}"
        echo "    bridge-stp off"
        echo "    bridge-fd 0"
        echo "    bridge-vlan-aware yes"
        echo "    bridge-vids 2-4094"
    } > "${temp}"

    install -m 0644 "${temp}" /etc/network/interfaces
    rm -f "${temp}"
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
    local type="\$1"
    local key="\$2"
    local value="\$3"
    ensure_dirs
    printf '%s\t%s\t%s\n' "${type}" "${key}" "${value}" >> "${STATE_FILE}"
}

state_has()
{
    local type="\$1" key="\$2"
    [[ -f "${STATE_FILE}" ]] || return 1
    awk -F '\t' -v t="${type}" -v k="${key}" '\$1==t && \$2==k {found=1} END{exit !found}' "${STATE_FILE}"
}

remove_state_entry()
{
    local type="\$1" key="\$2"
    [[ -f "${STATE_FILE}" ]] || return 0
    awk -F '\t' -v t="${type}" -v k="${key}" '!( \$1==t && \$2==k )' "${STATE_FILE}" > "${STATE_FILE}.tmp"
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
    local file="\$1"
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
    local bridge="\$1"
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

    before_cluster="\$(cluster_status_text)"
    if ! cluster_quorate; then
        log_error "變更後 Cluster Quorum 不正常：${before_cluster}"
        return 1
    fi
    after_cluster="\$(cluster_status_text)"

    log_ok "Bridge ${bridge} 驗證完成。"
    log_ok "Cluster：${after_cluster}"
    return 0
}

apply_interfaces()
{
    log_step "套用 /etc/network/interfaces"
    if ! validate_interfaces_syntax; then
        log_error "網路設定語法檢查失敗。"
        return 1
    fi
    ifreload -a
}

vss_setup()
{
    show_header
    echo "============================================================"
    echo " VSS 設定"
    echo " Standard Virtual Switch"
    echo "============================================================"
    echo ""

    if ! baseline_exists; then
        echo "尚未建立 Baseline。"
        echo ""
        if confirm "現在建立 Baseline？"; then
            create_baseline
        else
            log_error "VSS 設定前必須先建立 Baseline。"
            pause_screen
            return 0
        fi
    fi

    cluster_guard || { pause_screen; return 0; }

    if ! confirm "確認開始 VSS 網路設定？"; then
        log_info "已取消。"
        pause_screen
        return 0
    fi

    echo ""
    if ! select_bridge; then
        pause_screen
        return 0
    fi

    show_nics
    select_nic "請選擇第一張 Uplink NIC"
    FIRST_NIC="${SELECTED_NIC}"

    select_bond_mode

    SECONDARY_NIC=""
    if [[ -n "${BOND_MODE}" ]]; then
        select_second_nic "${FIRST_NIC}"
        if [[ -z "${SECONDARY_NIC}" ]]; then
            log_error "選擇 Bond 模式時必須使用兩張實體 NIC。"
            pause_screen
            return 0
        fi
    else
        echo ""
        echo "不使用 Bond，可只使用第一張 NIC。"
    fi

    echo ""
    echo "------------------------------------------------------------"
    echo " VSS 設定確認"
    echo "------------------------------------------------------------"
    echo " Virtual Switch：${SELECTED_BRIDGE}"
    echo " 第一張 NIC     ：${FIRST_NIC}"
    echo " 第二張 NIC     ：${SECONDARY_NIC:-未使用}"
    echo " Bond 模式      ：${BOND_MODE:-不使用 Bond}"
    echo " 管理 IP        ：${CURRENT_IP:-未偵測}"
    echo " Gateway        ：${CURRENT_GW:-未偵測}"
    echo "------------------------------------------------------------"
    echo ""

    if ! confirm "確認套用以上 VSS 設定？"; then
        log_info "已取消。"
        pause_screen
        return 0
    fi

    ensure_dirs
    save_interfaces_copy "${VSS_DIR}/interfaces.before"
    network_snapshot "${VSS_DIR}/network.before"

    if ! write_vss_interfaces "${SELECTED_BRIDGE}" "${FIRST_NIC}" "${SECONDARY_NIC}" "${BOND_MODE}"; then
        log_error "VSS 設定檔建立失敗。"
        cp -a "${VSS_DIR}/interfaces.before" /etc/network/interfaces
        pause_screen
        return 1
    fi

    if ! apply_interfaces; then
        log_error "VSS 套用失敗，立即嘗試還原變更前設定。"
        cp -a "${VSS_DIR}/interfaces.before" /etc/network/interfaces
        ifreload -a || true
        pause_screen
        return 1
    fi

    if ! validate_network_after_change "${SELECTED_BRIDGE}"; then
        log_error "VSS 驗證失敗，停止後續操作。"
        echo ""
        echo "變更前設定保存於：${VSS_DIR}/interfaces.before"
        pause_screen
        return 1
    fi

    cp -a /etc/network/interfaces "${VSS_DIR}/interfaces.vss"
    save_state "VSS" "bridge" "${SELECTED_BRIDGE}"
    save_state "VSS" "nic1" "${FIRST_NIC}"
    [[ -n "${SECONDARY_NIC}" ]] && save_state "VSS" "nic2" "${SECONDARY_NIC}"
    save_state "VSS" "bond_mode" "${BOND_MODE:-none}"

    log_ok "VSS 設定生效完成。"
    echo "保存位置：${VSS_DIR}/interfaces.vss"
    pause_screen
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
    echo "============================================================"
    echo ""
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
                    printf "  %2d) %s\n" "\$i" "\$zone"
                    i=\$((i + 1))
                done

                while true; do
                    read -r -p "請選擇：" choice
                    if [[ "${choice}" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#zones[@]})); then
                        SDN_ZONE="${zones[\$((choice - 1))]}"
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
    done < <(find /sys/class/net -maxdepth 1 -type l -printf '%f\n' 2>/dev/null | awk '/^vmbr[0-9]+$/ {print}' | sort -V)

    ((${#bridges[@]} > 0)) || die "找不到 vmbr Bridge。請先建立 VSS / Bridge。"

    echo ""
    echo "承載 VDS / SDN 的底層 Bridge："
    local i=1
    for bridge in "${bridges[@]}"; do
        printf "  %2d) %s\n" "\$i" "\$bridge"
        i=\$((i + 1))
    done

    while true; do
        read -r -p "請選擇：" choice
        if [[ "${choice}" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#bridges[@]})); then
            SDN_BRIDGE="${bridges[\$((choice - 1))]}"
            return 0
        fi
        log_error "選擇無效。"
    done
}

vds_create_zone()
{
    local zone="\$1" bridge="\$2"
    log_step "建立 SDN Zone：${zone}"
    pvesh create /cluster/sdn/zones --zone "${zone}" --type vlan --bridge "${bridge}"
}

vds_create_vnet()
{
    local zone="\$1" vnet="\$2" tag="\$3"
    log_step "建立 VNet / Port Group：${vnet} / VLAN ${tag}"
    pvesh create /cluster/sdn/vnets --vnet "${vnet}" --zone "${zone}" --tag "${tag}"
}

valid_vlan_id()
{
    local vlan="\$1"
    [[ "${vlan}" =~ ^[0-9]+$ ]] && ((vlan >= 1 && vlan <= 4094))
}

port_group_exists_sdn()
{
    local vnet="\$1"
    pvesh get "/cluster/sdn/vnets/${vnet}" >/dev/null 2>&1
}

vds_setup()
{
    show_header
    echo "============================================================"
    echo " VDS 設定"
    echo " Distributed Virtual Switch / SDN"
    echo "============================================================"
    echo ""

    cluster_guard || { pause_screen; return 0; }

    if ! baseline_exists; then
        echo "尚未建立 Baseline。"
        if confirm "現在建立 Baseline？"; then
            create_baseline
        else
            log_error "VDS 設定前必須先建立 Baseline。"
            pause_screen
            return 0
        fi
    fi

    select_sdn_zone || { pause_screen; return 0; }
    select_sdn_bridge

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

port_group_list()
{
    echo "============================================================"
    echo " Port Group / VNet"
    echo "============================================================"
    echo ""
    echo "名稱與 VLAN ID 分開管理。"
    echo "例如：vLan050 不代表 VLAN 50。"
    echo ""

    pvesh get /cluster/sdn/vnets 2>/dev/null || true
    echo ""
    echo "目前記錄的本工具物件："
    if [[ -f "${STATE_FILE}" ]]; then
        awk -F '\t' '\$1=="PORT_GROUP" {printf "  - %-20s VLAN ID=%s\n", \$2, \$3}' "${STATE_FILE}"
    fi
}

port_group_create()
{
    show_header
    echo "============================================================"
    echo " Port Group 建立"
    echo "============================================================"
    echo ""

    cluster_guard || { pause_screen; return 0; }

    local zone
    if ! select_sdn_zone; then
        pause_screen
        return 0
    fi
    zone="${SDN_ZONE}"

    local vnet vlan
    while true; do
        read -r -p "Port Group 名稱：" vnet
        [[ "${vnet}" =~ ^[A-Za-z0-9_-]+$ ]] || { log_error "名稱只能使用英數、底線、連字號。"; continue; }
        if port_group_exists_sdn "${vnet}"; then
            log_error "Port Group / VNet ${vnet} 已存在。"
            continue
        fi
        break
    done

    while true; do
        read -r -p "VLAN ID：" vlan
        valid_vlan_id "${vlan}" && break
        log_error "VLAN ID 必須為 1～4094。"
    done

    echo ""
    echo "------------------------------------------------------------"
    echo " Port Group 確認"
    echo "------------------------------------------------------------"
    echo " 名稱   ：${vnet}"
    echo " VLAN ID：${vlan}"
    echo " Zone   ：${zone}"
    echo "------------------------------------------------------------"
    echo ""

    if ! confirm "確認建立？"; then
        pause_screen
        return 0
    fi

    vds_create_vnet "${zone}" "${vnet}" "${vlan}"
    save_state "PORT_GROUP" "${vnet}" "${vlan}"
    save_state "PORT_GROUP_ZONE" "${vnet}" "${zone}"

    if confirm "現在 Apply SDN？"; then
        pvesh set /cluster/sdn
        log_ok "SDN Apply 完成。"
    fi

    log_ok "Port Group 建立完成：${vnet} / VLAN ${vlan}"
    pause_screen
}

port_group_delete()
{
    show_header
    echo "============================================================"
    echo " Port Group 刪除"
    echo "============================================================"
    echo ""
    echo "只允許刪除本工具記錄建立的 Port Group。"
    echo "不會盲刪整個 SDN。"
    echo ""

    local -a vnets=()
    local vnet choice
    while read -r vnet; do
        [[ -n "${vnet}" ]] && vnets+=("${vnet}")
    done < <(awk -F '\t' '\$1=="PORT_GROUP" {print \$2}' "${STATE_FILE}" 2>/dev/null || true)

    if ((${#vnets[@]} == 0)); then
        echo "沒有本工具建立的 Port Group。"
        pause_screen
        return 0
    fi

    local i=1
    for vnet in "${vnets[@]}"; do
        printf "  %2d) %s\n" "\$i" "\$vnet"
        i=\$((i + 1))
    done
    echo "  0) 返回"

    while true; do
        read -r -p "請選擇：" choice
        [[ "${choice}" == "0" ]] && { pause_screen; return 0; }
        if [[ "${choice}" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#vnets[@]})); then
            vnet="${vnets[\$((choice - 1))]}"
            break
        fi
        log_error "選擇無效。"
    done

    if ! confirm "確認刪除 ${vnet}？"; then
        pause_screen
        return 0
    fi

    pvesh delete "/cluster/sdn/vnets/${vnet}"
    pvesh set /cluster/sdn
    remove_state_entry "PORT_GROUP" "${vnet}"
    remove_state_entry "PORT_GROUP_ZONE" "${vnet}"
    log_ok "Port Group ${vnet} 已刪除。"
    pause_screen
}

port_group_menu()
{
    while true; do
        show_header
        echo "============================================================"
        echo " Port Group 管理"
        echo "============================================================"
        echo ""
        echo "  1) 查看 Port Group / VNet"
        echo "  2) 建立 Port Group"
        echo "  3) 刪除本工具建立的 Port Group"
        echo "  0) 返回"
        echo ""

        local choice
        read -r -p "請選擇：" choice
        case "${choice}" in
            1) show_header; port_group_list; pause_screen ;;
            2) port_group_create ;;
            3) port_group_delete ;;
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
    echo "PVE 節點：\$(get_node_name)"
    echo "PVE 版本：\$(get_pve_version)"
    echo "Cluster  ：\$(cluster_status_text)"
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
    while read -r nic; do
        [[ -n "${nic}" ]] || continue
        printf "  %-12s %-12s %s\n" "${nic}" "\$(get_link_speed "${nic}")" "\$(get_link_state "${nic}")"
    done < <(get_physical_nics)

    echo ""
    echo "------------------------------------------------------------"
    echo " Linux Bridge / vSwitch"
    echo "------------------------------------------------------------"
    ip -br link show type bridge 2>/dev/null || true
    echo ""
    ip -br addr show | awk '\$1 ~ /^vmbr[0-9]+$/ {print}' || true

    echo ""
    echo "------------------------------------------------------------"
    echo " Bond"
    echo "------------------------------------------------------------"
    if ls /proc/net/bonding/* >/dev/null 2>&1; then
        for file in /proc/net/bonding/*; do
            [[ -f "${file}" ]] || continue
            echo "[\$(basename "${file}")]"
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

rollback_vss()
{
    show_header
    echo "============================================================"
    echo " Rollback / 還原 - VSS"
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

    cluster_guard || { pause_screen; return 0; }

    cp -a /etc/network/interfaces "${VSS_DIR}/interfaces.current-before-rollback"
    cp -a "${VSS_DIR}/interfaces.before" /etc/network/interfaces

    if ! ifreload -a; then
        log_error "Rollback 套用失敗。"
        log_error "目前變更前版本仍保存於：${VSS_DIR}/interfaces.current-before-rollback"
        pause_screen
        return 1
    fi

    if cluster_quorate; then
        log_ok "VSS Rollback 完成，Cluster Quorum 正常。"
    else
        log_error "Rollback 後 Cluster Quorum 異常，請立即檢查。"
    fi
    pause_screen
}

rollback_vds()
{
    show_header
    echo "============================================================"
    echo " Rollback / 還原 - VDS"
    echo "============================================================"
    echo ""
    echo "只處理本工具記錄建立的 SDN Zone / VNet。"
    echo "不會清除所有 SDN 設定。"
    echo ""

    local -a zones=()
    local zone
    while read -r zone; do
        [[ -n "${zone}" ]] && zones+=("${zone}")
    done < <(awk -F '\t' '\$1=="VDS_ZONE" {print \$2}' "${STATE_FILE}" 2>/dev/null || true)

    if ((${#zones[@]} == 0)); then
        echo "沒有本工具建立的 SDN Zone。"
        pause_screen
        return 0
    fi

    local i=1 choice
    for zone in "${zones[@]}"; do
        printf "  %2d) %s\n" "\$i" "\$zone"
        i=\$((i + 1))
    done
    echo "  0) 返回"

    while true; do
        read -r -p "選擇要 Rollback 的 Zone：" choice
        [[ "${choice}" == "0" ]] && { pause_screen; return 0; }
        if [[ "${choice}" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#zones[@]})); then
            zone="${zones[\$((choice - 1))]}"
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
    done < <(awk -F '\t' -v z="${zone}" '\$1=="PORT_GROUP_ZONE" && \$3==z {print \$2}' "${STATE_FILE}" 2>/dev/null || true)

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
    echo " Rollback / 還原 - Baseline"
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

    cluster_guard || { pause_screen; return 0; }

    cp -a /etc/network/interfaces "${BASELINE_DIR}/interfaces.before-baseline-rollback.\$(date +%Y%m%d%H%M%S)"
    cp -a "${BASELINE_DIR}/interfaces.orig" /etc/network/interfaces

    if ! ifreload -a; then
        log_error "Baseline Rollback 套用失敗。"
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

rollback_menu()
{
    while true; do
        show_header
        echo "============================================================"
        echo " Rollback / 還原"
        echo "============================================================"
        echo ""
        echo "  1) VSS - 還原 VSS 變更前設定"
        echo "  2) VDS - 還原本工具建立的 SDN 物件"
        echo "  3) Baseline - 還原最初網路設定"
        echo "  0) 返回"
        echo ""

        local choice
        read -r -p "請選擇：" choice
        case "${choice}" in
            1) rollback_vss ;;
            2) rollback_vds ;;
            3) rollback_baseline ;;
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
        echo "  PVE 節點：\$(get_node_name)"
        echo "  Cluster  ：\$(cluster_status_text)"
        echo "  PVE 版本 ：\$(get_pve_version)"
        echo ""
        echo "------------------------------------------------------------"
        echo ""
        echo "  1) VSS 設定（Standard Virtual Switch）"
        echo "  2) VDS 設定（Distributed Virtual Switch / SDN）"
        echo "  3) 查看目前網路設定"
        echo "  4) Rollback / 還原"
        echo "  5) Baseline 管理"
        echo "  6) Port Group 管理"
        echo "  0) 離開"
        echo ""
        echo "------------------------------------------------------------"
        echo ""

        local choice
        read -r -p "請選擇：" choice
        case "${choice}" in
            1) vss_setup ;;
            2) vds_setup ;;
            3) show_current_network ;;
            4) rollback_menu ;;
            5) baseline_menu ;;
            6) port_group_menu ;;
            0)
                echo "離開 PVE NETWORK PRO。"
                return 0
                ;;
            *) log_error "選擇無效，請輸入 0～6。"; sleep 1 ;;
        esac
    done
}

main()
{
    require_root
    check_environment
    ensure_dirs
    main_menu
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "\$@"
fi
