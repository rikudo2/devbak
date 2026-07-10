#!/bin/bash
set -euo pipefail

: "${LOG_FILE:=/tmp/devbak.log}"

# ═════════════════════════════════════════════════════════════════════
# backup-dev.sh  —  Backup universel (DB + config serveur → rclone)
#
# Dev: Mr-Robot (Fsociety / Fs4)
# ═════════════════════════════════════════════════════════════════════

# ─── 1. Couleurs & affichage ─────────────────────────────────────
_supports_color() {
    [ -n "${NO_COLOR:-}" ] && return 1
    [ -t 1 ] || return 1
    command -v tput &>/dev/null || return 1
    [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ] 2>/dev/null
}

if _supports_color; then
    C_RESET="$(tput sgr0)"; C_BOLD="$(tput bold)"
    C_RED="$(tput setaf 1)"; C_GREEN="$(tput setaf 2)"
    C_YELLOW="$(tput setaf 3)"; C_BLUE="$(tput setaf 4)"
    C_CYAN="$(tput setaf 6)"; C_GRAY="$(tput setaf 8 2>/dev/null || echo '')"
else
    C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""; C_GRAY=""
fi

# ─── 2. Détection du type de projet ─────────────────────────────
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

# ─── 3. Conteneurs Docker ────────────────────────────────────────
DOCKER_APP_NAMES="${DOCKER_APP_NAMES:-${DOCKER_APP_NAME:-ferme-app app laravel fermeos web node app-server}}"
DOCKER_DB_NAMES="${DOCKER_DB_NAMES:-${DOCKER_DB_NAME:-mysql db mariadb postgres pgsql postgresql}}"
DOCKER_MODE="${DOCKER_MODE:-auto}"

detect_container() {
    local names="$1" filter="$2"
    IFS=' ' read -ra list <<< "$names"
    for name in "${list[@]}"; do
        cid=$(docker ps --filter "name=$name" -q 2>/dev/null | head -1) || cid=""
        [ -n "$cid" ] && { echo "$cid"; return 0; }
    done
    if [ -n "$filter" ]; then
        cid=$(docker ps --format '{{.ID}} {{.Image}}' 2>/dev/null | grep -i "$filter" | head -1 | awk '{print $1}') || cid=""
        [ -n "$cid" ] && echo "$cid" && return 0
    fi
    echo ""; return 0
}

APP_CONTAINER="" MYSQL_CONTAINER=""
if [ "$DOCKER_MODE" != "false" ] && command -v docker &>/dev/null && docker info &>/dev/null; then
    APP_CONTAINER=$(detect_container "$DOCKER_APP_NAMES" "")
    MYSQL_CONTAINER=$(detect_container "$DOCKER_DB_NAMES" "mysql\|mariadb\|postgres")
    [ -z "$MYSQL_CONTAINER" ] && MYSQL_CONTAINER="$APP_CONTAINER"
fi

# ─── 4. DB ───────────────────────────────────────────────────────
DB_TYPE="${DB_TYPE:-mysql}"
DB_USER="${DB_USER:-root}"
DB_PASSWORD="${DB_PASSWORD:-}"
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-3306}"
DB_NAME="${DB_NAME:-}"

detect_db_creds() {
    local c="$1" u="" p="" h="" d=""
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
    echo "${u:-${DB_USER}}|${p:-${DB_PASSWORD}}|${h:-${DB_HOST}}|${d:-${DB_NAME}}"
}

# ─── 5. Fichiers config à archiver ──────────────────────────────
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

# ─── 6. Rclone ──────────────────────────────────────────────────
detect_rclone_remote() {
    command -v rclone &>/dev/null || { echo "remote"; return 0; }
    for name in "${RCLONE_REMOTE:-fondateur fermeos backups gdrive}" "remote" "drive" "s3"; do
        rclone listremotes 2>/dev/null | grep -q "^${name}:" && { echo "$name"; return 0; }
    done
    first=$(rclone listremotes 2>/dev/null | head -1 | tr -d ':')
    echo "${first:-remote}"
}

# ─── 7. Découverte multi-projets ─────────────────────────────────
declare -a PROJECT_ROOTS=() PROJECT_TYPES=() PROJECT_NAMES=() PROJECT_SOURCES=()

register_project() {
    local root="$1" type="$2" name="$3" source="${4:-auto}"
    case "$root" in /usr/local/*|/bin/*|/usr/bin/*|/etc/*|/sys/*|/proc/*|/dev/*) return 0 ;; esac
    for existing in "${PROJECT_ROOTS[@]}"; do [ "$existing" = "$root" ] && return 0; done
    PROJECT_ROOTS+=("$root"); PROJECT_TYPES+=("$type"); PROJECT_NAMES+=("$name"); PROJECT_SOURCES+=("$source")
}

scan_docker_projects() {
    command -v docker &>/dev/null && docker info &>/dev/null || return 0
    local cid mounts containers
    containers=$(docker ps -q 2>/dev/null) || true
    for cid in $containers; do
        mounts=$(docker inspect --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' "$cid" 2>/dev/null || true)
        [ -z "$mounts" ] && continue
        while IFS= read -r mount; do
            [ -z "$mount" ] && continue
            for marker in "artisan" "composer.json" "package.json" "index.php" "wp-config.php" "Gemfile" "Cargo.toml" "mix.exs"; do
                if [ -f "$mount/$marker" ]; then
                    local ptype
                    ptype=$(detect_project_type "$mount")
                    register_project "$mount" "$ptype" "$(basename "$mount" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')" "docker"
                    break
                fi
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
                [ -n "$found" ] && {
                    local d
                    d=$(dirname "$found")
                    register_project "$d" "$(detect_project_type "$d")" "$(basename "$d" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')" "global"
                }
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
            [ -n "$path" ] && [ -d "$path" ] && register_project "$path" "$(detect_project_type "$path")" "$(basename "$path" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')" "yaml"
        done < "$yaml_path"
    done
}

save_project_yaml() {
    local path="$1"
    local yaml="/etc/devbak.yaml"
    if [ -f "$yaml" ] && grep -qF -- "$path" "$yaml" 2>/dev/null; then
        return 0
    fi
    echo "projects:" | sudo tee "$yaml" >/dev/null 2>&1 || return 1
    echo "  - $path" | sudo tee -a "$yaml" >/dev/null 2>&1 || return 1
}

ask_project() {
    echo "${C_CYAN}━━━ Aucun projet détecté automatiquement ━━━${C_RESET}"
    echo ""
    local containers=""
    if command -v docker &>/dev/null; then
        containers=$(docker ps --format '{{.Names}}' 2>/dev/null || true)
    fi
    if [ -n "$containers" ]; then
        echo "  Conteneurs détectés :"
        echo "$containers" | while IFS= read -r name; do echo "    • $name"; done
        echo ""
    fi
    echo "  Type d'installation :"
    echo "    1) Docker    — l'application tourne dans un conteneur"
    echo "    2) Baremetal — installation directe sur le système"
    echo "    3) Autre     — chemin personnalisé"
    echo ""
    if [ "$IS_TTY" = true ]; then
        printf "  Choix [1/2/3] (défaut: 1) : "
        read -r mode </dev/tty
    else
        printf "  Choix [1/2/3] (défaut: 1) : "
        read -r -t 5 mode </dev/tty 2>/dev/null || mode=1
    fi
    mode="${mode:-1}"
    local suggestions=()
    case "$mode" in
        2|3)
            for d in /var/www /home /opt /srv /data; do
                [ -d "$d" ] && while IFS= read -r -d '' found; do
                    [ -n "$found" ] && suggestions+=("$found")
                done < <(find "$d" -maxdepth 3 \( -name "artisan" -o -name "composer.json" -o -name "package.json" -o -name "index.php" \) -type f 2>/dev/null | head -10 | tr '\n' '\0')
            done
            ;;
    esac
    if [ ${#suggestions[@]} -gt 0 ]; then
        echo ""
        echo "  Projets trouvés sur le disque :"
        local i=1
        for sug in "${suggestions[@]}"; do
            local dir
            dir=$(dirname "$sug")
            echo "    $i) $dir"
            i=$((i + 1))
        done
        echo ""
        printf "  Choisis un numéro, ou laisse vide pour saisir manuellement : "
        read -r choice </dev/tty
        if [ -n "$choice" ] && [ "$choice" -ge 1 ] 2>/dev/null && [ "$choice" -le ${#suggestions[@]} ] 2>/dev/null; then
            PROJECT_DIR=$(dirname "${suggestions[$((choice - 1))]}")
        fi
    fi
    if [ -z "${PROJECT_DIR:-}" ]; then
        echo ""
        printf "  Chemin du projet (ex: /home/mr-robot/mon-app) : "
        read -r custom_path </dev/tty
        PROJECT_DIR="${custom_path}"
    fi
    if [ -z "${PROJECT_DIR:-}" ] || [ ! -d "$PROJECT_DIR" ]; then
        echo "${C_RED}❌ Chemin invalide : $PROJECT_DIR${C_RESET}"
        exit 1
    fi
    PROJECT_TYPE="$(detect_project_type "$PROJECT_DIR")"
    echo ""
    echo "  Projet : $PROJECT_DIR ($PROJECT_TYPE)"
    if save_project_yaml "$PROJECT_DIR"; then
        ok "Chemin sauvegardé dans /etc/devbak.yaml"
        echo ""
        ok "Prochain run : la détection sera automatique"
    else
        warn "Impossible d'écrire /etc/devbak.yaml (sudo ?)"
    fi
    register_project "$PROJECT_DIR" "manual" "$(basename "$PROJECT_DIR" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')" "manual"
}

discover_projects() {
    local allow_interactive="${1:-0}"
    set +e
    scan_docker_projects
    [ ${#PROJECT_ROOTS[@]} -eq 0 ] && scan_global_projects
    load_yaml_projects
    if [ ${#PROJECT_ROOTS[@]} -eq 0 ] && [ "$allow_interactive" = "1" ] && [ "$IS_TTY" = true ]; then
        ask_project
    fi
    set -e
}

# ─── 8. Variables finales ───────────────────────────────────────
resolve_backup_dir() {
    local candidates=(
        "${BACKUP_DIR:-}"
        "${PROJECT_DIR:+${PROJECT_DIR}/storage/app/backups}"
        "${PROJECT_DIR:+${PROJECT_DIR}/backups}"
        "/tmp/backups"
    )
    local c
    for c in "${candidates[@]}"; do
        [ -z "$c" ] && continue
        if [ -d "$c" ] && [ -w "$c" ]; then echo "$c"; return 0; fi
        if mkdir -p "$c" 2>/dev/null; then echo "$c"; return 0; fi
    done
    echo "/tmp/backups"
}

BACKUP_DIR="$(resolve_backup_dir)"
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
if [ -t 2 ] 2>/dev/null; then
    IS_TTY=true
fi
if [ -e /dev/tty ] 2>/dev/null && command -v tty >/dev/null 2>&1 && tty -s 2>/dev/null; then
    IS_TTY=true
fi
ARG="${1:-}"

# ─── 9. Fonctions utilitaires ───────────────────────────────────
log()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE" 2>/dev/null || true; }
info()  { log "${C_BLUE}ℹ️  $*${C_RESET}"; }
ok()     { log "${C_GREEN}✅ $*${C_RESET}"; }
warn()   { log "${C_YELLOW}⚠️  $*${C_RESET}"; }
fail()   { log "${C_RED}❌ $*${C_RESET}"; }
title()  { log "${C_BOLD}━━━ $* ━━━${C_RESET}"; }
step()   { log "${C_CYAN}▶ Étape $1/$2 — $3${C_RESET}"; }

cleanup() {
    local ec=$?
    [ -n "${WORK_DIR:-}" ] && rm -rf "$WORK_DIR" 2>/dev/null
    [ "$ec" -ne 0 ] && [ "$ec" -ne 130 ] && [ "$ec" -ne 143 ] && fail "Backup interrompu (code $ec)"
}
trap cleanup EXIT

confirm() {
    local prompt="$1" default="${2:-n}" ans
    [ "$IS_TTY" = false ] && return 1
    printf "%s %s[%s/%s]%s " "$prompt" "$C_BOLD" "$( [ "$default" = "y" ] && echo 'Y' || echo 'y' )" "$( [ "$default" = "n" ] && echo 'N' || echo 'n' )" "$C_RESET"
    read -r ans </dev/tty
    ans="${ans:-$default}"
    case "$ans" in [YyOo1]*) return 0 ;; *) return 1 ;; esac
}

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
    echo "${C_GRAY}╔═══════════════════════════════════════════╗"
    echo "║   Fs4 Backup System                       ║"
    echo "║   Mr-Robot                                ║"
    echo "╚═══════════════════════════════════════════╝${C_RESET}"
    echo ""
}

banner() {
    local title="${1:-Backup universel}" prefix="Fs4 :: "
    local text="${prefix}${title}"
    local width=$(( ${#text} + 4 ))
    [ "$width" -lt 62 ] && width=62
    local line
    line=$(printf '═%.0s' $(seq 1 "$width"))
    echo ""
    echo "${C_BOLD}${C_CYAN}╔${line}╗"
    printf "║  %-*s║\n" "$((width - 2))" "$text"
    echo "╚${line}╝${C_RESET}"
    echo ""
}

print_project_table() {
    local i
    printf "  %-3s %-22s %-10s %-8s %s\n" "#" "NOM" "TYPE" "SOURCE" "CHEMIN"
    printf "  %-3s %-22s %-10s %-8s %s\n" "---" "----------------------" "----------" "--------" "----------------------------------"
    for i in "${!PROJECT_ROOTS[@]}"; do
        printf "  %-3s %-22s %-10s %-8s %s\n" "$((i+1))" "${PROJECT_NAMES[$i]}" "${PROJECT_TYPES[$i]}" "${PROJECT_SOURCES[$i]:-auto}" "${PROJECT_ROOTS[$i]}"
    done
}

mkdir -p "$BACKUP_DIR"

# ═════════════════════════════════════════════════════════════════
# MODES & EXÉCUTIONS
# ═════════════════════════════════════════════════════════════════
run_help() {
    banner "Aide"
    echo "Usage :"
    echo "  ./backup-dev.sh                Menu interactif (TTY) ou run normal"
    echo "  ./backup-dev.sh --all          Backup de tous les projets découverts"
    echo "  ./backup-dev.sh --dry-run      Simulation"
    echo "  ./backup-dev.sh --setup        Config cron + rclone (interactif)"
    echo "  ./backup-dev.sh --cron-check   Vérifie les crons + dry-run de tous les projets"
    echo "  ./backup-dev.sh --list         Liste les projets détectés (sans backup)"
    echo "  ./backup-dev.sh --verify [f]   Vérifie l'intégrité d'une archive (défaut: la + récente)"
    echo "  ./backup-dev.sh --restore <f>  Extrait une archive dans un dossier d'inspection"
    echo ""
}

run_setup() {
    banner "Installation"
    echo "━━━ Détection ━━━"
    echo "  Projet :   ${PROJECT_DIR}  (${PROJECT_TYPE})"
    echo "  Conteneur app : ${APP_CONTAINER:-non trouvé}"
    echo "  Conteneur DB  : ${MYSQL_CONTAINER:-non trouvé}"
    echo ""
    if command -v rclone &>/dev/null; then
        REMOTES=$(rclone listremotes 2>/dev/null | tr -d ':')
        [ -n "$REMOTES" ] && ok "rclone : $(echo "$REMOTES" | tr '\n' ' ')" \
                           || warn "rclone installé mais aucun remote configuré (rclone config)"
    else
        warn "rclone non installé (sudo apt install rclone)"
    fi
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
    echo "    Pour tester : $SCRIPT_PATH --dry-run"
    echo ""
    signature
}

run_cron_check() {
    banner "Cron Check"
    CURRENT_CRON=$(crontab -l 2>/dev/null || true)
    OLD_CRON_PATTERN="${OLD_CRON_PATTERN:-backup-fermeos-app}"
    SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$SCRIPT_DIR/$(basename "$0")")
    CRON_SCHEDULE="${CRON_SCHEDULE:-30 2,18 * * *}"
    NEW_LINE="$CRON_SCHEDULE $SCRIPT_PATH >> $LOG_FILE 2>&1"
    ANY_CHANGE=false
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
    if ! echo "$CURRENT_CRON" | grep -q "$(basename "$0")"; then
        if [ "$IS_TTY" = true ] && confirm "👉 Installer la config cron ($CRON_HUMAN) ?" "y"; then
            (echo "$CURRENT_CRON"; echo "$NEW_LINE") | crontab -
            ok "Config cron installée"
            ANY_CHANGE=true
        else
            info "Config non installée"
        fi
    fi
    CURRENT_CRON=$(crontab -l 2>/dev/null || true)
    SCR_NAME=$(basename "$0")
    if echo "$CURRENT_CRON" | grep -q "$OLD_CRON_PATTERN"; then
        warn "Ancienne config toujours présente"
    elif echo "$CURRENT_CRON" | grep -q "$SCR_NAME"; then
        ok "Config cron active ($CRON_HUMAN)"
    else
        warn "Aucune config cron active pour $SCR_NAME"
    fi
    discover_projects 0
    count=${#PROJECT_ROOTS[@]}
    if [ "$count" -eq 0 ]; then
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
    print_project_table
    echo ""
    ok_count=0
    for i in "${!PROJECT_ROOTS[@]}"; do
        root="${PROJECT_ROOTS[$i]}"
        type="${PROJECT_TYPES[$i]}"
        name="${PROJECT_NAMES[$i]}"
        echo "── ${name} (${root}) ──"
        env_vars="PROJECT_DIR='${root}' PROJECT_TYPE='${type}' BACKUP_NAME_PREFIX='${name}'"
        env_vars="${env_vars} RCLONE_PATH='${name}-backups' BACKUP_DIR='/tmp/devbak-cron-check'"
        env_vars="${env_vars} KEEP_DAYS='${KEEP_DAYS}' RCLONE_CLEANUP=true DRY_RUN=true NON_INTERACTIVE=true"
        if eval "${env_vars} bash '${SCRIPT_PATH}' 2>&1"; then
            ok_count=$((ok_count + 1))
        fi
    done
    echo ""
    ok "Résumé : ${ok_count}/${count} dry-run OK"
    [ "$ANY_CHANGE" = true ] && info "Configuration cron modifiée — vérifie avec crontab -l"
    signature
}

run_list() {
    banner "Projets détectés"
    discover_projects 0
    if [ ${#PROJECT_ROOTS[@]} -eq 0 ]; then
        warn "Aucun projet découvert automatiquement."
        [ -n "${PROJECT_DIR:-}" ] && info "Projet courant : ${PROJECT_DIR} (${PROJECT_TYPE})"
        signature
        return 0
    fi
    print_project_table
    echo ""
    ok "${#PROJECT_ROOTS[@]} projet(s) trouvé(s)"
    signature
}

run_verify() {
    local target="${1:-}"
    banner "Vérification d'archive"
    if [ -z "$target" ]; then
        target=$(find "$BACKUP_DIR" -maxdepth 1 -name '*-backup-dev-*.tar.gz' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
        [ -z "$target" ] && { fail "Aucune archive trouvée dans ${BACKUP_DIR}"; signature; exit 1; }
        info "Aucun fichier précisé → dernière archive : $(basename "$target")"
    fi
    if [ ! -f "$target" ]; then
        fail "Fichier introuvable : $target"
        signature
        exit 1
    fi
    info "Fichier   : $target"
    if tar -tzf "$target" &>/dev/null; then
        ok "Archive valide (tar.gz lisible)"
        echo ""
        echo "  Contenu :"
        tar -tzf "$target" | sed 's/^/    /'
    else
        fail "Archive corrompue ou format invalide"
        signature
        exit 1
    fi
    signature
}

run_restore() {
    local target="${1:-}"
    banner "Restauration (inspection)"
    if [ -z "$target" ] || [ ! -f "$target" ]; then
        fail "Utilisation : --restore /chemin/vers/archive.tar.gz"
        signature
        exit 1
    fi
    if ! tar -tzf "$target" &>/dev/null; then
        fail "Archive invalide, restauration annulée : $target"
        signature
        exit 1
    fi
    local dest="${RESTORE_DIR:-${BACKUP_DIR}/restore-$(date +%Y%m%d_%H%M%S)}"
    info "Archive   : $target"
    info "Extraction vers : $dest"
    echo ""
    warn "Ceci extrait uniquement l'archive dans un dossier séparé pour inspection."
    if [ "$IS_TTY" = true ] && ! confirm "👉 Continuer l'extraction ?" "y"; then
        info "Annulé."
        signature
        return 0
    fi
    mkdir -p "$dest"
    tar -xzf "$target" -C "$dest"
    ok "Extraction terminée : $dest"
    [ -f "$dest/db.sql" ] && info "Dump SQL présent : $dest/db.sql"
    [ -f "$dest/config.tar.gz" ] && info "Config présente  : $dest/config.tar.gz"
    [ -f "$dest/system-info.txt" ] && info "Infos système    : $dest/system-info.txt"
    signature
}

run_single() {
    banner "${PROJECT_NAME}"
    title "Backup — ${PROJECT_NAME} (${PROJECT_TYPE})"
    info "Projet   : ${PROJECT_DIR}"
    info "DB       : ${DB_TYPE}"
    info "MySQL    : ${MYSQL_CONTAINER:-direct}"
    info "App      : ${APP_CONTAINER:-direct}"
    info "Rclone   : ${RCLONE_REMOTE}:${RCLONE_PATH}"
    [ "$DRY_RUN" = true ] && warn "Mode DRY-RUN : aucune action réelle"

    if [ "$IS_TTY" = false ] && echo "$(crontab -l 2>/dev/null || true)" | grep -q "${OLD_CRON_PATTERN:-backup-fermeos-app}"; then
         warn "Ancienne config détectée → lance --cron-check"
    fi

    step 1 4 "Base de données"
    if [ "$DB_TYPE" != "none" ] && [ -n "$MYSQL_CONTAINER" ]; then
        IFS='|' read -r DB_U DB_P DB_H DB_D <<< "$(detect_db_creds "$MYSQL_CONTAINER")"
        DB_U="${DB_U:-$DB_USER}"  DB_P="${DB_P:-$DB_PASSWORD}"
        DB_H="${DB_H:-$DB_HOST}"  DB_D="${DB_D:-$DB_NAME}"
        if [ "$DRY_RUN" = false ]; then
            if [ "$DB_TYPE" = "mysql" ]; then
                MYSQL_PWD="${DB_P}" docker exec "$MYSQL_CONTAINER" mysqldump \
                    -u "$DB_U" --single-transaction --routines --triggers --events \
                    "$DB_D" > "$WORK_DIR/db.sql" 2>/dev/null || {
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

    step 2 4 "Configuration serveur"
    FOUND_FILES=""
    TARGET_DIR=""
    for f in $CONFIG_FILES; do
        [ -f "$PROJECT_DIR/$f" ] && FOUND_FILES="$FOUND_FILES $f"
    done
    [ -n "$FOUND_FILES" ] && TARGET_DIR="$PROJECT_DIR" && info "Fichiers trouvés dans ${PROJECT_DIR}"
    
    if [ -z "$FOUND_FILES" ] && [ -n "$APP_CONTAINER" ]; then
        info "Fallback : extraction sécurisée depuis le conteneur ${APP_CONTAINER}..."
        mkdir -p "$WORK_DIR/config-app"
        for f in $CONFIG_FILES; do
            if docker exec "$APP_CONTAINER" [ -f "$f" ] 2>/dev/null; then
                docker cp "$APP_CONTAINER:$f" "$WORK_DIR/config-app/$f" 2>/dev/null && FOUND_FILES="$FOUND_FILES $f"
            fi
        done
        [ -n "$FOUND_FILES" ] && TARGET_DIR="$WORK_DIR/config-app"
    fi

    if [ -n "$FOUND_FILES" ] && [ "$DRY_RUN" = false ]; then
        tar -czf "$WORK_DIR/config.tar.gz" -C "$TARGET_DIR" $FOUND_FILES 2>/dev/null || true
        ok "Configuration archivée : $(echo $FOUND_FILES | wc -w) fichier(s)"
    else
        warn "Aucun fichier de configuration trouvé ou mode dry-run"
    fi

    step 3 4 "Archive finale"
    if [ "$DRY_RUN" = false ]; then
        {
            echo "Backup Name: $PROJECT_NAME"
            echo "Timestamp  : $TIMESTAMP"
            echo "Type       : $PROJECT_TYPE"
            echo "Host       : $(hostname)"
            echo "Docker App : ${APP_CONTAINER:-none}"
            echo "Docker DB  : ${MYSQL_CONTAINER:-none}"
        } > "$WORK_DIR/system-info.txt"

        tar -czf "$BACKUP_DIR/${BASENAME}.tar.gz" -C "$WORK_DIR" .
        ok "Archive créée : $BACKUP_DIR/${BASENAME}.tar.gz ($(du -sh "$BACKUP_DIR/${BASENAME}.tar.gz" 2>/dev/null | awk '{print $1}' || echo 'OK'))"
    else
        info "Archive virtuelle créée (dry-run)"
    fi

    step 4 4 "Upload cloud & Rétention"
    if command -v rclone &>/dev/null && [ -n "$RCLONE_REMOTE" ]; then
        if [ "$DRY_RUN" = false ]; then
            info "Synchronisation vers rclone (${RCLONE_REMOTE}:${RCLONE_PATH})..."
            if rclone copy "$BACKUP_DIR/${BASENAME}.tar.gz" "${RCLONE_REMOTE}:${RCLONE_PATH}" 2>/dev/null; then
                ok "Upload cloud réussi"
                [ "$RCLONE_CLEANUP" = "true" ] && rm -f "$BACKUP_DIR/${BASENAME}.tar.gz" && info "Archive locale nettoyée après envoi"
            else
                warn "Échec de l'upload via rclone"
            fi
        else
            info "Upload cloud simulé (dry-run)"
        fi
    else
        warn "rclone non configuré ou introuvable, upload sauté"
    fi

    if [ "$DRY_RUN" = false ] && [ -d "$BACKUP_DIR" ]; then
        find "$BACKUP_DIR" -maxdepth 1 -name "${PROJECT_NAME}-backup-dev-*.tar.gz" -mtime +"$KEEP_DAYS" -exec rm -f {} \; 2>/dev/null || true
    fi
    
    ok "Opération terminée avec succès"
    signature
}

# ─── 10. Point d'entrée principal ────────────────────────────────
case "$ARG" in
    --help|-h)       run_help ;;
    --setup)         run_setup ;;
    --cron-check)    run_cron_check ;;
    --list)          run_list ;;
    --verify)        run_verify "${2:-}" ;;
    --restore)       run_restore "${2:-}" ;;
    --dry-run)
        DRY_RUN=true
        discover_projects 1
        run_single
        ;;
    --all)
        discover_projects 0
        if [ ${#PROJECT_ROOTS[@]} -eq 0 ]; then
            fail "Aucun projet détecté pour le mode --all"
            exit 1
        fi
        SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$SCRIPT_DIR/$(basename "$0")")
        for i in "${!PROJECT_ROOTS[@]}"; do
            PROJECT_DIR="${PROJECT_ROOTS[$i]}" \
            PROJECT_TYPE="${PROJECT_TYPES[$i]}" \
            PROJECT_NAME="${PROJECT_NAMES[$i]}" \
            RCLONE_PATH="${PROJECT_NAMES[$i]}-backups" \
            bash "$SCRIPT_PATH" ""
        done
        ;;
    *)
        if [ -z "${PROJECT_DIR:-}" ]; then
            discover_projects 1
        fi
        run_single
        ;;
esac