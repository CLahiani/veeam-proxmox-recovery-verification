# Changelog

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). / Format basé sur [Keep a Changelog](https://keepachangelog.com/fr/1.1.0/).

## [1.0.0] - 2026-09-16

### Added / Ajouté
- **EN** Initial release: scripted Recovery Verification for Proxmox VE with Veeam Backup & Replication 13.x. Boots VMs directly from their backups using the supported **Veeam Data Integration API** (disk publishing, FUSE mode) to a Proxmox node, qcow2 overlays + `qm create` on an isolated bridge / VLAN, verification through the Proxmox VE API (power, NIC guardrail, guest-agent IP, ping, application checks), cleanup (destroy, overlays, unpublish), HTML / CSV / JSON report. Bilingual EN / FR (`-Language`). Checkpoints CP00–CP40, exit codes 0 / 1 / 2, `-WhatIf`.
- **FR** Version initiale : Recovery Verification scriptée pour Proxmox VE avec Veeam Backup & Replication 13.x. Démarre les VM directement depuis leurs sauvegardes via la **Data Integration API** Veeam (publication de disques, mode FUSE) vers un nœud Proxmox, overlays qcow2 + `qm create` sur un bridge / VLAN isolé, vérification via l'API Proxmox VE (alimentation, garde-fou NIC, IP guest agent, ping, contrôles applicatifs), nettoyage (destroy, overlays, dépublication), rapport HTML / CSV / JSON. Bilingue EN / FR (`-Language`). Points de contrôle CP00–CP40, codes de sortie 0 / 1 / 2, `-WhatIf`.
- **EN/FR** Documentation in English and French (`docs/en`, `docs/fr`).
