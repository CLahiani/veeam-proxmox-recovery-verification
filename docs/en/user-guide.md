# User guide

[← Installation](installation.md) · [Configuration →](configuration.md) · 🇫🇷 [Version française](../fr/guide-utilisateur.md)

## How a run works

```
Step 0  PRE-FLIGHT   Authenticate to VBR, Proxmox API, SSH. Node / bridge / overlay path / VBR
                     Linux credentials exist, bridge is isolated, no foreign VM, no leftovers
                     (test VMs or stale publish sessions).                       → CP00–CP04
Step 1  BOOT         Per VM, sequentially: latest restore point, RPO check, publish the disks
                     to the node (Data Integration API, FUSE), wait, attribute the new disk
                     images, create qcow2 overlays, qm create on the isolated network, qm start.
                                                                                  → CP10–CP12
Step 2  VERIFY       Per VM: wait for guest-agent IP (RTO), running state, NIC guardrail,
                     IP, ping, application checks.                               → CP13–CP30
Step 3  CLEANUP      qm stop / destroy --purge, remove overlays, unpublish (-Cleanup). → CP40
Step 4  REPORT       HTML + CSV + JSON + transcript, exit code.
```

Publishing is sequential (one VM at a time) so the disk images that appear under `/run/media/Veeam.Mount.Disks` can be attributed unambiguously; verification of all VMs then runs in Step 2 while they boot in parallel.

## Command line

```powershell
.\Test-PveBackupBoot.ps1 [-VmNames] <string[]>
    [-ConfigPath <string>] [-Language en|fr]
    [-PingCheck] [-Cleanup] [-FailOnWarning] [-ReportDir <string>]
    [-VbrCredential <PSCredential>] [-PveApiToken <PSCredential>]
    [<configuration overrides>] [-WhatIf] [-Verbose]

.\Test-PveBackupBoot.ps1 -InitConfig [-ConfigPath <string>]
```

### Main parameters

| Parameter | Description | Default |
|---|---|---|
| `-VmNames` | Source VM names **exactly as shown in Veeam**. Position 0. | — (required) |
| `-ConfigPath` | JSON configuration file. Command-line overrides win. | `.\RecoveryVerification.json` |
| `-InitConfig` | Write a configuration template and exit. | — |
| `-Language` | `en` or `fr`. | System culture |
| `-PingCheck` | Enable **CP23**. Requires the probe to sit on the isolated network. | off |
| `-Cleanup` | Destroy the test VMs, remove overlays and **unpublish** at the end; also remove leftovers (test VMs, stale FUSE publish sessions) in pre-flight. Without it CP40 is `SKIP` and **disks stay published** — do not forget. | off |
| `-FailOnWarning` | Count `WARN` as failure for the exit code. | off |
| `-ReportDir` | Output folder. | `.\Reports` |
| `-VbrCredential` | VBR account (Backup Administrator / Restore Operator). Prompted if omitted. | — |
| `-PveApiToken` | Proxmox API token as `PSCredential` (`user@realm!tokenid` / secret). Prompted if omitted. | — |
| `-WhatIf` | Pre-flight runs; publish / create / start / destroy are only displayed. | — |

### Configuration overrides

`-VbrServer -VbrPort -VbrApiVersion -NodeCredentialsName -PveApiHost -PveApiPort -PveNode -PveSshHost -PveSshUser -PveSshKeyPath -IsolatedBridge -IsolatedVlanTag -OverlayStoragePath -VmNamePrefix -VmIdRangeStart -MaxRestorePointAgeHours -MaxBootMinutes -GuestAgentTimeoutMinutes`. See [Configuration](configuration.md).

## Typical scenarios

### First run — validate the setup

```powershell
.\Test-PveBackupBoot.ps1 -VmNames SRV-FILE01 -WhatIf -Verbose
```

### Boot one VM and keep it for manual inspection

```powershell
.\Test-PveBackupBoot.ps1 -VmNames SRV-AD01 -PingCheck
```

VM `rv-srv-ad01` (VMID 9900) stays running on the isolated network; open its console in the Proxmox UI. The restore point stays **published** in VBR (visible under *Home → Restore → Published disks*). The **next run must use `-Cleanup`**, otherwise CP04 blocks.

### Full automated verification

```powershell
.\Test-PveBackupBoot.ps1 -VmNames SRV-AD01,SRV-FILE01,SRV-WEB01 -PingCheck -Cleanup -FailOnWarning
if ($LASTEXITCODE -ne 0) { <# alert #> }
```

### Daily rotation

```powershell
$all = Get-Content .\vms.txt ; $d = (Get-Date).DayOfYear
$sample = 0..2 | ForEach-Object { $all[($d * 3 + $_) % $all.Count] }
.\Test-PveBackupBoot.ps1 -VmNames $sample -Cleanup
```

### Windows / UEFI VMs

Give the VM the right virtual hardware through `VmOverrides` (see [Configuration](configuration.md#vmdefaults--vmoverrides)): `OsType: win11`, `Bios: ovmf` + `EfiStorage`, more memory. VMs that ran on Proxmox already have VirtIO drivers; the test VM uses `virtio-scsi-pci` and a `virtio` NIC like the original.

### Scheduled task (Windows)

```powershell
$action  = New-ScheduledTaskAction -Execute 'pwsh.exe' -Argument '-NoProfile -File C:\Tools\RecoveryVerification\Run.ps1'
$trigger = New-ScheduledTaskTrigger -Daily -At 06:00
Register-ScheduledTask -TaskName 'Veeam Recovery Verification PVE' -Action $action -Trigger $trigger -User 'DOMAIN\svc-rv' -Password '***'
```

`Run.ps1` fetches the two credentials from a vault ([Installation §7](installation.md#7-unattended-runs)) and calls the script with `-Cleanup`.

## Reading the output

### Console

```
  [CP02] OK   -                Isolated bridge / VLAN is non-routed - bridge vmbr1 tag 4000: no IP, no uplink
  [CP12] OK   SRV-AD01         Disk publishing completed - 2 disk(s): disk-0.raw, disk-1.raw
  [CP13] WARN SRV-AD01         Time to boot <= 20 min - 23.4 min - RTO target exceeded
  [CP30] KO   SRV-WEB01        Application: Health - HTTP 503 https://10.99.0.12/health
```

Green `OK`, red `KO`, yellow `WARN`, grey `SKIP`; summary table and file paths at the end.

### Files in `-ReportDir`

| File | Content |
|---|---|
| `RecoveryVerification-<RunId>.html` | Banner, KPIs (VMs, OK / WARN / KO, RPO, RTO), summary per VM, checkpoint table. Self-contained. |
| `RecoveryVerification-<RunId>.csv` | One row per checkpoint, `;`-delimited, UTF-8. |
| `RecoveryVerification-<RunId>.json` | RunId, date, `Platform: ProxmoxVE`, `Method: DataIntegrationApi+QemuOverlay`, target, thresholds, summary, checkpoints. |
| `RecoveryVerification-<RunId>.log` | PowerShell transcript (`-Verbose` adds REST URLs and SSH commands). |

### Exit codes

| Code | Meaning |
|---|---|
| `0` | All checkpoints OK (or WARN only without `-FailOnWarning`). |
| `1` | At least one `KO` (or `WARN` with `-FailOnWarning`). |
| `2` | Blocking pre-flight error or fatal error. Reports are still produced. |

## Safety guardrails

- **CP02 (blocking)** — the bridge must carry no IP / gateway on the node; a bridge with an uplink requires `Isolation.SwitchIsolationConfirmed: true`.
- **CP03** — any non-test VM attached to the isolated bridge / VLAN is reported.
- **CP04 (blocking)** — leftover test VMs (by name prefix or by VMID range + description marker) and stale FUSE publish sessions are removed with `-Cleanup`, otherwise the run stops.
- **CP21 (guardrail)** — a test VM with a NIC outside the isolated bridge / VLAN is **stopped immediately**.
- Published disks are **read-only** by construction (Veeam FUSE); all guest writes go to local qcow2 overlays that are deleted at cleanup. Production VMs and backup files are never touched.
- Test VMs live in a dedicated **VMID range** (`VmIdRangeStart`, 100 ids) with a `Veeam Recovery Verification` description marker, so they are easy to spot and safe to destroy.

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| CP00 KO `HTTP 401` on VBR | Wrong credentials, or `VbrApiVersion` not accepted (`1.3-rev2` for 13.1, `1.3-rev1` for 13.0). |
| CP00 KO `HTTP 401` on Proxmox | Token format: UserName must be `user@realm!tokenid`, Password the secret. Check *Privilege Separation*. |
| CP00 KO `SSH command failed` / `Permission denied` | Key not in `/root/.ssh/authorized_keys`, wrong `SshKeyPath`, or `PermitRootLogin` restricted to `prohibit-password` without key. |
| CP01 KO `no Linux credentials named …` | Create the record in VBR (*Credentials → Add → Linux account*) and set `Veeam.NodeCredentialsName` to its username or description. |
| CP02 KO `bridge carries IP` | The node has an address on the bridge. Use a bridge without IP for the test network. |
| CP02 KO `Isolation.SwitchIsolationConfirmed=true required` | Shared bridge with uplink: have the network team confirm the VLAN is not routed / trunked elsewhere, then set the flag. |
| CP04 KO `leftover(s)` | Previous run without `-Cleanup`. Rerun with `-Cleanup` or clean manually (`qm destroy`, *Published disks → Unpublish*). |
| CP10 KO `no Proxmox VE restore point` | Name must match Veeam exactly; VM must be in a Proxmox backup job with at least one restore point. |
| CP12 KO `status = Failed … agent` | Data Integration API could not deploy its agent on the node: SSH from the **VBR server** to the node blocked, wrong credentials record, `/bin/bash` missing. Check the session log in the Veeam console (*History → Restore*). |
| CP12 KO `no disk image found` | Published to another path: check `Proxmox.MountRoot` (default `/run/media/Veeam.Mount.Disks`) — `find /run/media -maxdepth 3` on the node. |
| CP20 KO after `qm create` | Look at `qm start <vmid>` error in the log: usually `EfiStorage` missing for `ovmf`, or an unsupported `Cpu` / `Machine` value on this node. |
| CP22 WARN `no IP` | Guest agent not installed / not running in the backup, or OS still booting → raise `GuestAgentTimeoutMinutes`. Windows: check the *QEMU Guest Agent* service and VirtIO serial driver. |
| CP23 / CP30 SKIP | `-PingCheck` off, no IP, no `AppChecks` entry, or the probe is not on the isolated network. |
| CP40 KO | Destroy or unpublish failed — clean manually; the detail lists the VMID and mount id. |
| VM boots but no disk found / bootloop | Disk order: overlays are attached `scsi0…N` in the order Veeam publishes them. For multi-disk VMs put the boot disk first by checking `qm config` and adjust `--boot order` if needed (see script `New-TestVm`). |
