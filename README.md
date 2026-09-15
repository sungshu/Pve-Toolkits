# PVE Toolkit

**Proxmox VE 的系統初始化、優化與硬體監控工具箱 —— 一行命令，快速就緒。**

![PVE Toolkit 自動化管理流程](img/p00/PVE-Toolkit_自動化管理流程.jpg)

> **🇹🇼 TW 繁體中文版**  
> **目前版本：PVE Toolkit 2.1.8**  
> **適用環境：Proxmox VE 9.x / Debian 13 Trixie**

PVE Toolkit 是針對 Proxmox VE 主機日常建置與維護所整理的 Shell 工具與實戰文件。

本專案提供 **TW 繁體中文版**，並在系統初始化時使用**台灣來源伺服器**作為 Debian 套件更新來源；PVE Repository 仍使用 Proxmox 官方來源。

它不取代 PVE 原生命令，而是把主機初始化、系統優化、硬體監控與 PVE Web UI 客製化等常用工作集中整理，讓需要重複執行或容易遺漏的步驟，可以透過固定流程快速完成。

---

## 📋 專案簡介

PVE Toolkit 目前主要包含兩個部分：

| 功能 | 說明 |
|---|---|
| **PVE 系統初始化與優化** | Repository、時區、Chrony、NTP、必要套件、Datacenter Tag 與系統升級 |
| **PVE 硬體監控客製化** | CPU、溫度、NVMe、SATA/SAS、MegaRAID、SMART 與 Node Summary 顯示 |

---

## 🚀 快速開始

> ⚠️ **使用前請注意**
>
> PVE Toolkit 是依照實際環境整理的實戰工具，**不保證適用於每一台 Proxmox VE 主機，也不保證在不同硬體、PVE 版本、套件版本或系統環境下都能正常執行。**
>
> 執行前請確認目標主機環境、目前設定與備份狀態。尤其 `pve_init.sh`、`--upgrade`、`remod` 與 `restore` 等操作可能會修改系統或 PVE Web UI 相關檔案。
>
> **如果您仍然心存疑慮，請不要使用本軟體。**
>
> ### 🇹🇼 更新來源提醒
>
> `pve_init.sh` 會修改 PVE 的 APT Repository 設定，其中 Debian 套件來源預設使用**台灣來源伺服器**：
>
> ```text
> https://mirror.twds.com.tw/debian
> ```
>
> PVE Repository 仍使用 Proxmox 官方來源：
>
> ```text
> http://download.proxmox.com/debian/pve
> ```
>
> **如果你不希望變更目前 PVE 的更新來源，請不要執行 `pve_init.sh`。**
>
> 如果你的環境與本文測試環境不同，請先確認腳本內容與實際影響，再決定是否執行。

### PVE 主機初始化

在 PVE 主機以 `root` 執行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sungshu/Pve-Toolkits/main/src/pve/pve_init.sh)
```

預設會執行：

- APT Repository 設定與備份
- `Asia/Taipei` 時區與 Chrony
- PVE Subscription Nag Hook
- 必要系統與硬體監控套件
- Datacenter Tag 樣式
- 自動部署 `disk_monitor.sh v1.0.52`

### 只需要硬體監控

```bash
curl -fsSL https://raw.githubusercontent.com/sungshu/Pve-Toolkits/main/src/pve/disk_monitor.sh -o /root/disk_monitor.sh
chmod +x /root/disk_monitor.sh
/root/disk_monitor.sh
```

正式安裝位置：

```text
/root/disk_monitor.sh
```

---

## ⚙️ 常用操作

### 完整系統升級

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sungshu/Pve-Toolkits/main/src/pve/pve_init.sh) --upgrade
```

執行完整 `apt full-upgrade`，更新 PVE 核心、韌體與其他系統套件。

### 啟用 Ceph Squid no-subscription Repository

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sungshu/Pve-Toolkits/main/src/pve/pve_init.sh) --ceph
```

### Ceph + 完整系統升級

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sungshu/Pve-Toolkits/main/src/pve/pve_init.sh) --ceph --upgrade
```

> `--ceph` 僅加入 Ceph Squid no-subscription repository，不會建立 Ceph Cluster 或 OSD。

### 重新套用硬體監控 UI

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sungshu/Pve-Toolkits/main/src/pve/pve_init.sh) remod
```

### 還原官方硬體監控 UI

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sungshu/Pve-Toolkits/main/src/pve/pve_init.sh) restore
```

### 指定內部 NTP

機房有內部 NTP 時，可透過 `INTERNAL_NTP` 指定：

```bash
INTERNAL_NTP=192.168.0.100 bash <(curl -fsSL https://raw.githubusercontent.com/sungshu/Pve-Toolkits/main/src/pve/pve_init.sh)
```

`192.168.0.100` 僅為範例，請替換為實際 NTP 位址。

---

## 🛠️ 功能特性

### PVE 系統初始化與優化

- APT Repository 設定與原始設定備份
- Debian 13 Trixie / PVE no-subscription Repository
- 台灣 Debian 套件來源伺服器
- `Asia/Taipei` 時區設定
- Chrony 時間同步與內部 NTP 指定
- PVE Subscription Nag Hook
- Datacenter Tag 樣式
- 系統與硬體監控套件安裝
- PVE 系統升級
- Ceph Squid no-subscription Repository

### PVE 硬體監控與 Web UI 客製化

- CPU 資訊與雙插槽溫度
- NVMe 健康資訊與使用量
- SATA / SAS 硬碟資訊
- MegaRAID 硬碟與 SMART 資訊
- 磁碟健康狀態與容量資訊
- Node Summary 硬體資訊整合
- `remod` 重新套用客製化 UI
- `restore` 還原官方 UI

---

## 📚 操作文件

| 文件 | 內容 |
|---|---|
| [00. PVE 系統初始化與優化](00.PVE系統初始化與優化.md) | 初始化、Repository、時間同步、Ceph、升級、重新套用與還原 |
| [01. PVE 硬體監控客製化](01.PVE硬體監控客製化.md) | 硬體資訊收集、Node Summary 客製化、安裝與實機驗證 |

---

## 📦 腳本

| 腳本 | 用途 |
|---|---|
| [`pve_init.sh`](src/pve/pve_init.sh) | PVE 系統初始化、優化、升級、Ceph、UI 套用與還原 |
| [`disk_monitor.sh`](src/pve/disk_monitor.sh) | 硬體資訊收集與 PVE Node Summary 客製化 |

---

## 📁 專案結構

```text
Pve-Toolkits/
├── img/
│   ├── p00/
│   └── p01/
│
├── src/
│   └── pve/
│       ├── pve_init.sh
│       └── disk_monitor.sh
│
├── 00.PVE系統初始化與優化.md
├── 01.PVE硬體監控客製化.md
├── LICENSE
└── README.md
```

- `img/p00/`：00 文件與專案流程圖
- `img/p01/`：01 文件使用的圖片
- `src/pve/`：正式使用的 PVE Shell 工具
- `00.PVE系統初始化與優化.md`：初始化與系統優化文件
- `01.PVE硬體監控客製化.md`：硬體監控與 PVE Web UI 客製化文件

---

## ⚠️ 免責與風險說明

PVE Toolkit 為個人實戰整理與測試使用的工具與文件，**不代表適用於所有 Proxmox VE 主機或所有硬體環境。**

本專案無法保證每一台 PVE 主機都可以直接使用，也無法保證不同的 CPU、主機板、RAID 控制器、硬碟、網路環境、PVE 版本、Debian 套件版本或其他客製化設定，都能得到與作者測試環境相同的結果。

即使腳本在作者的實際環境中可以正常執行，換到其他環境後仍可能因硬體、軟體版本、既有設定或第三方元件差異而發生錯誤、功能異常或其他未預期結果。

使用者在執行任何腳本或命令前，應自行確認：

- 目前 PVE / Debian 版本與硬體環境
- APT Repository 設定
- Cluster 狀態
- Storage 設定
- Network 設定
- 現有 PVE Web UI 客製化內容
- 必要的系統與設定備份

`--upgrade` 可能更新 PVE 核心，完成後請依實際環境安排重開機。

`--ceph` 僅加入 Ceph Squid no-subscription repository，不會建立 Ceph Cluster 或 OSD。

`remod` / `restore` 會修改 PVE Web UI 相關檔案，使用前應確認已有可用的還原方式。

本工具目前不負責 VM、CT、Storage、Network、Firewall、Ceph Cluster/OSD 或 VMware 遷移等其他 PVE 管理工作。

**本專案提供的是實戰整理與工具參考，不對任何特定環境的可用性、完整性、正確性或執行結果提供保證。由此造成的問題，由實際操作人自行負責。**

---

## ❤️ 支持項目

> 如果這個專案有幫你省下時間、少踩幾個坑，歡迎給個 Star ⭐
>
> 作者目前**很缺錢 XD**，也確實有打算建立贊助管道，不過目前還沒準備好正式的贊助方式。
>
> 所以現階段最實際的支持方式就是：
> - ⭐ 給專案一個 Star
> - 🐛 發現問題歡迎回報
> - 💡 有好的想法歡迎提出
> - 📢 覺得有用就分享給需要的人
>
> **贊助功能：Coming Soon... 💰**

---

## 👤 作者

**sungshu 手札筆記本**

GitHub：[sungshu.github.io](https://sungshu.github.io/)

---

## 📄 License

本專案採用 **GPL-3.0** 開源授權。造成的問題，由實際操作人自行負責。
