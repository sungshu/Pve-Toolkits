# PVE Toolkit

**Proxmox VE 的系統初始化、優化與硬體監控工具箱 —— 一行命令，快速就緒。**

![PVE Toolkit 自動化管理流程](img/p00/PVE-Toolkit_自動化管理流程.jpg)

> **🇹🇼 TW 繁體中文版**  
> **目前版本：PVE Toolkit 2.1.7**  
> **適用環境：Proxmox VE 9.x / Debian 13 Trixie**

PVE Toolkit 是針對 Proxmox VE 主機日常建置與維護所整理的 Shell 工具與實戰文件。

本專案提供 **TW 繁體中文版**，並在系統初始化時使用**台灣來源伺服器**作為 Debian 套件更新來源；PVE Repository 仍使用 Proxmox 官方來源。

它不取代 PVE 原生命令，而是把主機初始化、系統優化、硬體監控與 PVE Web UI 客製化等常用工作集中整理，讓需要重複執行或容易遺漏的步驟，可以透過固定流程快速完成。

---

## 📋 專案簡介

| 功能 | 說明 |
|---|---|
| **PVE 系統初始化與優化** | Repository、時區、Chrony、NTP、必要套件、Datacenter Tag 與系統升級 |
| **PVE 硬體監控客製化** | CPU、溫度、NVMe、SATA/SAS、MegaRAID、SMART 與 Node Summary 顯示 |

---

## 🚀 快速開始

> ⚠️ PVE Toolkit 是依照實際環境整理的實戰工具，**不保證適用於每一台 Proxmox VE 主機，也不保證在不同硬體、PVE 版本、套件版本或系統環境下都能正常執行。**
>
> **如果您仍然心存疑慮，請不要使用本軟體。**

### 🇹🇼 更新來源提醒

`pve_init.sh` 預設使用台灣 Debian 來源：

```text
https://mirror.twds.com.tw/debian
```

PVE Repository 仍使用 Proxmox 官方來源：

```text
http://download.proxmox.com/debian/pve
```

**如果你不希望變更目前 PVE 的更新來源，請不要執行 `pve_init.sh`。**

### PVE 主機初始化

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sungshu/Pve-Toolkits/main/src/pve/pve_init.sh)
```

### 只需要硬體監控

```bash
curl -fsSL https://raw.githubusercontent.com/sungshu/Pve-Toolkits/main/src/pve/disk_monitor.sh -o /root/disk_monitor.sh
chmod +x /root/disk_monitor.sh
/root/disk_monitor.sh
```

### 完整升級

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sungshu/Pve-Toolkits/main/src/pve/pve_init.sh) --upgrade
```

### Ceph

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sungshu/Pve-Toolkits/main/src/pve/pve_init.sh) --ceph
bash <(curl -fsSL https://raw.githubusercontent.com/sungshu/Pve-Toolkits/main/src/pve/pve_init.sh) --ceph --upgrade
```

> `--ceph` 僅加入 Ceph Squid no-subscription repository，不會建立 Ceph Cluster 或 OSD。

### 重新套用／還原硬體監控 UI

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sungshu/Pve-Toolkits/main/src/pve/pve_init.sh) remod
bash <(curl -fsSL https://raw.githubusercontent.com/sungshu/Pve-Toolkits/main/src/pve/pve_init.sh) restore
```

### 指定內部 NTP

```bash
INTERNAL_NTP=192.168.0.100 bash <(curl -fsSL https://raw.githubusercontent.com/sungshu/Pve-Toolkits/main/src/pve/pve_init.sh)
```

---

## 📚 操作文件

| 文件 | 內容 |
|---|---|
| [00. PVE 系統初始化與優化](00.PVE系統初始化與優化.md) | 初始化、Repository、時間同步、Ceph、升級、重新套用與還原 |
| [01. PVE 硬體監控客製化](01.PVE硬體監控客製化.md) | 硬體資訊收集、Node Summary 客製化、安裝與實機驗證 |

## 📦 腳本

| 腳本 | 用途 |
|---|---|
| [`pve_init.sh`](src/pve/pve_init.sh) | PVE 系統初始化、優化、升級、Ceph、UI 套用與還原 |
| [`disk_monitor.sh`](src/pve/disk_monitor.sh) | 硬體資訊收集與 PVE Node Summary 客製化 |

## 📁 專案結構

```text
Pve-Toolkits/
├── README.md
├── LICENSE
├── 00.PVE系統初始化與優化.md
├── 01.PVE硬體監控客製化.md
├── src/
│   └── pve/
│       ├── pve_init.sh
│       └── disk_monitor.sh
└── img/
    ├── p00/
    └── p01/
```

## ⚠️ 免責與風險說明

PVE Toolkit 為個人實戰整理與測試使用的工具與文件，**不代表適用於所有 Proxmox VE 主機或所有硬體環境。**

使用者在執行任何腳本或命令前，應自行確認目前 PVE / Debian 版本、硬體、APT Repository、Cluster、Storage、Network、Firewall 與必要備份狀態。

`--upgrade` 可能更新 PVE 核心；`remod` / `restore` 會修改 PVE Web UI 相關檔案。

**本專案提供的是實戰整理與工具參考，不對任何特定環境的可用性、完整性、正確性或執行結果提供保證。由此造成的問題，由實際操作人自行負責。**

## ❤️ 支持項目

作者目前**很缺錢 XD**，也確實有打算建立贊助管道，不過目前還沒準備好正式的贊助方式。

現階段最實際的支持方式：Star、問題回報、想法與分享。

**贊助功能：Coming Soon... 💰**

## 👤 作者

**sungshu 手札筆記本**

GitHub：[sungshu.github.io](https://sungshu.github.io/)

## 📄 License

本專案採用 **GPL-3.0** 開源授權。造成的問題，由實際操作人自行負責。
