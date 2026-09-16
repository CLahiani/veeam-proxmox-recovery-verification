# Installation et prérequis

[← README](../../README.md) · [Guide utilisateur →](guide-utilisateur.md) · 🇬🇧 [English version](../en/installation.md)

Le script s'exécute **sur le nœud Proxmox VE** qui hébergera les VM de test (en root). Veeam publie les disques de sauvegarde sur ce même nœud, `qm` / `qemu-img` sont locaux, l'API Proxmox est locale — pas de SSH, pas de sonde Windows.

## 1. Logiciels

| Composant | Exigence |
|---|---|
| Proxmox VE | **8.2 – 9.x** (versions prises en charge par le plug-in Veeam). Python 3.9+ déjà présent (Debian 12/13). `qm`, `qemu-img`, `ping` présents par défaut. |
| Modules Python | **Aucun pour le cœur** (bibliothèque standard). Optionnels, uniquement pour les contrôles réseau lancés depuis le nœud : `dnspython`, `ldap3`, `pymssql` (`pip install -r requirements.txt` ou `apt install python3-dnspython python3-ldap3 python3-pymssql`). |
| Veeam Backup & Replication | **13.x**, API REST sur 9419. `Veeam.VbrApiVersion` = `1.3-rev2` (13.1) / `1.3-rev1` (13.0). Veeam Plug-in for Proxmox VE installé, nœuds ajoutés à l'infrastructure de sauvegarde, au moins une sauvegarde réussie des VM à vérifier. |
| VM sources | **QEMU guest agent** installé et activé (`agent: 1`) — requis pour CP22 (IP) et pour les contrôles applicatifs `GuestExec`. |

## 2. Architecture

```
 nœud PVE ── python3 pve_backup_boot.py
   │  REST 9419 ─▶ VBR 13.x : points de restauration, identifiants, Data Integration API (publish / unpublish), sessions
   │  (VBR ─SSH 22─▶ ce nœud : déploie son agent FUSE temporaire, publie les disques bruts sous /run/media/Veeam.Mount.Disks)
   │  local        : qemu-img create (overlays), qm create / start / stop / destroy
   │  REST 8006 ─▶ API Proxmox (localhost, jeton) : nœud, réseau, état/config VM, guest agent (IP, exec)
   └─ VM de test sur <bridge isolé>[,tag=<VLAN>] ; contrôles applicatifs exécutés DANS les invités via le guest agent
```

## 3. Côté Veeam

### 3.1 Identifiants Linux du nœud, stockés dans VBR

La Data Integration API déploie un agent FUSE temporaire sur le serveur Linux cible via SSH **depuis le serveur VBR**. Elle a besoin d'un enregistrement d'identifiants stocké dans VBR :

*Console Veeam → Menu → Credentials and Passwords → Datacenter Credentials → Add → Linux account* — utilisateur `root`, mot de passe root du nœud (ou clé privée), description par ex. `root@pve-node01`.

Le script le retrouve par **utilisateur ou description** (`Veeam.NodeCredentialsName`) via `GET /api/v1/credentials?typeFilter=Linux` et passe son ID dans la requête de publication (CP01 échoue sinon). Le nœud est déjà connu de VBR comme *Proxmox VE server* ; la requête de publication le désigne par son nom (`Veeam.TargetServerName`, défaut : FQDN de cet hôte) comme simple hôte Linux — inutile de l'ajouter une seconde fois.

Pare-feu : le **serveur VBR doit joindre le nœud sur 22/tcp** (SSH) et les ports de l'agent FUSE — voir *Ports* dans le guide utilisateur VBR (Disk Publishing).

### 3.2 Compte VBR pour le script

*Backup Administrator* ou *Restore Operator* (ou rôle personnalisé 13.1 avec droits de restauration). Passé via `VBR_USER` / `VBR_PASSWORD` (environnement, fichier de secrets ou saisie).

## 4. Côté Proxmox

### 4.1 Réseau isolé — le fondement de sécurité

| Option | Configuration | Comportement CP02 |
|---|---|---|
| **A. Bridge dédié sans uplink** | `vmbr1`, `bridge_ports none`, **aucune IP** sur le nœud. | `OK` — isolement structurel. |
| **B. Bridge partagé + tag VLAN dédié** | `vmbr1` (VLAN-aware) avec uplink ; VM de test avec `tag=<VLAN>`. Le VLAN **ne doit** avoir d'interface L3 nulle part et doit être retiré de tous les trunks. | `KO` tant que `Isolation.SwitchIsolationConfirmed: true` n'est pas positionné — le script ne voit pas le commutateur ; la confirmation de l'équipe réseau est consignée et affichée dans le rapport. |

Dans les deux cas le nœud ne doit **pas** porter d'IP ni de passerelle sur le bridge (CP02, bloquant). Les contrôles applicatifs s'exécutant **dans les invités** via le guest agent, le nœud n'a besoin d'aucun accès au réseau isolé — c'est tout l'intérêt de tourner sur le nœud.

### 4.2 Stockage des overlays

`Target.OverlayStoragePath` : chemin **local au nœud, de type fichier**, pour les overlays qcow2 (stockage directory comme `/var/lib/vz/images/rv-overlays`, dataset ZFS, montage NFS). Les overlays ne contiennent que les blocs écrits pendant le test. Créé automatiquement. LVM-thin ne convient pas aux overlays mais reste utilisable pour le disque EFI (`VmDefaults.EfiStorage`).

### 4.3 Jeton API

*Datacenter → Permissions → API Tokens → Add* : utilisateur `root@pam` (ou dédié), id de jeton par ex. `rv`, *Privilege Separation* décoché (ou accorder au jeton les rôles ci-dessous). Privilèges minimaux sur `/nodes/<node>` et `/vms` : `Sys.Audit`, `VM.Audit`, `VM.Allocate`, `VM.Config.*`, `VM.PowerMgmt`, `VM.Monitor`, `VM.GuestAgent.Audit` et `VM.GuestAgent.Unrestricted` (PVE 9, pour `GuestExec`). `PVEVMAdmin` + `PVEAuditor` sur `/` : sur-ensemble simple.

Passé via `PVE_TOKEN_ID` = `root@pam!rv` et `PVE_TOKEN_SECRET`.

### 4.4 Pourquoi root

`qm create` avec des **chemins de disque absolus** (les overlays) n'est accepté que pour `root@pam`, et la publication FUSE atterrit sous `/run/media`. Exécuter le script en root sur le nœud (unité systemd `User=root`).

## 5. Installer

```bash
mkdir -p /opt/veeam-recovery-verification /var/lib/veeam-recovery-verification/reports
cd /opt/veeam-recovery-verification
# copier pve_backup_boot.py, RecoveryVerification.sample.json, deploy/ ici (git clone ou scp)
chmod +x pve_backup_boot.py deploy/rotate-sample.sh
./pve_backup_boot.py --init-config              # écrit RecoveryVerification.json - le renseigner (voir Configuration)

cat > /root/.veeam-rv-secrets.json <<'EOF'
{ "VBR_USER": "svc-rv@vsphere.local", "VBR_PASSWORD": "…", "PVE_TOKEN_ID": "root@pam!rv", "PVE_TOKEN_SECRET": "…" }
EOF
chmod 600 /root/.veeam-rv-secrets.json

./pve_backup_boot.py -v SRV-A --secrets-file /root/.veeam-rv-secrets.json --dry-run --debug   # pré-vol CP00-CP04 seul
```

Les secrets sont lus depuis `--secrets-file`, puis les variables d'environnement (`VBR_USER`, `VBR_PASSWORD`, `PVE_TOKEN_ID`, `PVE_TOKEN_SECRET`), puis la saisie interactive.

## 6. Planification (systemd)

```bash
cp deploy/veeam-recovery-verification.service deploy/veeam-recovery-verification.timer /etc/systemd/system/
# adapter ExecStart (liste de VM ou deploy/rotate-sample.sh + vms.txt), puis :
systemctl daemon-reload && systemctl enable --now veeam-recovery-verification.timer
systemctl list-timers veeam-recovery-verification.timer ; journalctl -u veeam-recovery-verification.service
```

L'unité déclare `SuccessExitStatus=1 2` pour qu'une vérification en échec ne marque pas l'unité failed (le résultat est dans les rapports, le code de sortie dans le journal). À retirer si vous préférez que systemd signale les échecs.

## 7. TLS

Les appels REST ignorent la validation des certificats par défaut (auto-signés VBR / Proxmox). Ajouter `--verify-tls` une fois des certificats de confiance en place.

## Étape suivante

Lire le [Guide utilisateur](guide-utilisateur.md).
