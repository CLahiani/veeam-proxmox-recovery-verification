# Référence des points de contrôle

[← Configuration](configuration.md) · [Notes de conception →](conception.md) · 🇬🇧 [English version](../en/checkpoints.md)

Chaque vérification est un **point de contrôle** avec un statut `OK`, `KO`, `WARN` ou `SKIP`, présent dans la console, les fichiers CSV / JSON et le rapport HTML. `Value` contient la mesure pour CP11 (heures) et CP13 (minutes). Les points **bloquants** arrêtent l'exécution en pré-vol (code de sortie 2) ; un `KO` sur une VM saute les contrôles restants de cette VM uniquement.

## Étape 0 — Pré-vol (une fois par exécution)

| CP | Contrôle | OK | WARN | KO | Bloquant |
|---|---|---|---|---|---|
| **CP00** | `qm` / `qemu-img` présents ; authentification : REST VBR (OAuth), API Proxmox (jeton) | Tout réussit ; le détail indique la version d'API et `pveversion` | — | L'une échoue | ✔ |
| **CP01** | Nœud présent dans le cluster ; bridge isolé présent sur le nœud ; chemin overlay existant / inscriptible ; identifiants Linux VBR trouvés | Tout trouvé | — | Un élément manque (`Detail` indique lequel) | ✔ |
| **CP02** | Bridge isolé **non routé** : aucune IP / passerelle sur le bridge du nœud ; un bridge avec uplink exige `Isolation.SwitchIsolationConfirmed` | Conditions remplies (détail : `aucun uplink` ou `isolement commutateur confirmé par la configuration`) | — | Le bridge porte IP / passerelle, ou uplink sans confirmation | ✔ |
| **CP03** | Aucune VM étrangère attachée au bridge isolé (+ tag) | Aucune | — | VM hors test listées | — |
| **CP04** | Aucune VM de test résiduelle (préfixe de nom, ou plage VMID + marqueur de description) et aucune publication FUSE périmée dans VBR | Aucune | Résidus trouvés **et supprimés** (`--cleanup`) | Résidus sans `--cleanup`, ou suppression en échec | ✔ |

## Étape 1 — Démarrage depuis la sauvegarde (par VM)

| CP | Contrôle | OK | WARN | KO | SKIP |
|---|---|---|---|---|---|
| **CP10** | Dernier point de restauration Proxmox VE dans VBR (nom exact) | Trouvé (date de création) | — | Aucun → reste `SKIP` | — |
| **CP11** | Âge du point de restauration ≤ `MaxRestorePointAgeHours` (**RPO**) | Dans la cible | — | Plus ancien | — |
| **CP12** | La session de publication Data Integration API se termine en `Success` / `Warning` **et** de nouvelles images disque brutes apparaissent sous `MountRoot` | `Success`, disques listés | `Warning` | Session `Failed` / délai dépassé, ou aucune image → reste `SKIP` | `--dry-run` |

Entre CP12 et l'étape 2, le script crée les overlays et la VM (`qemu-img`, `qm create`, `qm start`) ; une erreur à ce stade est rapportée en CP12 `KO` (`échec au lancement`). Avec `--dry-run`, CP10/CP11 s'exécutent et le reste est `SKIP` (`dry-run`).

## Étape 2 — Vérification (par VM)

| CP | Contrôle | OK | WARN | KO | SKIP |
|---|---|---|---|---|---|
| **CP13** | Délai entre le début de publication et l'IP guest agent ≤ `MaxBootMinutes` (**RTO, démarrage depuis la sauvegarde**) | Dans la cible | Dépassé | — | Non démarrée |
| **CP20** | VM de test `status = running` | Running | — | Introuvable / non running | Non démarrée |
| **CP21** | **Garde-fou** — chaque `netN` sur `IsolatedBridge` avec `IsolatedVlanTag` | Toutes les NIC isolées | Aucune NIC | Une NIC ailleurs → **VM arrêtée immédiatement** | Non démarrée |
| **CP22** | IPv4 remontée par le QEMU guest agent (hors loopback, hors APIPA) | IP (détail) | Running mais pas d'IP | Non running et pas d'IP | Non démarrée |
| **CP23** | Ping depuis cet hôte (`--ping-check`) | Réponse | — | Aucune réponse | Désactivé / pas d'IP |
| **CP30** | Contrôles applicatifs, un CP par contrôle (`Applicatif : <Label>`) — `GuestExec` dans l'invité, ou contrôles réseau depuis cet hôte | Réussi (`exit 0: …`) | — | Échec (code de sortie / regex / raison) | Aucun contrôle, VM non running, guest agent muet, module python absent, type inconnu |

## Étape 3 — Nettoyage (par VM, toujours tenté)

| CP | Contrôle | OK | KO | SKIP |
|---|---|---|---|---|
| **CP40** | `qm stop`, `qm destroy --purge`, overlays supprimés, point de restauration **dépublié** dans VBR | Tout effectué (détail : VMID, id de montage) | Une étape en échec (le détail indique quoi nettoyer manuellement) | `--cleanup` désactivé (VM conservée, disques toujours publiés) |

## Résultat par VM et code de sortie

| Situation | `Result` | Code de sortie |
|---|---|---|
| Aucun `KO`, aucun `WARN` | `OK` | `0` |
| `WARN` uniquement, sans `--fail-on-warning` | `OK (avertissements)` | `0` |
| `WARN` uniquement, avec `--fail-on-warning` | `KO` | `1` |
| Au moins un `KO` | `KO` | `1` |
| Échec bloquant en pré-vol ou erreur fatale | — | `2` |

## Correspondance avec les questions d'audit

| Question d'audit | Preuve |
|---|---|
| Les sauvegardes existent et respectent le RPO | CP10 + CP11 (`Value` heures) |
| Les sauvegardes sont lisibles / cohérentes | CP12 |
| Les systèmes peuvent être remis en service depuis la sauvegarde, dans le RTO | CP13 + CP20 (`Value` minutes) |
| Les systèmes restaurés sont joignables | CP22 + CP23 |
| Les applications fonctionnent | CP30 par service |
| Les tests n'exposent jamais la production | CP02 + CP03 + CP21 + publication en lecture seule |
| L'environnement de test est nettoyé | CP04 + CP40 |
