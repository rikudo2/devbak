# Installation Guide — devbak

## Prérequis

- **OS** : Linux (Debian/Ubuntu recommandé, fonctionne sur toute distribution avec Bash 4+)
- **Bash** 4.x ou supérieur
- **Accès root ou sudo** pour certaines opérations (installation cron, écriture dans `/etc/devbak.yaml`)

## Dépendances

### Essentielles

```bash
sudo apt update
sudo apt install -y bash tar gzip coreutils findutils curl
```

### Base de données (selon ton projet)

```bash
# Pour MySQL / MariaDB
sudo apt install -y mysql-client

# Pour PostgreSQL
sudo apt install -y postgresql-client
```

### Docker (optionnel mais recommandé)

```bash
sudo apt install -y docker.io
sudo systemctl enable --now docker
```

### rclone (pour l'upload distant)

```bash
sudo apt install -y rclone
rclone config
```

> **Configuration rclone** : lance `rclone config` et suis les instructions pour ajouter un remote (Google Drive, S3, SFTP, etc.).

## Installation

### 1. Téléchargement

```bash
git clone https://github.com/rikudo2/devbak.git
cd devbak
```

Ou télécharge le script directement :

```bash
curl -O https://raw.githubusercontent.com/rikudo2/devbak/main/backup-dev.sh
chmod +x backup-dev.sh
```

### 2. Rendre le script exécutable

```bash
chmod +x backup-dev.sh
```

### 3. Test rapide

```bash
./backup-dev.sh --dry-run
```

Si tout est bien configuré, tu verras un résumé de la détection sans qu'aucune action réelle ne soit effectuée.

### 4. Configuration automatique (recommandé)

```bash
./backup-dev.sh --setup
```

Ce mode interactive :
- Détecte ton projet
- Configure rclone si nécessaire
- Installe une tâche cron (quotidienne à 2h30 et 18h30 par défaut)

### 5. Vérification

```bash
crontab -l                    # Vérifier que le cron est bien installé
./backup-dev.sh --cron-check  # Tester tous les projets détectés
```

## Configuration manuelle

### Projet unique

```bash
PROJECT_DIR=/var/www/monsite ./backup-dev.sh
```

### Multi-projets

Crée `/etc/devbak.yaml` :

```yaml
projects:
  - /var/www/site1
  - /var/www/site2
  - /home/user/app
```

Puis lance :

```bash
./backup-dev.sh --all
```

### Cron manuel

Ajoute cette ligne dans `crontab -e` :

```cron
30 2,18 * * * /chemin/vers/backup-dev.sh >> /tmp/devbak.log 2>&1
```

## Variables d'environnement

Toutes les variables peuvent être passées en préfixe :

```bash
DB_TYPE=pgsql DB_PORT=5432 DOCKER_MODE=false ./backup-dev.sh
```

Voir `./backup-dev.sh --help` pour la liste complète.

## Structure des backups

```
{PROJECT_DIR}/storage/app/backups/
├── {prefix}-backup-dev-{date}.tar.gz   # Archive complète
└── backup-dev.log                       # Journal des opérations
```

Contenu de l'archive :
```
db.sql                  # Dump de la base de données
config.tar.gz           # Fichiers de configuration
system-info.txt         # Informations système
```

## Désinstallation

```bash
# Supprimer le cron
crontab -e   # Retire la ligne devbak

# Supprimer le script
rm /chemin/vers/backup-dev.sh

# Supprimer les logs et backups
rm -rf /tmp/devbak.log /tmp/backups
rm -rf ~/devbak
```

## Support

- **Documentation** : `./backup-dev.sh --help`
- **Dépot** : https://github.com/rikudo2/devbak
- **Dev** : Mr-Robot (Fsociety / Fs4)
