# Installation et prérequis

[← README](../../README.md) · [Guide utilisateur →](guide-utilisateur.md) · 🇬🇧 [English version](../en/installation.md)

## 1. Logiciels

| Composant | Exigence |
|---|---|
| PowerShell | **7.2 ou supérieur** (`pwsh`) sur la machine sonde. |
| Client OpenSSH | `ssh.exe` dans le `PATH` (intégré à Windows 10/11 et Windows Server 2019+). Authentification par clé, non interactive, vers le nœud Proxmox. |
| Veeam Backup & Replication | **13.x** avec API REST activée (port 9419). `Veeam.VbrApiVersion` = `1.3-rev2` pour 13.1, `1.3-rev1` pour 13.0. Veeam Plug-in for Proxmox VE installé et nœuds Proxmox ajoutés à l'infrastructure de sauvegarde. |
| Proxmox VE | **8.2 – 9.x** (versions prises en charge par le plug-in Veeam). Un nœud désigné comme *nœud de vérification*. |
| VM sources | **QEMU guest agent** installé et activé (`agent: 1`) — nécessaire pour CP22 (IP), CP23 et CP30. |
| Module `SqlServer` | Uniquement si des contrôles `Sql` sont définis : `Install-Module SqlServer -Scope CurrentUser`. |
| OS de la sonde | Windows recommandé (`Test-NetConnection`, `Resolve-DnsName` utilisés par les contrôles Tcp / Ldap / Dns). |

## 2. Architecture

```
 sonde (PowerShell) ──REST 9419──▶ VBR 13.x ──Data Integration API (SSH, agent temporaire)──▶ nœud Proxmox
 sonde ──SSH 22 (clé)───────────▶ nœud Proxmox : qemu-img, qm
 sonde ──REST 8006 (jeton API)──▶ API Proxmox : nœuds, réseau, état/config VM, guest agent
 sonde ──(2e NIC sur le bridge/VLAN isolé)──▶ VM de test : ping, contrôles applicatifs
```

## 3. Côté Veeam

### 3.1 Identifiants Linux du nœud, stockés dans VBR

La Data Integration API déploie un agent FUSE temporaire sur le serveur Linux cible via SSH. Elle a besoin d'un **enregistrement d'identifiants stocké dans VBR** :

*Console Veeam → Menu → Credentials and Passwords → Datacenter Credentials → Add → Linux account* — utilisateur `root`, mot de passe root du nœud (ou clé), description par ex. `root@pve-node01`. Pas d'élévation nécessaire pour root.

Le script retrouve cet enregistrement par **nom d'utilisateur ou description** (`Veeam.NodeCredentialsName`) via `GET /api/v1/credentials?typeFilter=Linux` et passe son ID dans la requête de publication. Le point de contrôle **CP01** échoue s'il est introuvable.

> Le nœud Proxmox est déjà connu de VBR comme *Proxmox VE server* (via le plug-in). La requête de publication le désigne par son nom (`targetServerName`) comme simple hôte Linux — inutile de l'ajouter une seconde fois comme *Linux server*.

### 3.2 Compte VBR pour le script

Un utilisateur (ou rôle RBAC personnalisé 13.1) avec **droits de restauration** : *Backup Administrator* ou *Restore Operator*. Les endpoints Data Integration API sont documentés comme accessibles aux deux.

## 4. Côté Proxmox

### 4.1 Réseau isolé — le fondement de sécurité

Créer, sur le nœud de vérification, l'une des deux options :

| Option | Configuration | Comportement CP02 |
|---|---|---|
| **A. Bridge dédié sans uplink** (recommandé si la sonde peut être une VM sur le même nœud) | `vmbr1` avec `bridge_ports none`, **aucune adresse IP** sur le nœud. VM de test et VM sonde s'y attachent. | `OK` — isolement structurel. |
| **B. Bridge partagé + tag VLAN dédié** | `vmbr1` (VLAN-aware) avec uplink ; les VM de test reçoivent `tag=<VLAN>`. Le VLAN **ne doit** avoir d'interface L3 nulle part et doit être retiré de tous les trunks sauf le port de la sonde. | `KO` tant que `Isolation.SwitchIsolationConfirmed: true` n'est pas positionné — le script ne peut pas vérifier le commutateur physique ; la confirmation de l'équipe réseau est consignée dans la configuration et affichée dans le rapport. |

Dans les deux cas, le nœud lui-même ne doit **pas** porter d'IP ni de passerelle sur le bridge (vérifié par CP02, bloquant). `firewall=1` est positionné sur la NIC de test afin de pouvoir ajouter des règles de pare-feu Proxmox si souhaité.

### 4.2 Stockage des overlays

Un **chemin local au nœud, de type fichier**, pour les overlays qcow2 : `Target.OverlayStoragePath`, par ex. `/var/lib/vz/images/rv-overlays` (stockage directory), un point de montage ZFS ou NFS. Les overlays ne contiennent que les blocs écrits par l'invité pendant le test (quelques centaines de Mo par VM en général). Le script crée le dossier s'il manque. Un stockage bloc (LVM-thin) **ne convient pas** aux overlays ; il reste utilisable pour le disque de variables EFI (`VmDefaults.EfiStorage`).

### 4.3 Jeton API

*Datacenter → Permissions → API Tokens → Add* — utilisateur `root@pam` (ou un utilisateur dédié), id de jeton par ex. `rv`, **Privilege Separation décoché** (ou accorder au jeton lui-même les rôles ci-dessous). Noter le secret ; il n'est affiché qu'une fois.

Privilèges minimaux sur `/nodes/<node>` et `/vms` : `Sys.Audit`, `VM.Audit`, `VM.Allocate`, `VM.Config.Disk`, `VM.Config.Network`, `VM.Config.Options`, `VM.Config.HWType`, `VM.PowerMgmt`, `VM.Monitor` (requêtes guest agent). Les rôles intégrés `PVEVMAdmin` + `PVEAuditor` sur `/` constituent un sur-ensemble simple.

Le jeton est passé en `PSCredential` : **UserName** = `root@pam!rv`, **Password** = le secret.

### 4.4 Clé SSH

`qm create` avec des **chemins de disque absolus** (les overlays) n'est accepté que pour `root@pam` — d'où le SSH root par clé :

```bash
# sur la sonde
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -C rv-probe
# copier la clé publique dans /root/.ssh/authorized_keys sur le nœud, puis tester :
ssh -i ~/.ssh/id_ed25519 -o BatchMode=yes root@pve-node01 pveversion
```

Commandes exécutées sur le nœud : `pveversion`, `find <MountRoot>`, `mkdir -p` / `test -w` sur le chemin overlay, `qemu-img create`, `qm create`, `qm start`, `qm stop`, `qm destroy --purge`, `rm -rf <dossier overlay>`.

## 5. La machine sonde

| Destination | Port | Usage |
|---|---|---|
| Serveur VBR | 9419/tcp | Points de restauration, identifiants, Data Integration API, sessions |
| Nœud Proxmox | 22/tcp | qemu-img / qm via SSH |
| API Proxmox | 8006/tcp | Nœud, réseau, état des VM, guest agent |
| Bridge / VLAN isolé | ICMP, ports applicatifs | Ping CP23 et contrôles applicatifs CP30 |

Pour la dernière ligne, la sonde a besoin d'une **seconde NIC sur le bridge / VLAN isolé** (le plus simple : la sonde est elle-même une petite VM Windows sur le nœud de vérification avec `net1` sur `vmbr1[,tag=…]`). Sans cela le script fonctionne ; CP23 et CP30 sont `SKIP`.

## 6. Installer le script

1. Copier `Test-PveBackupBoot.ps1` et `RecoveryVerification.sample.json` dans un dossier de la sonde, par ex. `C:\Tools\RecoveryVerification\`.
2. `Unblock-File .\Test-PveBackupBoot.ps1` si téléchargé.
3. Générer et renseigner la configuration : `.\Test-PveBackupBoot.ps1 -InitConfig` puis éditer `RecoveryVerification.json` (ou copier l'exemple). Voir [Configuration](configuration.md).
4. Simulation — s'authentifie partout et exécute le pré-vol CP00–CP04, ne démarre rien :

   ```powershell
   .\Test-PveBackupBoot.ps1 -VmNames SRV-A -WhatIf -Verbose
   ```

## 7. Exécutions non supervisées

Stocker les deux secrets dans un coffre et les passer en identifiants :

```powershell
$vbr = Get-Secret -Name RV-VBR      # PSCredential : utilisateur / mot de passe VBR
$pve = Get-Secret -Name RV-PveToken # PSCredential : "root@pam!rv" / secret du jeton
.\Test-PveBackupBoot.ps1 -VmNames SRV-A,SRV-B -Cleanup -VbrCredential $vbr -PveApiToken $pve
```

## 8. TLS

Tous les appels REST utilisent `-SkipCertificateCheck` (certificats auto-signés habituels sur VBR et Proxmox). Retirer `SkipCertificateCheck = $true` dans `Invoke-Api` et `Connect-Vbr` pour une validation stricte.

## Étape suivante

Lire le [Guide utilisateur](guide-utilisateur.md).
