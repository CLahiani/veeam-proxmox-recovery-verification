# Installation & prerequisites

[← README](../../README.md) · [User guide →](user-guide.md) · 🇫🇷 [Version française](../fr/installation.md)

The script runs **on the Proxmox VE node** that will host the test VMs (as root). Veeam publishes the backup disks to that same node, `qm` / `qemu-img` are local, the Proxmox API is local — no SSH, no Windows probe.

## 1. Software

| Component | Requirement |
|---|---|
| Proxmox VE | **8.2 – 9.x** (versions supported by the Veeam plug-in). Python 3.9+ is already there (Debian 12/13). `qm`, `qemu-img`, `ping` present by default. |
| Python modules | **None for the core** (standard library). Optional, only for network checks run from the node: `dnspython`, `ldap3`, `pymssql` (`pip install -r requirements.txt` or `apt install python3-dnspython python3-ldap3 python3-pymssql`). |
| Veeam Backup & Replication | **13.x**, REST API on 9419. `Veeam.VbrApiVersion` = `1.3-rev2` (13.1) / `1.3-rev1` (13.0). Veeam Plug-in for Proxmox VE installed, nodes added to the backup infrastructure, at least one successful backup of the VMs to verify. |
| Source VMs | **QEMU guest agent** installed and enabled (`agent: 1`) — required for CP22 (IP) and for `GuestExec` application checks. |

## 2. How the pieces fit

```
 PVE node ── python3 pve_backup_boot.py
   │  REST 9419 ─▶ VBR 13.x : restore points, credentials lookup, Data Integration API (publish / unpublish), sessions
   │  (VBR ─SSH 22─▶ this node : deploys its temporary FUSE agent, publishes raw disks under /run/media/Veeam.Mount.Disks)
   │  local        : qemu-img create (overlays), qm create / start / stop / destroy
   │  REST 8006 ─▶ Proxmox API (localhost, token) : node, network, VM status/config, guest agent (IP, exec)
   └─ test VMs on <isolated bridge>[,tag=<VLAN>] ; application checks executed INSIDE the guests via the guest agent
```

## 3. Veeam side

### 3.1 Linux credentials record for the node

The Data Integration API deploys a temporary FUSE agent on the target Linux server over SSH **from the VBR server**. It needs a credentials record stored in VBR:

*Veeam console → Menu → Credentials and Passwords → Datacenter Credentials → Add → Linux account* — username `root`, the node's root password (or private key), description e.g. `root@pve-node01`.

The script resolves it by **username or description** (`Veeam.NodeCredentialsName`) via `GET /api/v1/credentials?typeFilter=Linux` and passes its ID in the publish request (CP01 fails if not found). The node is already known to VBR as a *Proxmox VE server*; the publish request addresses it by name (`Veeam.TargetServerName`, default: this host's FQDN) as a plain Linux host — no need to add it a second time.

Firewall: the **VBR server must reach the node on 22/tcp** (SSH) and the ports used by the FUSE agent — see *Ports* in the VBR User Guide (Disk Publishing).

### 3.2 VBR account for the script

*Backup Administrator* or *Restore Operator* (or a 13.1 custom role with restore permissions). Passed as `VBR_USER` / `VBR_PASSWORD` (environment, secrets file or prompt).

## 4. Proxmox side

### 4.1 Isolated network — the safety foundation

| Option | Configuration | CP02 behaviour |
|---|---|---|
| **A. Dedicated bridge without uplink** | `vmbr1`, `bridge_ports none`, **no IP address** on the node. | `OK` — isolation is structural. |
| **B. Shared bridge + dedicated VLAN tag** | `vmbr1` (VLAN-aware) with uplink; test VMs get `tag=<VLAN>`. The VLAN **must not** have an L3 interface anywhere and must be pruned from every trunk. | `KO` until `Isolation.SwitchIsolationConfirmed: true` — the script cannot see the physical switch; the network team's confirmation is recorded in the configuration and shown in the report. |

In both cases the node must **not** carry an IP or gateway on the bridge (CP02, blocking). Because application checks run **inside the guests** through the guest agent, the node needs no access to the isolated network at all — that is the point of running on the node.

### 4.2 Overlay storage

`Target.OverlayStoragePath`: a **file-based, node-local** path for the qcow2 overlays (directory storage such as `/var/lib/vz/images/rv-overlays`, a ZFS dataset, an NFS mount). Overlays hold only the blocks written during the test. Created automatically if missing. LVM-thin is not suitable for overlays but fine for the EFI vars disk (`VmDefaults.EfiStorage`).

### 4.3 API token

*Datacenter → Permissions → API Tokens → Add*: user `root@pam` (or a dedicated user), token id e.g. `rv`, *Privilege Separation* unchecked (or grant the token the roles below). Minimum privileges on `/nodes/<node>` and `/vms`: `Sys.Audit`, `VM.Audit`, `VM.Allocate`, `VM.Config.*`, `VM.PowerMgmt`, `VM.Monitor`, `VM.GuestAgent.Audit` and `VM.GuestAgent.Unrestricted` (PVE 9, for `GuestExec`). `PVEVMAdmin` + `PVEAuditor` on `/` is a simple superset.

Passed as `PVE_TOKEN_ID` = `root@pam!rv` and `PVE_TOKEN_SECRET`.

### 4.4 Why root

`qm create` with **absolute disk paths** (the overlays) is only accepted for `root@pam`, and FUSE publishing lands under `/run/media`. Run the script as root on the node (systemd unit `User=root`).

## 5. Install

```bash
mkdir -p /opt/veeam-recovery-verification /var/lib/veeam-recovery-verification/reports
cd /opt/veeam-recovery-verification
# copy pve_backup_boot.py, RecoveryVerification.sample.json, deploy/ here (git clone or scp)
chmod +x pve_backup_boot.py deploy/rotate-sample.sh
./pve_backup_boot.py --init-config              # writes RecoveryVerification.json - edit it (see Configuration)

cat > /root/.veeam-rv-secrets.json <<'EOF'
{ "VBR_USER": "svc-rv@vsphere.local", "VBR_PASSWORD": "…", "PVE_TOKEN_ID": "root@pam!rv", "PVE_TOKEN_SECRET": "…" }
EOF
chmod 600 /root/.veeam-rv-secrets.json

./pve_backup_boot.py -v SRV-A --secrets-file /root/.veeam-rv-secrets.json --dry-run --debug   # pre-flight CP00-CP04 only
```

Secrets are read from `--secrets-file`, then environment variables (`VBR_USER`, `VBR_PASSWORD`, `PVE_TOKEN_ID`, `PVE_TOKEN_SECRET`), then interactive prompt.

## 6. Schedule (systemd)

```bash
cp deploy/veeam-recovery-verification.service deploy/veeam-recovery-verification.timer /etc/systemd/system/
# edit ExecStart (VM list or deploy/rotate-sample.sh + vms.txt), then:
systemctl daemon-reload && systemctl enable --now veeam-recovery-verification.timer
systemctl list-timers veeam-recovery-verification.timer ; journalctl -u veeam-recovery-verification.service
```

The unit declares `SuccessExitStatus=1 2` so a failed verification does not mark the unit failed (the result lives in the reports and the exit code in the journal). Remove it if you prefer systemd to flag failures.

## 7. TLS

REST calls skip certificate validation by default (self-signed VBR / Proxmox). Add `--verify-tls` once trusted certificates are in place.

## Next step

Read the [User guide](user-guide.md).
