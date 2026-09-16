# Installation & prerequisites

[← README](../../README.md) · [User guide →](user-guide.md) · 🇫🇷 [Version française](../fr/installation.md)

## 1. Software

| Component | Requirement |
|---|---|
| PowerShell | **7.2 or later** (`pwsh`) on the probe machine. |
| OpenSSH client | `ssh.exe` in `PATH` (built into Windows 10/11 and Windows Server 2019+). Key-based, non-interactive authentication to the Proxmox node. |
| Veeam Backup & Replication | **13.x** with REST API enabled (port 9419). `Veeam.VbrApiVersion` = `1.3-rev2` for 13.1, `1.3-rev1` for 13.0. Veeam Plug-in for Proxmox VE installed and the Proxmox nodes added to the backup infrastructure. |
| Proxmox VE | **8.2 – 9.x** (versions supported by the Veeam plug-in). One node designated as *verification node*. |
| Source VMs | **QEMU guest agent** installed and enabled (`agent: 1`) — needed for CP22 (IP), CP23 and CP30. |
| `SqlServer` module | Only if `Sql` application checks are defined: `Install-Module SqlServer -Scope CurrentUser`. |
| Probe OS | Windows recommended (`Test-NetConnection`, `Resolve-DnsName` used by Tcp / Ldap / Dns checks). |

## 2. How the pieces fit

```
 probe (PowerShell) ──REST 9419──▶ VBR 13.x ──Data Integration API (SSH, temp agent)──▶ Proxmox node
 probe ──SSH 22 (key)───────────▶ Proxmox node : qemu-img, qm
 probe ──REST 8006 (API token)──▶ Proxmox API : nodes, network, VM status/config, guest agent
 probe ──(2nd NIC on the isolated bridge/VLAN)──▶ test VMs : ping, app checks
```

## 3. Veeam side

### 3.1 Linux credentials record for the node

The Data Integration API deploys a temporary FUSE agent on the target Linux server over SSH. It needs a **credentials record stored in VBR**:

*Veeam console → Menu → Credentials and Passwords → Datacenter Credentials → Add → Linux account* — username `root`, the node's root password (or a key), description e.g. `root@pve-node01`. Elevation is not needed for root.

The script finds that record by **username or description** (`Veeam.NodeCredentialsName`) through `GET /api/v1/credentials?typeFilter=Linux` and passes its ID in the publish request. Checkpoint **CP01** fails if it is not found.

> The Proxmox node is already known to VBR as a *Proxmox VE server* (through the plug-in). The publish request addresses it by name (`targetServerName`) as a plain Linux host — no need to add it a second time as a *Linux server*.

### 3.2 VBR account for the script

A user (or 13.1 custom RBAC role) with **restore permissions**: *Backup Administrator* or *Restore Operator*. The Data Integration API endpoints are documented as available to both.

## 4. Proxmox side

### 4.1 Isolated network — the safety foundation

Create, on the verification node, one of:

| Option | Configuration | CP02 behaviour |
|---|---|---|
| **A. Dedicated bridge without uplink** (recommended when the probe can be a VM on the same node) | `vmbr1` with `bridge_ports none`, **no IP address** on the node. Test VMs and the probe VM attach to it. | `OK` — isolation is structural. |
| **B. Shared bridge + dedicated VLAN tag** | `vmbr1` (VLAN-aware) with an uplink; test VMs get `tag=<VLAN>`. The VLAN **must not** have an L3 interface anywhere and must be pruned from every trunk except the probe's port. | `KO` until `Isolation.SwitchIsolationConfirmed: true` is set — the script cannot verify the physical switch, so the network team's confirmation is recorded in the configuration and shown in the report. |

In both cases the node itself must **not** carry an IP or gateway on the bridge (checked by CP02, blocking). `firewall=1` is set on the test NIC so Proxmox firewall rules can be added on top if desired.

### 4.2 Overlay storage

A **file-based, node-local path** for the qcow2 overlays: `Target.OverlayStoragePath`, e.g. `/var/lib/vz/images/rv-overlays` (directory storage), a ZFS dataset mount point or an NFS mount. Overlays only hold the blocks written by the guest during the test (typically a few hundred MB per VM). The script creates the folder if missing. Block storage (LVM-thin) is **not** suitable for the overlays; it can still be used for the EFI vars disk (`VmDefaults.EfiStorage`).

### 4.3 API token

*Datacenter → Permissions → API Tokens → Add* — user `root@pam` (or a dedicated user), token id e.g. `rv`, **Privilege Separation unchecked** (or grant the token itself the roles below). Note the secret; it is shown once.

Minimum privileges on `/nodes/<node>` and `/vms`: `Sys.Audit`, `VM.Audit`, `VM.Allocate`, `VM.Config.Disk`, `VM.Config.Network`, `VM.Config.Options`, `VM.Config.HWType`, `VM.PowerMgmt`, `VM.Monitor` (guest agent queries). Built-in `PVEVMAdmin` + `PVEAuditor` on `/` is a simple superset.

The token is passed as a `PSCredential`: **UserName** = `root@pam!rv`, **Password** = the secret.

### 4.4 SSH key

`qm create` with **absolute disk paths** (the overlays) is only accepted for `root@pam` — hence root SSH with a key:

```bash
# on the probe
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -C rv-probe
# copy the public key to /root/.ssh/authorized_keys on the node, then test:
ssh -i ~/.ssh/id_ed25519 -o BatchMode=yes root@pve-node01 pveversion
```

Commands executed on the node: `pveversion`, `find <MountRoot>`, `mkdir -p` / `test -w` on the overlay path, `qemu-img create`, `qm create`, `qm start`, `qm stop`, `qm destroy --purge`, `rm -rf <overlay dir>`.

## 5. The probe machine

| Destination | Port | Purpose |
|---|---|---|
| VBR server | 9419/tcp | Restore points, credentials lookup, Data Integration API, sessions |
| Proxmox node | 22/tcp | qemu-img / qm over SSH |
| Proxmox API | 8006/tcp | Node, network, VM state, guest agent |
| Isolated bridge / VLAN | ICMP, app ports | CP23 ping and CP30 application checks |

For the last line the probe needs a **second NIC on the isolated bridge / VLAN** (easiest: the probe is itself a small Windows VM on the verification node with `net1` on `vmbr1[,tag=…]`). Without it the script still works; CP23 and CP30 are `SKIP`.

## 6. Install the script

1. Copy `Test-PveBackupBoot.ps1` and `RecoveryVerification.sample.json` to a folder on the probe, e.g. `C:\Tools\RecoveryVerification\`.
2. `Unblock-File .\Test-PveBackupBoot.ps1` if downloaded.
3. Generate and fill the configuration: `.\Test-PveBackupBoot.ps1 -InitConfig` then edit `RecoveryVerification.json` (or copy the sample). See [Configuration](configuration.md).
4. Dry run — authenticates everywhere and runs pre-flight CP00–CP04, boots nothing:

   ```powershell
   .\Test-PveBackupBoot.ps1 -VmNames SRV-A -WhatIf -Verbose
   ```

## 7. Unattended runs

Store the two secrets in a vault and pass them as credentials:

```powershell
$vbr = Get-Secret -Name RV-VBR      # PSCredential: VBR user / password
$pve = Get-Secret -Name RV-PveToken # PSCredential: "root@pam!rv" / token secret
.\Test-PveBackupBoot.ps1 -VmNames SRV-A,SRV-B -Cleanup -VbrCredential $vbr -PveApiToken $pve
```

## 8. TLS

All REST calls use `-SkipCertificateCheck` (self-signed certificates are the norm on VBR and Proxmox). Remove `SkipCertificateCheck = $true` in `Invoke-Api` and `Connect-Vbr` for strict validation.

## Next step

Read the [User guide](user-guide.md).
