# Configuration reference

[← User guide](user-guide.md) · [Checkpoints →](checkpoints.md) · 🇫🇷 [Version française](../fr/configuration.md)

JSON file, `./RecoveryVerification.json` by default (`-c`). Generate with `--init-config` or copy `RecoveryVerification.sample.json`.

**Precedence:** built-in defaults ← JSON file ← command-line overrides. `AppChecks` and `VmOverrides`, when present in the file, **replace** the defaults entirely. Keep the real file out of git (`.gitignore`).

## `Veeam`

| Key | CLI | Description | Default |
|---|---|---|---|
| `VbrServer` / `VbrPort` | `--vbr-server` / `--vbr-port` | VBR 13.x server and REST port. | `vbr.example.local` / `9419` |
| `VbrApiVersion` | `--vbr-api-version` | `x-api-version`: **`1.3-rev2` = 13.1**, `1.3-rev1` = 13.0. | `1.3-rev2` |
| `NodeCredentialsName` | `--node-credentials-name` | Username or description of the **Linux credentials record stored in VBR** for root on this node. | `root@pve-node01` |
| `TargetServerName` | `--target-server-name` | Name VBR uses to reach this node for FUSE publishing (`targetServerName`); must resolve **from the VBR server**. Empty = this host's FQDN. | `""` |

## `Proxmox`

| Key | CLI | Description | Default |
|---|---|---|---|
| `ApiHost` / `ApiPort` | `--pve-api-host` / `--pve-api-port` | Proxmox API endpoint. `localhost` when running on the node. | `localhost` / `8006` |
| `Node` | `--pve-node` | Node name as in `/nodes`. Empty = this machine's short hostname. | `""` |
| `MountRoot` | — | Where Veeam FUSE publishing exposes raw disk images. | `/run/media/Veeam.Mount.Disks` |

## `Target`

| Key | CLI | Description | Default |
|---|---|---|---|
| `IsolatedBridge` | `--isolated-bridge` | Bridge for the test VMs; must exist, carry **no IP**. | `vmbr1` |
| `IsolatedVlanTag` | `--isolated-vlan-tag` | VLAN tag for the test NICs, or `null` for an untagged isolated bridge. CP21 enforces bridge **and** tag. | `4000` |
| `OverlayStoragePath` | `--overlay-storage-path` | Node-local, **file-based** path for qcow2 overlays (sub-folder per VMID). | `/var/lib/vz/images/rv-overlays` |
| `VmNamePrefix` | `--vm-name-prefix` | Test VM names `<prefix><source>` lower-cased, `[^a-z0-9-]` → `-`. Also identifies leftovers. | `rv-` |
| `VmIdRangeStart` | `--vmid-range-start` | First VMID for test VMs; 100 ids reserved, existing ids skipped. | `9900` |

## `VmDefaults` / `VmOverrides`

Virtual hardware of the throw-away VM (not derivable from the backup). `VmDefaults` for all, `VmOverrides["<source VM>"]` per VM.

| Key | Meaning | Default | Notes |
|---|---|---|---|
| `Memory` (MB), `Cores`, `Cpu`, `Machine` | `qm create` values | `4096`, `2`, `host`, `q35` | `Cpu: x86-64-v2-AES` if `host` is refused. |
| `Bios` | `seabios` / `ovmf` | `seabios` | UEFI sources need `ovmf`. |
| `EfiStorage` | Storage for `--efidisk0 <storage>:1` | `""` | Required with `ovmf`; `local-lvm` is fine. Secure Boot off (`pre-enrolled-keys=0`). |
| `ScsiHw`, `OsType`, `Agent` | controller, OS type, guest agent channel | `virtio-scsi-pci`, `l26`, `1` | `OsType: win11` for Windows. `Agent: 1` is required for CP22 / GuestExec. |

Tip: mirror `bios`, `ostype`, `machine`, `cores`, `memory` from the source VM's `qm config <vmid>`.

## `Isolation`

| Key | Description | Default |
|---|---|---|
| `SwitchIsolationConfirmed` | `true` once the network team has confirmed the VLAN is neither routed nor trunked elsewhere. Required by CP02 when the bridge has an uplink; recorded in the report. | `false` |

## `Thresholds`

| Key | CLI | Description | Default |
|---|---|---|---|
| `MaxRestorePointAgeHours` | `--max-restore-point-age-hours` | **RPO target** (CP11 `KO` if older). | `30` |
| `MaxBootMinutes` | `--max-boot-minutes` | **RTO target**: publish → overlay → create → start → guest-agent IP (CP13 `WARN`). | `20` |
| `GuestAgentTimeoutMinutes` | `--guest-agent-timeout-minutes` | Max wait for `running` + guest-agent IP (CP20–CP22). | `10` |
| `PublishTimeoutMinutes` | — | Max wait for the Data Integration API session (CP12). | `15` |
| `PollIntervalSeconds` | — | Polling interval. | `15` |

## `AppChecks`

Map **VM name → list of checks**; `"*"` applies to every VM and is merged with the VM list. One **CP30** per check.

### `GuestExec` — recommended

Runs a command **inside the test VM** through the QEMU guest agent (`agent/exec` + `agent/exec-status`). Needs no network path from the node to the isolated VLAN, works for Linux and Windows guests, and can test anything the OS can (services, ports on localhost, HTTP on localhost, database queries with local tools).

| Field | Description | Default |
|---|---|---|
| `Command` | Command line passed to the shell. | required |
| `Shell` | `sh`, `bash`, `powershell`, `cmd`, or an absolute executable. | `sh` |
| `ExpectedExitCode` | Exit code that means success. | `0` |
| `ExpectedOutput` | Optional regex (multiline) that stdout must match. | — |
| `TimeoutSeconds` | Max execution time. | `60` |
| `Label` | Text shown in CP30. | `Type` |

```json
{ "Type": "GuestExec", "Command": "systemctl is-active sshd", "ExpectedOutput": "^active", "Label": "sshd" }
{ "Type": "GuestExec", "Shell": "powershell", "Command": "(Get-Service NTDS).Status", "ExpectedOutput": "Running", "Label": "AD DS" }
{ "Type": "GuestExec", "Command": "curl -sk -o /dev/null -w '%{http_code}' https://localhost/health", "ExpectedOutput": "^200", "Label": "Health" }
{ "Type": "GuestExec", "Shell": "powershell", "Command": "Invoke-Sqlcmd -Query \"SELECT COUNT(*) FROM sys.databases WHERE state_desc='ONLINE'\" | Select -Expand Column1", "ExpectedOutput": "^[1-9]", "Label": "Online DBs" }
```

The guest agent must be running in the guest; on Windows the *QEMU Guest Agent* service and the VirtIO serial driver. Proxmox VE 9 also requires the `VM.GuestAgent.Unrestricted` privilege on the token for `exec`.

### Network checks — from the node

Only meaningful if the host running the script has a route to the isolated network (usually **not** the case, by design). They use the guest-agent IP (CP22).

| Type | Fields | Passes when | Needs |
|---|---|---|---|
| `Tcp` | `Port` | TCP connect OK | — |
| `Http` | `Url` (`{ip}`), `ExpectedStatus` | expected status (TLS not validated) | — |
| `Ldap` | `Port` | anonymous bind OK | `ldap3` |
| `Dns` | `Name`, `RecordType` | records returned by `<ip>` | `dnspython` |
| `Sql` | `Port`, `Query`, `User`, `Password` | query returns a row | `pymssql` |

Missing module → check reported `SKIP` with the module name.

## Secrets

Never in the JSON configuration. Order: `--secrets-file` (JSON, `chmod 600`) → environment (`VBR_USER`, `VBR_PASSWORD`, `PVE_TOKEN_ID`, `PVE_TOKEN_SECRET`) → interactive prompt.

## Report language

`-l en|fr` (or system locale) drives console strings, HTML labels and the `Language` field of the JSON report. CSV headers are technical and identical in both languages.
