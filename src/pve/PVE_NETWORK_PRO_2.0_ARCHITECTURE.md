# PVE NETWORK PRO 2.0 Architecture

## 1. 定位

PVE NETWORK PRO 2.0 定位為：

> VMware-first Network Object Manager + PVE Native Transactional Network Change Engine

使用者操作層採 VMware 熟悉的 VSS / VDS / Uplink / Port Group / VMkernel 模型；底層由 Proxmox VE 原生網路機制負責實際設定與套用。

## 2. 正式資料根目錄

PVE NETWORK PRO 正式資料根目錄：

`/etc/pve-toolkit/net/`

禁止使用：

`/etc/pve-poc/`

目錄：

```
/etc/pve-toolkit/net/
├── baseline/
├── state/
│   ├── vss/
│   ├── vds/
│   ├── objects/
│   └── topology/
├── plans/
├── backup/
├── changes/
└── recovery/
```

## 3. PVE Native Network Staging

PVE NETWORK PRO 的管理資料與 PVE 原生設定必須分離。

PVE NETWORK PRO：

`/etc/pve-toolkit/net/`

PVE Native：

`/etc/network/interfaces`

暫存：

`/etc/network/interfaces.new`

PVE NETWORK PRO 不應直接把自己當成 Network Engine。

## 4. Change Management

所有正式 Network Change 必須遵循：

```
Current
  ↓
Proposed
  ↓
Diff
  ↓
Dry-run
  ↓
Validate
  ↓
Backup
  ↓
Apply
  ↓
Verify
  ↓
Confirm
  ↓
Commit
```

失敗或確認逾時：

```
Failure / Timeout
  ↓
Rollback
  ↓
Verify Recovery
```

### 強制規則

1. 沒有 Diff 不得 Apply。
2. Backup 失敗不得 Apply。
3. 影響 Management Network 的變更必須進入 Confirmation Transaction。
4. Rollback 本身也是一個 Change Transaction。

## 5. Network Objects

### VSS / vSwitch

```
vSwitch0
├── Physical Uplink
│   ├── NIC
│   └── NIC Teaming
├── Port Group
│   ├── VLAN
│   └── Virtual Machine / VMkernel
└── Management
```

PVE 對應：

- vSwitch → Linux Bridge / vmbr
- Physical Uplink → NIC / Bond
- Port Group → Bridge + VLAN 邏輯
- VMkernel → PVE Host / Management Network

UI 以 VMware 名稱為主，PVE 名稱作詳細資訊。

### VDS / Distributed Switch

```
VDS
├── Zone
├── VNet
├── Subnet
└── Port Group
```

PVE 對應：

```
VDS
 ↓
SDN Zone
 ↓
VNet
 ↓
Subnet
```

## 6. Baseline / Backup / Recovery

### Baseline

`/etc/pve-toolkit/net/baseline/`

第一次建立後不得自動覆蓋。

用途：保存 PVE NETWORK PRO 正式管理前的已知正常狀態。

### Backup

每次正式 Apply 前建立：

`/etc/pve-toolkit/net/backup/CHG-YYYYMMDD-HHMMSS/`

至少保存：

- interfaces
- interfaces.new
- ip-address
- ip-route
- ip-link
- cluster-status

### Change ID

所有 Plan / Backup / Change / Recovery 使用相同 Change ID：

`CHG-YYYYMMDD-HHMMSS`

## 7. State

舊式 append-only TSV state 不作為 2.0 正式架構。

State 必須提供：

- get
- set
- upsert
- delete

State 描述的是目前有效的 Network Object / Topology，而不是單純記錄工具曾經執行過的動作。

## 8. Topology Discovery

不得硬編碼 `bond0`。

實際 topology 必須由系統目前狀態解析：

```
vmbr
 ↓
bridge-ports
 ↓
bondX / nicX
 ↓
bond-slaves
 ↓
Physical NIC
```

系統實際 topology 是唯一可信來源。

## 9. Change Safety

變更分為：

### SAFE

- Port Group metadata
- 描述
- 非破壞性物件資訊

### CAUTION

- Bond
- Uplink
- Bridge topology
- VLAN topology

### MANAGEMENT IMPACT

- Management IP
- Gateway
- Management Bridge
- Management NIC
- Host Network

Management Impact 變更必須使用 Confirmation Transaction。

## 10. 2.0 UI

```
PVE NETWORK PRO
────────────────────────────────

1) Network Objects
   ├─ VSS / vSwitch
   ├─ VDS / Distributed Switch
   ├─ Uplink
   ├─ Port Group
   └─ VMkernel / Management

2) Change Management
   ├─ New Change
   ├─ Current Changes
   ├─ Diff / Dry-run
   ├─ Apply
   └─ Change History

3) Backup / Recovery
   ├─ Baseline
   ├─ Backup History
   ├─ Restore
   └─ Recovery

4) Network Status
   ├─ Current Configuration
   ├─ Topology
   ├─ Cluster
   └─ Connectivity

0) Exit
```

## 11. 2.0 禁止事項

- 禁止使用 `/etc/pve-poc/`
- 禁止整份直接覆蓋 `/etc/network/interfaces`
- 禁止沒有 Diff 就 Apply
- 禁止沒有 Backup 就 Apply
- 禁止硬編碼 `bond0`
- 禁止 PVE NETWORK PRO 自行取代 PVE Network Engine

## 12. 底層原則

PVE NETWORK PRO 負責：

- Object Model
- Change Plan
- Diff
- Dry-run
- Validation
- Backup
- Transaction
- Recovery

PVE 負責：

- `/etc/network/interfaces`
- `/etc/network/interfaces.new`
- ifupdown2
- PVE SDN
- PVE API / pvesh

架構目標：

```
PVE NETWORK PRO
      ↓
/etc/pve-toolkit/net/
      ↓
Current / Proposed / Diff
      ↓
Validate / Backup
      ↓
PVE Native Staging
      ↓
Apply / Verify / Commit
      ↓
Recovery when required
```

