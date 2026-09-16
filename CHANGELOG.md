# Changelog

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). / Format basé sur [Keep a Changelog](https://keepachangelog.com/fr/1.1.0/).

## [2.0.1] - 2026-09-16

### Fixed / Corrigé
- **EN** RTO measurement: booted VMs are now polled round-robin (`poll_ready`) during and after publishing, so each VM's time-to-IP is its own, not inflated by the publishing of later VMs. `examples/` added (reports on fake data); `.gitattributes` for GitHub language statistics.
- **FR** Mesure du RTO : les VM démarrées sont désormais interrogées en tourniquet (`poll_ready`) pendant et après la publication, le délai jusqu'à l'IP de chaque VM est le sien et non gonflé par la publication des VM suivantes. Ajout de `examples/` (rapports sur données fictives) ; `.gitattributes` pour les statistiques de langage GitHub.

## [2.0.0] - 2026-09-16

### Changed / Modifié
- **EN** Rewritten in **Python 3** (`pve_backup_boot.py`, standard library only) and designed to **run on the Proxmox VE node** as root: no Windows probe, no SSH layer, `qm` / `qemu-img` / Proxmox API local. New **`GuestExec` check type** runs application tests *inside* the test VM through the QEMU guest agent (`agent/exec`), so no machine needs a NIC on the isolated VLAN; `Tcp` / `Http` / `Ldap` / `Dns` / `Sql` kept as optional network checks (`dnspython`, `ldap3`, `pymssql`). Secrets via `--secrets-file` (chmod 600), environment variables or prompt — never in the JSON. CLI: `-v/--vm`, `--cleanup`, `--dry-run`, `--ping-check`, `--fail-on-warning`, `-l en|fr`, `--verify-tls`, `--debug`, `--init-config`. `deploy/` adds a systemd service + timer and a daily rotation helper. Same checkpoints CP00–CP40, same HTML / CSV / JSON reports, same exit codes.
- **FR** Réécriture en **Python 3** (`pve_backup_boot.py`, bibliothèque standard uniquement), conçue pour **s'exécuter sur le nœud Proxmox VE** en root : plus de sonde Windows, plus de couche SSH, `qm` / `qemu-img` / API Proxmox en local. Nouveau **type de contrôle `GuestExec`** exécutant les tests applicatifs *dans* la VM de test via le QEMU guest agent (`agent/exec`) : aucune machine n'a besoin d'une NIC sur le VLAN isolé ; `Tcp` / `Http` / `Ldap` / `Dns` / `Sql` conservés comme contrôles réseau optionnels (`dnspython`, `ldap3`, `pymssql`). Secrets via `--secrets-file` (chmod 600), variables d'environnement ou saisie — jamais dans le JSON. CLI : `-v/--vm`, `--cleanup`, `--dry-run`, `--ping-check`, `--fail-on-warning`, `-l en|fr`, `--verify-tls`, `--debug`, `--init-config`. `deploy/` ajoute un service + timer systemd et un script de rotation quotidienne. Mêmes points de contrôle CP00–CP40, mêmes rapports HTML / CSV / JSON, mêmes codes de sortie.
- **EN/FR** Configuration: `Proxmox.Ssh*` removed; `Proxmox.ApiHost` defaults to `localhost`, `Proxmox.Node` and `Veeam.TargetServerName` default to this host. / Configuration : `Proxmox.Ssh*` supprimé ; `Proxmox.ApiHost` par défaut `localhost`, `Proxmox.Node` et `Veeam.TargetServerName` par défaut = cet hôte.

### Deprecated / Déprécié
- **EN/FR** The v1 PowerShell script moves to `legacy/` and is no longer maintained. / Le script PowerShell v1 passe dans `legacy/` et n'est plus maintenu.

## [1.0.0] - 2026-09-16

### Added / Ajouté
- **EN** Initial release: scripted Recovery Verification for Proxmox VE with Veeam Backup & Replication 13.x. Boots VMs directly from their backups using the supported **Veeam Data Integration API** (disk publishing, FUSE mode) to a Proxmox node, qcow2 overlays + `qm create` on an isolated bridge / VLAN, verification through the Proxmox VE API (power, NIC guardrail, guest-agent IP, ping, application checks), cleanup (destroy, overlays, unpublish), HTML / CSV / JSON report. Bilingual EN / FR (`-Language`). Checkpoints CP00–CP40, exit codes 0 / 1 / 2, `-WhatIf`.
- **FR** Version initiale : Recovery Verification scriptée pour Proxmox VE avec Veeam Backup & Replication 13.x. Démarre les VM directement depuis leurs sauvegardes via la **Data Integration API** Veeam (publication de disques, mode FUSE) vers un nœud Proxmox, overlays qcow2 + `qm create` sur un bridge / VLAN isolé, vérification via l'API Proxmox VE (alimentation, garde-fou NIC, IP guest agent, ping, contrôles applicatifs), nettoyage (destroy, overlays, dépublication), rapport HTML / CSV / JSON. Bilingue EN / FR (`-Language`). Points de contrôle CP00–CP40, codes de sortie 0 / 1 / 2, `-WhatIf`.
- **EN/FR** Documentation in English and French (`docs/en`, `docs/fr`).
