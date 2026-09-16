# User guide

[← Installation](installation.md) · [Configuration →](configuration.md) · 🇫🇷 [Version française](../fr/guide-utilisateur.md)

## How a run works

```
Step 0  PRE-FLIGHT   qm / qemu-img present; VBR, Proxmox API OK. Node / bridge / overlay path /
                     VBR Linux credentials exist, bridge is isolated, no foreign VM, no leftovers
                     (test VMs or stale publish sessions).                       → CP00–CP04
Step 1  BOOT         Per VM, sequentially: latest restore point, RPO, publish disks to this node
                     (Data Integration API, FUSE), wait, attribute the new disk images, qcow2
                     overlays, qm create on the isolated network, qm start.       → CP10–CP12
Step 2  VERIFY       Per VM: wait for guest-agent IP (RTO), running, NIC guardrail, IP, ping,
                     application checks (GuestExec inside the guest, or network checks). → CP13–CP30
Step 3  CLEANUP      qm stop / destroy --purge, remove overlays, unpublish (--cleanup).  → CP40
Step 4  REPORT       HTML + CSV + JSON + log, exit code.
```

## Command line

```
pve_backup_boot.py -v NAME [-v NAME ...] [-c CONFIG] [-l en|fr] [--cleanup] [--ping-check] [--fail-on-warning]
                   [--report-dir DIR] [--secrets-file FILE] [--verify-tls] [-n|--dry-run] [--debug]
                   [configuration overrides]
pve_backup_boot.py --init-config [--force] [-c CONFIG]
```

| Option | Description | Default |
|---|---|---|
| `-v`, `--vm NAME` | Source VM name **exactly as shown in Veeam**. Repeat for several VMs. | required |
| `-c`, `--config` | JSON configuration file. | `./RecoveryVerification.json` |
| `--init-config` / `--force` | Write the configuration template (overwrite with `--force`) and exit. | — |
| `-l`, `--language` | `en` or `fr` for console and reports. | system locale |
| `--cleanup` | Destroy test VMs, remove overlays and **unpublish** at the end; also remove leftovers in pre-flight. Without it CP40 is `SKIP` and **disks stay published**. | off |
| `--ping-check` | Enable CP23 — ping from **this host**, which normally has no route to the isolated network. Prefer `GuestExec` checks. | off |
| `--fail-on-warning` | Count `WARN` as failure for the exit code. | off |
| `--report-dir` | Output folder for reports and log. | `./Reports` |
| `--secrets-file` | JSON with `VBR_USER`, `VBR_PASSWORD`, `PVE_TOKEN_ID`, `PVE_TOKEN_SECRET` (chmod 600). Env vars and prompt are the fallbacks. | — |
| `--verify-tls` | Validate VBR / Proxmox certificates. | off |
| `-n`, `--dry-run` | Pre-flight runs for real; publish / create / start / destroy are only displayed. | — |
| `--debug` | Echo the debug log (REST calls, shell commands) to the console. | — |

Configuration overrides: `--vbr-server --vbr-port --vbr-api-version --node-credentials-name --target-server-name --pve-api-host --pve-api-port --pve-node --isolated-bridge --isolated-vlan-tag --overlay-storage-path --vm-name-prefix --vmid-range-start --max-restore-point-age-hours --max-boot-minutes --guest-agent-timeout-minutes`.

## Typical scenarios

```bash
# first run - validate the setup, nothing is booted
./pve_backup_boot.py -v SRV-FILE01 --secrets-file /root/.veeam-rv-secrets.json --dry-run --debug

# boot one VM and keep it for manual inspection (open its console in the Proxmox UI; rerun with --cleanup afterwards!)
./pve_backup_boot.py -v SRV-AD01 --secrets-file /root/.veeam-rv-secrets.json

# full automated verification
./pve_backup_boot.py -v SRV-AD01 -v SRV-FILE01 -v SRV-WEB01 --cleanup --fail-on-warning --secrets-file /root/.veeam-rv-secrets.json
echo $?      # 0 OK, 1 checkpoint failed, 2 pre-flight / fatal

# daily rotation of 3 VMs from vms.txt (see deploy/rotate-sample.sh) - scheduled by the systemd timer
```

### Windows / UEFI VMs

Set the virtual hardware in `VmOverrides` (`OsType: win11`, `Bios: ovmf` + `EfiStorage`, memory). Use `GuestExec` with `"Shell": "powershell"` for the checks — commands run inside the guest, no network path needed.

## Reading the output

```
  [CP02] OK   -                Isolated bridge / VLAN is non-routed - bridge vmbr1 tag 4000: no IP, no uplink
  [CP12] OK   SRV-AD01         Disk publishing completed - 2 disk(s): disk-0.raw, disk-1.raw
  [CP13] WARN SRV-AD01         Time to boot <= 20 min - 23.4 min - RTO target exceeded
  [CP30] OK   SRV-AD01         Application: AD DS, DNS, KDC running - exit 0: 0
```

| File in `--report-dir` | Content |
|---|---|
| `RecoveryVerification-<RunId>.html` | Banner, KPIs, summary per VM, checkpoint table. Self-contained. |
| `RecoveryVerification-<RunId>.csv` | One row per checkpoint, `;`-delimited. |
| `RecoveryVerification-<RunId>.json` | RunId, `Platform: ProxmoxVE`, `Method: DataIntegrationApi+QemuOverlay`, target, thresholds, summary, checkpoints. |
| `RecoveryVerification-<RunId>.log` | Debug log: REST calls, shell commands, tracebacks. |

Exit codes: `0` all OK · `1` at least one `KO` (or `WARN` with `--fail-on-warning`) · `2` blocking pre-flight or fatal error (reports still produced).

## Safety guardrails

- **CP02 (blocking)** — bridge without IP / gateway on the node; an uplink requires `Isolation.SwitchIsolationConfirmed: true`.
- **CP03** — non-test VMs attached to the isolated bridge / VLAN are reported.
- **CP04 (blocking)** — leftover test VMs (name prefix, or VMID range + description marker) and stale FUSE publish sessions are removed with `--cleanup`, otherwise the run stops.
- **CP21 (guardrail)** — a test VM with a NIC outside the isolated bridge / VLAN is **stopped immediately**.
- Published disks are read-only (Veeam FUSE); guest writes go to local qcow2 overlays deleted at cleanup. Backups and production VMs are never written.
- Test VMs use a dedicated **VMID range** and a `Veeam Recovery Verification` description marker.

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| CP00 KO `required tool not found` | Not running on a Proxmox node, or `PATH` stripped (systemd): use absolute `/usr/bin/python3`, keep default `PATH`. |
| CP00 KO `HTTP 401` on VBR | Wrong credentials or `VbrApiVersion` (`1.3-rev2` for 13.1). |
| CP00 KO `HTTP 401` on Proxmox | `PVE_TOKEN_ID` must be `user@realm!tokenid`; check *Privilege Separation* and token expiry. |
| CP01 KO `no Linux credentials named …` | Create the record in VBR (*Credentials → Add → Linux account*), set `Veeam.NodeCredentialsName`. |
| CP02 KO `bridge carries IP` | The node has an address on the bridge — use a bridge without IP. |
| CP02 KO `SwitchIsolationConfirmed=true required` | Bridge with uplink: get the network team's confirmation, then set the flag. |
| CP04 KO `leftover(s)` | Previous run without `--cleanup`. Rerun with `--cleanup` or clean manually (`qm destroy`, VBR *Published disks → Unpublish*). |
| CP10 KO `no Proxmox VE restore point` | Exact Veeam name required; VM must be in a Proxmox backup job with a restore point. |
| CP12 KO `status = Failed …` | VBR could not deploy its FUSE agent: SSH from the **VBR server** to the node blocked, wrong credentials record, `TargetServerName` not resolvable from VBR. See *History → Restore* in the Veeam console. |
| CP12 KO `no new disk image found` | Published elsewhere: `find /run/media -maxdepth 3` and set `Proxmox.MountRoot`. |
| CP12 KO after `qm create` | Read the `qm` error in the log: `EfiStorage` missing for `ovmf`, unsupported `Cpu` / `Machine`. |
| CP22 WARN `no IP` | Guest agent missing / not running in the backup, or OS still booting → raise `GuestAgentTimeoutMinutes`. |
| CP30 SKIP `guest agent not responding` | Guest agent not started yet or not installed. `GuestExec` also needs `VM.GuestAgent.Unrestricted` (PVE 9). |
| CP30 SKIP `python module … missing` | Network check type needing `dnspython` / `ldap3` / `pymssql` — install it, or switch to `GuestExec`. |
| CP40 KO | Destroy or unpublish failed — the detail lists the VMID and mount id to clean manually. |
| Bootloop / no disk found | Overlays are attached `scsi0…N` in publish order; multi-disk VMs whose boot disk is not first: adjust `--boot order` in `create_test_vm`. |
