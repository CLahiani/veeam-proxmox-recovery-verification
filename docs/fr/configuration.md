# Référence de configuration

[← Guide utilisateur](guide-utilisateur.md) · [Points de contrôle →](points-de-controle.md) · 🇬🇧 [English version](../en/configuration.md)

Fichier JSON, `./RecoveryVerification.json` par défaut (`-c`). Générer avec `--init-config` ou copier `RecoveryVerification.sample.json`.

**Priorité :** valeurs par défaut du script ← fichier JSON ← surcharges de ligne de commande. `AppChecks` et `VmOverrides`, présents dans le fichier, **remplacent** entièrement les valeurs par défaut. Garder le vrai fichier hors de git (`.gitignore`).

## `Veeam`

| Clé | CLI | Description | Défaut |
|---|---|---|---|
| `VbrServer` / `VbrPort` | `--vbr-server` / `--vbr-port` | Serveur VBR 13.x et port REST. | `vbr.example.local` / `9419` |
| `VbrApiVersion` | `--vbr-api-version` | `x-api-version` : **`1.3-rev2` = 13.1**, `1.3-rev1` = 13.0. | `1.3-rev2` |
| `NodeCredentialsName` | `--node-credentials-name` | Utilisateur ou description de l'**enregistrement d'identifiants Linux stocké dans VBR** pour root sur ce nœud. | `root@pve-node01` |
| `TargetServerName` | `--target-server-name` | Nom utilisé par VBR pour joindre ce nœud lors de la publication FUSE (`targetServerName`) ; doit se résoudre **depuis le serveur VBR**. Vide = FQDN de cet hôte. | `""` |

## `Proxmox`

| Clé | CLI | Description | Défaut |
|---|---|---|---|
| `ApiHost` / `ApiPort` | `--pve-api-host` / `--pve-api-port` | Point d'accès API Proxmox. `localhost` en exécution sur le nœud. | `localhost` / `8006` |
| `Node` | `--pve-node` | Nom du nœud (comme dans `/nodes`). Vide = nom d'hôte court de cette machine. | `""` |
| `MountRoot` | — | Emplacement où la publication FUSE Veeam expose les images brutes. | `/run/media/Veeam.Mount.Disks` |

## `Target`

| Clé | CLI | Description | Défaut |
|---|---|---|---|
| `IsolatedBridge` | `--isolated-bridge` | Bridge des VM de test ; doit exister, **sans IP**. | `vmbr1` |
| `IsolatedVlanTag` | `--isolated-vlan-tag` | Tag VLAN des NIC de test, ou `null` pour un bridge isolé non taggé. CP21 vérifie bridge **et** tag. | `4000` |
| `OverlayStoragePath` | `--overlay-storage-path` | Chemin **local, de type fichier** pour les overlays qcow2 (sous-dossier par VMID). | `/var/lib/vz/images/rv-overlays` |
| `VmNamePrefix` | `--vm-name-prefix` | Noms `<préfixe><source>` en minuscules, `[^a-z0-9-]` → `-`. Identifie aussi les résidus. | `rv-` |
| `VmIdRangeStart` | `--vmid-range-start` | Premier VMID des VM de test ; 100 identifiants réservés, ids existants sautés. | `9900` |

## `VmDefaults` / `VmOverrides`

Matériel virtuel de la VM jetable (non déductible de la sauvegarde). `VmDefaults` pour toutes, `VmOverrides["<VM source>"]` par VM.

| Clé | Signification | Défaut | Notes |
|---|---|---|---|
| `Memory` (Mo), `Cores`, `Cpu`, `Machine` | Valeurs `qm create` | `4096`, `2`, `host`, `q35` | `Cpu: x86-64-v2-AES` si `host` refusé. |
| `Bios` | `seabios` / `ovmf` | `seabios` | Sources UEFI : `ovmf`. |
| `EfiStorage` | Stockage pour `--efidisk0 <storage>:1` | `""` | Requis avec `ovmf` ; `local-lvm` convient. Secure Boot désactivé (`pre-enrolled-keys=0`). |
| `ScsiHw`, `OsType`, `Agent` | contrôleur, type d'OS, canal guest agent | `virtio-scsi-pci`, `l26`, `1` | `OsType: win11` pour Windows. `Agent: 1` requis pour CP22 / GuestExec. |

Astuce : reproduire `bios`, `ostype`, `machine`, `cores`, `memory` du `qm config <vmid>` de la VM source.

## `Isolation`

| Clé | Description | Défaut |
|---|---|---|
| `SwitchIsolationConfirmed` | `true` une fois que l'équipe réseau a confirmé que le VLAN n'est ni routé ni trunké ailleurs. Exigé par CP02 quand le bridge a un uplink ; consigné dans le rapport. | `false` |

## `Thresholds`

| Clé | CLI | Description | Défaut |
|---|---|---|---|
| `MaxRestorePointAgeHours` | `--max-restore-point-age-hours` | **RPO cible** (CP11 `KO` si plus ancien). | `30` |
| `MaxBootMinutes` | `--max-boot-minutes` | **RTO cible** : publication → overlay → création → démarrage → IP guest agent (CP13 `WARN`). | `20` |
| `GuestAgentTimeoutMinutes` | `--guest-agent-timeout-minutes` | Attente maximale de `running` + IP guest agent (CP20–CP22). | `10` |
| `PublishTimeoutMinutes` | — | Attente maximale de la session Data Integration API (CP12). | `15` |
| `PollIntervalSeconds` | — | Intervalle d'interrogation. | `15` |

## `AppChecks`

Table **nom de VM → liste de contrôles** ; `"*"` s'applique à toutes les VM et se cumule avec la liste propre. Un **CP30** par contrôle.

### `GuestExec` — recommandé

Exécute une commande **dans la VM de test** via le QEMU guest agent (`agent/exec` + `agent/exec-status`). Aucun chemin réseau du nœud vers le VLAN isolé, fonctionne pour Linux et Windows, et peut tester tout ce que l'OS sait tester (services, ports sur localhost, HTTP sur localhost, requêtes avec les outils locaux).

| Champ | Description | Défaut |
|---|---|---|
| `Command` | Ligne de commande passée au shell. | requis |
| `Shell` | `sh`, `bash`, `powershell`, `cmd`, ou un exécutable absolu. | `sh` |
| `ExpectedExitCode` | Code de sortie signifiant le succès. | `0` |
| `ExpectedOutput` | Regex optionnelle (multiligne) que stdout doit vérifier. | — |
| `TimeoutSeconds` | Durée maximale d'exécution. | `60` |
| `Label` | Texte affiché dans CP30. | `Type` |

```json
{ "Type": "GuestExec", "Command": "systemctl is-active sshd", "ExpectedOutput": "^active", "Label": "sshd" }
{ "Type": "GuestExec", "Shell": "powershell", "Command": "(Get-Service NTDS).Status", "ExpectedOutput": "Running", "Label": "AD DS" }
{ "Type": "GuestExec", "Command": "curl -sk -o /dev/null -w '%{http_code}' https://localhost/health", "ExpectedOutput": "^200", "Label": "Health" }
{ "Type": "GuestExec", "Shell": "powershell", "Command": "Invoke-Sqlcmd -Query \"SELECT COUNT(*) FROM sys.databases WHERE state_desc='ONLINE'\" | Select -Expand Column1", "ExpectedOutput": "^[1-9]", "Label": "Bases ONLINE" }
```

Le guest agent doit tourner dans l'invité ; sous Windows le service *QEMU Guest Agent* et le pilote VirtIO serial. Proxmox VE 9 exige aussi le privilège `VM.GuestAgent.Unrestricted` sur le jeton pour `exec`.

### Contrôles réseau — depuis le nœud

Pertinents seulement si l'hôte qui exécute le script a une route vers le réseau isolé (en général **non**, par conception). Ils utilisent l'IP du guest agent (CP22).

| Type | Champs | Réussit si | Requiert |
|---|---|---|---|
| `Tcp` | `Port` | connexion TCP OK | — |
| `Http` | `Url` (`{ip}`), `ExpectedStatus` | code attendu (TLS non validé) | — |
| `Ldap` | `Port` | bind anonyme OK | `ldap3` |
| `Dns` | `Name`, `RecordType` | enregistrements renvoyés par `<ip>` | `dnspython` |
| `Sql` | `Port`, `Query`, `User`, `Password` | la requête renvoie une ligne | `pymssql` |

Module absent → contrôle rapporté `SKIP` avec le nom du module.

## Secrets

Jamais dans le JSON de configuration. Ordre : `--secrets-file` (JSON, `chmod 600`) → environnement (`VBR_USER`, `VBR_PASSWORD`, `PVE_TOKEN_ID`, `PVE_TOKEN_SECRET`) → saisie interactive.

## Langue des rapports

`-l en|fr` (ou locale système) pilote les chaînes console, les libellés HTML et le champ `Language` du rapport JSON. En-têtes CSV techniques, identiques dans les deux langues.
