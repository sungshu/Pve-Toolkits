#!/usr/bin/env bash
# PVE Toolkit - Proxmox VE 9（Debian 13 Trixie）台灣環境主機初始化、優化與硬體監控入口
# Version: 2.1.9
# Updated: 2026-09-15
set -Eeuo pipefail

SCRIPT_VERSION="2.1.9"
readonly DEBIAN_MIRROR="https://mirror.twds.com.tw/debian"
readonly DEBIAN_SECURITY="https://security.debian.org/debian-security"
readonly PVE_REPOSITORY="http://download.proxmox.com/debian/pve"
readonly CEPH_REPOSITORY="http://download.proxmox.com/debian/ceph-squid"
readonly REPOSITORY_RAW="https://raw.githubusercontent.com/sungshu/Pve-Toolkits/main/src/pve"
readonly MONITOR_RAW="${REPOSITORY_RAW}/disk_monitor.sh"
readonly SUITE="trixie"
INTERNAL_NTP="${INTERNAL_NTP:-}"
DO_UPGRADE=0
ENABLE_CEPH=0
ACTION="install"

# ---------- 顏色 ----------
if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'; C_BLUE=$'\033[34m'; C_BOLD=$'\033[1m'
else
    C_RESET=''; C_GREEN=''; C_RED=''; C_YELLOW=''; C_CYAN=''; C_BLUE=''; C_BOLD=''
fi
OK="${C_GREEN}✓ 成功${C_RESET}"
FAIL="${C_RED}✗ 失敗${C_RESET}"
WARN="${C_YELLOW}⚠ 警告${C_RESET}"
INFO="${C_CYAN}→${C_RESET}"

usage() {
    cat <<'EOF'
PVE Toolkit - Proxmox VE Infrastructure Toolkit

用法：
  ./pve_init.sh [--upgrade] [--ceph]
  ./pve_init.sh restore
  ./pve_init.sh remod

選項：
  --upgrade  安裝必要套件後執行 apt full-upgrade
  --ceph     啟用 Ceph Squid no-subscription repository
  restore    還原硬體監控介面修改
  remod      強制重新套用硬體監控介面
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --upgrade) DO_UPGRADE=1 ;;
        --ceph) ENABLE_CEPH=1 ;;
        restore|remod) ACTION="$1" ;;
        -h|--help) usage; exit 0 ;;
        *) echo "${FAIL} 未知參數：$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

if [[ ${EUID} -ne 0 ]]; then
    echo "${FAIL} 請以 root 執行。" >&2
    exit 1
fi

# 主入口腳本從 GitHub 下載執行時，正式硬體監控程式固定安裝於 /root。
disk_script="/root/disk_monitor.sh"

if [[ "$ACTION" != "install" ]]; then
    if [[ ! -x "$disk_script" ]]; then
        echo "${FAIL} 找不到可執行的 ${disk_script}。" >&2
        exit 1
    fi
    exec "$disk_script" "$ACTION"
fi

backup_dir="/root/apt-sources-backup-$(date +%F-%H%M%S)"
OK_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

print_header() {
    echo
    echo "${C_CYAN}${C_BOLD}=========================================================${C_RESET}"
    echo "${C_CYAN}${C_BOLD} PVE Toolkit v${SCRIPT_VERSION}${C_RESET}"
    echo "${C_CYAN} Proxmox VE 9 / Debian 13 Trixie${C_RESET}"
    echo "${C_CYAN}${C_BOLD}=========================================================${C_RESET}"
}

print_section() {
    echo
    echo "${C_BLUE}${C_BOLD}---------------------------------------------------------${C_RESET}"
    echo "${C_BLUE}${C_BOLD} $1${C_RESET}"
    echo "${C_BLUE}${C_BOLD}---------------------------------------------------------${C_RESET}"
}

ok_item() {
    printf '  %b  %-24s : %s\n' "$OK" "$1" "$2"
    ((OK_COUNT+=1))
}

fail_item() {
    printf '  %b  %-24s : %s\n' "$FAIL" "$1" "$2"
    ((FAIL_COUNT+=1))
}

warn_item() {
    printf '  %b  %-24s : %s\n' "$WARN" "$1" "$2"
    ((WARN_COUNT+=1))
}

info_item() {
    printf '  %b  %-24s : %s\n' "$INFO" "$1" "$2"
}

run_step() {
    local name="$1"; shift
    info_item "$name" "執行中..."
    if "$@" >/tmp/pve_toolkit_step.$$ 2>&1; then
        ok_item "$name" "完成"
        return 0
    else
        fail_item "$name" "執行失敗"
        echo "    ${C_RED}錯誤：$(tail -n 3 /tmp/pve_toolkit_step.$$ | tr '\n' ' ')${C_RESET}"
        return 1
    fi
}

print_header

print_section "[1/6] APT 來源設定"
mkdir -p "$backup_dir"
[[ -f /etc/apt/sources.list ]] && cp -a /etc/apt/sources.list "$backup_dir/"
[[ -d /etc/apt/sources.list.d ]] && cp -a /etc/apt/sources.list.d "$backup_dir/"
info_item "Debian Mirror" "$DEBIAN_MIRROR"
info_item "Debian Suite" "${SUITE} / ${SUITE}-updates / ${SUITE}-security"
info_item "PVE Repository" "$PVE_REPOSITORY"
info_item "PVE Channel" "pve-no-subscription"
info_item "Ceph Source" "$([[ "$ENABLE_CEPH" -eq 1 ]] && echo 已啟用 || echo 未啟用)"
info_item "APT 備份" "$backup_dir"

rm -f /etc/apt/sources.list
for f in debian.sources pve-enterprise.list pve-enterprise.sources pve-install-repo.list pve-install-repo.sources pve-no-subscription.list pve-no-subscription.sources ceph.list ceph.sources ceph-enterprise.list ceph-enterprise.sources ceph-no-subscription.list ceph-no-subscription.sources; do
    rm -f "/etc/apt/sources.list.d/${f}"
done

cat > /etc/apt/sources.list.d/debian.sources <<EOF
Types: deb deb-src
URIs: ${DEBIAN_MIRROR}
Suites: ${SUITE} ${SUITE}-updates
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: ${DEBIAN_SECURITY}
Suites: ${SUITE}-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF

cat > /etc/apt/sources.list.d/pve-no-subscription.sources <<EOF
Types: deb
URIs: ${PVE_REPOSITORY}
Suites: ${SUITE}
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF

if [[ "$ENABLE_CEPH" -eq 1 ]]; then
    cat > /etc/apt/sources.list.d/ceph-no-subscription.sources <<EOF
Types: deb
URIs: ${CEPH_REPOSITORY}
Suites: ${SUITE}
Components: no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
fi

if grep -q "${DEBIAN_MIRROR}" /etc/apt/sources.list.d/debian.sources && grep -q "pve-no-subscription" /etc/apt/sources.list.d/pve-no-subscription.sources; then
    ok_item "APT Repository" "設定完成並驗證"
else
    fail_item "APT Repository" "設定驗證失敗"
fi

print_section "[2/6] 時區與 Chrony"
timedatectl set-timezone Asia/Taipei
ntp_lines=$'pool tick.stdtime.gov.tw iburst\npool tock.stdtime.gov.tw iburst\npool tw.pool.ntp.org iburst'
if [[ -n "$INTERNAL_NTP" ]]; then
    ntp_lines="server ${INTERNAL_NTP} iburst
${ntp_lines}"
fi
install -d -m 0755 /etc/chrony
cat > /etc/chrony/chrony.conf <<EOF
${ntp_lines}
keyfile /etc/chrony/chrony.keys
driftfile /var/lib/chrony/chrony.drift
logdir /var/log/chrony
maxupdateskew 100.0
rtcsync
makestep 1 3
EOF
if systemctl enable --now chrony >/tmp/pve_toolkit_step.$$ 2>&1; then
    tz="$(timedatectl show --property=Timezone --value)"
    state="$(systemctl is-active chrony) / $(systemctl is-enabled chrony)"
    [[ "$tz" == "Asia/Taipei" ]] && ok_item "Timezone" "$tz" || fail_item "Timezone" "$tz"
    [[ "$state" == "active / enabled" ]] && ok_item "Chrony Service" "$state" || fail_item "Chrony Service" "$state"
    ok_item "NTP" "tick.stdtime.gov.tw / tock.stdtime.gov.tw / tw.pool.ntp.org"
    [[ -n "$INTERNAL_NTP" ]] && info_item "Internal NTP" "$INTERNAL_NTP"
else
    fail_item "Chrony Service" "啟動失敗"
fi

print_section "[3/6] PVE UI Subscription Nag Hook"
cat > /etc/apt/apt.conf.d/no-nag-script <<'EOF'
DPkg::Post-Invoke { "dpkg -V proxmox-widget-toolkit | grep -q '/proxmoxlib\\.js$'; if [ $? -eq 1 ]; then { echo 'Patching subscription nag...'; sed -i '/.*data\\.status.*active/{s/!//;s/active/NoMoreNagging/}' /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js; }; fi"; };
EOF
[[ -f /etc/apt/apt.conf.d/no-nag-script ]] && ok_item "Subscription Nag Hook" "已設定" || fail_item "Subscription Nag Hook" "設定失敗"

print_section "[4/6] 必要套件"
info_item "APT Update" "正在更新套件索引..."
if apt update >/tmp/pve_toolkit_step.$$ 2>&1; then
    ok_item "APT Update" "完成"
else
    fail_item "APT Update" "失敗"
    echo "    ${C_RED}錯誤：$(tail -n 3 /tmp/pve_toolkit_step.$$ | tr '\n' ' ')${C_RESET}"
fi
info_item "Required Packages" "正在安裝必要套件..."
if apt install -y chrony lm-sensors smartmontools linux-cpupower nvme-cli hdparm curl wget util-linux jq >/tmp/pve_toolkit_step.$$ 2>&1; then
    ok_item "Required Packages" "安裝完成"
else
    fail_item "Required Packages" "安裝失敗"
    echo "    ${C_RED}錯誤：$(tail -n 3 /tmp/pve_toolkit_step.$$ | tr '\n' ' ')${C_RESET}"
fi
info_item "proxmox-widget-toolkit" "正在重新安裝..."
if apt --reinstall install -y proxmox-widget-toolkit >/tmp/pve_toolkit_step.$$ 2>&1; then
    ok_item "proxmox-widget-toolkit" "重新安裝完成"
else
    fail_item "proxmox-widget-toolkit" "重新安裝失敗"
fi
if [[ "$DO_UPGRADE" -eq 1 ]]; then
    info_item "System Upgrade" "正在執行 apt full-upgrade..."
    if apt full-upgrade -y >/tmp/pve_toolkit_step.$$ 2>&1; then
        ok_item "System Upgrade" "full-upgrade 完成"
    else
        fail_item "System Upgrade" "full-upgrade 失敗"
    fi
else
    warn_item "System Upgrade" "未執行（未指定 --upgrade）"
fi

for pkg in chrony lm-sensors smartmontools linux-cpupower nvme-cli hdparm curl wget util-linux jq proxmox-widget-toolkit; do
    if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
        ver="$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null)"
        ok_item "$pkg" "${ver} 已安裝"
    else
        fail_item "$pkg" "未安裝"
    fi
done

print_section "[5/6] Datacenter Tag"
if [[ -f /etc/pve/datacenter.cfg ]]; then
    if grep -q '^tag-style' /etc/pve/datacenter.cfg; then
        sed -i 's/^tag-style:.*/tag-style: shape=full,ordering=alphabetical/' /etc/pve/datacenter.cfg
    else
        echo 'tag-style: shape=full,ordering=alphabetical' >> /etc/pve/datacenter.cfg
    fi
    tag_style="$(grep '^tag-style:' /etc/pve/datacenter.cfg | tail -1 | cut -d: -f2- | sed 's/^ *//')"
    [[ "$tag_style" == "shape=full,ordering=alphabetical" ]] && ok_item "tag-style" "$tag_style" || fail_item "tag-style" "$tag_style"
else
    fail_item "Datacenter Tag" "找不到 /etc/pve/datacenter.cfg"
fi

print_section "[6/6] 硬體監控"
monitor_tmp="${disk_script}.tmp.$$"
latest_tmp="${disk_script}.latest.$$"
latest_url="${MONITOR_RAW}?v=$(date +%s)"

info_item "Latest Version" "正在確認目前最新版..."
if curl -fsSL "$latest_url" -o "$latest_tmp" >/tmp/pve_toolkit_step.$$ 2>&1; then
    latest_version="$(grep -m1 '^VERSION=' "$latest_tmp" | cut -d'=' -f2- | tr -d '\"' | tr -d '\r')"
    if [[ -z "$latest_version" ]]; then
        fail_item "Latest Version" "無法解析版本"
        rm -f "$latest_tmp" "$monitor_tmp" /tmp/pve_toolkit_step.$$
        exit 1
    fi
    ok_item "Latest Version" "v${latest_version}"
else
    fail_item "Latest Version" "取得最新版失敗"
    rm -f "$latest_tmp" "$monitor_tmp" /tmp/pve_toolkit_step.$$
    exit 1
fi

DOWNLOAD_VERSION="${DISK_MONITOR_VERSION:-$latest_version}"
DOWNLOAD_REF="${DISK_MONITOR_REF:-main}"

info_item "Download Version" "v${DOWNLOAD_VERSION}"
info_item "Execute Version" "v${DOWNLOAD_VERSION}"
info_item "disk_monitor.sh" "正在下載 v${DOWNLOAD_VERSION}..."

if [[ "$DOWNLOAD_REF" == "main" && "$DOWNLOAD_VERSION" == "$latest_version" ]]; then
    cp -f "$latest_tmp" "$monitor_tmp"
elif [[ "$DOWNLOAD_REF" == "main" ]]; then
    if ! curl -fsSL "$latest_url" -o "$monitor_tmp" >/tmp/pve_toolkit_step.$$ 2>&1; then
        fail_item "disk_monitor.sh" "下載失敗"
        rm -f "$latest_tmp" "$monitor_tmp" /tmp/pve_toolkit_step.$$
        exit 1
    fi
else
    version_url="https://raw.githubusercontent.com/sungshu/Pve-Toolkits/${DOWNLOAD_REF}/src/pve/disk_monitor.sh"
    if ! curl -fsSL "${version_url}?v=$(date +%s)" -o "$monitor_tmp" >/tmp/pve_toolkit_step.$$ 2>&1; then
        fail_item "disk_monitor.sh" "下載 v${DOWNLOAD_VERSION} 失敗"
        rm -f "$latest_tmp" "$monitor_tmp" /tmp/pve_toolkit_step.$$
        exit 1
    fi
fi

chmod 0755 "$monitor_tmp"
actual_version="$(grep -m1 '^VERSION=' "$monitor_tmp" | cut -d'=' -f2- | tr -d '\"' | tr -d '\r')"
info_item "Actual Version" "v${actual_version:-未知}"

if [[ -z "$actual_version" ]]; then
    fail_item "Version Check" "無法取得實際版本"
    rm -f "$latest_tmp" "$monitor_tmp"
    exit 1
fi

if [[ "$actual_version" == "$DOWNLOAD_VERSION" ]]; then
    ok_item "Version Check" "版本相同（v${actual_version}）"
    mv -f "$monitor_tmp" "$disk_script"
    chmod 0755 "$disk_script"

    echo
    echo "  ${C_GREEN}${C_BOLD}✓ 版本相同，自動執行 v${DOWNLOAD_VERSION}${C_RESET}"
    for ((count=60; count>=1; count--)); do
        printf "\r  ${C_CYAN}→${C_RESET} 將於 %2d 秒後執行 disk_monitor.sh v${DOWNLOAD_VERSION}..." "$count"
        sleep 1
    done
    printf '\r%*s\r' 90 ''
    info_item "Execute" "開始執行 v${DOWNLOAD_VERSION}..."
    if "$disk_script" install >/tmp/pve_toolkit_step.$$ 2>&1; then
        ok_item "disk_monitor.sh" "v${DOWNLOAD_VERSION} 執行完成"
    else
        fail_item "disk_monitor.sh" "v${DOWNLOAD_VERSION} 執行失敗"
        echo "    ${C_RED}錯誤：$(tail -n 5 /tmp/pve_toolkit_step.$$ | tr '\n' ' ')${C_RESET}"
        rm -f "$latest_tmp" /tmp/pve_toolkit_step.$$
        exit 1
    fi
else
    warn_item "Version Check" "版本不同（下載 v${DOWNLOAD_VERSION} / 實際 v${actual_version} / 最新 v${latest_version}）"
    echo
    echo "  ${C_YELLOW}${C_BOLD}⚠ 版本不同，是否執行 v${actual_version}？ [Y/N]${C_RESET}"
    read -r -p "  ${C_YELLOW}請選擇 [Y/N]：${C_RESET}" execute_choice
    case "$execute_choice" in
        Y|y)
            mv -f "$monitor_tmp" "$disk_script"
            chmod 0755 "$disk_script"
            ok_item "Execute Decision" "使用者選擇執行 v${actual_version}"
            info_item "Execute" "開始執行 v${actual_version}..."
            if "$disk_script" install >/tmp/pve_toolkit_step.$$ 2>&1; then
                ok_item "disk_monitor.sh" "v${actual_version} 執行完成"
            else
                fail_item "disk_monitor.sh" "v${actual_version} 執行失敗"
                echo "    ${C_RED}錯誤：$(tail -n 5 /tmp/pve_toolkit_step.$$ | tr '\n' ' ')${C_RESET}"
                rm -f "$latest_tmp" /tmp/pve_toolkit_step.$$
                exit 1
            fi
            ;;
        *)
            warn_item "Execute Decision" "使用者選擇不執行"
            rm -f "$monitor_tmp"
            ;;
    esac
fi

rm -f "$latest_tmp" /tmp/pve_toolkit_step.$$

echo
echo "${C_CYAN}${C_BOLD}=========================================================${C_RESET}"
echo "${C_CYAN}${C_BOLD} 設定結果${C_RESET}"
echo "${C_CYAN}${C_BOLD}=========================================================${C_RESET}"
printf '  %b：%d 項\n' "$OK" "$OK_COUNT"
printf '  %b：%d 項\n' "$FAIL" "$FAIL_COUNT"
printf '  %b：%d 項\n' "$WARN" "$WARN_COUNT"
echo
if (( FAIL_COUNT > 0 )); then
    echo "${C_RED}${C_BOLD}結果：✗ 失敗${C_RESET}"
    echo "${C_RED}請處理上方紅色項目後重新執行。${C_RESET}"
elif (( WARN_COUNT > 0 )); then
    echo "${C_YELLOW}${C_BOLD}結果：⚠ 有警告${C_RESET}"
    echo "${C_YELLOW}目前有警告項目；如需完整執行可重新指定對應選項。${C_RESET}"
else
    echo "${C_GREEN}${C_BOLD}結果：✓ 完成${C_RESET}"
fi
