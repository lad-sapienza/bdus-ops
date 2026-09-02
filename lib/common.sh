# lib/common.sh — sourced by every libexec/bdus-* script. Not executable.
# Requires bash 4+ (Debian default). Loads config.env, defines helpers.

set -euo pipefail

: "${BDUS_OPS_DIR:?source via bin/bdus}"

# ── output ──────────────────────────────────────────────────────────────────
if [ -t 2 ]; then
  _r=$'\e[31m'; _g=$'\e[32m'; _y=$'\e[33m'; _c=$'\e[36m'; _d=$'\e[2m'; _z=$'\e[0m'
else
  _r=; _g=; _y=; _c=; _d=; _z=
fi
say()  { printf '%s\n'      "$*" >&2; }
info() { printf '%s%s%s\n'  "$_c" "$*" "$_z" >&2; }
ok()   { printf '%s✓%s %s\n' "$_g" "$_z" "$*" >&2; }
warn() { printf '%s!%s %s\n' "$_y" "$_z" "$*" >&2; }
bad()  { printf '%s✗%s %s\n' "$_r" "$_z" "$*" >&2; }
die()  { printf '%sERROR%s %s\n' "$_r" "$_z" "$*" >&2; exit 1; }

confirm() {   # confirm "question?"  → 0 on y/Y
  local a
  printf '%s [y/N] ' "$1" >&2
  read -r a </dev/tty 2>/dev/null || read -r a || true
  [[ "$a" == [yY] ]]
}

need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

# ── config ──────────────────────────────────────────────────────────────────
CONFIG_FILE="${BDUS_OPS_CONFIG:-$BDUS_OPS_DIR/config.env}"
[ -f "$CONFIG_FILE" ] || die "no config — run: cp $BDUS_OPS_DIR/config.env.example $CONFIG_FILE && \$EDITOR $CONFIG_FILE"
# shellcheck disable=SC1090
. "$CONFIG_FILE"

: "${BDUS_ROOT:?config.env: BDUS_ROOT}"
: "${INSTANCES:?config.env: INSTANCES}"
: "${API_IMAGE:=ghcr.io/lad-sapienza/bdus-api}"
: "${APP_IMAGE:=ghcr.io/lad-sapienza/bdus-app}"
: "${GHCR_YAML_REF:=v5}"
: "${BDUS_VERSION:=latest}"
: "${HEALTH_PATH:=/api/new-app/status}"
: "${STALE_BACKUP_DAYS:=2}"
: "${BACKUP_RETENTION:=14}"
: "${BACKUP_RSYNC_TARGET:=}"
: "${PROXY_ALLOW_IPS:=}"

need docker
docker compose version >/dev/null 2>&1 || die "'docker compose' (v2) not available"

# ── instances ───────────────────────────────────────────────────────────────
instance_dir() { printf '%s/%s' "$BDUS_ROOT" "$1"; }

instance_known() {
  local i
  for i in $INSTANCES; do [ "$i" = "$1" ] && return 0; done
  return 1
}

# "prod" | "demo" | "all" | "" → prints one instance name per line
resolve_instances() {
  case "${1:-all}" in
    all) printf '%s\n' $INSTANCES ;;
    *)   instance_known "$1" || die "unknown instance '$1' (config INSTANCES=\"$INSTANCES\")"
         printf '%s\n' "$1" ;;
  esac
}

# per-instance config value, e.g.  cfg_instance prod PORT
cfg_instance() {
  local var="INSTANCE_${1}_${2}"
  printf '%s' "${!var:-}"
}

# read a KEY= line from an instance's .env
env_get() {   # env_get <instance> KEY
  local f; f="$(instance_dir "$1")/.env"
  [ -f "$f" ] || return 1
  awk -F= -v k="$2" '$1==k { sub(/^[^=]*=/, ""); print; exit }' "$f"
}

# docker compose, run in the instance directory (.env drives COMPOSE_FILE/PROJECT)
dc() {   # dc <instance> <compose args...>
  local i="$1"; shift
  local d; d="$(instance_dir "$i")"
  [ -f "$d/.env" ] || die "$d/.env not found — run: bdus init $i"
  ( cd "$d" && docker compose "$@" )
}

instance_has_pg() {   # 0 if this instance runs Postgres
  # config.env is authoritative; fall back to compose introspection (capture,
  # never pipe into grep -q under pipefail).
  local flag; flag="$(cfg_instance "$1" POSTGRES)"
  [ "$flag" = 1 ] && return 0
  [ "$flag" = 0 ] && return 1
  local svcs=""
  svcs="$( ( cd "$(instance_dir "$1")" 2>/dev/null && docker compose config --services ) 2>/dev/null )" || true
  printf '%s\n' "$svcs" | grep -qx postgres
}

instance_project() { env_get "$1" COMPOSE_PROJECT_NAME; }
instance_version() { env_get "$1" BDUS_VERSION; }
backup_dir()       { printf '%s/backups' "$(instance_dir "$1")"; }

# ── health ──────────────────────────────────────────────────────────────────
instance_health() {   # 0 if the published endpoint answers 2xx
  local hp; hp="$(env_get "$1" BDUS_PORT || true)"
  [ -n "$hp" ] || return 2
  curl -fsS --max-time 5 -o /dev/null "http://${hp}${HEALTH_PATH}"
}

wait_health() {   # wait_health <instance> [seconds]
  local i="$1" t="${2:-60}" n=0
  while [ "$n" -lt "$t" ]; do
    instance_health "$i" && return 0
    sleep 3; n=$((n + 3))
  done
  return 1
}

# ── images ──────────────────────────────────────────────────────────────────
image_tag_exists() {   # image_tag_exists <image> <tag>
  docker manifest inspect "$1:$2" >/dev/null 2>&1
}

valid_semver() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
