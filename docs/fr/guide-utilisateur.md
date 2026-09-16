# Guide utilisateur

[← Installation](installation.md) · [Configuration →](configuration.md) · 🇬🇧 [English version](../en/user-guide.md)

## Déroulement d'une exécution

```
Étape 0  PRÉ-VOL        Authentification VBR, API Proxmox, SSH. Nœud / bridge / chemin overlay /
                        identifiants Linux VBR présents, bridge isolé, aucune VM étrangère, aucun
                        résidu (VM de test ou publication FUSE périmée).           → CP00–CP04
Étape 1  DÉMARRAGE      Par VM, séquentiellement : dernier point de restauration, contrôle RPO,
                        publication des disques vers le nœud (Data Integration API, FUSE),
                        attente, attribution des nouvelles images, overlays qcow2, qm create sur
                        le réseau isolé, qm start.                                → CP10–CP12
Étape 2  VÉRIFICATION   Par VM : attente de l'IP guest agent (RTO), état running, garde-fou NIC,
                        IP, ping, contrôles applicatifs.                         → CP13–CP30
Étape 3  NETTOYAGE      qm stop / destroy --purge, suppression overlays, dépublication (-Cleanup). → CP40
Étape 4  RAPPORT        HTML + CSV + JSON + journal, code de sortie.
```

La publication est séquentielle (une VM à la fois) afin d'attribuer sans ambiguïté les images disque qui apparaissent sous `/run/media/Veeam.Mount.Disks` ; la vérification de toutes les VM se fait ensuite à l'étape 2 pendant qu'elles démarrent en parallèle.

## Ligne de commande

```powershell
.\Test-PveBackupBoot.ps1 [-VmNames] <string[]>
    [-ConfigPath <string>] [-Language en|fr]
    [-PingCheck] [-Cleanup] [-FailOnWarning] [-ReportDir <string>]
    [-VbrCredential <PSCredential>] [-PveApiToken <PSCredential>]
    [<surcharges de configuration>] [-WhatIf] [-Verbose]

.\Test-PveBackupBoot.ps1 -InitConfig [-ConfigPath <string>]
```

### Paramètres principaux

| Paramètre | Description | Défaut |
|---|---|---|
| `-VmNames` | Noms des VM sources **exactement tels qu'affichés dans Veeam**. Position 0. | — (obligatoire) |
| `-ConfigPath` | Fichier de configuration JSON. Les paramètres de ligne de commande ont priorité. | `.\RecoveryVerification.json` |
| `-InitConfig` | Écrit un modèle de configuration puis s'arrête. | — |
| `-Language` | `en` ou `fr`. | Culture système |
| `-PingCheck` | Active **CP23**. Nécessite que la sonde soit sur le réseau isolé. | désactivé |
| `-Cleanup` | Détruit les VM de test, supprime les overlays et **dépublie** à la fin ; supprime aussi les résidus (VM de test, publications FUSE périmées) en pré-vol. Sans cette option, CP40 est `SKIP` et **les disques restent publiés** — ne pas oublier. | désactivé |
| `-FailOnWarning` | Compte les `WARN` comme échecs pour le code de sortie. | désactivé |
| `-ReportDir` | Dossier de sortie. | `.\Reports` |
| `-VbrCredential` | Compte VBR (Backup Administrator / Restore Operator). Demandé si absent. | — |
| `-PveApiToken` | Jeton API Proxmox en `PSCredential` (`user@realm!tokenid` / secret). Demandé si absent. | — |
| `-WhatIf` | Le pré-vol s'exécute ; publication / création / démarrage / destruction sont seulement affichés. | — |

### Surcharges de configuration

`-VbrServer -VbrPort -VbrApiVersion -NodeCredentialsName -PveApiHost -PveApiPort -PveNode -PveSshHost -PveSshUser -PveSshKeyPath -IsolatedBridge -IsolatedVlanTag -OverlayStoragePath -VmNamePrefix -VmIdRangeStart -MaxRestorePointAgeHours -MaxBootMinutes -GuestAgentTimeoutMinutes`. Voir [Configuration](configuration.md).

## Scénarios types

### Première exécution — valider la mise en place

```powershell
.\Test-PveBackupBoot.ps1 -VmNames SRV-FILE01 -WhatIf -Verbose
```

### Démarrer une VM et la conserver pour inspection manuelle

```powershell
.\Test-PveBackupBoot.ps1 -VmNames SRV-AD01 -PingCheck
```

La VM `rv-srv-ad01` (VMID 9900) reste démarrée sur le réseau isolé ; ouvrir sa console dans l'interface Proxmox. Le point de restauration reste **publié** dans VBR (visible sous *Home → Restore → Published disks*). **La prochaine exécution doit utiliser `-Cleanup`**, sinon CP04 bloque.

### Vérification complète automatisée

```powershell
.\Test-PveBackupBoot.ps1 -VmNames SRV-AD01,SRV-FILE01,SRV-WEB01 -PingCheck -Cleanup -FailOnWarning
if ($LASTEXITCODE -ne 0) { <# alerte #> }
```

### Rotation quotidienne

```powershell
$all = Get-Content .\vms.txt ; $d = (Get-Date).DayOfYear
$sample = 0..2 | ForEach-Object { $all[($d * 3 + $_) % $all.Count] }
.\Test-PveBackupBoot.ps1 -VmNames $sample -Cleanup
```

### VM Windows / UEFI

Donner à la VM le bon matériel virtuel via `VmOverrides` (voir [Configuration](configuration.md#vmdefaults--vmoverrides)) : `OsType: win11`, `Bios: ovmf` + `EfiStorage`, plus de mémoire. Les VM qui tournaient déjà sur Proxmox disposent des pilotes VirtIO ; la VM de test utilise `virtio-scsi-pci` et une NIC `virtio` comme l'originale.

### Tâche planifiée (Windows)

```powershell
$action  = New-ScheduledTaskAction -Execute 'pwsh.exe' -Argument '-NoProfile -File C:\Tools\RecoveryVerification\Run.ps1'
$trigger = New-ScheduledTaskTrigger -Daily -At 06:00
Register-ScheduledTask -TaskName 'Veeam Recovery Verification PVE' -Action $action -Trigger $trigger -User 'DOMAINE\svc-rv' -Password '***'
```

`Run.ps1` récupère les deux identifiants depuis un coffre ([Installation §7](installation.md#7-exécutions-non-supervisées)) et appelle le script avec `-Cleanup`.

## Lire les résultats

### Console

```
  [CP02] OK   -                Bridge / VLAN isolé non routé - bridge vmbr1 tag 4000 : aucune IP, aucun uplink
  [CP12] OK   SRV-AD01         Publication des disques terminée - 2 disque(s) : disk-0.raw, disk-1.raw
  [CP13] WARN SRV-AD01         Délai de démarrage <= 20 min - 23.4 min - RTO cible dépassé
  [CP30] KO   SRV-WEB01        Applicatif : Health - HTTP 503 https://10.99.0.12/health
```

Vert `OK`, rouge `KO`, jaune `WARN`, gris `SKIP` ; tableau de synthèse et chemins des fichiers à la fin.

### Fichiers dans `-ReportDir`

| Fichier | Contenu |
|---|---|
| `RecoveryVerification-<RunId>.html` | Bandeau, indicateurs (VM, OK / WARN / KO, RPO, RTO), synthèse par VM, tableau des points de contrôle. Autonome. |
| `RecoveryVerification-<RunId>.csv` | Une ligne par point de contrôle, séparateur `;`, UTF-8. |
| `RecoveryVerification-<RunId>.json` | RunId, date, `Platform: ProxmoxVE`, `Method: DataIntegrationApi+QemuOverlay`, cible, seuils, synthèse, points de contrôle. |
| `RecoveryVerification-<RunId>.log` | Transcription PowerShell (`-Verbose` ajoute les URL REST et les commandes SSH). |

### Codes de sortie

| Code | Signification |
|---|---|
| `0` | Tous les points de contrôle OK (ou WARN seulement sans `-FailOnWarning`). |
| `1` | Au moins un `KO` (ou `WARN` avec `-FailOnWarning`). |
| `2` | Erreur bloquante en pré-vol ou erreur fatale. Les rapports sont quand même produits. |

## Garde-fous de sécurité

- **CP02 (bloquant)** — le bridge ne doit porter ni IP ni passerelle sur le nœud ; un bridge avec uplink exige `Isolation.SwitchIsolationConfirmed: true`.
- **CP03** — toute VM hors test attachée au bridge / VLAN isolé est signalée.
- **CP04 (bloquant)** — les VM de test résiduelles (préfixe de nom, ou plage VMID + marqueur de description) et les publications FUSE périmées sont supprimées avec `-Cleanup`, sinon l'exécution s'arrête.
- **CP21 (garde-fou)** — une VM de test avec une NIC hors du bridge / VLAN isolé est **arrêtée immédiatement**.
- Les disques publiés sont **en lecture seule** par construction (FUSE Veeam) ; toutes les écritures de l'invité vont dans des overlays qcow2 locaux supprimés au nettoyage. VM de production et fichiers de sauvegarde ne sont jamais touchés.
- Les VM de test vivent dans une **plage VMID dédiée** (`VmIdRangeStart`, 100 identifiants) avec un marqueur de description `Veeam Recovery Verification` : faciles à repérer, sûres à détruire.

## Dépannage

| Symptôme | Cause probable / correction |
|---|---|
| CP00 KO `HTTP 401` sur VBR | Identifiants incorrects, ou `VbrApiVersion` refusé (`1.3-rev2` pour 13.1, `1.3-rev1` pour 13.0). |
| CP00 KO `HTTP 401` sur Proxmox | Format du jeton : UserName doit être `user@realm!tokenid`, Password le secret. Vérifier *Privilege Separation*. |
| CP00 KO `Commande SSH en échec` / `Permission denied` | Clé absente de `/root/.ssh/authorized_keys`, mauvais `SshKeyPath`, ou `PermitRootLogin` en `prohibit-password` sans clé. |
| CP01 KO `aucun identifiant Linux nommé …` | Créer l'enregistrement dans VBR (*Credentials → Add → Linux account*) et régler `Veeam.NodeCredentialsName` sur son utilisateur ou sa description. |
| CP02 KO `le bridge porte IP` | Le nœud a une adresse sur le bridge. Utiliser un bridge sans IP pour le réseau de test. |
| CP02 KO `Isolation.SwitchIsolationConfirmed=true requis` | Bridge partagé avec uplink : faire confirmer par l'équipe réseau que le VLAN n'est ni routé ni trunké ailleurs, puis positionner l'indicateur. |
| CP04 KO `résidu(s)` | Exécution précédente sans `-Cleanup`. Relancer avec `-Cleanup` ou nettoyer manuellement (`qm destroy`, *Published disks → Unpublish*). |
| CP10 KO `aucun point de restauration Proxmox VE` | Le nom doit correspondre exactement à Veeam ; la VM doit être dans un job Proxmox avec au moins un point de restauration. |
| CP12 KO `statut = Failed … agent` | La Data Integration API n'a pas pu déployer son agent sur le nœud : SSH depuis le **serveur VBR** vers le nœud bloqué, mauvais enregistrement d'identifiants, `/bin/bash` absent. Voir le journal de session dans la console Veeam (*History → Restore*). |
| CP12 KO `aucune image disque trouvée` | Publication ailleurs : vérifier `Proxmox.MountRoot` (défaut `/run/media/Veeam.Mount.Disks`) — `find /run/media -maxdepth 3` sur le nœud. |
| CP20 KO après `qm create` | Voir l'erreur de `qm start <vmid>` dans le journal : en général `EfiStorage` manquant pour `ovmf`, ou valeur `Cpu` / `Machine` non prise en charge sur ce nœud. |
| CP22 WARN `aucune IP` | Guest agent non installé / non démarré dans la sauvegarde, ou OS encore en démarrage → augmenter `GuestAgentTimeoutMinutes`. Windows : vérifier le service *QEMU Guest Agent* et le pilote VirtIO serial. |
| CP23 / CP30 SKIP | `-PingCheck` désactivé, pas d'IP, aucune entrée `AppChecks`, ou sonde hors du réseau isolé. |
| CP40 KO | Destruction ou dépublication en échec — nettoyer manuellement ; le détail indique le VMID et l'id de montage. |
| La VM démarre mais ne trouve pas de disque / boucle de boot | Ordre des disques : les overlays sont attachés `scsi0…N` dans l'ordre de publication Veeam. Pour les VM multi-disques dont le disque de boot n'est pas le premier, ajuster `--boot order` (voir `New-TestVm` dans le script). |
