# Design notes

[← Checkpoints](checkpoints.md) · [README](../../README.md) · 🇫🇷 [Version française](../fr/conception.md)

## What Veeam 13.1 exposes for Proxmox VE (as of September 2026)

| Capability | Console / Web UI | REST API 1.3-rev2 | PowerShell |
|---|---|---|---|
| Backup jobs (create, start, stop) | ✔ | start / stop, list | ✖ (unsupported .NET reflection only) |
| Restore points, backups, sessions, infrastructure queries | ✔ | ✔ (13.1 additions) | ✖ |
| **Entire VM Restore to Proxmox VE** | ✔ | ✖ (endpoints exist for vSphere, Cloud Director, Hyper-V only) | ✖ |
| **Instant Recovery to Proxmox VE** | ✔ (Experimental in 13.1) | ✖ (`instantRecovery/vSphere`, `hyperV`, Azure, FCD only) | ✖ |
| Instant Recovery *of a Proxmox backup* to vSphere / Hyper-V | ✔ | ✔ (`type: OtherPlatform`) | — |
| VM replication (13.1) | ✔ (console only) | ✖ | ✖ |
| SureBackup / Virtual Lab | ✖ | ✖ | ✖ |
| **Data Integration API (disk publishing)** — Proxmox VE backups listed as supported | ✔ | **✔** `/api/v1/dataIntegration/*` | ✔ `Publish-VBRBackupContent` |

Sources: [REST API Reference 13 — 1.3-rev2](https://helpcenter.veeam.com/references/vbr/13/rest/1.3-rev2/), [What's New 13.1 — REST API](https://helpcenter.veeam.com/docs/vbr/wn/rest_api.html?ver=13), [Disk Publishing — supported backup types](https://helpcenter.veeam.com/docs/vbr/userguide/data_integration_api.html), Veeam R&D forums (Product Management answers, July 2026).

Unlike the Nutanix AHV plug-in, the Proxmox VE plug-in has **no published REST reference** of its own (the AHV one lives at `/extension/<id>/api/v9`). The Web UI can restore Proxmox VMs, so an internal extension API almost certainly exists — but it is undocumented and unsupported, and this project deliberately does not rely on it.

## Why boot from backup instead of restoring

SureBackup does not restore VMs either: it runs them from the backup through vPower NFS, verifies, then discards. Disk publishing gives the same primitive on Proxmox VE:

1. **Veeam does the hard part** — reads the restore point from the repository (any type: block, object, dedup appliance, Hardened Repository) and presents each disk as a raw image on the node, read-only, through FUSE. No worker VM, no storage copy.
2. **QEMU does the rest** — a qcow2 overlay with the raw image as backing file makes the disk writable for the guest while the backup stays untouched; `qm create` builds a throw-away VM around it on the isolated network.
3. Everything is undone at the end: `qm destroy --purge`, overlays deleted, `unpublish`.

Consequences:

- **Proof delivered**: backup readable and consistent, OS boots, network stack up, services answer, RPO met, time-to-service from backup measured.
- **Not measured**: the duration of a real Entire VM Restore to Proxmox VE (worker deployment, VirtIO injection, full copy to the target storage). Schedule one manually per quarter and keep the session as evidence.
- **Read performance** is that of the repository through FUSE — comparable to Instant Recovery before migration. Fine for boot + service checks; not a load test.

## Why Python, on the node (v2.0)

v1 was a PowerShell script on a Windows probe that drove the node over SSH. It worked on paper but carried three structural costs: SSH key management and `root@pam` from a second machine; Windows-only cmdlets (`Test-NetConnection`, `Resolve-DnsName`, `Invoke-Sqlcmd`) that do not exist on Linux PowerShell; and a probe NIC on the isolated VLAN for the application checks, while CP02 forbids the node itself from having one.

Running **Python on the Proxmox node** removes all three. Python 3 ships with every node; `qm`, `qemu-img` and the API are local; and the application checks run **inside the guests through the QEMU guest agent** (`GuestExec`), so no machine needs a foot in the isolated network — which is also closer to how SureBackup executes its application test scripts. The whole tool is standard library only; scheduling is a systemd timer. The PowerShell version is kept under `legacy/` for reference and is no longer maintained.

## Safety model

- The only write targets are the **overlays** under `Target.OverlayStoragePath` on the verification node. Backup files, repositories and production VMs are never opened for writing.
- Network isolation is checked from two angles: **structure** (CP02: bridge without IP on the node; uplink requires an explicit, recorded confirmation that the VLAN is not routed) and **occupants** (CP03 before, CP21 after — a leak stops the VM at once).
- Test VMs are recognisable three ways: name prefix, reserved VMID range, description marker. CP04 refuses to start if any remain from a previous run (unless `--cleanup`).
- All Veeam operations run under a standard VBR role (Backup Administrator / Restore Operator). The script runs as root on the node because `qm` accepts absolute disk paths for `root@pam` alone and FUSE publishing lands under `/run/media`. Secrets come from a `chmod 600` file or the environment, never from the JSON configuration.

## Known limitations / future work

- Disk order: overlays are attached `scsi0…N` in the order the images are listed; multi-disk VMs whose boot disk is not first may need `--boot order` adjustment (`create_test_vm`).
- Virtual hardware (BIOS type, OS type, memory) comes from `VmDefaults` / `VmOverrides`, not from the backup. A future version could read the original `qm config` through the Proxmox API when the source VM still exists.
- One verification node at a time; publishing is sequential per VM by design (unambiguous attribution of disk images).
- If Veeam ships a supported REST endpoint for Entire VM Restore / Instant Recovery to Proxmox VE, a second mode measuring the real restore path should be added alongside this one — as done for Nutanix AHV in the [sister project](https://github.com/CLahiani/veeam-ahv-recovery-verification).
