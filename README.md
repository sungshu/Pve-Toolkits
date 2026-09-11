# PVE Toolkit

**Proxmox VE 的系統初始化、優化與硬體監控工具箱 —— 一行命令，快速就緒。**

![PVE Toolkit 自動化管理流程](img/p00/PVE-Toolkit_自動化管理流程.jpg)

> **🇹🇼 TW 繁體中文版**  
> **目前版本：PVE Toolkit 2.1.7**  
> **適用環境：Proxmox VE 9.x / Debian 13 Trixie**

PVE Toolkit 是針對 Proxmox VE 主機日常建置與維護所整理的 Shell 工具與實戰文件。

本專案提供 **TW 繁體中文版**，並在系統初始化時使用**台灣來源伺服器**作為 Debian 套件更新來源；PVE Repository 仍使用 Proxmox 官方來源。

## 🚀 快速開始

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

本專案提供的是實戰整理與工具參考，不對任何特定環境的可用性、完整性、正確性或執行結果提供保證。由此造成的問題，由實際操作人自行負責。

**如果您仍然心存疑慮，請不要使用本軟體。**

## ❤️ 支持項目

作者目前**很缺錢 XD**，也確實有打算建立贊助管道，不過目前還沒準備好正式的贊助方式。

現階段最實際的支持方式：
- ⭐ 給專案一個 Star
- 🐛 發現問題歡迎回報
- 💡 有好的想法歡迎提出
- 📢 覺得有用就分享給需要的人

**贊助功能：Coming Soon... 💰**

## 👤 作者

**sungshu 手札筆記本**

GitHub：[sungshu.github.io](https://sungshu.github.io/)

## 📄 License

本專案採用 **GPL-3.0** 開源授權。造成的問題，由實際操作人自行負責。
