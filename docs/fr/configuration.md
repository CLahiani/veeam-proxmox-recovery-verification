# Référence de configuration

[← Guide utilisateur](guide-utilisateur.md) · [Points de contrôle →](points-de-controle.md) · 🇬🇧 [English version](../en/configuration.md)

Fichier JSON, `.\RecoveryVerification.json` par défaut (`-ConfigPath`). Générer avec `-InitConfig` ou copier `RecoveryVerification.sample.json`.

**Priorité :** valeurs par défaut du script ← fichier JSON ← paramètres de ligne de commande. `AppChecks` et `VmOverrides`, lorsqu'ils sont présents dans le fichier, **remplacent** entièrement les valeurs par défaut.

> Garder `RecoveryVerification.json` hors du dépôt Git (il est dans `.gitignore`).

## `Veeam`

| Clé | Surcharge CLI | Description | Défaut |
|---|---|---|---|
| `VbrServer` | `-VbrServer` | Serveur VBR 13.x (FQDN / IP). | `vbr.example.local` |
| `VbrPort` | `-VbrPort` | Port de l'API REST. | `9419` |
| `VbrApiVersion` | `-VbrApiVersion` | En-tête `x-api-version` : **`1.3-rev2` = 13.1**, `1.3-rev1` = 13.0. | `1.3-rev2` |
| `NodeCredentialsName` | `-NodeCredentialsName` | Utilisateur ou description de l'**enregistrement d'identifiants Linux stocké dans VBR** pour root sur le nœud. Résolu en ID via `GET /api/v1/credentials`. | `root@pve-node01` |

## `Proxmox`

| Clé | Surcharge CLI | Description | Défaut |
|---|---|---|---|
| `ApiHost` / `ApiPort` | `-PveApiHost` / `-PveApiPort` | Point d'accès API Proxmox (n'importe quel nœud du cluster). | `pve-node01.example.local` / `8006` |
| `Node` | `-PveNode` | Nom du nœud (comme dans `/nodes`) hébergeant les VM de test et recevant la publication FUSE. | `pve-node01` |
| `SshHost` | `-PveSshHost` | Point d'accès SSH de ce nœud. Passé aussi à VBR comme `targetServerName` pour la publication : doit être résolvable **depuis le serveur VBR**. | `pve-node01.example.local` |
| `SshUser` / `SshKeyPath` | `-PveSshUser` / `-PveSshKeyPath` | `root` et la clé privée sur la sonde (`~` = profil). | `root` / `~/.ssh/id_ed25519` |
| `MountRoot` | — | Emplacement où la publication FUSE Veeam expose les images disque brutes sur le nœud. | `/run/media/Veeam.Mount.Disks` |

## `Target`

| Clé | Surcharge CLI | Description | Défaut |
|---|---|---|---|
| `IsolatedBridge` | `-IsolatedBridge` | Bridge des VM de test. Doit exister sur le nœud, **sans IP**. | `vmbr1` |
| `IsolatedVlanTag` | `-IsolatedVlanTag` | Tag VLAN ajouté aux NIC de test, ou `null` pour un bridge isolé non taggé. CP21 vérifie bridge **et** tag. | `4000` |
| `OverlayStoragePath` | `-OverlayStoragePath` | Chemin local au nœud, **de type fichier**, pour les overlays qcow2 (un sous-dossier par VMID). | `/var/lib/vz/images/rv-overlays` |
| `VmNamePrefix` | `-VmNamePrefix` | Noms des VM de test `<préfixe><source>` en minuscules, caractères hors `[a-z0-9-]` remplacés par `-`. Sert aussi à reconnaître les résidus (CP04). | `rv-` |
| `VmIdRangeStart` | `-VmIdRangeStart` | Premier VMID des VM de test ; 100 identifiants réservés. Les ids existants sont sautés. | `9900` |

## `VmDefaults` / `VmOverrides`

Matériel virtuel de la VM jetable. `VmDefaults` s'applique à toutes les VM ; `VmOverrides["<nom VM source>"]` surcharge n'importe quelle clé pour cette VM.

| Clé | Signification | Défaut | Notes |
|---|---|---|---|
| `Memory` (Mo), `Cores`, `Cpu`, `Machine` | Valeurs `qm create` | `4096`, `2`, `host`, `q35` | Utiliser `Cpu: x86-64-v2-AES` si `host` est refusé. |
| `Bios` | `seabios` ou `ovmf` | `seabios` | Les VM sources UEFI exigent `ovmf`. |
| `EfiStorage` | Stockage du disque de variables EFI (`--efidisk0 <storage>:1`) | `""` | Requis avec `Bios: ovmf` ; un stockage bloc (`local-lvm`) convient. `pre-enrolled-keys=0` (Secure Boot désactivé). |
| `ScsiHw` | Contrôleur SCSI | `virtio-scsi-pci` | Les disques sont attachés en `scsi0…N`. |
| `OsType` | `l26`, `win11`, `win10`… | `l26` | Influence les valeurs QEMU par défaut (HPET, localtime…). |
| `Agent` | Active le canal guest agent | `1` | Nécessaire pour CP22. |

```json
"VmOverrides": {
  "SRV-WIN01": { "OsType": "win11", "Bios": "ovmf", "EfiStorage": "local-lvm", "Memory": 8192 }
}
```

Astuce : lire une fois le `qm config <vmid>` de la VM d'origine et reproduire `bios`, `ostype`, `machine`, `cores`, `memory`.

## `Isolation`

| Clé | Description | Défaut |
|---|---|---|
| `SwitchIsolationConfirmed` | Positionner à `true` une fois que l'équipe réseau a confirmé que `IsolatedVlanTag` n'est ni routé ni trunké ailleurs que sur le port de la sonde. Exigé par CP02 quand le bridge a un uplink. Consigné dans le rapport. | `false` |

## `Thresholds`

| Clé | Surcharge CLI | Description | Défaut |
|---|---|---|---|
| `MaxRestorePointAgeHours` | `-MaxRestorePointAgeHours` | **RPO cible** (CP11 `KO` si plus ancien). | `30` |
| `MaxBootMinutes` | `-MaxBootMinutes` | **RTO cible** : publication + overlay + création + démarrage jusqu'à l'IP remontée par le guest agent (CP13 `WARN` si dépassé). | `20` |
| `GuestAgentTimeoutMinutes` | `-GuestAgentTimeoutMinutes` | Attente maximale de `running` + IP guest agent (CP20–CP22). | `10` |
| `PublishTimeoutMinutes` | — | Attente maximale de la session Data Integration API (CP12). | `15` |
| `PollIntervalSeconds` | — | Intervalle d'interrogation des sessions et de l'état des VM. | `15` |

## `AppChecks`

Table **nom de VM → liste de contrôles** ; `"*"` s'applique à toutes les VM et se cumule avec la liste propre à la VM. Un **CP30** par contrôle, exécuté **depuis la sonde** vers l'IP remontée par le guest agent.

| Type | Champs | Réussit si |
|---|---|---|
| `Tcp` | `Port` | Connexion TCP établie. |
| `Http` | `Url` (avec `{ip}`), `ExpectedStatus` (défaut 200) | Le GET renvoie le code attendu (certificats non validés, délai 15 s). |
| `Ldap` | `Port` | Port TCP ouvert **et** bind anonyme RootDSE réussi. |
| `Dns` | `Name` | `Resolve-DnsName <Name> -Server <ip>` renvoie des enregistrements. |
| `Sql` | `Port`, `Query` | `Invoke-Sqlcmd` renvoie un résultat (module `SqlServer` requis ; authentification intégrée). |

```json
"AppChecks": {
  "*":         [ { "Type": "Tcp", "Port": 22, "Label": "SSH" } ],
  "SRV-AD01":  [ { "Type": "Ldap", "Port": 389, "Label": "LDAP" }, { "Type": "Dns", "Name": "example.local", "Label": "Zone DNS" } ],
  "SRV-WEB01": [ { "Type": "Http", "Url": "https://{ip}/health", "ExpectedStatus": 200, "Label": "Health" } ]
}
```

> La VM de test est un clone dans un réseau isolé : l'authentification intégrée au domaine peut ne pas fonctionner sauf si un contrôleur de domaine est démarré dans la même exécution. Privilégier les contrôles sans identifiants pour les exécutions non supervisées.

## Langue des rapports

`-Language en|fr` (ou culture système) pilote les chaînes console, les libellés HTML et le champ `Language` du rapport JSON. Les en-têtes CSV sont techniques et identiques dans les deux langues.
