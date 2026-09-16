#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
pve_backup_boot.py — Scripted Recovery Verification for Proxmox VE with Veeam Backup & Replication 13.x
                     Recovery Verification scriptée pour Proxmox VE avec Veeam Backup & Replication 13.x

MIT License — Copyright (c) 2026 — see LICENSE.

[EN] Boots a sample of VMs DIRECTLY FROM THEIR VEEAM BACKUPS on the Proxmox VE node where this script
     runs, inside an isolated bridge / VLAN, checks that they boot and that their services respond,
     destroys the test VMs, then produces an HTML / CSV / JSON report. English or French output.

     WHY  SureBackup / Virtual Lab is not available for Proxmox VE, and VBR 13.x exposes neither a REST
     endpoint nor a PowerShell cmdlet to start an Entire VM Restore or an Instant Recovery TO Proxmox VE.
     The supported, documented primitive is the Veeam Data Integration API (disk publishing), which lists
     Proxmox VE backups among its sources. Like SureBackup, this script RUNS the VM from the backup:

       1. POST /api/v1/dataIntegration/publish (FUSELinuxMount) -> raw, read-only disk images appear
          under /run/media/Veeam.Mount.Disks on this node.
       2. qemu-img create -f qcow2 -b <image> -F raw overlay.qcow2 ; qm create ... --net0 bridge=<isolated>,tag=<vlan> ; qm start
       3. Proxmox VE API: running, NIC guardrail, guest-agent IP ; application checks, preferably executed
          INSIDE the guest through the QEMU guest agent (GuestExec) so no probe NIC on the isolated VLAN is needed.
       4. qm stop / destroy, remove overlays, unpublish. 5. Report.

[FR] Démarre un échantillon de VM DIRECTEMENT DEPUIS LEURS SAUVEGARDES VEEAM sur le nœud Proxmox VE où
     s'exécute ce script, dans un bridge / VLAN isolé, vérifie qu'elles démarrent et que leurs services
     répondent, détruit les VM de test, puis produit un rapport HTML / CSV / JSON. Sortie en anglais ou français.

     POURQUOI  SureBackup / Virtual Lab n'existe pas pour Proxmox VE, et VBR 13.x n'expose ni endpoint REST
     ni cmdlet PowerShell pour lancer un Entire VM Restore ou un Instant Recovery VERS Proxmox VE. La
     primitive supportée et documentée est la Data Integration API Veeam (publication de disques), qui liste
     les sauvegardes Proxmox VE parmi ses sources. Comme SureBackup, ce script EXÉCUTE la VM depuis la sauvegarde.

CHECKPOINTS / POINTS DE CONTRÔLE (OK / KO / WARN / SKIP)
  CP00 Authentication VBR / Proxmox API / local tools       CP20 Test VM running
  CP01 Node, bridge, overlay storage, VBR Linux credentials CP21 All NICs on the isolated bridge / VLAN (guardrail)
  CP02 Isolated bridge / VLAN not routed (blocking)         CP22 IP reported by QEMU guest agent
  CP03 No foreign VM on the isolated network                CP23 Ping from this host (--ping-check)
  CP04 No leftover test VM / stale publish (blocking)       CP30 Application checks (one CP per check)
  CP10 Restore point found   CP11 Age <= RPO                CP40 VM destroyed, overlays removed, unpublished
  CP12 Disk publishing Success   CP13 Time to boot <= RTO

QUICK START / DÉMARRAGE RAPIDE
  ./pve_backup_boot.py --init-config            # then edit RecoveryVerification.json / puis renseigner
  ./pve_backup_boot.py -v SRV-A -v SRV-B --cleanup --dry-run   # pre-flight only / pré-vol seul
  ./pve_backup_boot.py -v SRV-A -v SRV-B --cleanup             # real run / exécution réelle
Secrets: env VBR_USER / VBR_PASSWORD / PVE_TOKEN_ID / PVE_TOKEN_SECRET, or --secrets-file (JSON, mode 600), or prompt.

Exit code: 0 all OK | 1 at least one checkpoint failed | 2 blocking pre-flight / fatal error.
Requires Python 3.9+. Optional: dnspython (Dns), ldap3 (Ldap), pymssql (Sql). Runs as root on the PVE node.
Lines depending on API response field names are tagged "# [API]". Illustrative example, no warranty.
"""

from __future__ import annotations

import argparse
import base64
import csv
import getpass
import html
import json
import locale
import logging
import os
import re
import shlex
import socket
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

VERSION = "2.0.1"
EXTENSION_DIR_HINT = "/run/media/Veeam.Mount.Disks"

# =====================================================================================
# Localisation / Localization
# =====================================================================================

STRINGS: Dict[str, Dict[str, str]] = {
    "en": {
        "Step0": "Step 0 - Pre-flight: connections and environment checks",
        "Step1": "Step 1 - Publishing and booting {0} VM(s) from backup into the isolated network",
        "Step2": "Step 2 - Verifying test VMs",
        "Step4": "Step 4 - Report",
        "CP00": "Authentication VBR / Proxmox API / local tools (qm, qemu-img)",
        "CP01": "Node, isolated bridge, overlay storage and VBR Linux credentials present",
        "CP02": "Isolated bridge / VLAN is non-routed",
        "CP03": "No foreign VM on the isolated bridge / VLAN",
        "CP04": "No leftover test VM or stale disk publishing",
        "CP10": "Restore point found",
        "CP11": "Restore point age <= {0} h",
        "CP12": "Disk publishing completed",
        "CP12Start": "Disk publishing started",
        "CP13": "Time to boot <= {0} min",
        "CP20": "Test VM running",
        "CP21": "NICs only on the isolated bridge / VLAN",
        "CP22": "IP address reported (QEMU guest agent)",
        "CP23": "Ping from this host",
        "CP30": "Application checks",
        "CP30Item": "Application: {0}",
        "CP40": "Test VM destroyed, overlays removed, disks unpublished",
        "PostBoot": "Post-boot check",
        "Verify": "Verification",
        "D_ToolMissing": "required tool not found: {0}",
        "D_NodeUnknown": "node '{0}' not found in the Proxmox cluster",
        "D_BridgeMissing": "bridge '{0}' not found on node",
        "D_StorageMissing": "overlay storage path '{0}' not found or not writable",
        "D_CredMissing": "no Linux credentials named '{0}' in VBR (Credentials > Add > Linux account)",
        "D_BridgeHasIp": "bridge {0} carries IP {1} / gateway {2} on the node - test VMs would reach the node network",
        "D_BridgeUplinkVlan": "bridge {0} has uplink {1}; VLAN {2} isolation is enforced by the physical switch - Isolation.SwitchIsolationConfirmed=true required",
        "D_BridgeOk": "bridge {0}{1}: no IP, {2}",
        "D_NoUplink": "no uplink",
        "D_UplinkConfirmed": "uplink {0}, switch isolation confirmed by configuration",
        "D_ForeignVms": "VMs present: {0}",
        "D_LeftoverDeleteFailed": "could not remove: {0}",
        "D_LeftoverDeleted": "{0} leftover(s) removed: {1}",
        "D_LeftoverFound": "{0} leftover(s) - rerun with --cleanup: {1}",
        "D_NoRestorePoint": "no Proxmox VE restore point for this name",
        "D_NoRestorePointShort": "no restore point",
        "D_CreatedOn": "created on {0}",
        "D_RpoMissed": " - RPO missed, check the backup job",
        "D_PublishStarted": "    -> publish session {0} started",
        "D_LaunchFailed": "launch failed",
        "D_SessionFailed": "status = {0} after {1} min ({2})",
        "D_PublishFailed": "publishing failed",
        "D_NoDisks": "no new disk image found under {0}",
        "D_Disks": "{0} disk(s): {1}",
        "D_RtoMissed": " - RTO target exceeded",
        "D_VmNotFound": "VM {0} not found on node",
        "D_VmNotFoundShort": "VM not found",
        "D_Status": "status = {0}",
        "D_NicLeak": "NIC outside the isolated bridge / VLAN ({0}) - VM stopped immediately",
        "D_NoNic": "no NIC attached",
        "D_NoIp": "no IP - guest agent missing / not started, or OS not booted",
        "D_NoIpShort": "no IP address",
        "D_PingOff": "--ping-check not enabled",
        "D_NoChecks": "no check defined (AppChecks section)",
        "D_CleanupOff": "--cleanup not enabled (VM kept for analysis, disks stay published)",
        "D_CleanupFailed": "{0} - clean VM {1} / publish {2} manually",
        "D_Unexpected": "unexpected error: {0}",
        "D_DryRun": "dry-run",
        "D_ModuleMissing": "python module '{0}' missing",
        "D_GuestExecNoAgent": "guest agent not responding",
        "M_NeedVm": "Specify at least one VM with -v/--vm (or use --init-config to create the configuration).",
        "M_ConfigWritten": "Configuration template written to {0}. Fill it in, then rerun with -v.",
        "M_ConfigExists": "File {0} exists - use --force to overwrite.",
        "M_ConfigUnreadable": "Unreadable configuration ({0}): {1}",
        "M_NoConfig": "No configuration file ({0}): defaults in use. Generate one with --init-config.",
        "M_CredVbr": "Veeam Backup & Replication account for {0}",
        "M_CredPve": "Proxmox API token for {0} (id = user@realm!tokenid)",
        "M_PreflightAbort": "Stopped in pre-flight: fix the KO items above and rerun.",
        "M_Fatal": "Fatal error: {0}",
        "M_ReportFailed": "Report generation failed: {0}",
        "M_Failures": "{0} checkpoint(s) failed.",
        "M_AllOk": "All checkpoints passed: the verified backups boot and respond.",
        "M_ShutdownFailed": "Safety stop of VM {0} failed: {1}",
        "M_ApiFailed": "Call {0} {1} failed (HTTP {2}){3}. {4}",
        "M_Http401": ": invalid credentials or expired token",
        "M_Http403": ": insufficient rights for this operation",
        "M_Http404": ": resource not found (check API version and object IDs)",
        "M_Retry": "Attempt {0} failed ({1}) - retrying in {2} s",
        "M_CmdFailed": "Command failed (exit {0}): {1}\n{2}",
        "M_DeleteAction": "Stop and destroy test VM {0}, remove overlays, unpublish disks",
        "M_BootAction": "Publish backup disks of {0} to this node and boot as VM {1}",
        "R_Title": "Recovery Verification - Proxmox VE (boot from backup)",
        "R_Run": "Run", "R_Node": "Node", "R_Bridge": "Isolated network",
        "R_Fail": "FAILED - {0} checkpoint(s) KO", "R_Warn": "PASSED WITH WARNINGS - {0} WARN", "R_Ok": "PASSED - all checkpoints OK",
        "R_KpiVms": "VMs verified", "R_KpiOk": "checks OK", "R_KpiWarn": "warnings", "R_KpiKo": "failures",
        "R_KpiRpo": "RPO target", "R_KpiRto": "RTO target (boot)",
        "R_Summary": "Summary per VM", "R_Details": "Checkpoint details",
        "R_H_Vm": "VM", "R_H_Age": "Restore point age (h)", "R_H_Dur": "Time to boot (min)", "R_H_Ip": "IP",
        "R_H_Result": "Result", "R_H_Time": "Time", "R_H_Check": "Check", "R_H_Status": "Status", "R_H_Detail": "Detail",
        "R_Footer": "Generated by pve_backup_boot.py v{3} (MIT license). Related files: {0}, {1}, log {2}.",
        "R_OkWarn": "OK (warnings)",
    },
    "fr": {
        "Step0": "Étape 0 - Pré-vol : connexions et contrôle de l'environnement",
        "Step1": "Étape 1 - Publication et démarrage de {0} VM depuis la sauvegarde dans le réseau isolé",
        "Step2": "Étape 2 - Vérification des VM de test",
        "Step4": "Étape 4 - Rapport",
        "CP00": "Authentification VBR / API Proxmox / outils locaux (qm, qemu-img)",
        "CP01": "Nœud, bridge isolé, stockage overlay et identifiants Linux VBR présents",
        "CP02": "Bridge / VLAN isolé non routé",
        "CP03": "Aucune VM hors périmètre sur le bridge / VLAN isolé",
        "CP04": "Aucune VM de test ni publication de disques résiduelle",
        "CP10": "Point de restauration trouvé",
        "CP11": "Âge du point de restauration <= {0} h",
        "CP12": "Publication des disques terminée",
        "CP12Start": "Publication des disques lancée",
        "CP13": "Délai de démarrage <= {0} min",
        "CP20": "VM de test démarrée",
        "CP21": "Cartes réseau sur le bridge / VLAN isolé uniquement",
        "CP22": "Adresse IP remontée (QEMU guest agent)",
        "CP23": "Ping depuis cet hôte",
        "CP30": "Contrôles applicatifs",
        "CP30Item": "Applicatif : {0}",
        "CP40": "VM de test détruite, overlays supprimés, disques dépubliés",
        "PostBoot": "Contrôle post-démarrage",
        "Verify": "Vérification",
        "D_ToolMissing": "outil requis introuvable : {0}",
        "D_NodeUnknown": "nœud '{0}' introuvable dans le cluster Proxmox",
        "D_BridgeMissing": "bridge '{0}' introuvable sur le nœud",
        "D_StorageMissing": "chemin de stockage overlay '{0}' introuvable ou non inscriptible",
        "D_CredMissing": "aucun identifiant Linux nommé '{0}' dans VBR (Credentials > Add > Linux account)",
        "D_BridgeHasIp": "le bridge {0} porte IP {1} / passerelle {2} sur le nœud - les VM de test atteindraient le réseau du nœud",
        "D_BridgeUplinkVlan": "le bridge {0} a l'uplink {1} ; l'isolement du VLAN {2} dépend du commutateur physique - Isolation.SwitchIsolationConfirmed=true requis",
        "D_BridgeOk": "bridge {0}{1} : aucune IP, {2}",
        "D_NoUplink": "aucun uplink",
        "D_UplinkConfirmed": "uplink {0}, isolement commutateur confirmé par la configuration",
        "D_ForeignVms": "VM présentes : {0}",
        "D_LeftoverDeleteFailed": "suppression impossible : {0}",
        "D_LeftoverDeleted": "{0} résidu(s) supprimé(s) : {1}",
        "D_LeftoverFound": "{0} résidu(s) - relancer avec --cleanup : {1}",
        "D_NoRestorePoint": "aucun point de restauration Proxmox VE pour ce nom",
        "D_NoRestorePointShort": "pas de point de restauration",
        "D_CreatedOn": "créé le {0}",
        "D_RpoMissed": " - RPO non tenu, vérifier le job de sauvegarde",
        "D_PublishStarted": "    -> session de publication {0} démarrée",
        "D_LaunchFailed": "échec au lancement",
        "D_SessionFailed": "statut = {0} après {1} min ({2})",
        "D_PublishFailed": "publication en échec",
        "D_NoDisks": "aucune nouvelle image disque trouvée sous {0}",
        "D_Disks": "{0} disque(s) : {1}",
        "D_RtoMissed": " - RTO cible dépassé",
        "D_VmNotFound": "VM {0} introuvable sur le nœud",
        "D_VmNotFoundShort": "VM introuvable",
        "D_Status": "statut = {0}",
        "D_NicLeak": "carte réseau hors bridge / VLAN isolé ({0}) - arrêt immédiat de la VM",
        "D_NoNic": "aucune carte réseau attachée",
        "D_NoIp": "aucune IP - guest agent absent / non démarré, ou OS non démarré",
        "D_NoIpShort": "pas d'adresse IP",
        "D_PingOff": "option --ping-check non activée",
        "D_NoChecks": "aucun contrôle défini (section AppChecks)",
        "D_CleanupOff": "option --cleanup non activée (VM conservée pour analyse, disques toujours publiés)",
        "D_CleanupFailed": "{0} - nettoyer manuellement la VM {1} / la publication {2}",
        "D_Unexpected": "erreur inattendue : {0}",
        "D_DryRun": "dry-run",
        "D_ModuleMissing": "module python '{0}' absent",
        "D_GuestExecNoAgent": "guest agent ne répond pas",
        "M_NeedVm": "Indiquez au moins une VM avec -v/--vm (ou utilisez --init-config pour créer la configuration).",
        "M_ConfigWritten": "Modèle de configuration écrit dans {0}. Renseignez-le puis relancez avec -v.",
        "M_ConfigExists": "Le fichier {0} existe - utilisez --force pour l'écraser.",
        "M_ConfigUnreadable": "Configuration illisible ({0}) : {1}",
        "M_NoConfig": "Aucun fichier de configuration ({0}) : valeurs par défaut utilisées. Générez-en un avec --init-config.",
        "M_CredVbr": "Compte Veeam Backup & Replication pour {0}",
        "M_CredPve": "Jeton API Proxmox pour {0} (id = user@realm!tokenid)",
        "M_PreflightAbort": "Arrêt en pré-vol : corrigez les points KO ci-dessus puis relancez.",
        "M_Fatal": "Erreur bloquante : {0}",
        "M_ReportFailed": "Génération des rapports en échec : {0}",
        "M_Failures": "{0} point(s) de contrôle en échec.",
        "M_AllOk": "Tous les points de contrôle sont passés : les sauvegardes vérifiées démarrent et répondent.",
        "M_ShutdownFailed": "Arrêt de sécurité de la VM {0} impossible : {1}",
        "M_ApiFailed": "Appel {0} {1} en échec (HTTP {2}){3}. {4}",
        "M_Http401": " : identifiants invalides ou jeton expiré",
        "M_Http403": " : droits insuffisants pour cette opération",
        "M_Http404": " : ressource introuvable (vérifier la version d'API et les identifiants d'objets)",
        "M_Retry": "Tentative {0} échouée ({1}) - nouvelle tentative dans {2} s",
        "M_CmdFailed": "Commande en échec (code {0}) : {1}\n{2}",
        "M_DeleteAction": "Arrêt et destruction de la VM de test {0}, suppression des overlays, dépublication",
        "M_BootAction": "Publication des disques de {0} vers ce nœud et démarrage comme VM {1}",
        "R_Title": "Recovery Verification - Proxmox VE (démarrage depuis la sauvegarde)",
        "R_Run": "Exécution", "R_Node": "Nœud", "R_Bridge": "Réseau isolé",
        "R_Fail": "ÉCHEC - {0} point(s) de contrôle KO", "R_Warn": "SUCCÈS AVEC AVERTISSEMENTS - {0} WARN", "R_Ok": "SUCCÈS - tous les points de contrôle sont passés",
        "R_KpiVms": "VM vérifiées", "R_KpiOk": "contrôles OK", "R_KpiWarn": "avertissements", "R_KpiKo": "échecs",
        "R_KpiRpo": "RPO cible", "R_KpiRto": "RTO cible (démarrage)",
        "R_Summary": "Synthèse par VM", "R_Details": "Détail des points de contrôle",
        "R_H_Vm": "VM", "R_H_Age": "Âge du point de restauration (h)", "R_H_Dur": "Délai de démarrage (min)", "R_H_Ip": "IP",
        "R_H_Result": "Résultat", "R_H_Time": "Heure", "R_H_Check": "Contrôle", "R_H_Status": "Statut", "R_H_Detail": "Détail",
        "R_Footer": "Généré par pve_backup_boot.py v{3} (licence MIT). Fichiers associés : {0}, {1}, journal {2}.",
        "R_OkWarn": "OK (avertissements)",
    },
}

LANG = "en"


def L(key: str, *params: Any) -> str:
    s = STRINGS[LANG].get(key, key)
    return s.format(*params) if params else s


# =====================================================================================
# Configuration
# =====================================================================================

DEFAULT_CONFIG: Dict[str, Any] = {
    "Veeam": {
        "VbrServer": "vbr.example.local",       # VBR 13.x server
        "VbrPort": 9419,
        "VbrApiVersion": "1.3-rev2",            # 1.3-rev2 = VBR 13.1, 1.3-rev1 = 13.0
        "NodeCredentialsName": "root@pve-node01",   # username or description of the Linux credentials stored in VBR for this node
        "TargetServerName": "",                 # how VBR reaches this node for FUSE publishing; empty = this host's FQDN
    },
    "Proxmox": {
        "ApiHost": "localhost",                 # Proxmox API endpoint; localhost when running on the node
        "ApiPort": 8006,
        "Node": "",                             # node name; empty = hostname of this machine
        "MountRoot": EXTENSION_DIR_HINT,        # where Veeam FUSE publishing exposes raw disk images
    },
    "Target": {
        "IsolatedBridge": "vmbr1",
        "IsolatedVlanTag": 4000,                # null for an untagged isolated bridge
        "OverlayStoragePath": "/var/lib/vz/images/rv-overlays",   # node-local, file-based
        "VmNamePrefix": "rv-",
        "VmIdRangeStart": 9900,                 # 100 VMIDs reserved
    },
    "VmDefaults": {                             # hardware of the throw-away VM; override per VM in VmOverrides
        "Memory": 4096, "Cores": 2, "Cpu": "host", "Machine": "q35", "Bios": "seabios",
        "ScsiHw": "virtio-scsi-pci", "OsType": "l26", "Agent": 1, "EfiStorage": "",
    },
    "VmOverrides": {
        "SRV-WIN01": {"OsType": "win11", "Bios": "ovmf", "EfiStorage": "local-lvm", "Memory": 8192},
    },
    "Isolation": {
        "SwitchIsolationConfirmed": False,      # true once the network team confirms the VLAN is not routed / trunked elsewhere
    },
    "Thresholds": {
        "MaxRestorePointAgeHours": 30,          # RPO target
        "MaxBootMinutes": 20,                   # RTO target: publish + overlay + create + start until guest-agent IP
        "GuestAgentTimeoutMinutes": 10,
        "PublishTimeoutMinutes": 15,
        "PollIntervalSeconds": 15,
    },
    # Application checks per VM. "*" applies to every VM. Types:
    #  GuestExec (Command, ExpectedExitCode=0, ExpectedOutput regex, optional Shell) - runs INSIDE the guest via QEMU guest agent (recommended)
    #  Tcp (Port) | Http (Url with {ip}, ExpectedStatus) | Ldap (Port, needs ldap3) | Dns (Name, needs dnspython) | Sql (Port, Query, User, Password, needs pymssql)
    #  Network checks run from THIS host: they need a route to the isolated network (usually not the case on the node) -> prefer GuestExec.
    "AppChecks": {
        "*": [{"Type": "GuestExec", "Command": "systemctl is-system-running --wait || true", "ExpectedOutput": "running|degraded", "Label": "systemd up"}],
        "SRV-AD01": [{"Type": "GuestExec", "Command": "Get-Service NTDS,DNS | Where-Object Status -ne Running | Measure-Object | Select-Object -ExpandProperty Count", "Shell": "powershell", "ExpectedOutput": "^0", "Label": "AD DS + DNS running"}],
        "SRV-WEB01": [{"Type": "GuestExec", "Command": "curl -sk -o /dev/null -w '%{http_code}' https://localhost/health", "ExpectedOutput": "^200", "Label": "Health endpoint"}],
        "SRV-SQL01": [{"Type": "GuestExec", "Command": "(Get-Service MSSQLSERVER).Status", "Shell": "powershell", "ExpectedOutput": "Running", "Label": "SQL Server service"}],
    },
}

CLI_OVERRIDES = {  # argparse dest -> (section, key)
    "vbr_server": ("Veeam", "VbrServer"), "vbr_port": ("Veeam", "VbrPort"), "vbr_api_version": ("Veeam", "VbrApiVersion"),
    "node_credentials_name": ("Veeam", "NodeCredentialsName"), "target_server_name": ("Veeam", "TargetServerName"),
    "pve_api_host": ("Proxmox", "ApiHost"), "pve_api_port": ("Proxmox", "ApiPort"), "pve_node": ("Proxmox", "Node"),
    "isolated_bridge": ("Target", "IsolatedBridge"), "isolated_vlan_tag": ("Target", "IsolatedVlanTag"),
    "overlay_storage_path": ("Target", "OverlayStoragePath"), "vm_name_prefix": ("Target", "VmNamePrefix"), "vmid_range_start": ("Target", "VmIdRangeStart"),
    "max_restore_point_age_hours": ("Thresholds", "MaxRestorePointAgeHours"), "max_boot_minutes": ("Thresholds", "MaxBootMinutes"),
    "guest_agent_timeout_minutes": ("Thresholds", "GuestAgentTimeoutMinutes"),
}


def merge_config(path: Path, args: argparse.Namespace) -> Dict[str, Any]:
    cfg = json.loads(json.dumps(DEFAULT_CONFIG))  # deep copy
    if path.exists():
        try:
            file_cfg = json.loads(path.read_text(encoding="utf-8"))
        except Exception as e:  # noqa: BLE001
            raise SystemExit(L("M_ConfigUnreadable", path, e))
        for section, values in file_cfg.items():
            if section in ("AppChecks", "VmOverrides") or not isinstance(values, dict):
                cfg[section] = values
            else:
                cfg.setdefault(section, {}).update(values)
        logging.debug("configuration loaded from %s", path)
    else:
        logging.warning(L("M_NoConfig", path))
    for dest, (section, key) in CLI_OVERRIDES.items():
        val = getattr(args, dest, None)
        if val is not None:
            cfg[section][key] = val
    if not cfg["Proxmox"]["Node"]:
        cfg["Proxmox"]["Node"] = socket.gethostname().split(".")[0]
    if not cfg["Veeam"]["TargetServerName"]:
        cfg["Veeam"]["TargetServerName"] = socket.getfqdn()
    return cfg


# =====================================================================================
# Checkpoints and logging
# =====================================================================================

COLORS = {"OK": "\033[32m", "KO": "\033[31m", "WARN": "\033[33m", "SKIP": "\033[90m", "reset": "\033[0m", "step": "\033[36m"}


class Run:
    def __init__(self, report_dir: Path, fail_on_warning: bool):
        self.run_id = datetime.now().strftime("%Y%m%d-%H%M%S")
        self.report_dir = report_dir
        self.fail_on_warning = fail_on_warning
        self.checkpoints: List[Dict[str, Any]] = []
        self.color = sys.stdout.isatty()
        report_dir.mkdir(parents=True, exist_ok=True)
        self.log_path = report_dir / f"RecoveryVerification-{self.run_id}.log"
        logging.basicConfig(level=logging.DEBUG, format="%(asctime)s %(levelname)s %(message)s",
                            handlers=[logging.FileHandler(self.log_path, encoding="utf-8")])

    def step(self, title: str) -> None:
        c, r = (COLORS["step"], COLORS["reset"]) if self.color else ("", "")
        print(f"\n{c}=== {title} ==={r}")
        logging.info("=== %s ===", title)

    def cp(self, cp_id: str, vm: str, label: str, status: str, detail: str = "", value: Optional[float] = None) -> None:
        self.checkpoints.append({"RunId": self.run_id, "Time": datetime.now().strftime("%Y-%m-%dT%H:%M:%S"), "CP": cp_id, "VM": vm,
                                 "Label": label, "Status": status, "Value": value, "Detail": detail})
        c, r = (COLORS.get(status, ""), COLORS["reset"]) if self.color else ("", "")
        suffix = f" - {detail}" if detail else ""
        print(f"  {c}[{cp_id}] {status:<4} {vm:<16} {label}{suffix}{r}")
        logging.info("[%s] %s %s %s%s", cp_id, status, vm, label, suffix)

    def skip_remaining(self, vm: str, reason: str) -> None:
        for cp_id in ("CP13", "CP20", "CP21", "CP22", "CP23", "CP30", "CP40"):
            self.cp(cp_id, vm, L("PostBoot"), "SKIP", reason)


class Preflight(Exception):
    pass


# =====================================================================================
# HTTP / API clients
# =====================================================================================

class ApiError(Exception):
    def __init__(self, status: Optional[int], message: str):
        super().__init__(message)
        self.status = status


class Http:
    def __init__(self, verify_tls: bool):
        self.ctx = ssl.create_default_context()
        if not verify_tls:
            self.ctx.check_hostname = False
            self.ctx.verify_mode = ssl.CERT_NONE

    def call(self, method: str, url: str, headers: Optional[Dict[str, str]] = None, body: Any = None,
             form: bool = False, retries: int = 3, timeout: int = 120) -> Any:
        headers = dict(headers or {})
        data: Optional[bytes] = None
        if body is not None:
            if form:
                data = urllib.parse.urlencode(body).encode()
                headers["Content-Type"] = "application/x-www-form-urlencoded"
            else:
                data = json.dumps(body).encode()
                headers["Content-Type"] = "application/json"
        attempt = 0
        while True:
            attempt += 1
            req = urllib.request.Request(url, data=data, method=method, headers=headers)
            logging.debug("%s %s", method, url)
            try:
                with urllib.request.urlopen(req, context=self.ctx, timeout=timeout) as resp:
                    raw = resp.read()
                    return json.loads(raw) if raw.strip() else None
            except urllib.error.HTTPError as e:
                status = e.code
                content = e.read().decode(errors="replace")[:500]
            except (urllib.error.URLError, socket.timeout, ConnectionError, OSError) as e:
                status, content = None, str(e)
            retryable = status is None or status >= 500 or status == 429
            if retryable and attempt < retries:
                logging.debug(L("M_Retry", attempt, status, 5 * attempt))
                time.sleep(5 * attempt)
                continue
            hint = {401: L("M_Http401"), 403: L("M_Http403"), 404: L("M_Http404")}.get(status or 0, "")
            raise ApiError(status, L("M_ApiFailed", method, url, status, hint, content).strip())


def items(resp: Any) -> List[Any]:
    if isinstance(resp, dict):
        for key in ("data", "results"):
            if key in resp:
                return list(resp[key] or [])
    return list(resp or []) if isinstance(resp, list) else []


class Vbr:
    def __init__(self, http: Http, server: str, port: int, api_version: str, user: str, password: str):
        self.http = http
        self.base = f"https://{server}:{port}/api/v1"
        tok = http.call("POST", f"https://{server}:{port}/api/oauth2/token", {"x-api-version": api_version},
                        {"grant_type": "password", "username": user, "password": password}, form=True, retries=1, timeout=60)
        self.headers = {"Authorization": f"Bearer {tok['access_token']}", "x-api-version": api_version}

    def get(self, path: str, **kw: Any) -> Any:
        return self.http.call("GET", self.base + path, self.headers, **kw)

    def post(self, path: str, body: Any = None, **kw: Any) -> Any:
        return self.http.call("POST", self.base + path, self.headers, body, **kw)

    def latest_restore_point(self, vm_name: str) -> Optional[Dict[str, Any]]:
        q = f"nameFilter={urllib.parse.quote(vm_name)}&platformNameFilter=Proxmox&orderColumn=CreationTime&orderAsc=false&limit=10"
        try:
            rps = items(self.get(f"/restorePoints?{q}"))                 # [API] 1.3
        except ApiError:
            rps = items(self.get(f"/objectRestorePoints?{q}"))           # [API] 1.2 fallback
        rps = [r for r in rps if r.get("name") == vm_name]
        rps.sort(key=lambda r: r.get("creationTime", ""), reverse=True)
        return rps[0] if rps else None

    def linux_credentials(self, name_or_user: str) -> Optional[Dict[str, Any]]:
        creds = items(self.get("/credentials?typeFilter=Linux&limit=200"))   # [API]
        for c in creds:
            if c.get("username") == name_or_user or c.get("description") == name_or_user:
                return c
        for c in creds:
            if name_or_user in f"{c.get('username')}@{c.get('description')}":
                return c
        return None

    def publish(self, rp_id: str, target_server: str, credentials_id: str, reason: str) -> str:
        s = self.post("/dataIntegration/publish", {"restorePointId": rp_id, "type": "FUSELinuxMount", "targetServerName": target_server,
                                                    "targetServerCredentialsId": credentials_id, "credentialsStorageType": "Permanent", "reason": reason})
        return s["id"]

    def wait_session(self, session_id: str, timeout_min: int, poll_s: int) -> Dict[str, str]:
        deadline = time.time() + timeout_min * 60
        state = None
        s: Dict[str, Any] = {}
        while True:
            time.sleep(poll_s)
            s = self.get(f"/sessions/{session_id}")
            state = s.get("state")                                       # [API] Starting / Working / Stopped
            if state == "Stopped" or time.time() >= deadline:
                break
        if state != "Stopped":
            return {"Result": "Timeout", "Message": ""}
        res = s.get("result") or {}
        return {"Result": res.get("result", "Unknown"), "Message": res.get("message", "")}   # [API]

    def mounts(self) -> List[Dict[str, Any]]:
        return items(self.get("/dataIntegration?limit=200"))

    def mount_for(self, rp_id: str) -> Optional[Dict[str, Any]]:
        for m in self.mounts():
            if m.get("restorePointId") == rp_id:
                return m
        return None

    def unpublish(self, mount_id: str) -> None:
        self.post(f"/dataIntegration/{mount_id}/unpublish")


class Pve:
    def __init__(self, http: Http, host: str, port: int, token_id: str, secret: str):
        self.http = http
        self.base = f"https://{host}:{port}/api2/json"
        self.headers = {"Authorization": f"PVEAPIToken={token_id}={secret}"}
        self.http.call("GET", f"{self.base}/version", self.headers, retries=1, timeout=30)

    def get(self, path: str, **kw: Any) -> Any:
        return (self.http.call("GET", self.base + path, self.headers, **kw) or {}).get("data")

    def post(self, path: str, body: Any = None, **kw: Any) -> Any:
        return (self.http.call("POST", self.base + path, self.headers, body or {}, **kw) or {}).get("data")

    def vm(self, node: str, vmid: int) -> Optional[Dict[str, Any]]:
        try:
            return {"Status": self.get(f"/nodes/{node}/qemu/{vmid}/status/current"), "Config": self.get(f"/nodes/{node}/qemu/{vmid}/config")}
        except ApiError:
            return None

    def guest_ip(self, node: str, vmid: int) -> Optional[str]:
        try:
            r = self.get(f"/nodes/{node}/qemu/{vmid}/agent/network-get-interfaces", retries=1, timeout=30) or {}   # [API]
        except ApiError:
            return None
        for iface in r.get("result", []):
            for addr in iface.get("ip-addresses", []):
                ip = addr.get("ip-address", "")
                if addr.get("ip-address-type") == "ipv4" and not ip.startswith(("127.", "169.254.")):
                    return ip
        return None

    def guest_exec(self, node: str, vmid: int, command: List[str], timeout_s: int = 60) -> Dict[str, Any]:
        """Run a command inside the guest through the QEMU guest agent; returns {exitcode, out-data, err-data}."""
        r = self.post(f"/nodes/{node}/qemu/{vmid}/agent/exec", {"command": command}, retries=1, timeout=30)   # [API]
        pid = r["pid"]
        deadline = time.time() + timeout_s
        while time.time() < deadline:
            time.sleep(2)
            st = self.get(f"/nodes/{node}/qemu/{vmid}/agent/exec-status?pid={pid}", retries=1, timeout=30) or {}
            if st.get("exited"):
                return st
        return {"exitcode": -1, "out-data": "", "err-data": "timeout"}


# =====================================================================================
# Local node operations (qm / qemu-img)
# =====================================================================================

def sh(cmd: str, check: bool = True, timeout: int = 600) -> str:
    logging.debug("sh: %s", cmd)
    p = subprocess.run(["bash", "-lc", cmd], capture_output=True, text=True, timeout=timeout)
    if check and p.returncode != 0:
        raise RuntimeError(L("M_CmdFailed", p.returncode, cmd, (p.stderr or p.stdout).strip()[:800]))
    return p.stdout.strip()


def published_images(mount_root: str) -> List[str]:
    out = sh(f"find {shlex.quote(mount_root)} -mindepth 1 -maxdepth 4 -type f 2>/dev/null | sort", check=False)
    return [f for f in out.splitlines() if f and not re.search(r"\.(json|xml|txt|log)$", f)]


def hardware_for(cfg: Dict[str, Any], vm: str) -> Dict[str, Any]:
    hw = dict(cfg["VmDefaults"])
    hw.update((cfg.get("VmOverrides") or {}).get(vm, {}))
    return hw


def net_spec(cfg: Dict[str, Any]) -> str:
    tag = cfg["Target"].get("IsolatedVlanTag")
    return f"virtio,bridge={cfg['Target']['IsolatedBridge']}" + (f",tag={tag}" if tag not in (None, "") else "") + ",firewall=1"


def create_test_vm(cfg: Dict[str, Any], run_id: str, vmid: int, name: str, images: List[str], hw: Dict[str, Any], overlay_dir: str) -> None:
    cmds = [f"mkdir -p {shlex.quote(overlay_dir)}"]
    disks = []
    for i, img in enumerate(images):
        ov = f"{overlay_dir}/disk{i}.qcow2"
        cmds.append(f"qemu-img create -q -f qcow2 -b {shlex.quote(img)} -F raw {shlex.quote(ov)}")
        disks.append(f"--scsi{i} {shlex.quote(ov)}")
    bios = "--bios ovmf" + (f" --efidisk0 {shlex.quote(hw['EfiStorage'] + ':1,efitype=4m,pre-enrolled-keys=0')}" if hw.get("EfiStorage") else "") \
        if hw.get("Bios") == "ovmf" else "--bios seabios"
    desc = f"Veeam Recovery Verification {run_id} - TEMPORARY, boots from backup, safe to destroy"
    cmds.append(f"qm create {vmid} --name {shlex.quote(name)} --memory {hw['Memory']} --cores {hw['Cores']} --cpu {hw['Cpu']} --machine {hw['Machine']} "
                f"--scsihw {hw['ScsiHw']} --ostype {hw['OsType']} --agent {hw['Agent']} {bios} --net0 {shlex.quote(net_spec(cfg))} "
                f"--boot order=scsi0 --description {shlex.quote(desc)} " + " ".join(disks))
    cmds.append(f"qm start {vmid}")
    sh(" && ".join(cmds))


def destroy_test_vm(vmid: int, overlay_dir: str) -> None:
    sh(f"qm stop {vmid} --skiplock 1 >/dev/null 2>&1 || true; sleep 3; qm destroy {vmid} --purge 1 --skiplock 1 >/dev/null 2>&1 || true; rm -rf {shlex.quote(overlay_dir)}",
       check=False)


def parse_nics(config: Dict[str, Any]) -> List[Dict[str, Any]]:
    nics = []
    for k, v in (config or {}).items():
        if re.fullmatch(r"net\d+", k):
            m_b = re.search(r"bridge=([^,]+)", str(v))
            m_t = re.search(r"tag=(\d+)", str(v))
            nics.append({"Name": k, "Bridge": m_b.group(1) if m_b else "", "Tag": int(m_t.group(1)) if m_t else None, "Raw": str(v)})
    return nics


def poll_ready(pve: "Pve", node: str, sessions: Dict[str, Dict[str, Any]], cfg: Dict[str, Any]) -> None:
    """One round of polling over booted VMs: record running state and the moment the guest agent reports an IP."""
    timeout_s = int(cfg["Thresholds"]["GuestAgentTimeoutMinutes"]) * 60
    for s in sessions.values():
        if not s.get("Created") or s.get("Done"):
            continue
        vm_obj = pve.vm(node, s["VmId"])
        s["Vm"] = vm_obj
        if vm_obj and (vm_obj["Status"] or {}).get("status") == "running":
            ip = pve.guest_ip(node, s["VmId"])
            if ip:
                s["Ip"], s["IpAt"], s["Done"] = ip, time.time(), True
                continue
        if time.time() - s["CreatedAt"] >= timeout_s:
            s["Done"] = True


def nic_isolated(cfg: Dict[str, Any], nic: Dict[str, Any]) -> bool:
    tag = cfg["Target"].get("IsolatedVlanTag")
    want = int(tag) if tag not in (None, "") else None
    return nic["Bridge"] == cfg["Target"]["IsolatedBridge"] and nic["Tag"] == want


# =====================================================================================
# Application checks
# =====================================================================================

def app_check(pve: Pve, node: str, vmid: int, check: Dict[str, Any], ip: Optional[str]) -> Dict[str, Any]:
    """Returns {'Ok': True|False|None(SKIP), 'Detail': str}."""
    t = check.get("Type")
    try:
        if t == "GuestExec":
            shell = check.get("Shell", "sh")
            cmd = {"sh": ["/bin/sh", "-c"], "bash": ["/bin/bash", "-c"], "powershell": ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command"],
                   "cmd": ["cmd.exe", "/c"]}.get(shell, [shell])
            try:
                r = pve.guest_exec(node, vmid, cmd + [check["Command"]], int(check.get("TimeoutSeconds", 60)))
            except ApiError as e:
                return {"Ok": None, "Detail": L("D_GuestExecNoAgent") + f" ({e.status})"}
            out = base64.b64decode(r.get("out-data") or "").decode(errors="replace").strip() if r.get("out-data") else ""
            err = base64.b64decode(r.get("err-data") or "").decode(errors="replace").strip() if r.get("err-data") else ""
            code = r.get("exitcode", -1)
            ok = code == int(check.get("ExpectedExitCode", 0))
            if ok and check.get("ExpectedOutput"):
                ok = re.search(check["ExpectedOutput"], out, re.M) is not None
            return {"Ok": ok, "Detail": f"exit {code}: {(out or err)[:120]}"}
        if ip is None:
            return {"Ok": None, "Detail": L("D_NoIpShort")}
        if t == "Tcp":
            with socket.create_connection((ip, int(check["Port"])), timeout=5):
                return {"Ok": True, "Detail": f"tcp/{check['Port']}"}
        if t == "Http":
            url = check["Url"].replace("{ip}", ip)
            ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
            try:
                with urllib.request.urlopen(urllib.request.Request(url), context=ctx, timeout=15) as resp:
                    code = resp.status
            except urllib.error.HTTPError as e:
                code = e.code
            return {"Ok": code == int(check.get("ExpectedStatus", 200)), "Detail": f"HTTP {code} {url}"}
        if t == "Ldap":
            try:
                import ldap3  # type: ignore
            except ImportError:
                return {"Ok": None, "Detail": L("D_ModuleMissing", "ldap3")}
            conn = ldap3.Connection(ldap3.Server(ip, port=int(check.get("Port", 389)), connect_timeout=5), auto_bind=True)
            conn.unbind()
            return {"Ok": True, "Detail": "anonymous RootDSE bind OK"}
        if t == "Dns":
            try:
                import dns.resolver  # type: ignore
            except ImportError:
                return {"Ok": None, "Detail": L("D_ModuleMissing", "dnspython")}
            res = dns.resolver.Resolver(configure=False); res.nameservers = [ip]; res.lifetime = 5
            ans = res.resolve(check["Name"], check.get("RecordType", "A"))
            return {"Ok": len(ans) > 0, "Detail": f"{check['Name']} -> {ip}"}
        if t == "Sql":
            try:
                import pymssql  # type: ignore
            except ImportError:
                return {"Ok": None, "Detail": L("D_ModuleMissing", "pymssql")}
            conn = pymssql.connect(server=ip, port=int(check.get("Port", 1433)), user=check.get("User"), password=check.get("Password"), login_timeout=15)
            cur = conn.cursor(); cur.execute(check["Query"]); row = cur.fetchone(); conn.close()
            return {"Ok": row is not None, "Detail": f"result = {row[0] if row else None}"}
        return {"Ok": None, "Detail": f"unknown check type: {t}"}
    except Exception as e:  # noqa: BLE001
        return {"Ok": False, "Detail": str(e)[:200]}


def checks_for(cfg: Dict[str, Any], vm: str) -> List[Dict[str, Any]]:
    ac = cfg.get("AppChecks") or {}
    return list(ac.get("*", [])) + list(ac.get(vm, []))


# =====================================================================================
# Reports
# =====================================================================================

def summary(vm_names: List[str], cps: List[Dict[str, Any]], fail_on_warning: bool) -> List[Dict[str, Any]]:
    rows = []
    for vm in vm_names:
        mine = [c for c in cps if c["VM"] == vm]
        ko = sum(1 for c in mine if c["Status"] == "KO")
        wa = sum(1 for c in mine if c["Status"] == "WARN")
        first = lambda cp_id, ok_only=False: next((c for c in mine if c["CP"] == cp_id and (not ok_only or c["Status"] == "OK")), None)  # noqa: E731
        c11, c13, c22 = first("CP11"), first("CP13"), first("CP22", True)
        rows.append({"VM": vm, "RestorePointAgeH": c11["Value"] if c11 else None, "BootMinutes": c13["Value"] if c13 else None,
                     "IP": c22["Detail"] if c22 else "", "KO": ko, "WARN": wa,
                     "Result": "KO" if ko or (fail_on_warning and wa) else (L("R_OkWarn") if wa else "OK")})
    return rows


def export_reports(run: Run, cfg: Dict[str, Any], vm_names: List[str], rows: List[Dict[str, Any]]) -> Dict[str, Path]:
    d, rid = run.report_dir, run.run_id
    csv_p, json_p, html_p = d / f"RecoveryVerification-{rid}.csv", d / f"RecoveryVerification-{rid}.json", d / f"RecoveryVerification-{rid}.html"
    with csv_p.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=["RunId", "Time", "CP", "VM", "Label", "Status", "Value", "Detail"], delimiter=";")
        w.writeheader(); w.writerows(run.checkpoints)
    json_p.write_text(json.dumps({"RunId": rid, "Date": datetime.now().isoformat(timespec="seconds"), "Language": LANG, "Platform": "ProxmoxVE",
                                  "Method": "DataIntegrationApi+QemuOverlay", "Version": VERSION, "Target": cfg["Target"], "Thresholds": cfg["Thresholds"],
                                  "Summary": rows, "Checkpoints": run.checkpoints}, indent=2, ensure_ascii=False), encoding="utf-8")
    tot = {s: sum(1 for c in run.checkpoints if c["Status"] == s) for s in ("OK", "KO", "WARN")}
    banner = (L("R_Fail", tot["KO"]), "#c62828") if tot["KO"] else ((L("R_Warn", tot["WARN"]), "#ef6c00") if tot["WARN"] else (L("R_Ok"), "#2e7d32"))
    e = lambda x: html.escape("" if x is None else str(x))  # noqa: E731
    tag = cfg["Target"].get("IsolatedVlanTag")
    net = cfg["Target"]["IsolatedBridge"] + (f" / VLAN {tag}" if tag not in (None, "") else "")
    ok_warn = L("R_OkWarn")
    rows_html = "\n".join(
        f"<tr><td>{e(r['VM'])}</td><td>{e(r['RestorePointAgeH'])}</td><td>{e(r['BootMinutes'])}</td><td>{e(r['IP'])}</td><td>{r['KO']}</td><td>{r['WARN']}</td>"
        f"<td class='{'ko' if r['Result'] == 'KO' else ('warn' if r['Result'] == ok_warn else 'ok')}'>{e(r['Result'])}</td></tr>" for r in rows)
    cps_html = "\n".join(
        f"<tr><td>{e(c['Time'])}</td><td>{e(c['CP'])}</td><td>{e(c['VM'])}</td><td>{e(c['Label'])}</td><td class='{c['Status'].lower()}'>{e(c['Status'])}</td><td>{e(c['Detail'])}</td></tr>"
        for c in run.checkpoints)
    th = cfg["Thresholds"]
    html_p.write_text(f"""<!DOCTYPE html><html lang="{LANG}"><head><meta charset="utf-8"><title>{e(L('R_Title'))} - {rid}</title>
<style>
body{{font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#222;margin:24px;background:#fafafa}}
h1{{font-size:20px;margin:0 0 4px}}h2{{font-size:16px;margin:24px 0 8px;border-bottom:1px solid #ddd;padding-bottom:4px}}
.banner{{color:#fff;padding:10px 14px;border-radius:4px;font-weight:600;margin:12px 0;background:{banner[1]}}}
.kpi{{display:inline-block;background:#fff;border:1px solid #e0e0e0;border-radius:4px;padding:8px 14px;margin:0 8px 8px 0}}.kpi b{{font-size:18px;display:block}}
table{{border-collapse:collapse;width:100%;background:#fff}}th,td{{border:1px solid #e0e0e0;padding:6px 8px;text-align:left;vertical-align:top}}
th{{background:#f0f0f0}}td.ok{{background:#e8f5e9;color:#2e7d32;font-weight:600}}td.ko{{background:#ffebee;color:#c62828;font-weight:600}}
td.warn{{background:#fff3e0;color:#ef6c00;font-weight:600}}td.skip{{color:#888}}small{{color:#666}}
</style></head><body>
<h1>{e(L('R_Title'))}</h1>
<small>{e(L('R_Run'))} {rid} &middot; {datetime.now():%Y-%m-%d %H:%M} &middot; {e(L('R_Node'))} {e(cfg['Proxmox']['Node'])} &middot; {e(L('R_Bridge'))} {e(net)} &middot; VBR {e(cfg['Veeam']['VbrServer'])}</small>
<div class="banner">{e(banner[0])}</div>
<div class="kpi"><b>{len(vm_names)}</b>{e(L('R_KpiVms'))}</div><div class="kpi"><b>{tot['OK']}</b>{e(L('R_KpiOk'))}</div>
<div class="kpi"><b>{tot['WARN']}</b>{e(L('R_KpiWarn'))}</div><div class="kpi"><b>{tot['KO']}</b>{e(L('R_KpiKo'))}</div>
<div class="kpi"><b>{th['MaxRestorePointAgeHours']} h</b>{e(L('R_KpiRpo'))}</div><div class="kpi"><b>{th['MaxBootMinutes']} min</b>{e(L('R_KpiRto'))}</div>
<h2>{e(L('R_Summary'))}</h2>
<table><tr><th>{e(L('R_H_Vm'))}</th><th>{e(L('R_H_Age'))}</th><th>{e(L('R_H_Dur'))}</th><th>{e(L('R_H_Ip'))}</th><th>KO</th><th>WARN</th><th>{e(L('R_H_Result'))}</th></tr>
{rows_html}</table>
<h2>{e(L('R_Details'))}</h2>
<table><tr><th>{e(L('R_H_Time'))}</th><th>CP</th><th>{e(L('R_H_Vm'))}</th><th>{e(L('R_H_Check'))}</th><th>{e(L('R_H_Status'))}</th><th>{e(L('R_H_Detail'))}</th></tr>
{cps_html}</table>
<p><small>{e(L('R_Footer', csv_p.name, json_p.name, run.log_path.name, VERSION))}</small></p>
</body></html>
""", encoding="utf-8")
    return {"Csv": csv_p, "Json": json_p, "Html": html_p}


# =====================================================================================
# Secrets
# =====================================================================================

def load_secrets(args: argparse.Namespace, cfg: Dict[str, Any]) -> Dict[str, str]:
    s: Dict[str, str] = {}
    if args.secrets_file:
        p = Path(args.secrets_file)
        if p.stat().st_mode & 0o077:
            logging.warning("secrets file %s is readable by others (chmod 600 recommended)", p)
        s.update(json.loads(p.read_text(encoding="utf-8")))
    for k in ("VBR_USER", "VBR_PASSWORD", "PVE_TOKEN_ID", "PVE_TOKEN_SECRET"):
        if os.environ.get(k):
            s[k] = os.environ[k]
    if not s.get("VBR_USER") or not s.get("VBR_PASSWORD"):
        print(L("M_CredVbr", cfg["Veeam"]["VbrServer"]))
        s["VBR_USER"] = s.get("VBR_USER") or input("  user: ")
        s["VBR_PASSWORD"] = s.get("VBR_PASSWORD") or getpass.getpass("  password: ")
    if not s.get("PVE_TOKEN_ID") or not s.get("PVE_TOKEN_SECRET"):
        print(L("M_CredPve", cfg["Proxmox"]["ApiHost"]))
        s["PVE_TOKEN_ID"] = s.get("PVE_TOKEN_ID") or input("  token id: ")
        s["PVE_TOKEN_SECRET"] = s.get("PVE_TOKEN_SECRET") or getpass.getpass("  secret: ")
    return s


# =====================================================================================
# Main
# =====================================================================================

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="pve_backup_boot.py", description=__doc__.split("\n\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("-v", "--vm", dest="vm_names", action="append", metavar="NAME", help="source VM name as shown in Veeam (repeatable)")
    p.add_argument("-c", "--config", default="./RecoveryVerification.json", help="JSON configuration file (default ./RecoveryVerification.json)")
    p.add_argument("--init-config", action="store_true", help="write a configuration template to --config and exit")
    p.add_argument("--force", action="store_true", help="overwrite an existing configuration with --init-config")
    p.add_argument("-l", "--language", choices=["en", "fr"], help="output language (default: system locale)")
    p.add_argument("--ping-check", action="store_true", help="enable CP23 (ping from this host; needs a route to the isolated network)")
    p.add_argument("--cleanup", action="store_true", help="destroy test VMs, remove overlays and unpublish at the end (and clean leftovers in pre-flight)")
    p.add_argument("--fail-on-warning", action="store_true", help="treat WARN as failure for the exit code")
    p.add_argument("--report-dir", default="./Reports", help="output folder for reports and log (default ./Reports)")
    p.add_argument("--secrets-file", help="JSON file with VBR_USER, VBR_PASSWORD, PVE_TOKEN_ID, PVE_TOKEN_SECRET (chmod 600)")
    p.add_argument("--verify-tls", action="store_true", help="validate TLS certificates of VBR and Proxmox (default: skip, self-signed)")
    p.add_argument("-n", "--dry-run", action="store_true", help="pre-flight only; publish / create / start / destroy are displayed, not executed")
    p.add_argument("--debug", action="store_true", help="also print debug log to the console")
    g = p.add_argument_group("configuration overrides")
    g.add_argument("--vbr-server"); g.add_argument("--vbr-port", type=int); g.add_argument("--vbr-api-version")
    g.add_argument("--node-credentials-name"); g.add_argument("--target-server-name")
    g.add_argument("--pve-api-host"); g.add_argument("--pve-api-port", type=int); g.add_argument("--pve-node")
    g.add_argument("--isolated-bridge"); g.add_argument("--isolated-vlan-tag", type=int); g.add_argument("--overlay-storage-path")
    g.add_argument("--vm-name-prefix"); g.add_argument("--vmid-range-start", type=int)
    g.add_argument("--max-restore-point-age-hours", type=int); g.add_argument("--max-boot-minutes", type=int); g.add_argument("--guest-agent-timeout-minutes", type=int)
    p.add_argument("--version", action="version", version=f"%(prog)s {VERSION}")
    return p


def main() -> int:  # noqa: C901 - orchestration
    global LANG
    args = build_parser().parse_args()
    LANG = args.language or ("fr" if (locale.getlocale()[0] or os.environ.get("LANG", "")).lower().startswith("fr") else "en")
    cfg_path = Path(args.config)

    if args.init_config:
        if cfg_path.exists() and not args.force:
            print(L("M_ConfigExists", cfg_path)); return 2
        cfg_path.write_text(json.dumps(DEFAULT_CONFIG, indent=2, ensure_ascii=False), encoding="utf-8")
        print(L("M_ConfigWritten", cfg_path)); return 0
    if not args.vm_names:
        print(L("M_NeedVm")); return 2

    run = Run(Path(args.report_dir), args.fail_on_warning)
    if args.debug:
        logging.getLogger().addHandler(logging.StreamHandler(sys.stderr))
    cfg = merge_config(cfg_path, args)
    secrets = load_secrets(args, cfg)
    http = Http(args.verify_tls)
    node, prefix, poll = cfg["Proxmox"]["Node"], cfg["Target"]["VmNamePrefix"], int(cfg["Thresholds"]["PollIntervalSeconds"])
    exit_code = 0
    sessions: Dict[str, Dict[str, Any]] = {}
    vbr: Optional[Vbr] = None
    pve: Optional[Pve] = None

    try:
        # ------------------------------------------------------------------ Step 0
        run.step(L("Step0"))
        try:
            for tool in ("qm", "qemu-img"):
                if sh(f"command -v {tool}", check=False) == "":
                    raise RuntimeError(L("D_ToolMissing", tool))
            vbr = Vbr(http, cfg["Veeam"]["VbrServer"], int(cfg["Veeam"]["VbrPort"]), cfg["Veeam"]["VbrApiVersion"], secrets["VBR_USER"], secrets["VBR_PASSWORD"])
            pve = Pve(http, cfg["Proxmox"]["ApiHost"], int(cfg["Proxmox"]["ApiPort"]), secrets["PVE_TOKEN_ID"], secrets["PVE_TOKEN_SECRET"])
            run.cp("CP00", "-", L("CP00"), "OK", f"VBR {cfg['Veeam']['VbrApiVersion']}, {sh('pveversion', check=False)}")
        except Exception as e:  # noqa: BLE001
            run.cp("CP00", "-", L("CP00"), "KO", str(e)); raise Preflight()

        try:
            if not any(n.get("node") == node for n in pve.get("/nodes") or []):
                raise RuntimeError(L("D_NodeUnknown", node))
            ifaces = pve.get(f"/nodes/{node}/network") or []
            bridge = next((i for i in ifaces if i.get("iface") == cfg["Target"]["IsolatedBridge"] and i.get("type") == "bridge"), None)
            if not bridge:
                raise RuntimeError(L("D_BridgeMissing", cfg["Target"]["IsolatedBridge"]))
            ov = cfg["Target"]["OverlayStoragePath"]
            if sh(f"mkdir -p {shlex.quote(ov)} && test -w {shlex.quote(ov)} && echo ok", check=False) != "ok":
                raise RuntimeError(L("D_StorageMissing", ov))
            lin_cred = vbr.linux_credentials(cfg["Veeam"]["NodeCredentialsName"])
            if not lin_cred:
                raise RuntimeError(L("D_CredMissing", cfg["Veeam"]["NodeCredentialsName"]))
            run.cp("CP01", "-", L("CP01"), "OK", f"{node} / {bridge['iface']} / {ov} / cred {lin_cred.get('username')}")
        except Exception as e:  # noqa: BLE001
            run.cp("CP01", "-", L("CP01"), "KO", str(e)); raise Preflight()

        # CP02 - isolation (blocking)
        b_addr, b_gw = bridge.get("address"), bridge.get("gateway")
        ports = str(bridge.get("bridge_ports") or "").strip()
        tag = cfg["Target"].get("IsolatedVlanTag")
        tag_label = f" tag {tag}" if tag not in (None, "") else ""
        if b_addr or b_gw:
            run.cp("CP02", "-", L("CP02"), "KO", L("D_BridgeHasIp", bridge["iface"], b_addr, b_gw)); raise Preflight()
        has_uplink = ports and ports != "none"
        if has_uplink and not bool(cfg["Isolation"].get("SwitchIsolationConfirmed")):
            run.cp("CP02", "-", L("CP02"), "KO", L("D_BridgeUplinkVlan", bridge["iface"], ports, tag)); raise Preflight()
        run.cp("CP02", "-", L("CP02"), "OK", L("D_BridgeOk", bridge["iface"], tag_label, L("D_UplinkConfirmed", ports) if has_uplink else L("D_NoUplink")))

        # CP03 / CP04 - occupants and leftovers (VMs + stale publish sessions)
        all_vms = [v for v in (pve.get("/cluster/resources?type=vm") or []) if v.get("type") == "qemu"]
        on_iso, stale = [], []
        id_start = int(cfg["Target"]["VmIdRangeStart"])
        for v in [x for x in all_vms if x.get("node") == node]:
            try:
                c = pve.get(f"/nodes/{node}/qemu/{v['vmid']}/config") or {}
            except ApiError:
                continue
            is_test = str(v.get("name", "")).startswith(prefix) or (id_start <= int(v["vmid"]) < id_start + 100 and "Veeam Recovery Verification" in str(c.get("description", "")))
            if is_test:
                stale.append(v)
            elif any(nic_isolated(cfg, n) for n in parse_nics(c)):
                on_iso.append(v)
        if on_iso:
            run.cp("CP03", "-", L("CP03"), "KO", L("D_ForeignVms", ", ".join(f"{v.get('name')} ({v['vmid']})" for v in on_iso)))
        else:
            run.cp("CP03", "-", L("CP03"), "OK")
        stale_pub = [m for m in vbr.mounts() if m.get("mountState") in ("Mounted", "Mounting") and (m.get("info") or {}).get("mode") == "Fuse"]   # [API]
        left = [f"VM {v['vmid']}" for v in stale] + [f"publish {m.get('restorePointName')}" for m in stale_pub]
        if not left:
            run.cp("CP04", "-", L("CP04"), "OK")
        elif args.cleanup:
            failed = []
            for v in stale:
                try:
                    if not args.dry_run:
                        destroy_test_vm(int(v["vmid"]), f"{cfg['Target']['OverlayStoragePath']}/{v['vmid']}")
                except Exception:  # noqa: BLE001
                    failed.append(f"VM {v['vmid']}")
            for m in stale_pub:
                try:
                    if not args.dry_run:
                        vbr.unpublish(m["id"])
                except Exception:  # noqa: BLE001
                    failed.append(f"publish {m.get('restorePointName')}")
            if failed:
                run.cp("CP04", "-", L("CP04"), "KO", L("D_LeftoverDeleteFailed", ", ".join(failed))); raise Preflight()
            run.cp("CP04", "-", L("CP04"), "WARN", L("D_LeftoverDeleted", len(left), ", ".join(left)))
        else:
            run.cp("CP04", "-", L("CP04"), "KO", L("D_LeftoverFound", len(left), ", ".join(left))); raise Preflight()

        # ------------------------------------------------------------------ Step 1
        run.step(L("Step1", len(args.vm_names)))
        next_id = id_start
        used_ids = {int(v["vmid"]) for v in all_vms}
        for vm in args.vm_names:
            try:
                rp = vbr.latest_restore_point(vm)
                if not rp:
                    run.cp("CP10", vm, L("CP10"), "KO", L("D_NoRestorePoint")); run.skip_remaining(vm, L("D_NoRestorePointShort")); continue
                run.cp("CP10", vm, L("CP10"), "OK", L("D_CreatedOn", rp.get("creationTime")))
                created = datetime.fromisoformat(str(rp["creationTime"]).replace("Z", "+00:00"))
                if created.tzinfo is None:
                    created = created.replace(tzinfo=timezone.utc)
                age_h = round((datetime.now(timezone.utc) - created).total_seconds() / 3600, 1)
                rpo_ok = age_h <= float(cfg["Thresholds"]["MaxRestorePointAgeHours"])
                run.cp("CP11", vm, L("CP11", cfg["Thresholds"]["MaxRestorePointAgeHours"]), "OK" if rpo_ok else "KO",
                       f"{age_h} h" + ("" if rpo_ok else L("D_RpoMissed")), age_h)

                while next_id in used_ids:
                    next_id += 1
                vmid = next_id; next_id += 1; used_ids.add(vmid)
                target = re.sub(r"[^a-z0-9\-]", "-", (prefix + vm).lower())
                if args.dry_run:
                    print(f"  [dry-run] {L('M_BootAction', vm, vmid)}"); run.skip_remaining(vm, L("D_DryRun")); continue

                started = time.time()
                baseline = set(published_images(cfg["Proxmox"]["MountRoot"]))
                sid = vbr.publish(rp["id"], cfg["Veeam"]["TargetServerName"], lin_cred["id"], f"Recovery Verification {run.run_id}")
                s: Dict[str, Any] = {"SessionId": sid, "Rp": rp, "VmId": vmid, "Target": target, "Started": started,
                                     "OverlayDir": f"{cfg['Target']['OverlayStoragePath']}/{vmid}", "MountId": None, "Created": False}
                sessions[vm] = s
                print(L("D_PublishStarted", sid))

                res = vbr.wait_session(sid, int(cfg["Thresholds"]["PublishTimeoutMinutes"]), poll)
                pub_min = round((time.time() - started) / 60, 1)
                m = vbr.mount_for(rp["id"])
                if m:
                    s["MountId"] = m["id"]
                if res["Result"] not in ("Success", "Warning"):
                    run.cp("CP12", vm, L("CP12"), "KO", L("D_SessionFailed", res["Result"], pub_min, res["Message"])); run.skip_remaining(vm, L("D_PublishFailed")); continue
                images = [f for f in published_images(cfg["Proxmox"]["MountRoot"]) if f not in baseline]
                if not images:
                    run.cp("CP12", vm, L("CP12"), "KO", L("D_NoDisks", cfg["Proxmox"]["MountRoot"])); run.skip_remaining(vm, L("D_PublishFailed")); continue
                run.cp("CP12", vm, L("CP12"), "OK" if res["Result"] == "Success" else "WARN", L("D_Disks", len(images), ", ".join(Path(i).name for i in images)))

                create_test_vm(cfg, run.run_id, vmid, target, images, hardware_for(cfg, vm), s["OverlayDir"])
                s["Created"] = True
                s["CreatedAt"] = time.time()
                poll_ready(pve, node, sessions, cfg)   # earlier VMs keep booting while the next one is published
            except Exception as e:  # noqa: BLE001
                run.cp("CP12", vm, L("CP12Start"), "KO", str(e)[:300]); run.skip_remaining(vm, L("D_LaunchFailed"))

        # ------------------------------------------------------------------ Step 2
        run.step(L("Step2"))
        # Wait for every booted VM in round-robin (accurate time-to-IP per VM), then verify them one by one.
        while any(s["Created"] and not s.get("Done") for s in sessions.values()):
            time.sleep(poll)
            poll_ready(pve, node, sessions, cfg)
        for vm, s in sessions.items():
            if not s["Created"]:
                if args.cleanup and s["MountId"]:
                    try:
                        vbr.unpublish(s["MountId"])
                    except Exception as e:  # noqa: BLE001
                        logging.warning("unpublish failed: %s", e)
                continue
            vmid, ip = s["VmId"], s.get("Ip")
            try:
                vm_obj = s.get("Vm") or pve.vm(node, vmid)
                boot_min = round(((s.get("IpAt") or time.time()) - s["Started"]) / 60, 1)
                if not vm_obj:
                    run.cp("CP20", vm, L("CP20"), "KO", L("D_VmNotFound", vmid)); run.skip_remaining(vm, L("D_VmNotFoundShort")); continue
                running = (vm_obj["Status"] or {}).get("status") == "running"
                rto_ok = boot_min <= float(cfg["Thresholds"]["MaxBootMinutes"])
                run.cp("CP13", vm, L("CP13", cfg["Thresholds"]["MaxBootMinutes"]), "OK" if rto_ok else "WARN", f"{boot_min} min" + ("" if rto_ok else L("D_RtoMissed")), boot_min)
                run.cp("CP20", vm, L("CP20"), "OK" if running else "KO", L("D_Status", (vm_obj["Status"] or {}).get("status")))

                nics = parse_nics(vm_obj["Config"])
                leak = [n for n in nics if not nic_isolated(cfg, n)]
                if leak:
                    run.cp("CP21", vm, L("CP21"), "KO", L("D_NicLeak", " ; ".join(n["Raw"] for n in leak)))
                    try:
                        sh(f"qm stop {vmid} --skiplock 1", check=False)
                    except Exception as e:  # noqa: BLE001
                        logging.warning(L("M_ShutdownFailed", vmid, e))
                elif not nics:
                    run.cp("CP21", vm, L("CP21"), "WARN", L("D_NoNic"))
                else:
                    run.cp("CP21", vm, L("CP21"), "OK")

                if ip:
                    run.cp("CP22", vm, L("CP22"), "OK", ip)
                else:
                    run.cp("CP22", vm, L("CP22"), "WARN" if running else "KO", L("D_NoIp"))

                if not args.ping_check:
                    run.cp("CP23", vm, L("CP23"), "SKIP", L("D_PingOff"))
                elif not ip:
                    run.cp("CP23", vm, L("CP23"), "SKIP", L("D_NoIpShort"))
                else:
                    ok = subprocess.run(["ping", "-c", "2", "-W", "2", ip], capture_output=True).returncode == 0
                    run.cp("CP23", vm, L("CP23"), "OK" if ok else "KO", ip)

                checks = checks_for(cfg, vm)
                if not checks:
                    run.cp("CP30", vm, L("CP30"), "SKIP", L("D_NoChecks"))
                elif not running:
                    run.cp("CP30", vm, L("CP30"), "SKIP", L("D_Status", "not running"))
                else:
                    for c in checks:
                        r = app_check(pve, node, vmid, c, ip)
                        st = "SKIP" if r["Ok"] is None else ("OK" if r["Ok"] else "KO")
                        run.cp("CP30", vm, L("CP30Item", c.get("Label") or c.get("Type")), st, r["Detail"])
            except Exception as e:  # noqa: BLE001
                run.cp("CP20", vm, L("Verify"), "KO", L("D_Unexpected", str(e)[:300]))
            finally:
                # Step 3 - Cleanup (always attempted)
                if not args.cleanup:
                    run.cp("CP40", vm, L("CP40"), "SKIP", L("D_CleanupOff"))
                else:
                    errs = []
                    try:
                        destroy_test_vm(vmid, s["OverlayDir"])
                    except Exception as e:  # noqa: BLE001
                        errs.append(str(e)[:200])
                    if not s["MountId"]:
                        try:
                            m = vbr.mount_for(s["Rp"]["id"]); s["MountId"] = m["id"] if m else None
                        except Exception:  # noqa: BLE001
                            pass
                    if s["MountId"]:
                        try:
                            vbr.unpublish(s["MountId"])
                        except Exception as e:  # noqa: BLE001
                            errs.append(str(e)[:200])
                    if errs:
                        run.cp("CP40", vm, L("CP40"), "KO", L("D_CleanupFailed", " ; ".join(errs), vmid, s["MountId"]))
                    else:
                        run.cp("CP40", vm, L("CP40"), "OK", f"VM {vmid}, publish {s['MountId']}")
    except Preflight:
        print(f"\n{L('M_PreflightAbort')}"); exit_code = 2
    except KeyboardInterrupt:
        print("\ninterrupted"); exit_code = 2
    except Exception as e:  # noqa: BLE001
        print(f"\n{L('M_Fatal', e)}"); logging.exception("fatal"); exit_code = 2
    finally:
        # ------------------------------------------------------------------ Step 4
        run.step(L("Step4"))
        try:
            rows = summary(args.vm_names, run.checkpoints, args.fail_on_warning)
            files = export_reports(run, cfg, args.vm_names, rows)
            print(f"  {'VM':<20}{'Age(h)':>8}{'Boot(min)':>10}  {'IP':<16}{'KO':>4}{'WARN':>5}  Result")
            for r in rows:
                fmt = lambda x: "" if x is None else str(x)  # noqa: E731
                print(f"  {r['VM']:<20}{fmt(r['RestorePointAgeH']):>8}{fmt(r['BootMinutes']):>10}  {r['IP']:<16}{r['KO']:>4}{r['WARN']:>5}  {r['Result']}")
            print(f"\nHTML : {files['Html']}\nCSV  : {files['Csv']}\nJSON : {files['Json']}\nLog  : {run.log_path}")
        except Exception as e:  # noqa: BLE001
            print(L("M_ReportFailed", e)); logging.exception("report")
        if exit_code == 0:
            failures = sum(1 for c in run.checkpoints if c["Status"] == "KO" or (args.fail_on_warning and c["Status"] == "WARN"))
            if failures:
                print(f"\n{L('M_Failures', failures)}"); exit_code = 1
            else:
                print(f"\n{L('M_AllOk')}")
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
