# Configuration reference

[← User guide](user-guide.md) · [Checkpoints →](checkpoints.md) · 🇫🇷 [Version française](../fr/configuration.md)

JSON file, `.\RecoveryVerification.json` by default (`-ConfigPath`). Generate with `-InitConfig` or copy `RecoveryVerification.sample.json`.

**Precedence:** built-in defaults ← JSON file ← command-line parameters. `AppChecks` and `VmOverrides`, when present in the file, **replace** the defaults entirely.

> Keep `RecoveryVerification.json` out of source control (it is in `.gitignore`).

## `Veeam`

| Key | CLI override | Description | Default |
|---|---|---|---|
| `VbrServer` | `-VbrServer` | VBR 13.x server (FQDN / IP). | `vbr.example.local` |
| `VbrPort` | `-VbrPort` | REST API port. | `9419` |
| `VbrApiVersion` | `-VbrApiVersion` | `x-api-version` header: **`1.3-rev2` = 13.1**, `1.3-rev1` = 13.0. | `1.3-rev2` |
| `NodeCredentialsName` | `-NodeCredentialsName` | Username or description of the **Linux credentials record stored in VBR** for root on the node. Resolved to its ID via `GET /api/v1/credentials`. | `root@pve-node01` |

## `Proxmox`

| Key | CLI override | Description | Default |
|---|---|---|---|
| `ApiHost` / `ApiPort` | `-PveApiHost` / `-PveApiPort` | Proxmox API endpoint (any cluster node). | `pve-node01.example.local` / `8006` |
| `Node` | `-PveNode` | Node name (as in `/nodes`) hosting the test VMs and receiving the FUSE publish. | `pve-node01` |
| `SshHost` | `-PveSshHost` | SSH endpoint of that node. Also passed to VBR as `targetServerName` for publishing, so it must be resolvable **from the VBR server**. | `pve-node01.example.local` |
| `SshUser` / `SshKeyPath` | `-PveSshUser` / `-PveSshKeyPath` | `root` and the private key on the probe (`~` expands to the profile). | `root` / `~/.ssh/id_ed25519` |
| `MountRoot` | — | Where Veeam FUSE publishing exposes raw disk images on the node. | `/run/media/Veeam.Mount.Disks` |

## `Target`

| Key | CLI override | Description | Default |
|---|---|---|---|
| `IsolatedBridge` | `-IsolatedBridge` | Bridge for the test VMs. Must exist on the node, carry **no IP**. | `vmbr1` |
| `IsolatedVlanTag` | `-IsolatedVlanTag` | VLAN tag added to the test NICs, or `null` for an untagged isolated bridge. CP21 enforces bridge **and** tag. | `4000` |
| `OverlayStoragePath` | `-OverlayStoragePath` | Node-local, **file-based** path for qcow2 overlays (one sub-folder per VMID). | `/var/lib/vz/images/rv-overlays` |
| `VmNamePrefix` | `-VmNamePrefix` | Test VM names `<prefix><source>` lower-cased, non `[a-z0-9-]` replaced by `-`. Also used to recognise leftovers (CP04). | `rv-` |
| `VmIdRangeStart` | `-VmIdRangeStart` | First VMID for test VMs; 100 ids reserved. Existing ids are skipped. | `9900` |

## `VmDefaults` / `VmOverrides`

Virtual hardware of the throw-away VM. `VmDefaults` applies to every VM; `VmOverrides["<source VM name>"]` overrides any key for that VM.

| Key | Meaning | Default | Notes |
|---|---|---|---|
| `Memory` (MB), `Cores`, `Cpu`, `Machine` | `qm create` values | `4096`, `2`, `host`, `q35` | Use `Cpu: x86-64-v2-AES` if `host` is refused. |
| `Bios` | `seabios` or `ovmf` | `seabios` | UEFI source VMs need `ovmf`. |
| `EfiStorage` | Storage for the EFI vars disk (`--efidisk0 <storage>:1`) | `""` | Required when `Bios: ovmf`; block storage (`local-lvm`) is fine. `pre-enrolled-keys=0` (Secure Boot off). |
| `ScsiHw` | SCSI controller | `virtio-scsi-pci` | Disks are attached as `scsi0…N`. |
| `OsType` | `l26`, `win11`, `win10`… | `l26` | Affects QEMU defaults (e.g. HPET, localtime). |
| `Agent` | Enable guest agent channel | `1` | Needed for CP22. |

```json
"VmOverrides": {
  "SRV-WIN01": { "OsType": "win11", "Bios": "ovmf", "EfiStorage": "local-lvm", "Memory": 8192 }
}
```

Tip: read the original VM's `qm config <vmid>` once and mirror `bios`, `ostype`, `machine`, `cores`, `memory`.

## `Isolation`

| Key | Description | Default |
|---|---|---|
| `SwitchIsolationConfirmed` | Set to `true` once the network team has confirmed that `IsolatedVlanTag` is not routed and not trunked anywhere except the probe port. Required by CP02 when the bridge has an uplink. Recorded in the report. | `false` |

## `Thresholds`

| Key | CLI override | Description | Default |
|---|---|---|---|
| `MaxRestorePointAgeHours` | `-MaxRestorePointAgeHours` | **RPO target** (CP11 `KO` if older). | `30` |
| `MaxBootMinutes` | `-MaxBootMinutes` | **RTO target** for publish + overlay + create + start until the guest agent reports an IP (CP13 `WARN` if exceeded). | `20` |
| `GuestAgentTimeoutMinutes` | `-GuestAgentTimeoutMinutes` | Max wait for `running` + guest-agent IP (CP20–CP22). | `10` |
| `PublishTimeoutMinutes` | — | Max wait for the Data Integration API session (CP12). | `15` |
| `PollIntervalSeconds` | — | Polling interval for sessions and VM state. | `15` |

## `AppChecks`

Map **VM name → list of checks**; `"*"` applies to every VM and is merged with the VM-specific list. One **CP30** per check, run **from the probe** against the guest-agent IP.

| Type | Fields | Passes when |
|---|---|---|
| `Tcp` | `Port` | TCP connect succeeds. |
| `Http` | `Url` (with `{ip}`), `ExpectedStatus` (default 200) | GET returns the expected status (certificates not validated, 15 s timeout). |
| `Ldap` | `Port` | TCP open **and** anonymous RootDSE bind succeeds. |
| `Dns` | `Name` | `Resolve-DnsName <Name> -Server <ip>` returns records. |
| `Sql` | `Port`, `Query` | `Invoke-Sqlcmd` returns a result (needs the `SqlServer` module; integrated auth). |

```json
"AppChecks": {
  "*":         [ { "Type": "Tcp", "Port": 22, "Label": "SSH" } ],
  "SRV-AD01":  [ { "Type": "Ldap", "Port": 389, "Label": "LDAP" }, { "Type": "Dns", "Name": "example.local", "Label": "DNS zone" } ],
  "SRV-WEB01": [ { "Type": "Http", "Url": "https://{ip}/health", "ExpectedStatus": 200, "Label": "Health" } ]
}
```

> The test VM is a clone in an isolated network: domain-integrated authentication may not work unless a domain controller is booted in the same run. Prefer credential-less checks for unattended runs.

## Report language

`-Language en|fr` (or system culture) drives console strings, HTML labels and the `Language` field of the JSON report. CSV headers are technical and identical in both languages.
