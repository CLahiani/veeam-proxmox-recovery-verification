# Example reports — fake data / Exemples de rapports — données fictives

**EN** — Output of `pve_backup_boot.py` v2.0.0 against a **simulated** environment (mocked Veeam and Proxmox APIs, qm / qemu-img not executed): five VMs, one restore point older than the RPO, one boot longer than the RTO, one VM whose guest agent never answers, one failing health-endpoint check and one SQL service check, one VM with no restore point. Every host name, IP and identifier is invented. Open the HTML files in a browser; CSV / JSON are what a SIEM or Power BI would ingest.

**FR** — Sortie de `pve_backup_boot.py` v2.0.0 sur un environnement **simulé** (API Veeam et Proxmox factices, qm / qemu-img non exécutés) : cinq VM, un point de restauration plus ancien que le RPO, un démarrage plus long que le RTO, une VM dont le guest agent ne répond jamais, un contrôle health endpoint et un contrôle service SQL en échec, une VM sans point de restauration. Noms d'hôtes, IP et identifiants sont inventés. Ouvrir les HTML dans un navigateur ; CSV / JSON sont ce qu'un SIEM ou Power BI ingérerait.

| | English | Français |
|---|---|---|
| HTML | [RecoveryVerification-20260919-050000.html](en/RecoveryVerification-20260919-050000.html) | [RecoveryVerification-20260919-050000.html](fr/RecoveryVerification-20260919-050000.html) |
| CSV | [RecoveryVerification-20260919-050000.csv](en/RecoveryVerification-20260919-050000.csv) | [RecoveryVerification-20260919-050000.csv](fr/RecoveryVerification-20260919-050000.csv) |
| JSON | [RecoveryVerification-20260919-050000.json](en/RecoveryVerification-20260919-050000.json) | [RecoveryVerification-20260919-050000.json](fr/RecoveryVerification-20260919-050000.json) |

Rendered preview (GitHub does not render HTML in-repo): open through https://htmlpreview.github.io/?https://github.com/CLahiani/veeam-proxmox-recovery-verification/blob/main/examples/en/RecoveryVerification-20260919-050000.html
