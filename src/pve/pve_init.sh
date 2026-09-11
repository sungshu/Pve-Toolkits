#!/usr/bin/env bash
# PVE Toolkit - Proxmox VE 9（Debian 13 Trixie）台灣環境主機初始化、優化與硬體監控入口
# Version: 2.1.7
# Updated: 2026-09-07
set -Eeuo pipefail

SCRIPT_VERSION="2.1.7"
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

[[ ${EUID} -eq 0 ]] || { echo "${FAIL} 請以 root 執行。" >&2; exit 1; }

disk_script="/root/disk_monitor.sh"

if [[ "$ACTION" != "install" ]]; then
    [[ -x "$disk_script" ]] || { echo "${FAIL} 找不到可執行的 ${disk_script}。" >&2; exit 1; }
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

ok_item() { printf '  %b  %-24s : %s\n' "$OK" "$1" "$2"; ((OK_COUNT+=1)); }
fail_item() { printf '  %b  %-24s : %s\n' "$FAIL" "$1" "$2"; ((FAIL_COUNT+=1)); }
warn_item() { printf '  %b  %-24s : %s\n' "$WARN" "$1" "$2"; ((WARN_COUNT+=1)); }
info_item() { printf '  %b  %-24s : %s\n' "$INFO" "$1" "$2"; }

print_header

echo "${C_BLUE}${C_BOLD}[1/6] APT 來源設定${C_RESET}"
mkdir -p "$backup_dir"
[[ -f /etc/apt/sources.list ]] && cp -a /etc/apt/sources.list "$backup_dir/"
[[ -d /etc/apt/sources.list.d ]] && cp -a /etc/apt/sources.list.d "$backup_dir/"
rm -f /etc/apt/sources.list
for f in debian.sources pve-enterprise.list pve-enterprise.sources pve-install-repo.list pve-install-repo.sources pve-no-subscription.list pve-no-subscription.sources ceph.list ceph.sources ceph-enterprise.list ceph-enterprise.sources ceph-no-subscription.list ceph-no-subscription.sources; do rm -f "/etc/apt/sources.list.d/${f}"; done

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

if grep -q "${DEBIAN_MIRROR}" /etc/apt/sources.list.d/debian.sources && grep -q "pve-no-subscription" /etc/apt/sources.list.d/pve-no-subscription.sources; then ok_item "APT Repository" "設定完成並驗證"; else fail_item "APT Repository" "設定驗證失敗"; fi

echo "${C_BLUE}${C_BOLD}[2/6] 時區與 Chrony${C_RESET}"
timedatectl set-timezone Asia/Taipei
ntp_lines=$'pool tick.stdtime.gov.tw iburst\npool tock.stdtime.gov.tw iburst\npool tw.pool.ntp.org iburst'
[[ -n "$INTERNAL_NTP" ]] && ntp_lines="server ${INTERNAL_NTP} iburst\n${ntp_lines}"
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
if systemctl enable --now chrony >/dev/null 2>&1; then ok_item "Timezone" "$(timedatectl show --property=Timezone --value)"; ok_item "Chrony Service" "$(systemctl is-active chrony) / $(systemctl is-enabled chrony)"; else fail_item "Chrony Service" "啟動失敗"; fi

# 保留 PVE Web UI Subscription Nag Hook
cat > /etc/apt/apt.conf.d/no-nag-script <<'EOF'
DPkg::Post-Invoke { "dpkg -V proxmox-widget-toolkit | grep -q '/proxmoxlib\\.js$'; if [ $? -eq 1 ]; then { echo 'Patching subscription nag...'; sed -i '/.*data\\.status.*active/{s/!//;s/active/NoMoreNagging/}' /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js; }; fi"; };
EOF
ok_item "Subscription Nag Hook" "已設定"

echo "${C_BLUE}${C_BOLD}[4/6] 必要套件${C_RESET}"
if apt update >/dev/null 2>&1; then ok_item "APT Update" "完成"; else fail_item "APT Update" "失敗"; fi
if apt install -y chrony lm-sensors smartmontools linux-cpupower nvme-cli hdparm curl wget util-linux jq >/dev/null 2>&1; then ok_item "Required Packages" "安裝完成"; else fail_item "Required Packages" "安裝失敗"; fi
apt --reinstall install -y proxmox-widget-toolkit >/dev/null 2>&1 && ok_item "proxmox-widget-toolkit" "重新安裝完成" || fail_item "proxmox-widget-toolkit" "重新安裝失敗"
if [[ "$DO_UPGRADE" -eq 1 ]]; then apt full-upgrade -y >/dev/null 2>&1 && ok_item "System Upgrade" "full-upgrade 完成" || fail_item "System Upgrade" "full-upgrade 失敗"; else warn_item "System Upgrade" "未執行（未指定 --upgrade）"; fi

for pkg in chrony lm-sensors smartmontools linux-cpupower nvme-cli hdparm curl wget util-linux jq proxmox-widget-toolkit; do
    if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then ok_item "$pkg" "$(dpkg-query -W -f='${Version}' "$pkg") 已安裝"; else fail_item "$pkg" "未安裝"; fi
done

echo "${C_BLUE}${C_BOLD}[5/6] Datacenter Tag${C_RESET}"
if [[ -f /etc/pve/datacenter.cfg ]]; then
    if grep -q '^tag-style' /etc/pve/datacenter.cfg; then sed -i 's/^tag-style:.*/tag-style: shape=full,ordering=alphabetical/' /etc/pve/datacenter.cfg; else echo 'tag-style: shape=full,ordering=alphabetical' >> /etc/pve/datacenter.cfg; fi
    ok_item "tag-style" "shape=full,ordering=alphabetical"
else
    fail_item "Datacenter Tag" "找不到 /etc/pve/datacenter.cfg"
fi

echo "${C_BLUE}${C_BOLD}[6/6] 硬體監控${C_RESET}"
monitor_tmp="${disk_script}.tmp.$$"
if curl -fsSL "${MONITOR_RAW}?v=$(date +%s)" -o "$monitor_tmp" >/dev/null 2>&1; then
    chmod 0755 "$monitor_tmp"
    if grep -q '^VERSION="1\.0\.52"' "$monitor_tmp"; then
        mv -f "$monitor_tmp" "$disk_script"
        chmod 0755 "$disk_script"
        ok_item "disk_monitor.sh" "v1.0.52 已安裝至 $disk_script"
    else
        rm -f "$monitor_tmp"
        fail_item "disk_monitor.sh" "下載版本驗證失敗"
        exit 1
    fi
else
    rm -f "$monitor_tmp"
    fail_item "disk_monitor.sh" "下載失敗"
    exit 1
fi

rm -f /tmp/pve_toolkit_step.$$ 2>/dev/null || true

echo
echo "${C_CYAN}${C_BOLD}=========================================================${C_RESET}"
printf '  %b：%d 項\n' "$OK" "$OK_COUNT"
printf '  %b：%d 項\n' "$FAIL" "$FAIL_COUNT"
printf '  %b：%d 項\n' "$WARN" "$WARN_COUNT"
echo "${C_CYAN}${C_BOLD}=========================================================${C_RESET}"
(( FAIL_COUNT == 0 )) || exit 1
