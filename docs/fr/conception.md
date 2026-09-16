# Notes de conception

[← Points de contrôle](points-de-controle.md) · [README](../../README.md) · 🇬🇧 [English version](../en/design.md)

## Ce que Veeam 13.1 expose pour Proxmox VE (état septembre 2026)

| Capacité | Console / Web UI | API REST 1.3-rev2 | PowerShell |
|---|---|---|---|
| Jobs de sauvegarde (créer, démarrer, arrêter) | ✔ | démarrer / arrêter, lister | ✖ (réflexion .NET non supportée uniquement) |
| Points de restauration, sauvegardes, sessions, requêtes d'infrastructure | ✔ | ✔ (ajouts 13.1) | ✖ |
| **Entire VM Restore vers Proxmox VE** | ✔ | ✖ (endpoints pour vSphere, Cloud Director, Hyper-V seulement) | ✖ |
| **Instant Recovery vers Proxmox VE** | ✔ (Expérimental en 13.1) | ✖ (`instantRecovery/vSphere`, `hyperV`, Azure, FCD seulement) | ✖ |
| Instant Recovery *d'une sauvegarde Proxmox* vers vSphere / Hyper-V | ✔ | ✔ (`type: OtherPlatform`) | — |
| Réplication de VM (13.1) | ✔ (console seulement) | ✖ | ✖ |
| SureBackup / Virtual Lab | ✖ | ✖ | ✖ |
| **Data Integration API (publication de disques)** — sauvegardes Proxmox VE listées comme prises en charge | ✔ | **✔** `/api/v1/dataIntegration/*` | ✔ `Publish-VBRBackupContent` |

Sources : [REST API Reference 13 — 1.3-rev2](https://helpcenter.veeam.com/references/vbr/13/rest/1.3-rev2/), [What's New 13.1 — REST API](https://helpcenter.veeam.com/docs/vbr/wn/rest_api.html?ver=13), [Disk Publishing — types de sauvegarde pris en charge](https://helpcenter.veeam.com/docs/vbr/userguide/data_integration_api.html), forums R&D Veeam (réponses du Product Management, juillet 2026).

Contrairement au plug-in Nutanix AHV, le plug-in Proxmox VE n'a **aucune référence REST publiée** qui lui soit propre (celle d'AHV est servie sous `/extension/<id>/api/v9`). La Web UI sait restaurer des VM Proxmox : une API d'extension interne existe donc très probablement — mais elle est non documentée et non supportée, et ce projet choisit délibérément de ne pas s'y appuyer.

## Pourquoi démarrer depuis la sauvegarde plutôt que restaurer

SureBackup ne restaure pas non plus les VM : il les exécute depuis la sauvegarde via vPower NFS, vérifie, puis jette. La publication de disques offre la même primitive sur Proxmox VE :

1. **Veeam fait le plus dur** — lit le point de restauration depuis le dépôt (quel que soit son type : bloc, objet, appliance de déduplication, Hardened Repository) et présente chaque disque comme une image brute sur le nœud, en lecture seule, via FUSE. Pas de worker, pas de copie de stockage.
2. **QEMU fait le reste** — un overlay qcow2 avec l'image brute en backing file rend le disque inscriptible pour l'invité tandis que la sauvegarde reste intacte ; `qm create` construit une VM jetable autour, sur le réseau isolé.
3. Tout est défait à la fin : `qm destroy --purge`, overlays supprimés, `unpublish`.

Conséquences :

- **Preuve apportée** : sauvegarde lisible et cohérente, OS démarre, pile réseau opérationnelle, services répondent, RPO tenu, délai de remise en service depuis la sauvegarde mesuré.
- **Non mesuré** : la durée d'un véritable Entire VM Restore vers Proxmox VE (déploiement des workers, injection VirtIO, copie complète vers le stockage cible). En planifier un manuellement par trimestre et conserver la session comme preuve.
- **Performances en lecture** : celles du dépôt à travers FUSE — comparables à un Instant Recovery avant migration. Suffisant pour démarrage + contrôles de services ; ce n'est pas un test de charge.

## Modèle de sécurité

- Les seules cibles d'écriture sont les **overlays** sous `Target.OverlayStoragePath` sur le nœud de vérification. Fichiers de sauvegarde, dépôts et VM de production ne sont jamais ouverts en écriture.
- L'isolement réseau est contrôlé sous deux angles : **structure** (CP02 : bridge sans IP sur le nœud ; un uplink exige une confirmation explicite et consignée que le VLAN n'est pas routé) et **occupants** (CP03 avant, CP21 après — une fuite arrête la VM immédiatement).
- Les VM de test sont reconnaissables de trois façons : préfixe de nom, plage VMID réservée, marqueur de description. CP04 refuse de démarrer s'il en reste d'une exécution précédente (sauf `-Cleanup`).
- Toutes les opérations Veeam s'exécutent sous un rôle VBR standard (Backup Administrator / Restore Operator) ; le SSH vers le nœud n'est nécessaire que parce que `qm` n'accepte les chemins de disque absolus que pour `root@pam`.

## Limites connues / évolutions

- Ordre des disques : les overlays sont attachés `scsi0…N` dans l'ordre de listage des images ; les VM multi-disques dont le disque de boot n'est pas le premier peuvent nécessiter un ajustement de `--boot order` (`New-TestVm`).
- Le matériel virtuel (type de BIOS, type d'OS, mémoire) vient de `VmDefaults` / `VmOverrides`, pas de la sauvegarde. Une version future pourrait lire le `qm config` d'origine via l'API Proxmox quand la VM source existe encore.
- Un nœud de vérification à la fois ; publication séquentielle par VM par conception (attribution non ambiguë des images disque).
- Si Veeam livre un endpoint REST supporté pour l'Entire VM Restore / Instant Recovery vers Proxmox VE, un second mode mesurant le vrai chemin de restauration devra être ajouté à côté de celui-ci — comme pour Nutanix AHV dans le [projet frère](https://github.com/CLahiani/veeam-ahv-recovery-verification).
