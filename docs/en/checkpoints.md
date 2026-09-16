# Checkpoints reference

[← Configuration](configuration.md) · [Design notes →](design.md) · 🇫🇷 [Version française](../fr/points-de-controle.md)

Every check is a **checkpoint** with status `OK`, `KO`, `WARN` or `SKIP`, present in console, CSV / JSON and HTML. `Value` holds the measured figure for CP11 (hours) and CP13 (minutes). **Blocking** checkpoints stop the run in pre-flight (exit code 2); a `KO` on a VM skips the remaining checks for that VM only.

## Step 0 — Pre-flight (once per run)

| CP | Check | OK | WARN | KO | Blocking |
|---|---|---|---|---|---|
| **CP00** | Authentication: VBR REST (OAuth), Proxmox API (token), SSH to the node (`pveversion`) | All three succeed; detail shows API version and `pveversion` | — | Any failed | ✔ |
| **CP01** | Node exists in the cluster; isolated bridge exists on the node; overlay path exists / writable; VBR Linux credentials record found | All found | — | One missing (`Detail` says which) | ✔ |
| **CP02** | Isolated bridge is **not routed**: no IP / gateway on the node's bridge; bridge with uplink requires `Isolation.SwitchIsolationConfirmed` | Conditions met (detail: `no uplink` or `switch isolation confirmed by configuration`) | — | Bridge carries IP / gateway, or uplink without confirmation | ✔ |
| **CP03** | No foreign VM attached to the isolated bridge (+ tag) | None | — | Non-test VMs listed | — |
| **CP04** | No leftover test VM (name prefix, or VMID range + description marker) and no stale FUSE publish session in VBR | None | Leftovers found **and removed** (`-Cleanup`) | Leftovers without `-Cleanup`, or removal failed | ✔ |

## Step 1 — Boot from backup (per VM)

| CP | Check | OK | WARN | KO | SKIP |
|---|---|---|---|---|---|
| **CP10** | Latest Proxmox VE restore point in VBR (exact name) | Found (creation time) | — | None → rest `SKIP` | — |
| **CP11** | Restore point age ≤ `MaxRestorePointAgeHours` (**RPO**) | Within target | — | Older | — |
| **CP12** | Data Integration API publish session ends `Success` / `Warning` **and** new raw disk images appear under `MountRoot` | `Success`, disks listed | `Warning` | Session `Failed` / timeout, or no disk image → rest `SKIP` | `-WhatIf` |

Between CP12 and Step 2 the script creates overlays and the VM (`qemu-img`, `qm create`, `qm start`); an error there is reported as CP12 `KO` (`launch failed`).

## Step 2 — Verify (per VM)

| CP | Check | OK | WARN | KO | SKIP |
|---|---|---|---|---|---|
| **CP13** | Time from publish start to guest-agent IP ≤ `MaxBootMinutes` (**RTO, boot from backup**) | Within target | Exceeded | — | Not booted |
| **CP20** | Test VM `status = running` | Running | — | Not found / not running | Not booted |
| **CP21** | **Guardrail** — every `netN` on `IsolatedBridge` with `IsolatedVlanTag` | All NICs isolated | No NIC | A NIC elsewhere → **VM stopped immediately** | Not booted |
| **CP22** | IPv4 reported by the QEMU guest agent (non-loopback, non-APIPA) | IP (detail) | Running but no IP | Not running and no IP | Not booted |
| **CP23** | Ping from the probe (`-PingCheck`) | Reply | — | No reply | Off / no IP |
| **CP30** | Application checks, one CP per check (`Application: <Label>`) | Passed | — | Failed (reason) | No IP / no check / `SqlServer` missing / unknown type |

## Step 3 — Cleanup (per VM, always attempted)

| CP | Check | OK | KO | SKIP |
|---|---|---|---|---|
| **CP40** | `qm stop`, `qm destroy --purge`, overlays removed, restore point **unpublished** in VBR | All done (detail: VMID, mount id) | Any step failed (detail lists what to clean manually) | `-Cleanup` off (VM kept, disks stay published) |

## Per-VM result and exit code

| Situation | `Result` | Exit code |
|---|---|---|
| No `KO`, no `WARN` | `OK` | `0` |
| `WARN` only, no `-FailOnWarning` | `OK (warnings)` | `0` |
| `WARN` only, with `-FailOnWarning` | `KO` | `1` |
| Any `KO` | `KO` | `1` |
| Blocking pre-flight failure or fatal error | — | `2` |

## Mapping to audit questions

| Audit question | Evidence |
|---|---|
| Backups exist and respect the RPO | CP10 + CP11 (`Value` hours) |
| Backups are readable / consistent | CP12 |
| Systems can be brought up from backup, within the RTO | CP13 + CP20 (`Value` minutes) |
| Restored systems are reachable | CP22 + CP23 |
| Applications work | CP30 per service |
| Tests never expose production | CP02 + CP03 + CP21 + read-only publishing |
| Test environment is cleaned | CP04 + CP40 |
