# Guide utilisateur

[← Installation](installation.md) · [Configuration →](configuration.md) · 🇬🇧 [English version](../en/user-guide.md)

## Déroulement d'une exécution

```
Étape 0  PRÉ-VOL        qm / qemu-img présents ; VBR, API Proxmox OK. Nœud / bridge / chemin overlay /
                        identifiants Linux VBR présents, bridge isolé, aucune VM étrangère, aucun résidu
                        (VM de test ou publication périmée).                        → CP00–CP04
Étape 1  DÉMARRAGE      Par VM, séquentiellement : dernier point de restauration, RPO, publication des
                        disques vers ce nœud (Data Integration API, FUSE), attente, attribution des images,
                        overlays qcow2, qm create sur le réseau isolé, qm start.    → CP10–CP12
Étape 2  VÉRIFICATION   Par VM : attente IP guest agent (RTO), running, garde-fou NIC, IP, ping,
                        contrôles applicatifs (GuestExec dans l'invité, ou réseau). → CP13–CP30
Étape 3  NETTOYAGE      qm stop / destroy --purge, suppression overlays, dépublication (--cleanup). → CP40
Étape 4  RAPPORT        HTML + CSV + JSON + journal, code de sortie.
```

## Ligne de commande

```
pve_backup_boot.py -v NOM [-v NOM ...] [-c CONFIG] [-l en|fr] [--cleanup] [--ping-check] [--fail-on-warning]
                   [--report-dir DIR] [--secrets-file FICHIER] [--verify-tls] [-n|--dry-run] [--debug]
                   [surcharges de configuration]
pve_backup_boot.py --init-config [--force] [-c CONFIG]
```

| Option | Description | Défaut |
|---|---|---|
| `-v`, `--vm NOM` | Nom de la VM source **exactement tel qu'affiché dans Veeam**. Répéter pour plusieurs VM. | obligatoire |
| `-c`, `--config` | Fichier de configuration JSON. | `./RecoveryVerification.json` |
| `--init-config` / `--force` | Écrit le modèle de configuration (écrase avec `--force`) puis s'arrête. | — |
| `-l`, `--language` | `en` ou `fr` pour la console et les rapports. | locale système |
| `--cleanup` | Détruit les VM de test, supprime les overlays et **dépublie** à la fin ; nettoie aussi les résidus en pré-vol. Sans cette option CP40 est `SKIP` et **les disques restent publiés**. | désactivé |
| `--ping-check` | Active CP23 — ping depuis **cet hôte**, qui n'a normalement pas de route vers le réseau isolé. Préférer les contrôles `GuestExec`. | désactivé |
| `--fail-on-warning` | Compte les `WARN` comme échecs pour le code de sortie. | désactivé |
| `--report-dir` | Dossier de sortie des rapports et du journal. | `./Reports` |
| `--secrets-file` | JSON avec `VBR_USER`, `VBR_PASSWORD`, `PVE_TOKEN_ID`, `PVE_TOKEN_SECRET` (chmod 600). Variables d'environnement puis saisie en secours. | — |
| `--verify-tls` | Valide les certificats VBR / Proxmox. | désactivé |
| `-n`, `--dry-run` | Le pré-vol s'exécute réellement ; publication / création / démarrage / destruction sont seulement affichés. | — |
| `--debug` | Affiche aussi le journal de debug (appels REST, commandes shell) sur la console. | — |

Surcharges de configuration : `--vbr-server --vbr-port --vbr-api-version --node-credentials-name --target-server-name --pve-api-host --pve-api-port --pve-node --isolated-bridge --isolated-vlan-tag --overlay-storage-path --vm-name-prefix --vmid-range-start --max-restore-point-age-hours --max-boot-minutes --guest-agent-timeout-minutes`.

## Scénarios types

```bash
# première exécution - valider la mise en place, rien n'est démarré
./pve_backup_boot.py -v SRV-FILE01 --secrets-file /root/.veeam-rv-secrets.json --dry-run --debug

# démarrer une VM et la conserver pour inspection (console dans l'UI Proxmox ; relancer ensuite avec --cleanup !)
./pve_backup_boot.py -v SRV-AD01 --secrets-file /root/.veeam-rv-secrets.json

# vérification complète automatisée
./pve_backup_boot.py -v SRV-AD01 -v SRV-FILE01 -v SRV-WEB01 --cleanup --fail-on-warning --secrets-file /root/.veeam-rv-secrets.json
echo $?      # 0 OK, 1 point de contrôle en échec, 2 pré-vol / fatal

# rotation quotidienne de 3 VM depuis vms.txt (voir deploy/rotate-sample.sh) - planifiée par le timer systemd
```

### VM Windows / UEFI

Définir le matériel virtuel dans `VmOverrides` (`OsType: win11`, `Bios: ovmf` + `EfiStorage`, mémoire). Utiliser `GuestExec` avec `"Shell": "powershell"` pour les contrôles — les commandes s'exécutent dans l'invité, aucun chemin réseau nécessaire.

## Lire les résultats

```
  [CP02] OK   -                Bridge / VLAN isolé non routé - bridge vmbr1 tag 4000 : aucune IP, aucun uplink
  [CP12] OK   SRV-AD01         Publication des disques terminée - 2 disque(s) : disk-0.raw, disk-1.raw
  [CP13] WARN SRV-AD01         Délai de démarrage <= 20 min - 23.4 min - RTO cible dépassé
  [CP30] OK   SRV-AD01         Applicatif : AD DS, DNS, KDC running - exit 0: 0
```

| Fichier dans `--report-dir` | Contenu |
|---|---|
| `RecoveryVerification-<RunId>.html` | Bandeau, indicateurs, synthèse par VM, tableau des points de contrôle. Autonome. |
| `RecoveryVerification-<RunId>.csv` | Une ligne par point de contrôle, séparateur `;`. |
| `RecoveryVerification-<RunId>.json` | RunId, `Platform: ProxmoxVE`, `Method: DataIntegrationApi+QemuOverlay`, cible, seuils, synthèse, points de contrôle. |
| `RecoveryVerification-<RunId>.log` | Journal de debug : appels REST, commandes shell, traces. |

Codes de sortie : `0` tout OK · `1` au moins un `KO` (ou `WARN` avec `--fail-on-warning`) · `2` erreur bloquante en pré-vol ou fatale (rapports quand même produits).

## Garde-fous de sécurité

- **CP02 (bloquant)** — bridge sans IP / passerelle sur le nœud ; un uplink exige `Isolation.SwitchIsolationConfirmed: true`.
- **CP03** — les VM hors test attachées au bridge / VLAN isolé sont signalées.
- **CP04 (bloquant)** — les VM de test résiduelles (préfixe, ou plage VMID + marqueur) et les publications FUSE périmées sont supprimées avec `--cleanup`, sinon l'exécution s'arrête.
- **CP21 (garde-fou)** — une VM de test avec une NIC hors du bridge / VLAN isolé est **arrêtée immédiatement**.
- Disques publiés en lecture seule (FUSE Veeam) ; écritures dans des overlays qcow2 locaux supprimés au nettoyage. Sauvegardes et VM de production jamais modifiées.
- VM de test dans une **plage VMID dédiée** avec un marqueur de description `Veeam Recovery Verification`.

## Dépannage

| Symptôme | Cause probable / correction |
|---|---|
| CP00 KO `outil requis introuvable` | Pas sur un nœud Proxmox, ou `PATH` réduit (systemd) : utiliser `/usr/bin/python3` absolu, conserver le `PATH` par défaut. |
| CP00 KO `HTTP 401` sur VBR | Identifiants ou `VbrApiVersion` incorrects (`1.3-rev2` pour 13.1). |
| CP00 KO `HTTP 401` sur Proxmox | `PVE_TOKEN_ID` doit être `user@realm!tokenid` ; vérifier *Privilege Separation* et l'expiration du jeton. |
| CP01 KO `aucun identifiant Linux nommé …` | Créer l'enregistrement dans VBR (*Credentials → Add → Linux account*), régler `Veeam.NodeCredentialsName`. |
| CP02 KO `le bridge porte IP` | Le nœud a une adresse sur le bridge — utiliser un bridge sans IP. |
| CP02 KO `SwitchIsolationConfirmed=true requis` | Bridge avec uplink : obtenir la confirmation de l'équipe réseau, puis positionner l'indicateur. |
| CP04 KO `résidu(s)` | Exécution précédente sans `--cleanup`. Relancer avec `--cleanup` ou nettoyer manuellement (`qm destroy`, VBR *Published disks → Unpublish*). |
| CP10 KO `aucun point de restauration Proxmox VE` | Nom Veeam exact requis ; la VM doit être dans un job Proxmox avec un point de restauration. |
| CP12 KO `statut = Failed …` | VBR n'a pas pu déployer son agent FUSE : SSH depuis le **serveur VBR** vers le nœud bloqué, mauvais enregistrement d'identifiants, `TargetServerName` non résolvable depuis VBR. Voir *History → Restore* dans la console Veeam. |
| CP12 KO `aucune nouvelle image disque trouvée` | Publication ailleurs : `find /run/media -maxdepth 3` et régler `Proxmox.MountRoot`. |
| CP12 KO après `qm create` | Lire l'erreur `qm` dans le journal : `EfiStorage` manquant pour `ovmf`, `Cpu` / `Machine` non pris en charge. |
| CP22 WARN `aucune IP` | Guest agent absent / non démarré dans la sauvegarde, ou OS en démarrage → augmenter `GuestAgentTimeoutMinutes`. |
| CP30 SKIP `guest agent ne répond pas` | Guest agent pas encore démarré ou non installé. `GuestExec` exige aussi `VM.GuestAgent.Unrestricted` (PVE 9). |
| CP30 SKIP `module python … absent` | Contrôle réseau nécessitant `dnspython` / `ldap3` / `pymssql` — l'installer, ou passer en `GuestExec`. |
| CP40 KO | Destruction ou dépublication en échec — le détail indique VMID et id de montage à nettoyer manuellement. |
| Boucle de boot / disque introuvable | Overlays attachés `scsi0…N` dans l'ordre de publication ; VM multi-disques dont le disque de boot n'est pas le premier : ajuster `--boot order` dans `create_test_vm`. |
