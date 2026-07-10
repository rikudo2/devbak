# devbak — Universal Backup System

**devbak** est un script Bash universel de sauvegarde pour serveurs de développement. Il détecte automatiquement les projets (Laravel, WordPress, Node.js, PHP, Rails…) et sauvegarde leur BDD, config et infos système.

```
Dev: Mr-Robot (Fsociety / Fs4)
Licence: MIT
```

## Fonctionnalités

- **Découverte automatique** des projets : scan conteneurs Docker, scan disque global (`/var/www`, `/home`, `/data`), fichier YAML, ou saisie interactive
- **Sauvegarde triple** par projet :
  1. Dump base de données (MySQL/MariaDB ou PostgreSQL)
  2. Archive des fichiers de configuration (Dockerfile, .env, nginx.conf, etc.)
  3. Snapshot système (versions PHP/Node/Composer, état Docker, disque/RAM/uptime)
- **Upload rclone** vers le cloud/remote de ton choix
- **Rotation automatique** (30 jours par défaut)
- **Mode multi-projets** (`--all`) pour sauvegarder tout le serveur d'un coup
- **Mode simulation** (`--dry-run`) sans action réelle
- Configuration via **variables d'environnement**

## Installation

```bash
git clone https://github.com/rikudo2/devbak.git
cd devbak
chmod +x backup-dev.sh
./backup-dev.sh --setup
```

Voir [INSTALL.md](INSTALL.md) pour le guide complet (prérequis, dépendances, configuration manuelle).

## Utilisation rapide

```bash
# Sauvegarde automatique d'un projet
./backup-dev.sh

# Sauvegarde de tous les projets détectés
./backup-dev.sh --all

# Simulation
./backup-dev.sh --dry-run

# Configuration cron + rclone
./backup-dev.sh --setup

# Vérification des crons + test
./backup-dev.sh --cron-check

# Aide complète
./backup-dev.sh --help
```

## Variables d'environnement principales

| Variable | Défaut | Description |
|---|---|---|
| `PROJECT_DIR` | auto-détecté | Racine du projet |
| `BACKUP_NAME_PREFIX` | nom du dossier | Préfixe des archives |
| `BACKUP_DIR` | `storage/app/backups` | Dossier de sortie |
| `DB_TYPE` | `mysql` | Type de BDD (`mysql`, `pgsql`, `none`) |
| `DOCKER_MODE` | `auto` | Mode Docker (`auto`, `true`, `false`) |
| `RCLONE_REMOTE` | auto-détecté | Remote rclone |
| `RCLONE_PATH` | `{prefix}-backups` | Dossier cible remote |
| `RCLONE_CLEANUP` | `true` | Supprimer archive locale après upload |
| `KEEP_DAYS` | `30` | Rétention locale des backups |

## Dépendances

- Bash 4+
- `mysqldump` ou `pg_dump` (selon BDD)
- Docker (optionnel, recommandé)
- rclone (optionnel, pour upload distant)
- GNU tar, coreutils, findutils

## Configuration multi-projets

Crée `/etc/devbak.yaml` :

```yaml
projects:
  - /var/www/mon-site
  - /home/user/mon-app
  - /data/api
```

## Licence

MIT — Copyright (c) 2026 Mr-Robot (Fsociety / Fs4)
