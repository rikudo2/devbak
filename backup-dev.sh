#!/bin/bash
set -euo pipefail

: "${LOG_FILE:=/tmp/devbak.log}"

# ═════════════════════════════════════════════════════════════════════
# backup-dev.sh  —  Backup universel (DB + config serveur → rclone)
#
# Universel : fonctionne sur n'importe quel projet (Laravel, Node,
# Symfony, WordPress...) et n'importe quel serveur (Docker ou non).
#
# Tout est configurable via variables d'environnement. Les valeurs
# par défaut sont pensées pour FermeOS mais s'adaptent automatiquement
# au projet détecté.
#
# ═══ Usage ═══════════════════════════════════════════════════════════
#
#   backup-dev.sh                  # run normal (projet courant)
#   backup-dev.sh --all            # backup multi-projets
#   backup-dev.sh --dry-run        # simulation
#   backup-dev.sh --setup          # config cron + rclone (interactif)
#   backup-dev.sh --cron-check     # check crons + dry-run tous les projets
#   backup-dev.sh --help           # aide + variables disponibles
#
# ═══ Personnalisation ═══════════════════════════════════════════════
#
#   BACKUP_NAME_PREFIX="monprojet"   # préfixe des archives
#   BACKUP_DIR="/custom/path"        # dossier de sortie
#   KEEP_DAYS=30                     # rétention locale
#   RCLONE_REMOTE="monremote"        # remote rclone
#   RCLONE_PATH="monprojet-backups"  # dossier cible
#   RCLONE_CLEANUP=true              # supprimer l'archive locale après upload
#   DOCKER_APP_NAME="mon-app"        # nom du conteneur app
#   DOCKER_DB_NAME="mon-db"          # nom du conteneur DB
#   CONFIG_FILES="Dockerfile docker-compose.yaml ..."   # fichiers à archiver
#   DB_USER="root" DB_PASSWORD="..." DB_HOST="..." DB_NAME="..." DB_PORT="3306"
#
# ═══ Exemples multi-serveur ═════════════════════════════════════════
#
#   # Serveur A : Laravel + Docker
#   BACKUP_NAME_PREFIX="app-prod" ./backup-dev.sh
#
#   # Serveur B : Node.js + PostgreSQL direct
#   BACKUP_NAME_PREFIX="api" DOCKER_MODE=false DB_TYPE=pgsql ./backup-dev.sh
#
#   # Serveur C : WordPress
#   CONFIG_FILES="wp-config.php .htaccess" ./backup-dev.sh
#
# ═════════════════════════════════════════════════════════════════════

# ─── 1. Détection du type de projet ─────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

detect_project_dir() {
    local dir
    for marker in "artisan" "composer.json" "package.json" "index.php" "wp-config.php" "Gemfile" "Cargo.toml" "mix.exs"; do
        [ -f "$SCRIPT_DIR/$marker" ] && { echo "$SCRIPT_DIR"; return 0; }
    done
    for dir in "/var/www" "/var/www/html" "$HOME/project" "$HOME/app" "/data" "$HOME"; do
        for marker in "artisan" "composer.json" "package.json" "index.php"; do
            [ -f "$dir/$marker" ] && { echo "$dir"; return 0; }
        done
    done
    # Fallback : ne pas retourner de chemin système
    case "$SCRIPT_DIR" in
        /usr/local/*|/usr/bin/*|/bin/*|/etc/*|/opt/*) echo ""; return 0 ;;
        *) echo "$SCRIPT_DIR"; return 0 ;;
    esac
}

detect_project_type() {
    local dir="$1"
    [ -f "$dir/artisan" ] && { echo "laravel"; return 0; }
    [ -f "$dir/wp-config.php" ] && { echo "wordpress"; return 0; }
    [ -f "$dir/composer.json" ] && { echo "php"; return 0; }
    [ -f "$dir/package.json" ] && { echo "node"; return 0; }
    [ -f "$dir/Gemfile" ] && { echo "rails"; return 0; }
    echo "generic"
}

PROJECT_DIR="${PROJECT_DIR:-$(detect_project_dir)}"
PROJECT_TYPE="${PROJECT_TYPE:-$(detect_project_type "$PROJECT_DIR")}"
PROJECT_NAME="${BACKUP_NAME_PREFIX:-$(basename "${PROJECT_DIR:-generic}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')}"

# ─── 2. Conteneurs Docker ────────────────────────────────────────
DOCKER_APP_NAMES="${DOCKER_APP_NAMES:-${DOCKER_APP_NAME:-ferme-app app laravel fermeos web node app-server}}"
DOCKER_DB_NAMES="${DOCKER_DB_NAMES:-${DOCKER_DB_NAME:-mysql db mariadb postgres pgsql postgresql}}"
DOCKER_MODE="${DOCKER_MODE:-auto}"   # auto / true / false

detect_container() {
    local names="$1" filter="$2"
    IFS=' ' read -ra list <<< "$names"
    for name in "${list[@]}"; do
        cid=$(docker ps --filter "name=$name" -q | head -1)
        [ -n "$cid" ] && { echo "$cid"; return 0; }
    done
    if [ -n "$filter" ]; then
        cid=$(docker ps --format '{{.ID}} {{.Image}}' | grep -i "$filter" | head -1 | awk '{print $1}')
        [ -n "$cid" ] && echo "$cid" && return 0
    fi
    echo ""; return 0
}

APP_CONTAINER="" MYSQL_CONTAINER=""
if [ "$DOCKER_MODE" != "false" ] && command -v docker &>/dev/null; then
    APP_CONTAINER=$(detect_container "$DOCKER_APP_NAMES" "")
    MYSQL_CONTAINER=$(detect_container "$DOCKER_DB_NAMES" "mysql\|mariadb\|postgres")
    [ -z "$MYSQL_CONTAINER" ] && MYSQL_CONTAINER="$APP_CONTAINER"
fi

# ─── 3. DB ───────────────────────────────────────────────────────
DB_TYPE="${DB_TYPE:-mysql}"             # mysql / pgsql / none
DB_USER="${DB_USER:-root}"
DB_PASSWORD="${DB_PASSWORD:-}"
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-3306}"
DB_NAME="${DB_NAME:-}"

detect_db_creds() {
    local c="$1" u="" p="" h="" d=""

    # Depuis les variables d'env du conteneur (Coolify / Docker)
    if [ -n "$c" ] && [ "$DOCKER_MODE" != "false" ]; then
        case "$PROJECT_TYPE" in
            laravel)
                u=$(docker exec "$c" printenv DB_USERNAME 2>/dev/null || true)
                p=$(docker exec "$c" printenv DB_PASSWORD 2>/dev/null || true)
                h=$(docker exec "$c" printenv DB_HOST 2>/dev/null || true)
                d=$(docker exec "$c" printenv DB_DATABASE 2>/dev/null || true) ;;
            wordpress)
                u=$(docker exec "$c" printenv WORDPRESS_DB_USER 2>/dev/null || true)
                p=$(docker exec "$c" printenv WORDPRESS_DB_PASSWORD 2>/dev/null || true)
                h=$(docker exec "$c" printenv WORDPRESS_DB_HOST 2>/dev/null || true)
                d=$(docker exec "$c" printenv WORDPRESS_DB_NAME 2>/dev/null || true) ;;
            *)
                u=$(docker exec "$c" printenv DB_USER 2>/dev/null || true)
                p=$(docker exec "$c" printenv DB_PASS 2>/dev/null || true)
                h=$(docker exec "$c" printenv DB_HOST 2>/dev/null || true)
                d=$(docker exec "$c" printenv DB_NAME 2>/dev/null || true) ;;
        esac
    fi

    # Fallback .env local
    if [ -z "$p" ] && [ -f "$PROJECT_DIR/.env" ]; then
        case "$PROJECT_TYPE" in
            laravel)
                p=$(grep '^DB_PASSWORD=' "$PROJECT_DIR/.env" | cut -d= -f2- | tr -d '"'"'"' | head -1 || true)
                u=$(grep '^DB_USERNAME=' "$PROJECT_DIR/.env" | cut -d= -f2- | tr -d '"'"'"' | head -1 || true)
                h=$(grep '^DB_HOST=' "$PROJECT_DIR/.env" | cut -d= -f2- | tr -d '"'"'"' | head -1 || true)
                d=$(grep '^DB_DATABASE=' "$PROJECT_DIR/.env" | cut -d= -f2- | tr -d '"'"'"' | head -1 || true) ;;
            wordpress)
                p=$(grep '^DB_PASSWORD=' "$PROJECT_DIR/wp-config.php" | cut -d"'" -f4 || true) ;;
        esac
    fi

    # Valeurs finales : priorité aux vars d'env explicites
    echo "${u:-${DB_USER}}|${p:-${DB_PASSWORD}}|${h:-${DB_HOST}}|${d:-${DB_NAME}}"
}

# ─── 4. Fichiers config à archiver ──────────────────────────────
CONFIG_FILES="${CONFIG_FILES:-}"

detect_config_files() {
    local dir="$1" type="$2"
    case "$type" in
        laravel)
            echo "Dockerfile docker-compose.yaml nginx.conf entrypoint.sh composer.json package.json .env.example routes/console.php"
            ;;
        wordpress)
            echo "wp-config.php .htaccess nginx.conf docker-compose.yaml"
            ;;
        node)
            echo "package.json Dockerfile nginx.conf docker-compose.yaml .env.example"
            ;;
        *)
            echo "Dockerfile docker-compose.yaml nginx.conf .env.example"
            ;;
    esac
}

if [ -z "$CONFIG_FILES" ]; then
    CONFIG_FILES=$(detect_config_files "$PROJECT_DIR" "$PROJECT_TYPE")
fi

# ─── 5. Rclone ──────────────────────────────────────────────────
detect_rclone_remote() {
    command -v rclone &>/dev/null || { echo "remote"; return 0; }
    for name in "${RCLONE_REMOTE:-fondateur fermeos backups gdrive}" "remote" "drive" "s3"; do
        rclone listremotes 2>/dev/null | grep -q "^${name}:" && { echo "$name"; return 0; }
    done
    first=$(rclone listremotes 2>/dev/null | head -1 | tr -d ':')
    echo "${first:-remote}"
}

# ─── 5b. Découverte multi-projets ─────────────────────────────────
declare -a PROJECT_ROOTS=() PROJECT_TYPES=() PROJECT_NAMES=() PROJECT_SOURCES=()

register_project() {
    local root="$1" type="$2" name="$3" source="${4:-auto}"
    # Ignorer les répertoires système
    case "$root" in /usr/local/*|/bin/*|/usr/bin/*|/etc/*|/sys/*|/proc/*|/dev/*) return 1 ;; esac
    # Ignorer les doublons
    for existing in "${PROJECT_ROOTS[@]}"; do [ "$existing" = "$root" ] && return 1; done
    PROJECT_ROOTS+=("$root"); PROJECT_TYPES+=("$type"); PROJECT_NAMES+=("$name"); PROJECT_SOURCES+=("$source")
}

scan_docker_projects() {
    command -v docker &>/dev/null || return 0
    local cid mounts
    for cid in $(docker ps -q 2>/dev/null); do
        mounts=$(docker inspect --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' "$cid" 2>/dev/null || true)
        [ -z "$mounts" ] && continue
        while IFS= read -r mount; do
            [ -z "$mount" ] && continue
            for marker in "artisan" "composer.json" "package.json" "index.php" "wp-config.php" "Gemfile" "Cargo.toml" "mix.exs"; do
                [ -f "$mount/$marker" ] && { register_project "$mount" "auto" "$(basename "$mount" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')" "docker"; break; }
            done
        done <<< "$mounts"
    done
}

scan_global_projects() {
    local dir
    for dir in "/var/www" "/home" "/data"; do
        [ ! -d "$dir" ] && continue
        for marker in "artisan" "composer.json" "package.json" "index.php" "wp-config.php"; do
            while IFS= read -r found; do
                [ -n "$found" ] && register_project "$(dirname "$found")" "auto" "$(basename "$(dirname "$found")" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')" "global"
            done < <(find "$dir" -maxdepth 3 -name "$marker" -type f 2>/dev/null | head -20 || true)
        done
    done
}

load_yaml_projects() {
    for yaml_path in "/etc/devbak.yaml" "$HOME/.config/devbak.yaml" "${PROJECT_DIR:-.}/devbak.yaml"; do
        [ ! -f "$yaml_path" ] && continue
        local in_projects=false
        while IFS= read -r line; do
            case "$line" in
                "projects:"*) in_projects=true; continue ;;
                " "*|$'\t'*) ;;
                *) in_projects=false; continue ;;
            esac
            $in_projects || continue
            local path="${line#*- }"; path="${path#\"}"; path="${path%\"}"; path="${path# }"
            [ -n "$path" ] && [ -d "$path" ] && register_project "$path" "auto" "$(basename "$path" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')" "yaml"
        done < "$yaml_path"
    done
}

discover_projects() {
    scan_docker_projects
    [ ${#PROJECT_ROOTS[@]} -eq 0 ] && scan_global_projects
    load_yaml_projects
}

# ─── 6. Variables finales ───────────────────────────────────────
BACKUP_DIR="${BACKUP_DIR:-${PROJECT_DIR}/storage/app/backups}"
BACKUP_DIR="${BACKUP_DIR:-${PROJECT_DIR}/backups}"
BACKUP_DIR="${BACKUP_DIR:-/tmp/backups}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BASENAME="${PROJECT_NAME}-backup-dev-${TIMESTAMP}"
WORK_DIR=$(mktemp -d)
RCLONE_REMOTE="${RCLONE_REMOTE:-$(detect_rclone_remote)}"
RCLONE_PATH="${RCLONE_PATH:-${PROJECT_NAME}-backups}"
RCLONE_CLEANUP="${RCLONE_CLEANUP:-true}"
KEEP_DAYS="${KEEP_DAYS:-30}"
DRY_RUN="${DRY_RUN:-false}"
mkdir -p "$BACKUP_DIR" 2>/dev/null || true
LOG_FILE="${LOG_FILE:-$BACKUP_DIR/backup-dev.log}"
[ ! -d "$(dirname "$LOG_FILE")" ] && LOG_FILE="/tmp/backup-dev.log"

IS_TTY=false
[ -t 0 ] && IS_TTY=true
ARG="${1:-}"

# ─── Early exit : si aucun projet trouvé ─────────────────────────
if [ -z "${PROJECT_DIR}" ] && [ "$ARG" != "--help" ] && [ "$ARG" != "--setup" ] && [ "$ARG" != "--all" ] && [ "$ARG" != "--cron-check" ]; then
    echo "❌ Aucun projet trouvé dans les répertoires standards."
    echo "   Lance './$(basename "$0") --setup' pour configurer un chemin personnalisé"
    echo "   ou définis PROJECT_DIR=/chemin/vers/ton/projet"
    exit 1
fi

# ─── 7. Fonctions ───────────────────────────────────────────────
log()    { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE" 2>/dev/null || true; }
info()   { log "ℹ️  $*"; }
ok()     { log "✅ $*"; }
warn()   { log "⚠️  $*"; }
fail()   { log "❌ $*"; }
title()  { log "━━━ $* ━━━"; }

cleanup() {
    local ec=$?
    [ -n "${WORK_DIR:-}" ] && rm -rf "$WORK_DIR" 2>/dev/null
    [ "$ec" -ne 0 ] && [ "$ec" -ne 130 ] && [ "$ec" -ne 143 ] && fail "Backup interrompu (code $ec)"
}
trap cleanup EXIT

confirm() {
    local prompt="$1" default="${2:-n}" ans
    [ "$IS_TTY" = false ] && return 1
    printf "%s [%s/%s] " "$prompt" "$( [ "$default" = "y" ] && echo 'Y' || echo 'y' )" "$( [ "$default" = "n" ] && echo 'N' || echo 'n' )"
    read -r ans </dev/tty
    ans="${ans:-$default}"
    case "$ans" in [YyOo1]*) return 0 ;; *) return 1 ;; esac
}

# Traduit une expression cron en français concis
# Ex: "30 2,18 * * *" → "quotidien 02h30, 18h30"
cron_human() {
    local expr="$1" minute hour dom month dow
    IFS=' ' read -r minute hour dom month dow <<< "$expr"
    minute="$(printf '%s' "$minute" | sed 's/^0//')"
    local freq=""
    if [ "$dow" = "*" ] && [ "$dom" = "*" ]; then
        freq="quotidien"
    elif [ "$dow" != "*" ]; then
        case "$dow" in 0|7) freq="hebdo dimanche" ;; 1) freq="hebdo lundi" ;; 2) freq="hebdo mardi" ;; 3) freq="hebdo mercredi" ;; 4) freq="hebdo jeudi" ;; 5) freq="hebdo vendredi" ;; 6) freq="hebdo samedi" ;; *) freq="quotidien" ;; esac
    fi
    local times=""
    if [[ "$hour" == *","* ]]; then
        IFS=',' read -ra hrs <<< "$hour"
        local parts=()
        for h in "${hrs[@]}"; do parts+=("${h}h${minute}"); done
        times=$(IFS=,; echo "${parts[*]}")
    else
        times="${hour}h${minute}"
    fi
    echo "${freq} ${times}"
}

signature() {
    echo ""
    echo "╔═══════════════════════════════════════════╗"
    echo "║   Fs4 Backup System                       ║"
    echo "║   Mr-Robot                                ║"
    echo "╚═══════════════════════════════════════════╝"
    echo ""
}

banner() {
    local title="${1:-Backup universel}"
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  Fs4 :: ${title}                         ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
}

mkdir -p "$BACKUP_DIR"

# ═════════════════════════════════════════════════════════════════
# MODE : --help
# ═════════════════════════════════════════════════════════════════
if [ "$ARG" = "--help" ] || [ "$ARG" = "-h" ]; then
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  backup-dev.sh — Backup universel DB + config → rclone ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
    echo "Usage :"
    echo "  ./backup-dev.sh               Run normal (projet courant)"
    echo "  ./backup-dev.sh --all         Backup de tous les projets découverts"
    echo "  ./backup-dev.sh --dry-run     Simulation"
    echo "  ./backup-dev.sh --setup       Config cron + rclone (interactif)"
    echo "  ./backup-dev.sh --cron-check  Vérifie les crons + dry-run de tous les projets"
    echo ""
    echo "Découverte automatique des projets :"
    echo "  1. Conteneurs Docker (bind mounts)"
    echo "  2. Scan global (/var/www, /home, /data)"
    echo "  3. Fichier YAML (/etc/devbak.yaml ou ~/.config/devbak.yaml)"
    echo "     Format :"
    echo "       projects:"
    echo "         - /chemin/vers/mon/projet"
    echo ""
    echo "Détection par projet :"
    echo "  Type projet    → laravel / wordpress / node / php / generic"
    echo "  Conteneurs     → recherche par nom (configurable)"
    echo "  Credentials DB → variables d'env du conteneur → .env local"
    echo "  Remote rclone  → premier remote disponible"
    echo ""
    echo "Variables d'environnement :"
    echo "  PROJET_DIR          Racine du projet (sinon auto-détecté)"
    echo "  BACKUP_NAME_PREFIX  Préfixe des archives"
    echo "  BACKUP_DIR          Dossier de sortie des archives"
    echo "  DB_TYPE             mysql (defaut) / pgsql / none"
    echo "  DB_USER / DB_PASSWORD / DB_HOST / DB_PORT / DB_NAME"
    echo "  DOCKER_MODE         auto (defaut) / true / false"
    echo "  DOCKER_APP_NAMES    Liste des noms de conteneur app"
    echo "  DOCKER_DB_NAMES     Liste des noms de conteneur DB"
    echo "  CONFIG_FILES        Liste des fichiers à archiver"
    echo "  RCLONE_REMOTE       Remote rclone (auto-détecté)"
    echo "  RCLONE_PATH         Dossier cible sur le remote"
    echo "  RCLONE_CLEANUP      true (defaut) supprime locale après upload"
    echo "  KEEP_DAYS           Rétention locale (defaut 30)"
    echo ""
    echo "Exemples :"
    echo "  # Laravel + Docker"
    echo "  ./backup-dev.sh"
    echo ""
    echo "  # Node.js + PostgreSQL direct"
    echo "  DB_TYPE=pgsql DB_PORT=5432 DOCKER_MODE=false ./backup-dev.sh"
    echo ""
    echo "  # WordPress"
    echo "  BACKUP_NAME_PREFIX=blog CONFIG_FILES=\"wp-config.php .htaccess\" ./backup-dev.sh"
    echo ""
    exit 0
fi

# ═════════════════════════════════════════════════════════════════
# MODE : --setup
# ═════════════════════════════════════════════════════════════════
if [ "$ARG" = "--setup" ]; then
    banner "Installation"

    # 1. Résumé de la détection
    echo "━━━ Détection ━━━"
    echo "  Projet :   ${PROJECT_DIR}  (${PROJECT_TYPE})"
    echo "  Conteneur app : ${APP_CONTAINER:-non trouvé}"
    echo "  Conteneur DB  : ${MYSQL_CONTAINER:-non trouvé}"
    echo ""

    # 2. Rclone
    if command -v rclone &>/dev/null; then
        REMOTES=$(rclone listremotes 2>/dev/null | tr -d ':')
        [ -n "$REMOTES" ] && ok "rclone : $(echo "$REMOTES" | tr '\n' ' ')" \
                         || warn "rclone installé mais aucun remote configuré (sudo apt install rclone && rclone config)"
    else
        warn "rclone non installé (sudo apt install rclone && rclone config)"
    fi

    # 3. Ancien cron
    CURRENT_CRON=$(crontab -l 2>/dev/null || true)
    OLD_CRON_PATTERN="${OLD_CRON_PATTERN:-backup-fermeos-app}"
    OLD_LINES=$(echo "$CURRENT_CRON" | grep "$OLD_CRON_PATTERN" || true)

    if [ -n "$OLD_LINES" ] && [ "$IS_TTY" = true ]; then
        echo ""
        echo "━━━ Ancienne config cron détectée ━━━"
        echo "$OLD_LINES" | while IFS= read -r line; do echo "   $line"; done
        if confirm "👉 Remplacer l'ancienne config ?" "y"; then
            NEW_CRON=$(echo "$CURRENT_CRON" | grep -v "$OLD_CRON_PATTERN" || true)
            echo "$NEW_CRON" | crontab -
            ok "Ancienne config supprimée"
        else
            info "Ancienne config conservée"
        fi
    fi

    # 4. Nouveau cron
    SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$SCRIPT_DIR/$(basename "$0")")
    CRON_SCHEDULE="${CRON_SCHEDULE:-30 2,18 * * *}"
    NEW_LINE="$CRON_SCHEDULE $SCRIPT_PATH >> $LOG_FILE 2>&1"
    CRON_HUMAN=$(cron_human "$CRON_SCHEDULE")

    if echo "$CURRENT_CRON" | grep -qF "$SCRIPT_PATH"; then
        info "Config cron déjà active ($(basename "$0"))"
    elif confirm "👉 Installer la config cron ($CRON_HUMAN) ?" "y"; then
        (echo "$CURRENT_CRON"; echo "$NEW_LINE") | crontab -
        ok "Config cron installée"
    fi

    echo ""
    ok "Setup terminé"
    echo "   Pour tester : $SCRIPT_PATH --dry-run"
    echo ""
    signature
    exit 0
fi

# ═════════════════════════════════════════════════════════════════
# MODE : --cron-check  (vérification + dry-run multi-projets)
# ═════════════════════════════════════════════════════════════════
if [ "$ARG" = "--cron-check" ]; then
    banner "Cron Check"

    # Vérification cron
    CURRENT_CRON=$(crontab -l 2>/dev/null || true)
    OLD_CRON_PATTERN="${OLD_CRON_PATTERN:-backup-fermeos-app}"
    SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$SCRIPT_DIR/$(basename "$0")")
    CRON_SCHEDULE="${CRON_SCHEDULE:-30 2,18 * * *}"
    NEW_LINE="$CRON_SCHEDULE $SCRIPT_PATH >> $LOG_FILE 2>&1"
    ANY_CHANGE=false

    # Ancien cron
    CRON_HUMAN=$(cron_human "$CRON_SCHEDULE")
    if echo "$CURRENT_CRON" | grep -q "$OLD_CRON_PATTERN"; then
        warn "Ancienne config cron détectée :"
        echo "$CURRENT_CRON" | grep "$OLD_CRON_PATTERN" | while IFS= read -r line; do echo "   $line"; done
        if [ "$IS_TTY" = true ] && confirm "👉 Remplacer l'ancienne config ?" "y"; then
            CURRENT_CRON=$(echo "$CURRENT_CRON" | grep -v "$OLD_CRON_PATTERN" || true)
            (echo "$CURRENT_CRON"; echo "$NEW_LINE") | crontab -
            ok "Config cron mise à jour"
            ANY_CHANGE=true
        else
            info "Config existante conservée"
        fi
    fi

    # Nouveau cron manquant
    if ! echo "$CURRENT_CRON" | grep -q "$(basename "$0")"; then
        if [ "$IS_TTY" = true ] && confirm "👉 Installer la config cron ($CRON_HUMAN) ?" "y"; then
            (echo "$CURRENT_CRON"; echo "$NEW_LINE") | crontab -
            ok "Config cron installée"
            ANY_CHANGE=true
        else
            info "Config non installée"
        fi
    fi

    # Résultat final
    CURRENT_CRON=$(crontab -l 2>/dev/null || true)
    SCR_NAME=$(basename "$0")
    if echo "$CURRENT_CRON" | grep -q "$OLD_CRON_PATTERN"; then
        warn "Ancienne config toujours présente"
    elif echo "$CURRENT_CRON" | grep -q "$SCR_NAME"; then
        ok "Config cron active ($CRON_HUMAN)"
    else
        warn "Aucune config cron active pour $SCR_NAME"
    fi

    # Découverte + dry-run de chaque projet
    discover_projects
    count=${#PROJECT_ROOTS[@]}

    if [ "$count" -eq 0 ]; then
        # Fallback: projet local
        if [ -d "${PROJECT_DIR:-}" ] && [ "${PROJECT_TYPE:-}" != "generic" ]; then
            echo "✔ 1 projet trouvé (local: ${PROJECT_DIR})"
            register_project "$PROJECT_DIR" "$PROJECT_TYPE" "$PROJECT_NAME" "local"
            count=1
        else
            echo "✘ Aucun projet trouvé"
            signature
            exit 1
        fi
    fi

    echo "✔ ${count} projet(s) trouvé(s)"
    ok_count=0
    for i in "${!PROJECT_ROOTS[@]}"; do
        root="${PROJECT_ROOTS[$i]}"
        type="${PROJECT_TYPES[$i]}"
        name="${PROJECT_NAMES[$i]}"
        echo "── ${name} (${root}) ──"
        env_vars="PROJECT_DIR='${root}' PROJECT_TYPE='${type}' BACKUP_NAME_PREFIX='${name}'"
        env_vars="${env_vars} RCLONE_PATH='${name}-backups' BACKUP_DIR='/tmp/devbak-cron-check'"
        env_vars="${env_vars} KEEP_DAYS='${KEEP_DAYS}' RCLONE_CLEANUP=true DRY_RUN=true"
        if eval "${env_vars} bash '${SCRIPT_PATH}' 2>&1"; then
            ok_count=$((ok_count + 1))
        fi
    done
    echo ""
    ok "Résumé : ${ok_count}/${count} dry-run OK"
    [ "$ANY_CHANGE" = true ] && info "Configuration cron modifiée — vérifie avec crontab -l"
    signature
    exit 0
fi

# ═════════════════════════════════════════════════════════════════
# MODE : --dry-run
# ═════════════════════════════════════════════════════════════════
[ "$ARG" = "--dry-run" ] && DRY_RUN=true

# ═════════════════════════════════════════════════════════════════
# MODE : --all  (backup multi-projets)
# ═════════════════════════════════════════════════════════════════
if [ "$ARG" = "--all" ]; then
    discover_projects
    count=${#PROJECT_ROOTS[@]}

    if [ "$count" -eq 0 ]; then
        echo "✘ Aucun projet trouvé"
        echo ""
        echo "  Astuces :"
        echo "  - Vérifie que tes conteneurs Docker sont en cours d'exécution"
        echo "  - Crée un fichier /etc/devbak.yaml avec :"
        echo "      projects:"
        echo "        - /chemin/vers/mon/projet"
        echo ""
        exit 1
    fi

    SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$SCRIPT_DIR/$(basename "$0")")
    ok_count=0; fail_count=0

    for i in "${!PROJECT_ROOTS[@]}"; do
        root="${PROJECT_ROOTS[$i]}"
        type="${PROJECT_TYPES[$i]}"
        name="${PROJECT_NAMES[$i]}"
        src="${PROJECT_SOURCES[$i]:-auto}"

        echo ""
        echo "━━━ [${i}/${count}] ${name} (${type}) — ${root} (${src}) ━━━"

        env_vars="PROJECT_DIR='${root}' PROJECT_TYPE='${type}' BACKUP_NAME_PREFIX='${name}'"
        env_vars="${env_vars} RCLONE_PATH='${name}-backups' RCLONE_REMOTE='${RCLONE_REMOTE}'"
        env_vars="${env_vars} BACKUP_DIR='${BACKUP_DIR}' KEEP_DAYS='${KEEP_DAYS}'"
        [ "$RCLONE_CLEANUP" = true ] && env_vars="${env_vars} RCLONE_CLEANUP=true" || env_vars="${env_vars} RCLONE_CLEANUP=false"
        [ "$DRY_RUN" = true ] && env_vars="${env_vars} DRY_RUN=true"

        if eval "${env_vars} bash '${SCRIPT_PATH}' 2>&1"; then
            ok_count=$((ok_count + 1))
        else
            fail_count=$((fail_count + 1))
        fi
    done

    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  RÉSULTATS                                                  ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    [ "$ok_count" -gt 0 ]    && echo "  ✔ ${ok_count} succès"
    [ "$fail_count" -gt 0 ]  && echo "  ✘ ${fail_count} échecs"
    [ "$fail_count" -eq 0 ]  && echo "  ✅ Tout OK"
    signature
    exit $fail_count
fi

banner "${PROJECT_NAME}"

title "Backup — ${PROJECT_NAME} (${PROJECT_TYPE})"
info "Projet   : ${PROJECT_DIR}"
info "DB       : ${DB_TYPE}"
info "MySQL    : ${MYSQL_CONTAINER:-direct}"
info "App      : ${APP_CONTAINER:-direct}"
info "Rclone   : ${RCLONE_REMOTE}:${RCLONE_PATH}"
[ "$DRY_RUN" = true ] && warn "Mode DRY-RUN : aucune action réelle"

# ─── Vérification cron (une fois par jour) ──────────────────────
if [ "$IS_TTY" = false ]; then
    CURRENT_CRON=$(crontab -l 2>/dev/null || true)
    OLD_CRON_PATTERN="${OLD_CRON_PATTERN:-backup-fermeos-app}"
    if echo "$CURRENT_CRON" | grep -q "$OLD_CRON_PATTERN"; then
        warn "Ancienne config détectée → lance --cron-check"
    fi
fi

# ─── DB Dump ────────────────────────────────────────────────────
title "Base de données"
if [ "$DB_TYPE" != "none" ] && [ -n "$MYSQL_CONTAINER" ]; then
    IFS='|' read -r DB_U DB_P DB_H DB_D <<< "$(detect_db_creds "$MYSQL_CONTAINER")"
    DB_U="${DB_U:-$DB_USER}"  DB_P="${DB_P:-$DB_PASSWORD}"
    DB_H="${DB_H:-$DB_HOST}"  DB_D="${DB_D:-$DB_NAME}"

    if [ "$DRY_RUN" = false ]; then
        if [ "$DB_TYPE" = "mysql" ]; then
            MYSQL_PWD="${DB_P}" docker exec "$MYSQL_CONTAINER" mysqldump \
                -u "$DB_U" --single-transaction --routines --triggers --events \
                "$DB_D" > "$WORK_DIR/db.sql" 2>/dev/null || {
                # Fallback via le conteneur app
                if [ -n "$APP_CONTAINER" ] && [ "$APP_CONTAINER" != "$MYSQL_CONTAINER" ]; then
                    MYSQL_PWD="${DB_P}" docker exec "$APP_CONTAINER" mysqldump \
                        -u "$DB_U" -h "$DB_H" --single-transaction \
                        "$DB_D" > "$WORK_DIR/db.sql" 2>/dev/null || true
                fi
            }
        elif [ "$DB_TYPE" = "pgsql" ]; then
            PGPASSWORD="${DB_P}" docker exec "$MYSQL_CONTAINER" pg_dump \
                -U "$DB_U" -h "$DB_H" -p "${DB_PORT:-5432}" \
                "$DB_D" > "$WORK_DIR/db.sql" 2>/dev/null || true
        fi
    fi

    [ -s "$WORK_DIR/db.sql" ] && ok "Dump : $(wc -c < "$WORK_DIR/db.sql") octets" \
                              || warn "Dump vide ou échoué"

elif [ "$DB_TYPE" != "none" ] && [ "$DOCKER_MODE" != "false" ]; then
    # Mode direct (sans Docker)
    IFS='|' read -r DB_U DB_P DB_H DB_D <<< "$(detect_db_creds "")"
    DB_U="${DB_U:-$DB_USER}"  DB_P="${DB_P:-$DB_PASSWORD}"
    DB_H="${DB_H:-$DB_HOST}"  DB_D="${DB_D:-$DB_NAME}"

    if [ "$DRY_RUN" = false ] && command -v "${DB_TYPE}dump" &>/dev/null; then
        if [ "$DB_TYPE" = "mysql" ]; then
            MYSQL_PWD="$DB_P" mysqldump -u "$DB_U" -h "$DB_H" -P "${DB_PORT:-3306}" \
                --single-transaction "$DB_D" > "$WORK_DIR/db.sql" 2>/dev/null || true
        elif [ "$DB_TYPE" = "pgsql" ]; then
            PGPASSWORD="$DB_P" pg_dump -U "$DB_U" -h "$DB_H" -p "${DB_PORT:-5432}" \
                "$DB_D" > "$WORK_DIR/db.sql" 2>/dev/null || true
        fi
    fi
    [ -s "$WORK_DIR/db.sql" ] && ok "Dump direct : $(wc -c < "$WORK_DIR/db.sql") octets" || warn "Dump direct vide ou échoué"
else
    info "DB_TYPE=none ou aucun conteneur, dump ignoré"
fi

# ─── Config serveur ─────────────────────────────────────────────
title "Configuration serveur"

FOUND_FILES=""
TARGET_DIR=""

for f in $CONFIG_FILES; do
    [ -f "$PROJECT_DIR/$f" ] && FOUND_FILES="$FOUND_FILES $f"
done
[ -n "$FOUND_FILES" ] && TARGET_DIR="$PROJECT_DIR" && info "Fichiers trouvés dans ${PROJECT_DIR}"

if [ -z "$FOUND_FILES" ] && [ -n "$APP_CONTAINER" ]; then
    info "Fallback : extraction depuis ${APP_CONTAINER}..."
    mkdir -p "$WORK_DIR/config-app"
    docker cp "$APP_CONTAINER:/var/www/" "$WORK_DIR/config-app/app" 2>/dev/null || true
    for f in $CONFIG_FILES; do
        [ -f "$WORK_DIR/config-app/app/$f" ] && FOUND_FILES="$FOUND_FILES $f"
    done
    [ -n "$FOUND_FILES" ] && TARGET_DIR="$WORK_DIR/config-app/app"
fi

if [ -n "$FOUND_FILES" ] && [ -n "$TARGET_DIR" ]; then
    if [ "$DRY_RUN" = false ]; then
        tar -czf "$WORK_DIR/config.tar.gz" -C "$TARGET_DIR" $FOUND_FILES 2>/dev/null || warn "Erreur création archive config"
    fi
    ok "Config :$FOUND_FILES"
else
    warn "Aucun fichier de config trouvé"
fi

# ─── Informations système ──────────────────────────────────────
title "Informations système"
if [ "$DRY_RUN" = false ]; then
    PHP_V="php -v"
    [ -n "$APP_CONTAINER" ] && PHP_V="docker exec $APP_CONTAINER php -v"
    {
        echo "=== ${PROJECT_NAME} Backup ==="
        echo "Date: $(date)"
        echo "Hostname: $(hostname 2>/dev/null || echo 'N/A')"
        echo "Host: $(uname -a 2>/dev/null || echo 'N/A')"
        echo "Projet: ${PROJECT_DIR} (${PROJECT_TYPE})"
        echo ""
        echo "=== PHP ==="
        eval "$PHP_V" 2>/dev/null || echo "PHP non disponible"
        echo ""
        echo "=== Composer / Npm ==="
        composer --version 2>/dev/null || echo "Composer non disponible"
        node -v 2>/dev/null || echo "Node non disponible"
        echo ""
        echo "=== Docker ==="
        docker --version 2>/dev/null || echo "Docker non disponible"
        docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' 2>/dev/null || true
        echo ""
        echo "=== Système ==="
        df -h / 2>/dev/null || true
        free -h 2>/dev/null || true
        uptime 2>/dev/null || true
    } > "$WORK_DIR/system-info.txt"
fi
ok "system-info.txt créé"

# ─── Assemblage ─────────────────────────────────────────────────
title "Assemblage"
if [ "$DRY_RUN" = false ]; then
    tar -czf "$BACKUP_DIR/${BASENAME}.tar.gz" -C "$WORK_DIR" . 2>/dev/null
fi

if [ -f "$BACKUP_DIR/${BASENAME}.tar.gz" ]; then
    S=$(stat -c%s "$BACKUP_DIR/${BASENAME}.tar.gz" 2>/dev/null || stat -f%z "$BACKUP_DIR/${BASENAME}.tar.gz" 2>/dev/null || echo "?")
    ok "Archive : ${BASENAME}.tar.gz (${S} octets)"
else
    warn "Archive non créée"
fi

# ─── Upload rclone ─────────────────────────────────────────────
title "Upload"
if command -v rclone &>/dev/null && [ -f "$BACKUP_DIR/${BASENAME}.tar.gz" ]; then
    info "rclone ${RCLONE_REMOTE}:${RCLONE_PATH}/"
    if [ "$DRY_RUN" = false ]; then
        if rclone copy "$BACKUP_DIR/${BASENAME}.tar.gz" "${RCLONE_REMOTE}:${RCLONE_PATH}/" 2>>"$LOG_FILE"; then
            ok "Upload réussi"
            # Nettoyage local
            [ "$RCLONE_CLEANUP" = true ] && rm -f "$BACKUP_DIR/${BASENAME}.tar.gz" && info "Archive locale supprimée"
        else
            fail "Échec upload (code $?)"
        fi
    fi
elif ! command -v rclone &>/dev/null; then
    warn "rclone non installé"
    info "Archive locale : $BACKUP_DIR/${BASENAME}.tar.gz"
else
    warn "Archive introuvable"
fi

# ─── Rotation ───────────────────────────────────────────────────
title "Rotation"
if [ "$KEEP_DAYS" -gt 0 ]; then
    info "Nettoyage des backups > ${KEEP_DAYS} jours..."
    if [ "$DRY_RUN" = false ]; then
        find "$BACKUP_DIR" -maxdepth 1 -name "${PROJECT_NAME}-backup-dev-*.tar.gz" -mtime "+${KEEP_DAYS}" -delete 2>/dev/null
    fi
fi

# Vieux logs
find "$BACKUP_DIR" -maxdepth 1 -name 'backup-dev.log.*' -mtime +90 -delete 2>/dev/null || true

echo ""
ok "Backup terminé — ${PROJECT_NAME}"
signature
