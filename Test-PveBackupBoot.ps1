<#
MIT License

Copyright (c) 2026

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
#>

<#
.SYNOPSIS
    [EN] Scripted Recovery Verification for Proxmox VE with Veeam Backup & Replication 13.x.
    [FR] Recovery Verification scriptée pour Proxmox VE avec Veeam Backup & Replication 13.x.

    [EN] Boots a sample of VMs DIRECTLY FROM THEIR VEEAM BACKUPS on a Proxmox VE node, inside an
         isolated bridge / VLAN, checks that they boot and that their services respond, destroys
         the test VMs, then produces an HTML / CSV / JSON report. Console output and reports are
         available in English or French (-Language, auto-detected from the system culture).
    [FR] Démarre un échantillon de VM DIRECTEMENT DEPUIS LEURS SAUVEGARDES VEEAM sur un nœud
         Proxmox VE, dans un bridge / VLAN isolé, vérifie qu'elles démarrent et que leurs services
         répondent, détruit les VM de test, puis produit un rapport HTML / CSV / JSON. Console et
         rapports en anglais ou en français (-Language, détecté depuis la culture système).

.DESCRIPTION
    ══════════════════════════════════════════════════════════════════════════════════════════
    [EN] WHY
    SureBackup / Virtual Lab is not available for Proxmox VE, and Veeam Backup & Replication 13.x
    exposes neither a REST endpoint nor a PowerShell cmdlet to start an Entire VM Restore or an
    Instant Recovery TO Proxmox VE. What IS supported and documented is the Veeam Data Integration
    API (disk publishing), which lists Proxmox VE backups among its supported sources. This script
    therefore reproduces the SureBackup logic the way SureBackup itself works - by running the VM
    from the backup, not by restoring it:

      1. Publish the disks of the latest restore point to a Proxmox VE node in FUSE mode
         (POST /api/v1/dataIntegration/publish). The raw, read-only disk images appear under
         /run/media/Veeam.Mount.Disks on the node.
      2. Over SSH on the node: create a qcow2 overlay per disk (qemu-img -b <image> -F raw), create
         a throw-away VM (qm create) attached to the ISOLATED bridge / VLAN, and start it.
      3. Verify through the Proxmox VE API: power state, NIC guardrail (bridge + VLAN tag), IP
         reported by the QEMU guest agent, ping and per-VM application checks.
      4. Cleanup: qm stop / destroy, remove overlays, unpublish the disks.
      5. Report: HTML / CSV / JSON / transcript.

    [FR] POURQUOI
    SureBackup / Virtual Lab n'est pas disponible pour Proxmox VE, et Veeam Backup & Replication
    13.x n'expose ni endpoint REST ni cmdlet PowerShell pour lancer un Entire VM Restore ou un
    Instant Recovery VERS Proxmox VE. Ce qui EST supporté et documenté, c'est la Data Integration
    API de Veeam (publication de disques), qui liste les sauvegardes Proxmox VE parmi ses sources.
    Ce script reproduit donc la logique SureBackup comme SureBackup le fait lui-même : en exécutant
    la VM depuis la sauvegarde, sans la restaurer :

      1. Publier les disques du dernier point de restauration vers un nœud Proxmox VE en mode FUSE
         (POST /api/v1/dataIntegration/publish). Les images disque brutes, en lecture seule,
         apparaissent sous /run/media/Veeam.Mount.Disks sur le nœud.
      2. En SSH sur le nœud : créer un overlay qcow2 par disque (qemu-img -b <image> -F raw), créer
         une VM jetable (qm create) attachée au bridge / VLAN ISOLÉ, et la démarrer.
      3. Vérifier via l'API Proxmox VE : état d'alimentation, garde-fou NIC (bridge + tag VLAN),
         IP remontée par le QEMU guest agent, ping et contrôles applicatifs par VM.
      4. Nettoyage : qm stop / destroy, suppression des overlays, dépublication des disques.
      5. Rapport : HTML / CSV / JSON / journal.
    ══════════════════════════════════════════════════════════════════════════════════════════

    CHECKPOINTS / POINTS DE CONTRÔLE  (OK / KO / WARN / SKIP)
      CP00  Authentication VBR / Proxmox API / SSH node         | Authentification VBR / API Proxmox / SSH nœud
      CP01  Node, bridge, overlay storage, VBR credentials exist | Nœud, bridge, stockage overlay, identifiants VBR
      CP02  Isolated bridge / VLAN is not routed  (blocking)     | Bridge / VLAN isolé non routé (bloquant)
      CP03  No foreign VM on the isolated bridge / VLAN          | Aucune VM hors périmètre sur le bridge / VLAN
      CP04  No leftover test VM or stale publish     (blocking)  | Aucune VM de test / publication résiduelle (bloquant)
      CP10  Restore point found                                  | Point de restauration trouvé
      CP11  Restore point age <= RPO target                      | Âge du point de restauration <= RPO
      CP12  Disk publishing session Success                      | Session de publication Success
      CP13  Time to boot (publish + create + start) <= RTO       | Délai de démarrage (publication + création + start) <= RTO
      CP20  Test VM running                                      | VM de test démarrée
      CP21  All NICs on the isolated bridge / VLAN (guardrail)   | Toutes les NIC sur le bridge / VLAN isolé
      CP22  IP reported by QEMU guest agent                      | IP remontée par le QEMU guest agent
      CP23  Ping from the probe (-PingCheck)                     | Ping depuis la sonde (-PingCheck)
      CP30  Application checks (one CP per test)                 | Contrôles applicatifs (un CP par test)
      CP40  Test VM destroyed, overlays removed, unpublished     | VM détruite, overlays supprimés, dépubliée

    [EN] PREREQUISITES
      - PowerShell 7.2+ on the probe. OpenSSH client (ssh.exe) with a key authorised on the node.
      - Veeam Backup & Replication 13.x (REST API 1.3-rev2, port 9419). Veeam Plug-in for Proxmox VE.
        At least one successful backup of the VMs to verify.
      - A Linux credential record in VBR for root on the Proxmox node (Data Integration API uses it
        to deploy its temporary FUSE agent): Credentials > Add > Linux account. Its ID is read
        automatically from GET /api/v1/credentials (Veeam.NodeCredentialsName).
      - Proxmox VE 8.2 - 9.x node with: an isolated bridge (no uplink) or a VLAN tag that is NOT routed
        anywhere on the physical network; a local storage for overlays (file-based: dir / ZFS / NFS);
        API token for the Proxmox API (Datacenter > Permissions > API Tokens) with VM.Audit, VM.Config.*,
        VM.PowerMgmt, VM.Allocate, Sys.Audit on the node. Root SSH (key) for qm / qemu-img.
      - QEMU guest agent installed in the source VMs (for CP22 / CP23 / CP30).
      - A "probe" machine connected to the isolated bridge / VLAN, for CP23 / CP30 (otherwise SKIP).

    [FR] PRÉREQUIS
      - PowerShell 7.2+ sur la sonde. Client OpenSSH (ssh.exe) avec une clé autorisée sur le nœud.
      - Veeam Backup & Replication 13.x (API REST 1.3-rev2, port 9419). Veeam Plug-in for Proxmox VE.
        Au moins une sauvegarde réussie des VM à vérifier.
      - Un enregistrement d'identifiants Linux dans VBR pour root sur le nœud Proxmox (la Data
        Integration API l'utilise pour déployer son agent FUSE temporaire) : Credentials > Add > Linux
        account. Son ID est lu automatiquement via GET /api/v1/credentials (Veeam.NodeCredentialsName).
      - Nœud Proxmox VE 8.2 - 9.x avec : un bridge isolé (sans uplink) ou un tag VLAN NON routé sur le
        réseau physique ; un stockage local pour les overlays (fichier : dir / ZFS / NFS) ; un jeton API
        Proxmox (Datacenter > Permissions > API Tokens) avec VM.Audit, VM.Config.*, VM.PowerMgmt,
        VM.Allocate, Sys.Audit sur le nœud. SSH root (clé) pour qm / qemu-img.
      - QEMU guest agent installé dans les VM sources (pour CP22 / CP23 / CP30).
      - Une machine « sonde » connectée au bridge / VLAN isolé, pour CP23 / CP30 (sinon SKIP).

    [EN] QUICK START
      1. .\Test-PveBackupBoot.ps1 -InitConfig      then edit RecoveryVerification.json
      2. .\Test-PveBackupBoot.ps1 -VmNames SRV-A,SRV-B -Cleanup -WhatIf   (pre-flight only)
      3. .\Test-PveBackupBoot.ps1 -VmNames SRV-A,SRV-B -PingCheck -Cleanup
      4. Open the HTML report in -ReportDir.
    [FR] DÉMARRAGE RAPIDE
      1. .\Test-PveBackupBoot.ps1 -InitConfig      puis renseigner RecoveryVerification.json
      2. .\Test-PveBackupBoot.ps1 -VmNames SRV-A,SRV-B -Cleanup -WhatIf   (pré-vol seul)
      3. .\Test-PveBackupBoot.ps1 -VmNames SRV-A,SRV-B -PingCheck -Cleanup
      4. Ouvrir le rapport HTML dans -ReportDir.

    REFERENCES / RÉFÉRENCES
      - VBR 13 REST API (1.3-rev2), Data Integration API   https://helpcenter.veeam.com/references/vbr/13/rest/1.3-rev2/tag/Data-Integration-API/
      - VBR User Guide, Disk Publishing (supported types)   https://helpcenter.veeam.com/docs/vbr/userguide/data_integration_api.html
      - Proxmox VE API                                      https://pve.proxmox.com/pve-docs/api-viewer/

    [EN] WHAT THIS PROVES / DOES NOT PROVE
      Proves: the backup is readable and consistent, the OS boots, services respond, RPO is met, and
      how fast a VM can be brought up from backup ("instant" RTO). Does NOT measure the duration of an
      Entire VM Restore to Proxmox VE (workers, storage copy) - run one manually per quarter for that.
    [FR] CE QUE CELA PROUVE / NE PROUVE PAS
      Prouve : la sauvegarde est lisible et cohérente, l'OS démarre, les services répondent, le RPO
      est tenu, et le délai de remise en service depuis la sauvegarde (RTO « instantané »). Ne mesure
      PAS la durée d'un Entire VM Restore vers Proxmox VE (workers, copie du stockage) - en faire un
      manuellement par trimestre pour cela.

    [EN] DISCLAIMER  Illustrative example, provided without warranty. Validate in a test environment
         first. Lines depending on API response field names are tagged "# [API]".
    [FR] AVERTISSEMENT  Exemple illustratif, sans garantie. À valider en recette. Lignes dépendant des
         noms de champs des réponses d'API marquées "# [API]".

.PARAMETER VmNames
    [EN] Source VM names to verify (as shown in Veeam).   [FR] Noms des VM sources (tels qu'affichés dans Veeam).
.PARAMETER ConfigPath
    [EN] JSON configuration file. Command-line parameters override the file.
    [FR] Fichier de configuration JSON. Les paramètres de ligne de commande ont priorité.
.PARAMETER InitConfig
    [EN] Write a configuration template to -ConfigPath and exit.   [FR] Écrit un modèle de configuration puis s'arrête.
.PARAMETER Language
    [EN] Output language: en or fr. Default: system culture.   [FR] Langue : en ou fr. Défaut : culture système.
.PARAMETER PingCheck
    [EN] Enable CP23 (ping the test VM from this machine).   [FR] Active CP23 (ping depuis cette machine).
.PARAMETER Cleanup
    [EN] Destroy test VMs, remove overlays and unpublish at the end (and clean leftovers in pre-flight).
    [FR] Détruit les VM de test, supprime les overlays et dépublie à la fin (et nettoie les résidus en pré-vol).
.PARAMETER FailOnWarning
    [EN] Treat WARN as failure for the exit code.   [FR] Considère WARN comme un échec pour le code de sortie.
.PARAMETER ReportDir
    [EN] Output folder for reports and transcript.   [FR] Dossier de sortie des rapports et du journal.
.PARAMETER VbrCredential
    [EN] VBR account (Backup Administrator or Restore Operator).   [FR] Compte VBR (Backup Administrator ou Restore Operator).
.PARAMETER PveApiToken
    [EN] Proxmox API token as PSCredential: UserName = "user@realm!tokenid", Password = secret.
    [FR] Jeton API Proxmox en PSCredential : UserName = "user@realm!tokenid", Password = secret.

.EXAMPLE
    .\Test-PveBackupBoot.ps1 -InitConfig
.EXAMPLE
    .\Test-PveBackupBoot.ps1 -VmNames SRV-AD01,SRV-FILE01 -PingCheck -Cleanup -Language en
.EXAMPLE
    # [EN] Rotation: 3 different VMs each day.  [FR] Rotation : 3 VM différentes par jour.
    $all = Get-Content .\vms.txt ; $d = (Get-Date).DayOfYear
    $sample = 0..2 | ForEach-Object { $all[($d * 3 + $_) % $all.Count] }
    .\Test-PveBackupBoot.ps1 -VmNames $sample -Cleanup
.EXAMPLE
    .\Test-PveBackupBoot.ps1 -VmNames SRV-A -Cleanup -WhatIf
    [EN] Pre-flight only; publish / create / start / destroy are displayed, not executed.
    [FR] Pré-vol seul ; publication / création / démarrage / destruction affichés, non exécutés.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)]
    [string[]] $VmNames,

    [string] $ConfigPath = ".\RecoveryVerification.json",
    [switch] $InitConfig,
    [ValidateSet('en', 'fr')]
    [string] $Language,

    # --- Optional overrides of the configuration file / Surcharges facultatives ---
    [string] $VbrServer,
    [int]    $VbrPort,
    [string] $VbrApiVersion,
    [string] $NodeCredentialsName,
    [string] $PveApiHost,
    [int]    $PveApiPort,
    [string] $PveNode,
    [string] $PveSshHost,
    [string] $PveSshUser,
    [string] $PveSshKeyPath,
    [string] $IsolatedBridge,
    [nullable[int]] $IsolatedVlanTag,
    [string] $OverlayStoragePath,
    [string] $VmNamePrefix,
    [int]    $VmIdRangeStart,
    [int]    $MaxRestorePointAgeHours,
    [int]    $MaxBootMinutes,
    [int]    $GuestAgentTimeoutMinutes,

    # --- Credentials (prompted if omitted) / Identifiants (demandés si absents) ---
    [PSCredential] $VbrCredential,
    [PSCredential] $PveApiToken,

    # --- Options ---
    [switch] $PingCheck,
    [switch] $Cleanup,
    [switch] $FailOnWarning,
    [string] $ReportDir = ".\Reports"
)

#requires -Version 7.2
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# =====================================================================================
#region  Localisation / Localization
# =====================================================================================

if (-not $Language) { $Language = if ((Get-Culture).Name -like 'fr*') { 'fr' } else { 'en' } }

$Strings = @{
    en = @{
        Step0 = 'Step 0 - Pre-flight: connections and environment checks'
        Step1 = 'Step 1 - Publishing and booting {0} VM(s) from backup into the isolated network'
        Step2 = 'Step 2 - Verifying test VMs'
        Step4 = 'Step 4 - Report'
        CP00 = 'Authentication VBR / Proxmox API / SSH node'
        CP01 = 'Node, isolated bridge, overlay storage and VBR Linux credentials present'
        CP02 = 'Isolated bridge / VLAN is non-routed'
        CP03 = 'No foreign VM on the isolated bridge / VLAN'
        CP04 = 'No leftover test VM or stale disk publishing'
        CP10 = 'Restore point found'
        CP11 = 'Restore point age <= {0} h'
        CP12 = 'Disk publishing completed'
        CP12Start = 'Disk publishing started'
        CP13 = 'Time to boot <= {0} min'
        CP20 = 'Test VM running'
        CP21 = 'NICs only on the isolated bridge / VLAN'
        CP22 = 'IP address reported (QEMU guest agent)'
        CP23 = 'Ping from the probe'
        CP30 = 'Application checks'
        CP30Item = 'Application: {0}'
        CP40 = 'Test VM destroyed, overlays removed, disks unpublished'
        PostBoot = 'Post-boot check'
        Verify = 'Verification'
        D_NodeUnknown = "node '{0}' not found in the Proxmox cluster"
        D_BridgeMissing = "bridge '{0}' not found on node"
        D_StorageMissing = "overlay storage path '{0}' not found or not writable on node"
        D_CredMissing = "no Linux credentials named '{0}' in VBR (Credentials > Add > Linux account)"
        D_BridgeHasIp = 'bridge {0} carries IP {1} / gateway {2} on the node - test VMs would reach the node network'
        D_BridgeUplinkVlan = 'bridge {0} has uplink {1}; VLAN {2} isolation is enforced by the physical switch - Isolation.SwitchIsolationConfirmed=true required'
        D_BridgeOk = 'bridge {0}{1}: no IP, {2}'
        D_NoUplink = 'no uplink'
        D_UplinkConfirmed = 'uplink {0}, switch isolation confirmed by configuration'
        D_ForeignVms = 'VMs present: {0}'
        D_LeftoverDeleteFailed = 'could not delete: {0}'
        D_LeftoverDeleted = '{0} leftover(s) removed: {1}'
        D_LeftoverFound = '{0} leftover(s) - rerun with -Cleanup: {1}'
        D_NoRestorePoint = 'no Proxmox VE restore point for this name'
        D_NoRestorePointShort = 'no restore point'
        D_CreatedOn = 'created on {0}'
        D_RpoMissed = ' - RPO missed, check the backup job'
        D_PublishStarted = '    -> publish session {0} started'
        D_LaunchFailed = 'launch failed'
        D_SessionFailed = 'status = {0} after {1} min ({2})'
        D_PublishFailed = 'publishing failed'
        D_NoDisks = 'no disk image found under {0} on the node'
        D_Disks = '{0} disk(s): {1}'
        D_RtoMissed = ' - RTO target exceeded'
        D_VmNotFound = "VM {0} not found on node"
        D_VmNotFoundShort = 'VM not found'
        D_Status = 'status = {0}'
        D_NicLeak = 'NIC outside the isolated bridge / VLAN ({0}) - VM stopped immediately'
        D_NoNic = 'no NIC attached'
        D_NoIp = 'no IP - guest agent missing / not started, or OS not booted'
        D_NoIpShort = 'no IP address'
        D_PingOff = '-PingCheck not enabled'
        D_NoChecks = 'no check defined (AppChecks section)'
        D_CleanupOff = '-Cleanup not enabled (VM kept for analysis, disks stay published)'
        D_CleanupFailed = "{0} - clean VM {1} / publish {2} manually"
        D_Unexpected = 'unexpected error: {0}'
        D_WhatIf = 'WhatIf'
        M_NeedVm = 'Specify at least one VM with -VmNames (or use -InitConfig to create the configuration).'
        M_ConfigWritten = 'Configuration template written to {0}. Fill it in, then rerun with -VmNames.'
        M_ConfigExists = 'File {0} exists. Overwrite?'
        M_ConfigUnreadable = 'Unreadable configuration ({0}): {1}'
        M_ConfigLoaded = 'Configuration loaded from {0}'
        M_NoConfig = 'No configuration file ({0}): defaults in use. Generate one with -InitConfig.'
        M_CredVbr = 'Veeam Backup & Replication account ({0})'
        M_CredPve = 'Proxmox API token for {0}: user = "user@realm!tokenid", password = secret'
        M_PreflightAbort = 'Stopped in pre-flight: fix the KO items above and rerun.'
        M_Fatal = 'Fatal error: {0}'
        M_ReportFailed = 'Report generation failed: {0}'
        M_Failures = '{0} checkpoint(s) failed.'
        M_AllOk = 'All checkpoints passed: the verified backups boot and respond.'
        M_ShutdownFailed = 'Safety stop of VM {0} failed: {1}'
        M_ApiFailed = 'Call {0} {1} failed (HTTP {2}){3}. {4}'
        M_Http401 = ': invalid credentials or expired token'
        M_Http403 = ': insufficient rights for this operation'
        M_Http404 = ': resource not found (check API version and object IDs)'
        M_Retry = 'Attempt {0} failed ({1}) - retrying in {2} s'
        M_SshFailed = 'SSH command failed (exit {0}): {1}'
        M_DeleteAction = 'Stop and destroy test VM, remove overlays, unpublish disks'
        M_BootAction = 'Publish backup disks to {0} and boot as VM {1} on {2}'
        R_Title = 'Recovery Verification - Proxmox VE (boot from backup)'
        R_Run = 'Run'
        R_Node = 'Node'
        R_Bridge = 'Isolated network'
        R_Fail = 'FAILED - {0} checkpoint(s) KO'
        R_Warn = 'PASSED WITH WARNINGS - {0} WARN'
        R_Ok = 'PASSED - all checkpoints OK'
        R_KpiVms = 'VMs verified'; R_KpiOk = 'checks OK'; R_KpiWarn = 'warnings'; R_KpiKo = 'failures'
        R_KpiRpo = 'RPO target'; R_KpiRto = 'RTO target (boot)'
        R_Summary = 'Summary per VM'
        R_Details = 'Checkpoint details'
        R_H_Vm = 'VM'; R_H_Age = 'Restore point age (h)'; R_H_Dur = 'Time to boot (min)'; R_H_Ip = 'IP'
        R_H_Result = 'Result'; R_H_Time = 'Time'; R_H_Check = 'Check'; R_H_Status = 'Status'; R_H_Detail = 'Detail'
        R_Footer = 'Generated by Test-PveBackupBoot.ps1 (MIT license). Related files: {0}, {1}, transcript {2}.'
        R_OkWarn = 'OK (warnings)'
    }
    fr = @{
        Step0 = "Étape 0 - Pré-vol : connexions et contrôle de l'environnement"
        Step1 = 'Étape 1 - Publication et démarrage de {0} VM depuis la sauvegarde dans le réseau isolé'
        Step2 = 'Étape 2 - Vérification des VM de test'
        Step4 = 'Étape 4 - Rapport'
        CP00 = 'Authentification VBR / API Proxmox / SSH nœud'
        CP01 = 'Nœud, bridge isolé, stockage overlay et identifiants Linux VBR présents'
        CP02 = 'Bridge / VLAN isolé non routé'
        CP03 = 'Aucune VM hors périmètre sur le bridge / VLAN isolé'
        CP04 = 'Aucune VM de test ni publication de disques résiduelle'
        CP10 = 'Point de restauration trouvé'
        CP11 = 'Âge du point de restauration <= {0} h'
        CP12 = 'Publication des disques terminée'
        CP12Start = 'Publication des disques lancée'
        CP13 = 'Délai de démarrage <= {0} min'
        CP20 = 'VM de test démarrée'
        CP21 = 'Cartes réseau sur le bridge / VLAN isolé uniquement'
        CP22 = 'Adresse IP remontée (QEMU guest agent)'
        CP23 = 'Ping depuis la sonde'
        CP30 = 'Contrôles applicatifs'
        CP30Item = 'Applicatif : {0}'
        CP40 = 'VM de test détruite, overlays supprimés, disques dépubliés'
        PostBoot = 'Contrôle post-démarrage'
        Verify = 'Vérification'
        D_NodeUnknown = "nœud '{0}' introuvable dans le cluster Proxmox"
        D_BridgeMissing = "bridge '{0}' introuvable sur le nœud"
        D_StorageMissing = "chemin de stockage overlay '{0}' introuvable ou non inscriptible sur le nœud"
        D_CredMissing = "aucun identifiant Linux nommé '{0}' dans VBR (Credentials > Add > Linux account)"
        D_BridgeHasIp = 'le bridge {0} porte IP {1} / passerelle {2} sur le nœud - les VM de test atteindraient le réseau du nœud'
        D_BridgeUplinkVlan = "le bridge {0} a l'uplink {1} ; l'isolement du VLAN {2} dépend du commutateur physique - Isolation.SwitchIsolationConfirmed=true requis"
        D_BridgeOk = 'bridge {0}{1} : aucune IP, {2}'
        D_NoUplink = 'aucun uplink'
        D_UplinkConfirmed = 'uplink {0}, isolement commutateur confirmé par la configuration'
        D_ForeignVms = 'VM présentes : {0}'
        D_LeftoverDeleteFailed = 'suppression impossible : {0}'
        D_LeftoverDeleted = '{0} résidu(s) supprimé(s) : {1}'
        D_LeftoverFound = '{0} résidu(s) - relancer avec -Cleanup : {1}'
        D_NoRestorePoint = 'aucun point de restauration Proxmox VE pour ce nom'
        D_NoRestorePointShort = 'pas de point de restauration'
        D_CreatedOn = 'créé le {0}'
        D_RpoMissed = ' - RPO non tenu, vérifier le job de sauvegarde'
        D_PublishStarted = '    -> session de publication {0} démarrée'
        D_LaunchFailed = 'échec au lancement'
        D_SessionFailed = 'statut = {0} après {1} min ({2})'
        D_PublishFailed = 'publication en échec'
        D_NoDisks = 'aucune image disque trouvée sous {0} sur le nœud'
        D_Disks = '{0} disque(s) : {1}'
        D_RtoMissed = ' - RTO cible dépassé'
        D_VmNotFound = "VM {0} introuvable sur le nœud"
        D_VmNotFoundShort = 'VM introuvable'
        D_Status = 'statut = {0}'
        D_NicLeak = 'carte réseau hors bridge / VLAN isolé ({0}) - arrêt immédiat de la VM'
        D_NoNic = 'aucune carte réseau attachée'
        D_NoIp = "aucune IP - guest agent absent / non démarré, ou OS non démarré"
        D_NoIpShort = "pas d'adresse IP"
        D_PingOff = 'option -PingCheck non activée'
        D_NoChecks = 'aucun contrôle défini (section AppChecks)'
        D_CleanupOff = 'option -Cleanup non activée (VM conservée pour analyse, disques toujours publiés)'
        D_CleanupFailed = "{0} - nettoyer manuellement la VM {1} / la publication {2}"
        D_Unexpected = 'erreur inattendue : {0}'
        D_WhatIf = 'WhatIf'
        M_NeedVm = 'Indiquez au moins une VM avec -VmNames (ou utilisez -InitConfig pour créer la configuration).'
        M_ConfigWritten = 'Modèle de configuration écrit dans {0}. Renseignez-le puis relancez avec -VmNames.'
        M_ConfigExists = "Le fichier {0} existe. L'écraser ?"
        M_ConfigUnreadable = 'Configuration illisible ({0}) : {1}'
        M_ConfigLoaded = 'Configuration chargée depuis {0}'
        M_NoConfig = 'Aucun fichier de configuration ({0}) : valeurs par défaut utilisées. Générez-en un avec -InitConfig.'
        M_CredVbr = 'Compte Veeam Backup & Replication ({0})'
        M_CredPve = 'Jeton API Proxmox pour {0} : utilisateur = "user@realm!tokenid", mot de passe = secret'
        M_PreflightAbort = 'Arrêt en pré-vol : corrigez les points KO ci-dessus puis relancez.'
        M_Fatal = 'Erreur bloquante : {0}'
        M_ReportFailed = 'Génération des rapports en échec : {0}'
        M_Failures = '{0} point(s) de contrôle en échec.'
        M_AllOk = 'Tous les points de contrôle sont passés : les sauvegardes vérifiées démarrent et répondent.'
        M_ShutdownFailed = "Arrêt de sécurité de la VM {0} impossible : {1}"
        M_ApiFailed = 'Appel {0} {1} en échec (HTTP {2}){3}. {4}'
        M_Http401 = ' : identifiants invalides ou jeton expiré'
        M_Http403 = ' : droits insuffisants pour cette opération'
        M_Http404 = " : ressource introuvable (vérifier la version d'API et les identifiants d'objets)"
        M_Retry = 'Tentative {0} échouée ({1}) - nouvelle tentative dans {2} s'
        M_SshFailed = 'Commande SSH en échec (code {0}) : {1}'
        M_DeleteAction = 'Arrêt et destruction de la VM de test, suppression des overlays, dépublication'
        M_BootAction = 'Publication des disques vers {0} et démarrage comme VM {1} sur {2}'
        R_Title = 'Recovery Verification - Proxmox VE (démarrage depuis la sauvegarde)'
        R_Run = 'Exécution'
        R_Node = 'Nœud'
        R_Bridge = 'Réseau isolé'
        R_Fail = 'ÉCHEC - {0} point(s) de contrôle KO'
        R_Warn = 'SUCCÈS AVEC AVERTISSEMENTS - {0} WARN'
        R_Ok = 'SUCCÈS - tous les points de contrôle sont passés'
        R_KpiVms = 'VM vérifiées'; R_KpiOk = 'contrôles OK'; R_KpiWarn = 'avertissements'; R_KpiKo = 'échecs'
        R_KpiRpo = 'RPO cible'; R_KpiRto = 'RTO cible (démarrage)'
        R_Summary = 'Synthèse par VM'
        R_Details = 'Détail des points de contrôle'
        R_H_Vm = 'VM'; R_H_Age = 'Âge du point de restauration (h)'; R_H_Dur = 'Délai de démarrage (min)'; R_H_Ip = 'IP'
        R_H_Result = 'Résultat'; R_H_Time = 'Heure'; R_H_Check = 'Contrôle'; R_H_Status = 'Statut'; R_H_Detail = 'Détail'
        R_Footer = 'Généré par Test-PveBackupBoot.ps1 (licence MIT). Fichiers associés : {0}, {1}, journal {2}.'
        R_OkWarn = 'OK (avertissements)'
    }
}
$T = $Strings[$Language]

function L {
    param([Parameter(Mandatory)][string]$Key, [Parameter(Position = 1)][object[]]$Params = @())
    $s = $T[$Key]; if (-not $s) { return $Key }
    if ($Params.Count) { return ($s -f $Params) } else { return $s }
}

#endregion

# =====================================================================================
#region  Configuration
# =====================================================================================

$DefaultConfig = [ordered]@{
    Veeam = [ordered]@{
        VbrServer           = "vbr.example.local"   # Veeam Backup & Replication 13.x server
        VbrPort             = 9419                  # REST API port
        VbrApiVersion       = "1.3-rev2"            # x-api-version: 1.3-rev2 = VBR 13.1, 1.3-rev1 = 13.0
        NodeCredentialsName = "root@pve-node01"     # Description/username of the Linux credentials stored in VBR for the node
    }
    Proxmox = [ordered]@{
        ApiHost    = "pve-node01.example.local"    # Proxmox VE API endpoint (any node of the cluster)
        ApiPort    = 8006
        Node       = "pve-node01"                  # Node that will host the test VMs and receive the FUSE publish
        SshHost    = "pve-node01.example.local"    # SSH endpoint of that node (qm / qemu-img)
        SshUser    = "root"
        SshKeyPath = "~/.ssh/id_ed25519"           # Private key authorised on the node
        MountRoot  = "/run/media/Veeam.Mount.Disks" # Where Veeam publishes raw disk images (FUSE mode)
    }
    Target = [ordered]@{
        IsolatedBridge     = "vmbr1"               # Bridge for test VMs
        IsolatedVlanTag    = 4000                  # VLAN tag on that bridge, or null for an untagged isolated bridge
        OverlayStoragePath = "/var/lib/vz/images/rv-overlays"   # Node-local, file-based path for qcow2 overlays
        VmNamePrefix       = "rv-"                 # Test VM names: <prefix><source vm> (lowercase, DNS-safe)
        VmIdRangeStart     = 9900                  # VMIDs 9900, 9901... reserved for test VMs
    }
    VmDefaults = [ordered]@{                       # Hardware of the throw-away VM (override per VM in VmOverrides)
        Memory = 4096; Cores = 2; Cpu = "host"; Machine = "q35"; Bios = "seabios"; ScsiHw = "virtio-scsi-pci"
        OsType = "l26"; Agent = 1; EfiStorage = ""  # Bios = "ovmf" needs EfiStorage (e.g. "local-lvm") for the EFI vars disk
    }
    VmOverrides = [ordered]@{                      # Per source VM: any VmDefaults key
        "SRV-WIN01" = [ordered]@{ OsType = "win11"; Bios = "ovmf"; EfiStorage = "local-lvm"; Memory = 8192 }
    }
    Isolation = [ordered]@{
        SwitchIsolationConfirmed = $false          # Set true once the network team confirms the VLAN tag is not routed / trunked anywhere else
    }
    Thresholds = [ordered]@{
        MaxRestorePointAgeHours  = 30   # RPO target
        MaxBootMinutes           = 20   # RTO target: publish + overlay + qm create + start
        GuestAgentTimeoutMinutes = 10   # Max wait for the guest agent to report an IP
        PublishTimeoutMinutes    = 15
        PollIntervalSeconds      = 15
    }
    # Application checks per VM. Key "*" applies to every VM.
    # Types: Tcp (Port) | Http (Url with {ip}, ExpectedStatus) | Ldap (Port) | Dns (Name) | Sql (Port, Query)
    AppChecks = [ordered]@{
        "*"         = @( [ordered]@{ Type = "Tcp"; Port = 22; Label = "SSH" } )
        "SRV-AD01"  = @( [ordered]@{ Type = "Ldap"; Port = 389; Label = "LDAP" },
                         [ordered]@{ Type = "Dns"; Name = "example.local"; Label = "DNS zone" } )
        "SRV-WEB01" = @( [ordered]@{ Type = "Http"; Url = "https://{ip}/health"; ExpectedStatus = 200; Label = "Health" } )
    }
}

if ($InitConfig) {
    if ((Test-Path $ConfigPath) -and -not $PSCmdlet.ShouldContinue((L M_ConfigExists $ConfigPath), 'Confirmation')) { return }
    $DefaultConfig | ConvertTo-Json -Depth 6 | Set-Content -Path $ConfigPath -Encoding UTF8
    Write-Host (L M_ConfigWritten $ConfigPath) -ForegroundColor Green
    return
}

function Merge-Config {
    param($Defaults, $FilePath, $Bound)
    $cfg = $Defaults
    if (Test-Path $FilePath) {
        try   { $file = Get-Content $FilePath -Raw | ConvertFrom-Json -AsHashtable }
        catch { throw (L M_ConfigUnreadable $FilePath, $_.Exception.Message) }
        foreach ($section in $file.Keys) {
            if ($section -in 'AppChecks', 'VmOverrides') { $cfg[$section] = $file[$section]; continue }
            if (-not $cfg.Contains($section)) { $cfg[$section] = [ordered]@{} }
            foreach ($k in $file[$section].Keys) { $cfg[$section][$k] = $file[$section][$k] }
        }
        Write-Verbose (L M_ConfigLoaded $FilePath)
    }
    else { Write-Warning (L M_NoConfig $FilePath) }

    $map = @{
        VbrServer = 'Veeam.VbrServer'; VbrPort = 'Veeam.VbrPort'; VbrApiVersion = 'Veeam.VbrApiVersion'; NodeCredentialsName = 'Veeam.NodeCredentialsName'
        PveApiHost = 'Proxmox.ApiHost'; PveApiPort = 'Proxmox.ApiPort'; PveNode = 'Proxmox.Node'; PveSshHost = 'Proxmox.SshHost'; PveSshUser = 'Proxmox.SshUser'; PveSshKeyPath = 'Proxmox.SshKeyPath'
        IsolatedBridge = 'Target.IsolatedBridge'; IsolatedVlanTag = 'Target.IsolatedVlanTag'; OverlayStoragePath = 'Target.OverlayStoragePath'; VmNamePrefix = 'Target.VmNamePrefix'; VmIdRangeStart = 'Target.VmIdRangeStart'
        MaxRestorePointAgeHours = 'Thresholds.MaxRestorePointAgeHours'; MaxBootMinutes = 'Thresholds.MaxBootMinutes'; GuestAgentTimeoutMinutes = 'Thresholds.GuestAgentTimeoutMinutes'
    }
    foreach ($p in $map.Keys) {
        if ($Bound.ContainsKey($p)) { $sec, $key = $map[$p].Split('.'); $cfg[$sec][$key] = $Bound[$p] }
    }
    return $cfg
}

if (-not $VmNames -or $VmNames.Count -eq 0) { throw (L M_NeedVm) }
$Cfg = Merge-Config $DefaultConfig $ConfigPath $PSBoundParameters
if (-not $VbrCredential) { $VbrCredential = Get-Credential -Message (L M_CredVbr $Cfg.Veeam.VbrServer) }
if (-not $PveApiToken)   { $PveApiToken   = Get-Credential -Message (L M_CredPve $Cfg.Proxmox.ApiHost) }

#endregion

# =====================================================================================
#region  Logging and checkpoints / Journalisation et points de contrôle
# =====================================================================================

$RunId = Get-Date -Format 'yyyyMMdd-HHmmss'
New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null
$LogPath = Join-Path $ReportDir "RecoveryVerification-$RunId.log"
Start-Transcript -Path $LogPath -Append | Out-Null

$Checkpoints = [System.Collections.Generic.List[object]]::new()

function Write-Step { param([string]$Title) Write-Host "`n=== $Title ===" -ForegroundColor Cyan }

function Add-Checkpoint {
    param(
        [Parameter(Mandatory)][string] $Id,
        [string] $Vm = '-',
        [Parameter(Mandatory)][string] $Label,
        [Parameter(Mandatory)][ValidateSet('OK','KO','WARN','SKIP')][string] $Status,
        [string] $Detail = '',
        [double] $Value = [double]::NaN
    )
    $Checkpoints.Add([pscustomobject]@{
        RunId = $RunId; Time = (Get-Date -Format 's'); CP = $Id; VM = $Vm
        Label = $Label; Status = $Status; Value = $Value; Detail = $Detail
    })
    $color = switch ($Status) { 'OK' { 'Green' } 'KO' { 'Red' } 'WARN' { 'Yellow' } default { 'DarkGray' } }
    $suffix = if ($Detail) { " - $Detail" } else { '' }
    Write-Host ("  [{0}] {1,-4} {2,-16} {3}{4}" -f $Id, $Status, $Vm, $Label, $suffix) -ForegroundColor $color
}

function Skip-RemainingChecks {
    param([string]$Vm, [string]$Reason)
    foreach ($cp in 'CP13','CP20','CP21','CP22','CP23','CP30','CP40') { Add-Checkpoint $cp $Vm (L PostBoot) SKIP $Reason }
}

#endregion

# =====================================================================================
#region  API access (VBR REST, Proxmox API, SSH) / Accès API
# =====================================================================================

function Invoke-Api {
    <# Generic REST call: 3 retries on network / 5xx / 429, readable error with HTTP code and body. #>
    param(
        [Parameter(Mandatory)][ValidateSet('GET','POST','PUT','DELETE')][string] $Method,
        [Parameter(Mandatory)][string] $Uri,
        [hashtable] $Headers = @{},
        $Body,
        [string] $ContentType = 'application/json',
        [int] $Retries = 3
    )
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            $p = @{ Method = $Method; Uri = $Uri; Headers = $Headers; SkipCertificateCheck = $true; ContentType = $ContentType; TimeoutSec = 120 }
            if ($null -ne $Body) { $p.Body = if ($ContentType -eq 'application/json') { $Body | ConvertTo-Json -Depth 12 } else { $Body } }
            Write-Verbose "$Method $Uri"
            return Invoke-RestMethod @p
        }
        catch {
            $status = $null; $content = ''
            if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
                $status = [int]$_.Exception.Response.StatusCode
                try { $content = $_.ErrorDetails.Message } catch {}
            }
            $retryable = (-not $status) -or $status -ge 500 -or $status -eq 429
            if ($retryable -and $attempt -lt $Retries) {
                Write-Verbose (L M_Retry $attempt, $status, (5 * $attempt)); Start-Sleep -Seconds (5 * $attempt); continue
            }
            $hint = switch ($status) { 401 { L M_Http401 } 403 { L M_Http403 } 404 { L M_Http404 } default { '' } }
            throw (L M_ApiFailed $Method, $Uri, $status, $hint, $content).Trim()
        }
    }
}

function Get-Items {
    <# Normalize collections returned flat or under .data / .results #>
    param($Response)
    foreach ($prop in 'data','results') {
        if ($Response -is [pscustomobject] -and $Response.PSObject.Properties[$prop]) { return @($Response.$prop) }
    }
    return @($Response)
}

function Connect-Vbr {
    param($Server, $Port, $ApiVersion, [PSCredential]$Credential)
    $base = "https://$Server`:$Port/api"
    $tok = Invoke-RestMethod -Method Post -Uri "$base/oauth2/token" -SkipCertificateCheck -TimeoutSec 60 `
        -Headers @{ 'x-api-version' = $ApiVersion } -ContentType 'application/x-www-form-urlencoded' `
        -Body @{ grant_type = 'password'; username = $Credential.UserName; password = $Credential.GetNetworkCredential().Password }
    return @{ Base = "$base/v1"; Headers = @{ Authorization = "Bearer $($tok.access_token)"; 'x-api-version' = $ApiVersion } }
}

function Connect-Pve {
    <# Proxmox VE API with an API token (no ticket / CSRF needed). #>
    param($Host_, $Port, [PSCredential]$Token)
    $base = "https://$Host_`:$Port/api2/json"
    $ctx  = @{ Base = $base; Headers = @{ Authorization = "PVEAPIToken=$($Token.UserName)=$($Token.GetNetworkCredential().Password)" } }
    Invoke-Api GET "$base/version" $ctx.Headers | Out-Null   # connection test
    return $ctx
}

function Invoke-Ssh {
    <# Run a command on the node with the OpenSSH client (key auth, non-interactive). Returns stdout. #>
    param([Parameter(Mandatory)][string]$Command, [switch]$AllowFailure)
    $key  = [Environment]::ExpandEnvironmentVariables(($Cfg.Proxmox.SshKeyPath -replace '^~', $HOME))
    $sshArgs = @('-i', $key, '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=accept-new', '-o', 'ConnectTimeout=20',
                 "$($Cfg.Proxmox.SshUser)@$($Cfg.Proxmox.SshHost)", $Command)
    Write-Verbose "ssh: $Command"
    $out = & ssh @sshArgs 2>&1
    $code = $LASTEXITCODE
    if ($code -ne 0 -and -not $AllowFailure) { throw (L M_SshFailed $code, (($out | Out-String).Trim())) }
    return ($out | Where-Object { $_ -is [string] -or $_ -isnot [System.Management.Automation.ErrorRecord] } | Out-String).Trim()
}

#endregion

# =====================================================================================
#region  Business functions / Fonctions métier
# =====================================================================================

function Get-LatestRestorePoint {
    <# Latest Proxmox VE restore point of a VM (VBR REST 1.3), exact name match. #>
    param($Vbr, [string]$VmName)
    $q = "nameFilter=$([uri]::EscapeDataString($VmName))&platformNameFilter=Proxmox&orderColumn=CreationTime&orderAsc=false&limit=10"
    try   { $rps = Get-Items (Invoke-Api GET "$($Vbr.Base)/restorePoints?$q" $Vbr.Headers) }           # [API] 1.3
    catch { $rps = Get-Items (Invoke-Api GET "$($Vbr.Base)/objectRestorePoints?$q" $Vbr.Headers) }     # [API] 1.2 fallback
    return $rps | Where-Object { $_.name -eq $VmName } | Sort-Object creationTime -Descending | Select-Object -First 1
}

function Get-VbrLinuxCredentialId {
    <# ID of the Linux credentials record stored in VBR (matched on username or description). #>
    param($Vbr, [string]$NameOrUser)
    $creds = Get-Items (Invoke-Api GET "$($Vbr.Base)/credentials?typeFilter=Linux&limit=200" $Vbr.Headers)   # [API]
    $c = $creds | Where-Object { $_.username -eq $NameOrUser -or $_.description -eq $NameOrUser } | Select-Object -First 1
    if (-not $c) { $c = $creds | Where-Object { "$($_.username)@$($_.description)" -like "*$NameOrUser*" } | Select-Object -First 1 }
    return $c
}

function Start-DiskPublishing {
    <# Data Integration API: publish restore point disks to the node in FUSE mode. Returns session id. #>
    param($Vbr, $RestorePoint, [string]$TargetServer, [string]$CredentialsId, [string]$Reason)
    $body = @{ restorePointId = $RestorePoint.id; type = 'FUSELinuxMount'; targetServerName = $TargetServer
               targetServerCredentialsId = $CredentialsId; credentialsStorageType = 'Permanent'; reason = $Reason }
    $s = Invoke-Api POST "$($Vbr.Base)/dataIntegration/publish" $Vbr.Headers $body
    return $s.id
}

function Wait-VbrSession {
    <# Wait for a VBR session to end. Returns final result ('Success', 'Warning', 'Failed', 'Timeout'). #>
    param($Vbr, [string]$SessionId, [int]$TimeoutMinutes, [int]$PollSeconds)
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    do {
        Start-Sleep -Seconds $PollSeconds
        $s = Invoke-Api GET "$($Vbr.Base)/sessions/$SessionId" $Vbr.Headers
        $state = $s.state                                                                    # [API] Starting / Working / Stopped
    } while ($state -ne 'Stopped' -and (Get-Date) -lt $deadline)
    if ($state -ne 'Stopped') { return @{ Result = 'Timeout'; Message = '' } }
    return @{ Result = $s.result.result; Message = $s.result.message }                       # [API]
}

function Get-PublishMount {
    <# Mount point of a published restore point (to read disks and to unpublish). #>
    param($Vbr, [string]$RestorePointId)
    $m = Get-Items (Invoke-Api GET "$($Vbr.Base)/dataIntegration?limit=200" $Vbr.Headers)
    return $m | Where-Object { $_.restorePointId -eq $RestorePointId } | Select-Object -First 1
}

function Stop-DiskPublishing {
    param($Vbr, [string]$MountId)
    Invoke-Api POST "$($Vbr.Base)/dataIntegration/$MountId/unpublish" $Vbr.Headers | Out-Null
}

function Get-PublishedDiskImages {
    <#
      Raw disk images currently published on the node (FUSE mode), sorted by path.
      Called before and after a publish session: the difference = the disks of that session.
    #>
    param([string]$MountRoot)
    $ls = Invoke-Ssh "find '$MountRoot' -mindepth 1 -maxdepth 4 -type f 2>/dev/null | sort" -AllowFailure
    return @($ls -split "`n" | Where-Object { $_ -and ($_ -notmatch '\.(json|xml|txt|log)$') })
}

function New-TestVm {
    <# Create qcow2 overlays and a throw-away VM on the node, attached to the isolated bridge/VLAN. #>
    param([int]$VmId, [string]$Name, [string[]]$DiskImages, $Hw, [string]$OverlayDir)
    $net = "virtio,bridge=$($Cfg.Target.IsolatedBridge)" + $(if ($null -ne $Cfg.Target.IsolatedVlanTag -and "$($Cfg.Target.IsolatedVlanTag)" -ne '') { ",tag=$($Cfg.Target.IsolatedVlanTag)" } else { '' }) + ",firewall=1"
    $cmds = @("mkdir -p '$OverlayDir'")
    $disks = @(); $i = 0
    foreach ($img in $DiskImages) {
        $ov = "$OverlayDir/disk$i.qcow2"
        $cmds += "qemu-img create -q -f qcow2 -b '$img' -F raw '$ov'"
        $disks += "--scsi$i '$ov'"
        $i++
    }
    $bios = if ($Hw.Bios -eq 'ovmf') { "--bios ovmf" + $(if ($Hw.EfiStorage) { " --efidisk0 '$($Hw.EfiStorage):1,efitype=4m,pre-enrolled-keys=0'" } else { '' }) } else { "--bios seabios" }
    $create = "qm create $VmId --name '$Name' --memory $($Hw.Memory) --cores $($Hw.Cores) --cpu $($Hw.Cpu) --machine $($Hw.Machine) " +
              "--scsihw $($Hw.ScsiHw) --ostype $($Hw.OsType) --agent $($Hw.Agent) $bios --net0 '$net' --boot order=scsi0 " +
              "--description 'Veeam Recovery Verification $RunId - TEMPORARY, boots from backup, safe to destroy' " + ($disks -join ' ')
    $cmds += $create
    $cmds += "qm start $VmId"
    Invoke-Ssh ($cmds -join ' && ') | Out-Null
}

function Get-PveVm {
    param($Pve, [string]$Node, [int]$VmId)
    try {
        $st  = (Invoke-Api GET "$($Pve.Base)/nodes/$Node/qemu/$VmId/status/current" $Pve.Headers).data
        $cfg = (Invoke-Api GET "$($Pve.Base)/nodes/$Node/qemu/$VmId/config" $Pve.Headers).data
        return @{ Status = $st; Config = $cfg }
    } catch { return $null }
}

function Get-PveVmNics {
    <# Parse netN entries of a VM config: bridge + tag. #>
    param($Config)
    $nics = @()
    foreach ($p in $Config.PSObject.Properties | Where-Object { $_.Name -match '^net\d+$' }) {
        $bridge = if ($p.Value -match 'bridge=([^,]+)') { $Matches[1] } else { '' }
        $tag    = if ($p.Value -match 'tag=(\d+)')      { [int]$Matches[1] } else { $null }
        $nics += @{ Name = $p.Name; Bridge = $bridge; Tag = $tag; Raw = $p.Value }
    }
    return $nics
}

function Test-NicIsolated {
    param($Nic)
    $wantTag = if ($null -ne $Cfg.Target.IsolatedVlanTag -and "$($Cfg.Target.IsolatedVlanTag)" -ne '') { [int]$Cfg.Target.IsolatedVlanTag } else { $null }
    if ($Nic.Bridge -ne $Cfg.Target.IsolatedBridge) { return $false }
    if ($null -ne $wantTag) { return ($Nic.Tag -eq $wantTag) }
    return ($null -eq $Nic.Tag)
}

function Wait-GuestIp {
    <# Wait until the VM is running and the QEMU guest agent reports a non-loopback IPv4. #>
    param($Pve, [string]$Node, [int]$VmId, [int]$TimeoutMinutes, [int]$PollSeconds)
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes); $vm = $null; $ip = $null
    do {
        Start-Sleep -Seconds $PollSeconds
        $vm = Get-PveVm $Pve $Node $VmId
        if ($vm -and $vm.Status.status -eq 'running') {
            try {
                $r = (Invoke-Api GET "$($Pve.Base)/nodes/$Node/qemu/$VmId/agent/network-get-interfaces" $Pve.Headers -Retries 1).data.result   # [API]
                $ip = @($r | ForEach-Object { $_.'ip-addresses' } | Where-Object { $_.'ip-address-type' -eq 'ipv4' -and $_.'ip-address' -notlike '127.*' -and $_.'ip-address' -notlike '169.254.*' } |
                        ForEach-Object { $_.'ip-address' }) | Select-Object -First 1
            } catch { $ip = $null }   # agent not ready yet
        }
    } while (-not $ip -and (Get-Date) -lt $deadline)
    return @{ Vm = $vm; Ip = $ip }
}

function Remove-TestVm {
    [CmdletBinding(SupportsShouldProcess)]
    param([int]$VmId, [string]$Name, [string]$OverlayDir)
    if ($PSCmdlet.ShouldProcess($Name, (L M_DeleteAction))) {
        Invoke-Ssh "qm stop $VmId --skiplock 1 >/dev/null 2>&1 || true; sleep 3; qm destroy $VmId --purge 1 --skiplock 1 >/dev/null 2>&1 || true; rm -rf '$OverlayDir'" -AllowFailure | Out-Null
    }
}

function Test-AppCheck {
    param($Check, [string]$Ip)
    try {
        switch ($Check['Type']) {
            'Tcp' {
                $ok = Test-NetConnection -ComputerName $Ip -Port $Check['Port'] -WarningAction SilentlyContinue -InformationLevel Quiet
                return @{ Ok = [bool]$ok; Detail = "tcp/$($Check['Port'])" }
            }
            'Ldap' {
                $ok = Test-NetConnection -ComputerName $Ip -Port $Check['Port'] -WarningAction SilentlyContinue -InformationLevel Quiet
                if (-not $ok) { return @{ Ok = $false; Detail = "tcp/$($Check['Port']) closed" } }
                $conn = [System.DirectoryServices.Protocols.LdapConnection]::new("$Ip`:$($Check['Port'])")
                $conn.AuthType = 'Anonymous'; $conn.Bind()
                return @{ Ok = $true; Detail = 'anonymous RootDSE bind OK' }
            }
            'Http' {
                $url = $Check['Url'] -replace '\{ip\}', $Ip
                $r = Invoke-WebRequest -Uri $url -SkipCertificateCheck -TimeoutSec 15 -UseBasicParsing
                $expected = if ($Check['ExpectedStatus']) { [int]$Check['ExpectedStatus'] } else { 200 }
                return @{ Ok = ([int]$r.StatusCode -eq $expected); Detail = "HTTP $($r.StatusCode) $url" }
            }
            'Dns' {
                $r = Resolve-DnsName -Name $Check['Name'] -Server $Ip -DnsOnly
                return @{ Ok = ($r.Count -gt 0); Detail = "$($Check['Name']) -> $Ip" }
            }
            'Sql' {
                if (-not (Get-Module -ListAvailable SqlServer)) { return @{ Ok = $null; Detail = 'SqlServer module missing' } }
                $res = Invoke-Sqlcmd -ServerInstance "$Ip,$($Check['Port'])" -Query $Check['Query'] -TrustServerCertificate -ConnectionTimeout 15
                return @{ Ok = ($null -ne $res); Detail = "result = $($res[0])" }
            }
            default { return @{ Ok = $null; Detail = "unknown check type: $($Check['Type'])" } }
        }
    }
    catch { return @{ Ok = $false; Detail = $_.Exception.Message } }
}

function Get-ChecksForVm {
    param($AppChecks, [string]$Vm)
    $list = @()
    if ($AppChecks.Contains('*')) { $list += @($AppChecks['*']) }
    if ($AppChecks.Contains($Vm)) { $list += @($AppChecks[$Vm]) }
    return $list
}

function Get-VmHardware {
    param([string]$Vm)
    $hw = [ordered]@{}
    foreach ($k in $Cfg.VmDefaults.Keys) { $hw[$k] = $Cfg.VmDefaults[$k] }
    if ($Cfg.VmOverrides -and $Cfg.VmOverrides.Contains($Vm)) { foreach ($k in $Cfg.VmOverrides[$Vm].Keys) { $hw[$k] = $Cfg.VmOverrides[$Vm][$k] } }
    return $hw
}

#endregion

# =====================================================================================
#region  Reports / Rapports
# =====================================================================================

function New-Summary {
    param($VmNames, $Checkpoints, [switch]$FailOnWarning)
    foreach ($vm in $VmNames) {
        $cps = $Checkpoints | Where-Object VM -eq $vm
        $ko  = @($cps | Where-Object Status -eq 'KO').Count
        $wa  = @($cps | Where-Object Status -eq 'WARN').Count
        [pscustomobject]@{
            VM               = $vm
            RestorePointAgeH = ($cps | Where-Object CP -eq 'CP11' | Select-Object -First 1).Value
            BootMinutes      = ($cps | Where-Object CP -eq 'CP13' | Select-Object -First 1).Value
            IP               = ($cps | Where-Object { $_.CP -eq 'CP22' -and $_.Status -eq 'OK' } | Select-Object -First 1).Detail
            KO = $ko; WARN = $wa
            Result = if ($ko -gt 0 -or ($FailOnWarning -and $wa -gt 0)) { 'KO' } elseif ($wa -gt 0) { L R_OkWarn } else { 'OK' }
        }
    }
}

function Export-Reports {
    param($Summary, $Checkpoints, $Cfg, [string]$Dir, [string]$RunId, [string[]]$VmNames)
    $csv  = Join-Path $Dir "RecoveryVerification-$RunId.csv"
    $json = Join-Path $Dir "RecoveryVerification-$RunId.json"
    $html = Join-Path $Dir "RecoveryVerification-$RunId.html"

    $Checkpoints | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8 -Delimiter ';'
    [ordered]@{ RunId = $RunId; Date = (Get-Date -Format 's'); Language = $Language; Platform = 'ProxmoxVE'; Method = 'DataIntegrationApi+QemuOverlay'
                Target = $Cfg.Target; Thresholds = $Cfg.Thresholds; Summary = $Summary; Checkpoints = $Checkpoints } |
        ConvertTo-Json -Depth 6 | Set-Content -Path $json -Encoding UTF8

    $totKo = @($Checkpoints | Where-Object Status -eq 'KO').Count
    $totWa = @($Checkpoints | Where-Object Status -eq 'WARN').Count
    $totOk = @($Checkpoints | Where-Object Status -eq 'OK').Count
    $banner = if ($totKo -gt 0) { @{ Text = (L R_Fail $totKo); Color = '#c62828' } }
              elseif ($totWa -gt 0) { @{ Text = (L R_Warn $totWa); Color = '#ef6c00' } }
              else { @{ Text = (L R_Ok); Color = '#2e7d32' } }
    $enc = { param($t) [System.Net.WebUtility]::HtmlEncode([string]$t) }
    $okWarnLabel = L R_OkWarn
    $netLabel = "$($Cfg.Target.IsolatedBridge)" + $(if ("$($Cfg.Target.IsolatedVlanTag)" -ne '') { " / VLAN $($Cfg.Target.IsolatedVlanTag)" } else { '' })

    $rowsSummary = ($Summary | ForEach-Object {
        $cls = if ($_.Result -eq 'KO') { 'ko' } elseif ($_.Result -eq $okWarnLabel) { 'warn' } else { 'ok' }
        "<tr><td>$(& $enc $_.VM)</td><td>$(& $enc $_.RestorePointAgeH)</td><td>$(& $enc $_.BootMinutes)</td><td>$(& $enc $_.IP)</td><td>$($_.KO)</td><td>$($_.WARN)</td><td class='$cls'>$(& $enc $_.Result)</td></tr>"
    }) -join "`n"
    $rowsCp = ($Checkpoints | ForEach-Object {
        "<tr><td>$(& $enc $_.Time)</td><td>$(& $enc $_.CP)</td><td>$(& $enc $_.VM)</td><td>$(& $enc $_.Label)</td><td class='$($_.Status.ToLower())'>$(& $enc $_.Status)</td><td>$(& $enc $_.Detail)</td></tr>"
    }) -join "`n"

    @"
<!DOCTYPE html><html lang="$Language"><head><meta charset="utf-8"><title>$(L R_Title) - $RunId</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#222;margin:24px;background:#fafafa}
h1{font-size:20px;margin:0 0 4px}h2{font-size:16px;margin:24px 0 8px;border-bottom:1px solid #ddd;padding-bottom:4px}
.banner{color:#fff;padding:10px 14px;border-radius:4px;font-weight:600;margin:12px 0;background:$($banner.Color)}
.kpi{display:inline-block;background:#fff;border:1px solid #e0e0e0;border-radius:4px;padding:8px 14px;margin:0 8px 8px 0}.kpi b{font-size:18px;display:block}
table{border-collapse:collapse;width:100%;background:#fff}th,td{border:1px solid #e0e0e0;padding:6px 8px;text-align:left;vertical-align:top}
th{background:#f0f0f0}td.ok{background:#e8f5e9;color:#2e7d32;font-weight:600}td.ko{background:#ffebee;color:#c62828;font-weight:600}
td.warn{background:#fff3e0;color:#ef6c00;font-weight:600}td.skip{color:#888}small{color:#666}
</style></head><body>
<h1>$(L R_Title)</h1>
<small>$(L R_Run) $RunId &middot; $(Get-Date -Format 'yyyy-MM-dd HH:mm') &middot; $(L R_Node) $(& $enc $Cfg.Proxmox.Node) &middot; $(L R_Bridge) $(& $enc $netLabel) &middot; VBR $(& $enc $Cfg.Veeam.VbrServer)</small>
<div class="banner">$(& $enc $banner.Text)</div>
<div class="kpi"><b>$($VmNames.Count)</b>$(L R_KpiVms)</div><div class="kpi"><b>$totOk</b>$(L R_KpiOk)</div>
<div class="kpi"><b>$totWa</b>$(L R_KpiWarn)</div><div class="kpi"><b>$totKo</b>$(L R_KpiKo)</div>
<div class="kpi"><b>$($Cfg.Thresholds.MaxRestorePointAgeHours) h</b>$(L R_KpiRpo)</div><div class="kpi"><b>$($Cfg.Thresholds.MaxBootMinutes) min</b>$(L R_KpiRto)</div>
<h2>$(L R_Summary)</h2>
<table><tr><th>$(L R_H_Vm)</th><th>$(L R_H_Age)</th><th>$(L R_H_Dur)</th><th>$(L R_H_Ip)</th><th>KO</th><th>WARN</th><th>$(L R_H_Result)</th></tr>
$rowsSummary</table>
<h2>$(L R_Details)</h2>
<table><tr><th>$(L R_H_Time)</th><th>CP</th><th>$(L R_H_Vm)</th><th>$(L R_H_Check)</th><th>$(L R_H_Status)</th><th>$(L R_H_Detail)</th></tr>
$rowsCp</table>
<p><small>$(L R_Footer (Split-Path $csv -Leaf), (Split-Path $json -Leaf), (Split-Path $LogPath -Leaf))</small></p>
</body></html>
"@ | Set-Content -Path $html -Encoding UTF8

    return @{ Csv = $csv; Json = $json; Html = $html }
}

#endregion

# =====================================================================================
#region  Execution / Exécution
# =====================================================================================

$exitCode = 0
$prefix   = $Cfg.Target.VmNamePrefix
$node     = $Cfg.Proxmox.Node
try {
    # ---------------------------------------------------------------------------------
    Write-Step (L Step0)
    # ---------------------------------------------------------------------------------
    try {
        $Vbr = Connect-Vbr $Cfg.Veeam.VbrServer $Cfg.Veeam.VbrPort $Cfg.Veeam.VbrApiVersion $VbrCredential
        $Pve = Connect-Pve $Cfg.Proxmox.ApiHost $Cfg.Proxmox.ApiPort $PveApiToken
        $pveVer = Invoke-Ssh "pveversion"
        Add-Checkpoint CP00 -Label (L CP00) -Status OK -Detail "VBR $($Cfg.Veeam.VbrApiVersion), $pveVer"
    }
    catch { Add-Checkpoint CP00 -Label (L CP00) -Status KO -Detail $_.Exception.Message; throw [System.Exception]::new('PREFLIGHT', $_.Exception) }

    try {
        $nodes = Get-Items (Invoke-Api GET "$($Pve.Base)/nodes" $Pve.Headers)
        if (-not ($nodes | Where-Object node -eq $node)) { throw (L D_NodeUnknown $node) }
        $ifaces = Get-Items (Invoke-Api GET "$($Pve.Base)/nodes/$node/network" $Pve.Headers)
        $bridge = $ifaces | Where-Object { $_.iface -eq $Cfg.Target.IsolatedBridge -and $_.type -eq 'bridge' } | Select-Object -First 1
        if (-not $bridge) { throw (L D_BridgeMissing $Cfg.Target.IsolatedBridge) }
        $st = Invoke-Ssh "mkdir -p '$($Cfg.Target.OverlayStoragePath)' && test -w '$($Cfg.Target.OverlayStoragePath)' && echo ok" -AllowFailure
        if ($st -ne 'ok') { throw (L D_StorageMissing $Cfg.Target.OverlayStoragePath) }
        $linCred = Get-VbrLinuxCredentialId $Vbr $Cfg.Veeam.NodeCredentialsName
        if (-not $linCred) { throw (L D_CredMissing $Cfg.Veeam.NodeCredentialsName) }
        Add-Checkpoint CP01 -Label (L CP01) -Status OK -Detail "$node / $($bridge.iface) / $($Cfg.Target.OverlayStoragePath) / cred $($linCred.username)"
    }
    catch { Add-Checkpoint CP01 -Label (L CP01) -Status KO -Detail $_.Exception.Message; throw [System.Exception]::new('PREFLIGHT', $_.Exception) }

    # CP02 - isolation (blocking). The node must not have an IP on the bridge; a bridge with an uplink needs the switch attestation.
    $bAddr = if ($bridge.PSObject.Properties['address']) { $bridge.address } else { $null }
    $bGw   = if ($bridge.PSObject.Properties['gateway']) { $bridge.gateway } else { $null }
    $ports = if ($bridge.PSObject.Properties['bridge_ports']) { "$($bridge.bridge_ports)".Trim() } else { '' }
    $tag   = if ("$($Cfg.Target.IsolatedVlanTag)" -ne '') { $Cfg.Target.IsolatedVlanTag } else { $null }
    $tagLabel = if ($null -ne $tag) { " tag $tag" } else { '' }
    if ($bAddr -or $bGw) {
        Add-Checkpoint CP02 -Label (L CP02) -Status KO -Detail (L D_BridgeHasIp $bridge.iface, $bAddr, $bGw); throw [System.Exception]::new('PREFLIGHT')
    }
    if ($ports -and $ports -ne 'none' -and -not [bool]$Cfg.Isolation.SwitchIsolationConfirmed) {
        Add-Checkpoint CP02 -Label (L CP02) -Status KO -Detail (L D_BridgeUplinkVlan $bridge.iface, $ports, $tag); throw [System.Exception]::new('PREFLIGHT')
    }
    $upl = if ($ports -and $ports -ne 'none') { L D_UplinkConfirmed $ports } else { L D_NoUplink }
    Add-Checkpoint CP02 -Label (L CP02) -Status OK -Detail (L D_BridgeOk $bridge.iface, $tagLabel, $upl)

    # CP03 / CP04 - occupants of the isolated network and leftovers (VMs + stale publish sessions)
    $allVms = @((Get-Items (Invoke-Api GET "$($Pve.Base)/cluster/resources?type=vm" $Pve.Headers)) | Where-Object { $_.type -eq 'qemu' })
    $onIso = @(); $stale = @()
    foreach ($v in $allVms | Where-Object node -eq $node) {
        $c = try { (Invoke-Api GET "$($Pve.Base)/nodes/$node/qemu/$($v.vmid)/config" $Pve.Headers).data } catch { $null }
        if (-not $c) { continue }
        $isTest = ($v.name -like "$prefix*") -or ($v.vmid -ge $Cfg.Target.VmIdRangeStart -and $v.vmid -lt ($Cfg.Target.VmIdRangeStart + 100) -and "$($c.description)" -like '*Veeam Recovery Verification*')
        if ($isTest) { $stale += $v; continue }
        if (@(Get-PveVmNics $c | Where-Object { Test-NicIsolated $_ }).Count) { $onIso += $v }
    }
    if ($onIso.Count) { Add-Checkpoint CP03 -Label (L CP03) -Status KO -Detail (L D_ForeignVms (($onIso | ForEach-Object { "$($_.name) ($($_.vmid))" }) -join ', ')) }
    else              { Add-Checkpoint CP03 -Label (L CP03) -Status OK }

    $stalePub = @((Get-Items (Invoke-Api GET "$($Vbr.Base)/dataIntegration?limit=200" $Vbr.Headers)) | Where-Object { $_.mountState -in 'Mounted','Mounting' -and $_.info.mode -eq 'Fuse' })   # [API]
    $leftNames = @($stale | ForEach-Object { "VM $($_.vmid)" }) + @($stalePub | ForEach-Object { "publish $($_.restorePointName)" })
    if ($leftNames.Count -eq 0) { Add-Checkpoint CP04 -Label (L CP04) -Status OK }
    elseif ($Cleanup) {
        $failed = @()
        foreach ($sv in $stale)    { try { Remove-TestVm $sv.vmid $sv.name "$($Cfg.Target.OverlayStoragePath)/$($sv.vmid)" } catch { $failed += "VM $($sv.vmid)" } }
        foreach ($sp in $stalePub) { try { Stop-DiskPublishing $Vbr $sp.id } catch { $failed += "publish $($sp.restorePointName)" } }
        if ($failed.Count) { Add-Checkpoint CP04 -Label (L CP04) -Status KO -Detail (L D_LeftoverDeleteFailed ($failed -join ', ')); throw [System.Exception]::new('PREFLIGHT') }
        Add-Checkpoint CP04 -Label (L CP04) -Status WARN -Detail (L D_LeftoverDeleted $leftNames.Count, ($leftNames -join ', '))
    }
    else { Add-Checkpoint CP04 -Label (L CP04) -Status KO -Detail (L D_LeftoverFound $leftNames.Count, ($leftNames -join ', ')); throw [System.Exception]::new('PREFLIGHT') }

    # ---------------------------------------------------------------------------------
    Write-Step (L Step1 $VmNames.Count)
    # ---------------------------------------------------------------------------------
    $sessions = @{}; $nextId = [int]$Cfg.Target.VmIdRangeStart
    $poll = $Cfg.Thresholds.PollIntervalSeconds
    foreach ($vm in $VmNames) {
        try {
            $rp = Get-LatestRestorePoint $Vbr $vm
            if (-not $rp) { Add-Checkpoint CP10 $vm (L CP10) KO (L D_NoRestorePoint); Skip-RemainingChecks $vm (L D_NoRestorePointShort); continue }
            Add-Checkpoint CP10 $vm (L CP10) OK (L D_CreatedOn $rp.creationTime)

            $ageH  = [math]::Round(((Get-Date) - [datetime]$rp.creationTime).TotalHours, 1)
            $rpoOk = $ageH -le $Cfg.Thresholds.MaxRestorePointAgeHours
            Add-Checkpoint CP11 $vm (L CP11 $Cfg.Thresholds.MaxRestorePointAgeHours) ($rpoOk ? 'OK' : 'KO') "$ageH h$(if (-not $rpoOk) { L D_RpoMissed })" $ageH

            while ($allVms | Where-Object vmid -eq $nextId) { $nextId++ }
            $vmid = $nextId; $nextId++
            $target = ($prefix + $vm).ToLower() -replace '[^a-z0-9\-]', '-'
            if (-not $PSCmdlet.ShouldProcess($vm, (L M_BootAction $Cfg.Proxmox.SshHost, $vmid, $node))) { Skip-RemainingChecks $vm (L D_WhatIf); continue }

            # Publish (sequential per VM so that the new disk images can be attributed unambiguously)
            $started  = Get-Date
            $baseline = Get-PublishedDiskImages $Cfg.Proxmox.MountRoot
            $sid = Start-DiskPublishing $Vbr $rp $Cfg.Proxmox.SshHost $linCred.id "Recovery Verification $RunId"
            $s = @{ SessionId = $sid; Rp = $rp; VmId = $vmid; Target = $target; Started = $started; OverlayDir = "$($Cfg.Target.OverlayStoragePath)/$vmid"; MountId = $null; Created = $false }
            $sessions[$vm] = $s
            Write-Host (L D_PublishStarted $sid) -ForegroundColor DarkGray

            # CP12 - publish session result and disk images
            $res = Wait-VbrSession $Vbr $sid $Cfg.Thresholds.PublishTimeoutMinutes $poll
            $pubMin = [math]::Round(((Get-Date) - $started).TotalMinutes, 1)
            $mount = Get-PublishMount $Vbr $rp.id
            if ($mount) { $s.MountId = $mount.id }
            if ($res.Result -notin @('Success','Warning')) {
                Add-Checkpoint CP12 $vm (L CP12) KO (L D_SessionFailed $res.Result, $pubMin, $res.Message); Skip-RemainingChecks $vm (L D_PublishFailed); continue
            }
            $images = @(Get-PublishedDiskImages $Cfg.Proxmox.MountRoot | Where-Object { $_ -notin $baseline })
            if ($images.Count -eq 0) { Add-Checkpoint CP12 $vm (L CP12) KO (L D_NoDisks $Cfg.Proxmox.MountRoot); Skip-RemainingChecks $vm (L D_PublishFailed); continue }
            Add-Checkpoint CP12 $vm (L CP12) ($res.Result -eq 'Success' ? 'OK' : 'WARN') (L D_Disks $images.Count, (($images | ForEach-Object { Split-Path $_ -Leaf }) -join ', '))

            # Create + start the throw-away VM (overlays keep the published images read-only)
            New-TestVm $vmid $target $images (Get-VmHardware $vm) $s.OverlayDir
            $s.Created = $true
        }
        catch { Add-Checkpoint CP12 $vm (L CP12Start) KO $_.Exception.Message; Skip-RemainingChecks $vm (L D_LaunchFailed) }
    }

    # ---------------------------------------------------------------------------------
    Write-Step (L Step2)
    # ---------------------------------------------------------------------------------
    foreach ($vm in @($sessions.Keys)) {
        $s = $sessions[$vm]
        if (-not $s.Created) {              # CP12 KO: nothing booted, just release the publish session if any
            if ($Cleanup -and $s.MountId) { try { Stop-DiskPublishing $Vbr $s.MountId } catch { Write-Warning $_.Exception.Message } }
            continue
        }
        try {
            # CP20 / CP22 - running + IP via guest agent (also drives CP13)
            $boot = Wait-GuestIp $Pve $node $s.VmId $Cfg.Thresholds.GuestAgentTimeoutMinutes $poll
            $bootMin = [math]::Round(((Get-Date) - $s.Started).TotalMinutes, 1)
            if (-not $boot.Vm) { Add-Checkpoint CP20 $vm (L CP20) KO (L D_VmNotFound $s.VmId); Skip-RemainingChecks $vm (L D_VmNotFoundShort); continue }
            $running = $boot.Vm.Status.status -eq 'running'
            $rtoOk = $bootMin -le $Cfg.Thresholds.MaxBootMinutes
            Add-Checkpoint CP13 $vm (L CP13 $Cfg.Thresholds.MaxBootMinutes) ($rtoOk ? 'OK' : 'WARN') "$bootMin min$(if (-not $rtoOk) { L D_RtoMissed })" $bootMin
            Add-Checkpoint CP20 $vm (L CP20) ($running ? 'OK' : 'KO') (L D_Status $boot.Vm.Status.status)

            # CP21 - guardrail on every NIC
            $nics = @(Get-PveVmNics $boot.Vm.Config)
            $leak = @($nics | Where-Object { -not (Test-NicIsolated $_) })
            if ($leak.Count) {
                Add-Checkpoint CP21 $vm (L CP21) KO (L D_NicLeak (($leak | ForEach-Object { $_.Raw }) -join ' ; '))
                try { Invoke-Ssh "qm stop $($s.VmId) --skiplock 1" -AllowFailure | Out-Null } catch { Write-Warning (L M_ShutdownFailed $s.VmId, $_.Exception.Message) }
            }
            elseif ($nics.Count -eq 0) { Add-Checkpoint CP21 $vm (L CP21) WARN (L D_NoNic) }
            else { Add-Checkpoint CP21 $vm (L CP21) OK }

            if ($boot.Ip) { Add-Checkpoint CP22 $vm (L CP22) OK $boot.Ip }
            else { Add-Checkpoint CP22 $vm (L CP22) ($running ? 'WARN' : 'KO') (L D_NoIp) }

            # CP23
            if (-not $PingCheck)   { Add-Checkpoint CP23 $vm (L CP23) SKIP (L D_PingOff) }
            elseif (-not $boot.Ip) { Add-Checkpoint CP23 $vm (L CP23) SKIP (L D_NoIpShort) }
            else { $p = Test-Connection -TargetName $boot.Ip -Count 2 -Quiet -ErrorAction SilentlyContinue; Add-Checkpoint CP23 $vm (L CP23) ($p ? 'OK' : 'KO') $boot.Ip }

            # CP30
            $checks = Get-ChecksForVm $Cfg.AppChecks $vm
            if (-not $boot.Ip)           { Add-Checkpoint CP30 $vm (L CP30) SKIP (L D_NoIpShort) }
            elseif ($checks.Count -eq 0) { Add-Checkpoint CP30 $vm (L CP30) SKIP (L D_NoChecks) }
            else {
                foreach ($c in $checks) {
                    $r  = Test-AppCheck $c $boot.Ip
                    $stt = if ($null -eq $r.Ok) { 'SKIP' } elseif ($r.Ok) { 'OK' } else { 'KO' }
                    $label = if ($c['Label']) { $c['Label'] } else { $c['Type'] }
                    Add-Checkpoint CP30 $vm (L CP30Item $label) $stt $r.Detail
                }
            }
        }
        catch { Add-Checkpoint CP20 $vm (L Verify) KO (L D_Unexpected $_.Exception.Message) }
        finally {
            # Step 3 - Cleanup (always attempted): VM + overlays + unpublish
            if (-not $Cleanup) { Add-Checkpoint CP40 $vm (L CP40) SKIP (L D_CleanupOff) }
            else {
                $errs = @()
                try { Remove-TestVm $s.VmId $s.Target $s.OverlayDir } catch { $errs += $_.Exception.Message }
                if (-not $s.MountId) { try { $m = Get-PublishMount $Vbr $s.Rp.id; if ($m) { $s.MountId = $m.id } } catch {} }
                if ($s.MountId) { try { Stop-DiskPublishing $Vbr $s.MountId } catch { $errs += $_.Exception.Message } }
                if ($errs.Count) { Add-Checkpoint CP40 $vm (L CP40) KO (L D_CleanupFailed ($errs -join ' ; '), $s.VmId, $s.MountId) }
                else             { Add-Checkpoint CP40 $vm (L CP40) OK "VM $($s.VmId), publish $($s.MountId)" }
            }
        }
    }
}
catch {
    if ($_.Exception.Message -eq 'PREFLIGHT') { Write-Host "`n$(L M_PreflightAbort)" -ForegroundColor Red }
    else { Write-Host "`n$(L M_Fatal $_.Exception.Message)" -ForegroundColor Red; Write-Verbose $_.ScriptStackTrace }
    $exitCode = 2
}
finally {
    # ---------------------------------------------------------------------------------
    Write-Step (L Step4)
    # ---------------------------------------------------------------------------------
    try {
        $summary = @(New-Summary $VmNames $Checkpoints -FailOnWarning:$FailOnWarning)
        $files   = Export-Reports $summary $Checkpoints $Cfg $ReportDir $RunId $VmNames
        $summary | Format-Table VM, RestorePointAgeH, BootMinutes, IP, KO, WARN, Result -AutoSize | Out-String | Write-Host
        Write-Host "HTML : $($files.Html)`nCSV  : $($files.Csv)`nJSON : $($files.Json)`nLog  : $LogPath"
    }
    catch { Write-Warning (L M_ReportFailed $_.Exception.Message) }

    if ($exitCode -eq 0) {
        $failures = @($Checkpoints | Where-Object { $_.Status -eq 'KO' -or ($FailOnWarning -and $_.Status -eq 'WARN') }).Count
        if ($failures -gt 0) { Write-Host "`n$(L M_Failures $failures)" -ForegroundColor Red; $exitCode = 1 }
        else { Write-Host "`n$(L M_AllOk)" -ForegroundColor Green }
    }
    Stop-Transcript | Out-Null
}
exit $exitCode

#endregion
