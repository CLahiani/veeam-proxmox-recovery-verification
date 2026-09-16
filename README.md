# Recovery Verification for Proxmox VE — Veeam Backup & Replication 13.x

[🇬🇧 English](#english) · [🇫🇷 Français](#français)

![PowerShell 7.2+](https://img.shields.io/badge/PowerShell-7.2%2B-5391FE?logo=powershell&logoColor=white)
![License MIT](https://img.shields.io/badge/License-MIT-green)
![Platform Proxmox VE](https://img.shields.io/badge/Platform-Proxmox%20VE%208.2%2B-E57000?logo=proxmox&logoColor=white)
![Veeam 13.x](https://img.shields.io/badge/Veeam-13.x-00B336)

---

## English

**SureBackup / Virtual Lab is not available for Proxmox VE**, and Veeam Backup & Replication 13.x exposes neither a REST endpoint nor a PowerShell cmdlet to start an Entire VM Restore or an Instant Recovery *to* Proxmox VE. This script fills the gap with **supported, documented APIs only**, and does it the way SureBackup itself works: it **boots the VM directly from the backup** instead of restoring it.

```
Veeam Data Integration API ──publish (FUSE)──▶ Proxmox node: /run/media/Veeam.Mount.Disks/<raw disks, read-only>
                                                      │ qemu-img create -b <raw> overlay.qcow2   (writes go to the overlay)
                                                      │ qm create … --net0 bridge=<isolated>,tag=<VLAN> ; qm start
Proxmox VE API ◀──verify── running? NICs isolated? IP (guest agent)? ping? services?
Cleanup ──▶ qm destroy, rm overlays, unpublish        Report ──▶ HTML / CSV / JSON
```

### What it proves

| Question | Checkpoint |
|---|---|
| Are the backups recent enough? | CP10, CP11 — restore point found, age ≤ RPO target |
| Are the backups readable and consistent? | CP12 — disk publishing succeeds, disk images present |
| Does the OS boot, and how fast can it be brought up from backup? | CP13, CP20 — time to boot ≤ RTO target, VM running |
| Does it get on the network? | CP22, CP23 — IP reported by the QEMU guest agent, ping |
| Do the applications answer? | CP30 — TCP / HTTP / LDAP / DNS / SQL checks per VM |
| Is production safe? | CP02, CP03, CP21 — isolated bridge / VLAN enforced before, during and after |
| Is the environment left clean? | CP04, CP40 — no leftovers, test VMs destroyed, disks unpublished |

What it does **not** measure: the duration of an Entire VM Restore to Proxmox VE (workers, storage copy). Run one manually per quarter for that figure.

### Quick start

```powershell
.\Test-PveBackupBoot.ps1 -InitConfig                      # 1. template → edit RecoveryVerification.json
.\Test-PveBackupBoot.ps1 -VmNames SRV-AD01 -Cleanup -WhatIf  # 2. pre-flight only, nothing is booted
.\Test-PveBackupBoot.ps1 -VmNames SRV-AD01,SRV-FILE01 -PingCheck -Cleanup -Language en   # 3. real run
# 4. open the HTML report in .\Reports\
```

Exit code: `0` all checkpoints OK · `1` at least one checkpoint failed · `2` blocking pre-flight error.

### Documentation

- [Installation & prerequisites](docs/en/installation.md) — VBR credentials record, Proxmox API token, SSH key, isolated bridge / VLAN, overlay storage
- [User guide](docs/en/user-guide.md) — parameters, scenarios, reading the output, troubleshooting
- [Configuration reference](docs/en/configuration.md)
- [Checkpoints reference](docs/en/checkpoints.md)
- [Design notes](docs/en/design.md) — why disk publishing, what Veeam 13.1 does and does not expose for Proxmox VE

### Repository content

| File | Purpose |
|---|---|
| `Test-PveBackupBoot.ps1` | The script (single file; `SqlServer` module only for SQL checks) |
| `RecoveryVerification.sample.json` | Sample configuration to copy as `RecoveryVerification.json` |
| `docs/en/`, `docs/fr/` | Documentation in English and French |

### Disclaimer

Illustrative example, provided **without warranty**. Validate in a test environment first. Lines depending on API response field names are tagged `# [API]`. This is not an official Veeam product. Sister project for Nutanix AHV: [veeam-ahv-recovery-verification](https://github.com/CLahiani/veeam-ahv-recovery-verification).

---

## Français

**SureBackup / Virtual Lab n'est pas disponible pour Proxmox VE**, et Veeam Backup & Replication 13.x n'expose ni endpoint REST ni cmdlet PowerShell pour lancer un Entire VM Restore ou un Instant Recovery *vers* Proxmox VE. Ce script comble le manque avec **uniquement des API supportées et documentées**, et le fait comme SureBackup lui-même : il **démarre la VM directement depuis la sauvegarde** au lieu de la restaurer.

```
Data Integration API Veeam ──publication (FUSE)──▶ nœud Proxmox : /run/media/Veeam.Mount.Disks/<disques bruts, lecture seule>
                                                          │ qemu-img create -b <brut> overlay.qcow2   (les écritures vont dans l'overlay)
                                                          │ qm create … --net0 bridge=<isolé>,tag=<VLAN> ; qm start
API Proxmox VE ◀──vérification── démarrée ? NIC isolées ? IP (guest agent) ? ping ? services ?
Nettoyage ──▶ qm destroy, rm overlays, dépublication        Rapport ──▶ HTML / CSV / JSON
```

### Ce que le script démontre

| Question | Point de contrôle |
|---|---|
| Les sauvegardes sont-elles assez récentes ? | CP10, CP11 — point de restauration trouvé, âge ≤ RPO cible |
| Sont-elles lisibles et cohérentes ? | CP12 — publication des disques réussie, images présentes |
| L'OS démarre-t-il, et en combien de temps depuis la sauvegarde ? | CP13, CP20 — délai de démarrage ≤ RTO cible, VM démarrée |
| Obtient-elle une IP ? | CP22, CP23 — IP remontée par le QEMU guest agent, ping |
| Les applications répondent-elles ? | CP30 — contrôles TCP / HTTP / LDAP / DNS / SQL par VM |
| La production est-elle protégée ? | CP02, CP03, CP21 — bridge / VLAN isolé vérifié avant, pendant et après |
| L'environnement est-il laissé propre ? | CP04, CP40 — aucun résidu, VM détruites, disques dépubliés |

Ce que le script ne mesure **pas** : la durée d'un Entire VM Restore vers Proxmox VE (workers, copie du stockage). En faire un manuellement par trimestre pour ce chiffre.

### Démarrage rapide

```powershell
.\Test-PveBackupBoot.ps1 -InitConfig                      # 1. modèle → renseigner RecoveryVerification.json
.\Test-PveBackupBoot.ps1 -VmNames SRV-AD01 -Cleanup -WhatIf  # 2. pré-vol seul, rien n'est démarré
.\Test-PveBackupBoot.ps1 -VmNames SRV-AD01,SRV-FILE01 -PingCheck -Cleanup -Language fr   # 3. exécution réelle
# 4. ouvrir le rapport HTML dans .\Reports\
```

Code de sortie : `0` tous les points de contrôle OK · `1` au moins un point de contrôle en échec · `2` erreur bloquante en pré-vol.

### Documentation

- [Installation et prérequis](docs/fr/installation.md) — identifiants VBR, jeton API Proxmox, clé SSH, bridge / VLAN isolé, stockage overlay
- [Guide utilisateur](docs/fr/guide-utilisateur.md) — paramètres, scénarios, lecture des résultats, dépannage
- [Référence de configuration](docs/fr/configuration.md)
- [Référence des points de contrôle](docs/fr/points-de-controle.md)
- [Notes de conception](docs/fr/conception.md) — pourquoi la publication de disques, ce que Veeam 13.1 expose ou non pour Proxmox VE

### Contenu du dépôt

| Fichier | Rôle |
|---|---|
| `Test-PveBackupBoot.ps1` | Le script (fichier unique ; module `SqlServer` uniquement pour les contrôles SQL) |
| `RecoveryVerification.sample.json` | Configuration exemple à copier en `RecoveryVerification.json` |
| `docs/en/`, `docs/fr/` | Documentation en anglais et en français |

### Avertissement

Exemple illustratif, fourni **sans garantie**. À valider en environnement de recette avant toute utilisation. Les lignes dépendant des noms de champs des réponses d'API sont marquées `# [API]`. Ceci n'est pas un produit officiel Veeam. Projet frère pour Nutanix AHV : [veeam-ahv-recovery-verification](https://github.com/CLahiani/veeam-ahv-recovery-verification).

---

## References / Références

- [Veeam Backup & Replication 13 REST API (1.3-rev2) — Data Integration API](https://helpcenter.veeam.com/references/vbr/13/rest/1.3-rev2/tag/Data-Integration-API/)
- [VBR User Guide — Disk Publishing (supported backup types)](https://helpcenter.veeam.com/docs/vbr/userguide/data_integration_api.html)
- [VBR User Guide — Proxmox VE, considerations and limitations](https://helpcenter.veeam.com/docs/vbr/userguide/pve_limitations.html)
- [Proxmox VE API viewer](https://pve.proxmox.com/pve-docs/api-viewer/) · [qm(1)](https://pve.proxmox.com/pve-docs/qm.1.html)

## License / Licence

[MIT](LICENSE)
