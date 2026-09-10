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
: "${BACKUP_KEEP:=--keep-last 3 --keep-daily 7 --keep-weekly 8 --keep-monthly 12}"
: "${BACKUP_PRUNE:=weekly}"
: "${BACKUP_VERIFY_DAYS:=7}"
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

instance_has_martin() {   # 0 if this instance runs Martin (vector tiles)
  local flag; flag="$(cfg_instance "$1" MARTIN)"
  [ "$flag" = 1 ] && return 0
  [ "$flag" = 0 ] && return 1
  local svcs=""
  svcs="$( ( cd "$(instance_dir "$1")" 2>/dev/null && docker compose config --services ) 2>/dev/null )" || true
  printf '%s\n' "$svcs" | grep -qx martin
}

instance_project() { env_get "$1" COMPOSE_PROJECT_NAME; }
instance_version() { env_get "$1" BDUS_VERSION; }
backup_dir()       { printf '%s/backups' "$(instance_dir "$1")"; }
gis_data_dir()     { printf '%s/gis-data' "$(instance_dir "$1")"; }

# ── backups: restic engine ──────────────────────────────────────────────────
backup_repo()      { printf '%s/repo'          "$(backup_dir "$1")"; }
backup_repo_key()  { printf '%s/repo.key'      "$(backup_dir "$1")"; }
backup_lastok()    { printf '%s/.last-ok'      "$(backup_dir "$1")"; }
backup_verified()  { printf '%s/.last-verified' "$(backup_dir "$1")"; }
backup_repo_ready() { [ -f "$(backup_repo "$1")/config" ]; }   # 0 if `restic init` was run

# restic bound to instance $1's repo; remaining args pass straight through.
rst() {
  local i="$1"; shift
  need restic
  RESTIC_REPOSITORY="$(backup_repo "$i")" \
  RESTIC_PASSWORD_FILE="$(backup_repo_key "$i")" \
  restic "$@"
}

restic_ok_version() {   # 0 if restic ≥ 0.17 (needs --stdin-from-command)
  local v maj min rest
  v="$(restic version 2>/dev/null | awk '{print $2; exit}')" || return 1
  IFS=. read -r maj min rest <<<"${v:-0.0}"
  [ "${maj:-0}" -gt 0 ] || { [ "${maj:-0}" -eq 0 ] && [ "${min:-0}" -ge 17 ]; }
}

# hold the per-instance backup lock on FD 9. mode: try | wait:<secs>
# Call it PLAINLY (not in $(...) or a pipeline), so FD 9 stays open in the caller.
backup_lock() {
  local i="$1" mode="${2:-try}" f
  f="$(backup_dir "$1")/.lock"
  mkdir -p "$(backup_dir "$1")"
  exec 9>"$f"
  case "$mode" in
    try)    flock -n 9 ;;
    wait:*) flock -w "${mode#wait:}" 9 ;;
    *)      die "backup_lock: bad mode '$mode'" ;;
  esac
}

# resolve a snapshot short-id for <instance> <kind> <when>, or print nothing.
#   when = "latest" | "<run tag e.g. 20260910T021503>" | "<short-id of any snapshot in that run>"
# Every snapshot of one `bdus backup` carries a shared run:<ts> tag; this maps
# whatever the operator passed to --at onto that run, then picks the kind asked for.
snap_at() {
  local i="$1" kind="$2" when="${3:-latest}" run=""
  need jq
  case "$when" in
    ""|latest)
      run="$(rst "$i" snapshots --tag "instance:$i,kind:files" --latest 1 --json 2>/dev/null \
             | jq -r '.[0].tags[]? | select(startswith("run:")) | ltrimstr("run:")' || true)" ;;
    [0-9]*T[0-9]*)
      run="$when" ;;
    *)
      run="$(rst "$i" snapshots "$when" --json 2>/dev/null \
             | jq -r '.[0].tags[]? | select(startswith("run:")) | ltrimstr("run:")' || true)"
      [ -n "$run" ] || die "no snapshot '$when' in $i's repo (or it predates run: tags)" ;;
  esac
  [ -n "$run" ] || return 0
  rst "$i" snapshots --tag "instance:$i,kind:$kind,run:$run" --latest 1 --json 2>/dev/null \
    | jq -r '.[0].short_id // empty'
}

# ── health ──────────────────────────────────────────────────────────────────
instance_health() {   # 0 if the published endpoint answers 2xx
  local hp; hp="$(env_get "$1" BDUS_PORT || true)"
  [ -n "$hp" ] || return 2
  curl -fs --max-time 5 -o /dev/null "http://${hp}${HEALTH_PATH}"
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

# ── secrets ─────────────────────────────────────────────────────────────────
gen_pw() { openssl rand -hex 24 2>/dev/null || head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
