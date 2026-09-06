# bdus — command reference

`bdus <command> [instance|all] [args]`. Every subcommand also prints `--help`.
Instance selectors: a name from `INSTANCES` in `config.env`, or `all` (default
for the commands that accept it). Exit code is `0` on success, `2` on usage
errors, `1` on operational failure.

---

## `bdus setup host [--with-unattended] [--skip-ufw]`

One-time, re-execs under `sudo`. Idempotent.

- adds `$SUDO_USER` to the `docker` group; `systemctl enable --now docker containerd`
- writes `/etc/docker/daemon.json` (json-file logging `10m×3`, `live-restore`), restarts docker **only if it changed**
- `ufw`: default deny incoming / allow outgoing, allow OpenSSH, enable (unless `--skip-ufw`)
- installs `/usr/local/sbin/bdus-fw.sh` + `bdus-fw.service`: a `DOCKER-USER` chain rule set that lets **only `PROXY_ALLOW_IPS`** reach the instances' published ports (ports are discovered from each `<instance>/.env` at run time)
- `mkdir -p $BDUS_ROOT`, chown to the user, `chmod 750`
- `--with-unattended`: configure `unattended-upgrades`

Re-login after the first run (docker group).

## `bdus init <instance> [--version X.Y.Z] [--force]`

Creates `$BDUS_ROOT/<instance>/` from the `INSTANCE_<instance>_*` keys in
`config.env`:

- fetches `bradypus.yml` (ref `GHCR_YAML_REF`) — kept intact; it still declares
  named Docker volumes for anyone else deploying it as-is
- creates `data/projects/` and, for a Postgres instance, `data/pgdata/` —
  **host bind mounts**, not named volumes: this is a single-operator install
  with direct SSH access, so a plain directory is simpler to inspect and back
  up than Docker's volume abstraction. `bdus.override.yml` mounts these over
  `bradypus.yml`'s own named-volume paths (a Compose override replaces a
  mount at the same target). No manual `chown` is needed: both the `api` and
  Postgres/PostGIS images fix up ownership of whatever is mounted there on
  every boot
- writes `.env` (`chmod 600`): `COMPOSE_PROJECT_NAME=bdus-<instance>`,
  `COMPOSE_FILE`, `BDUS_VERSION` (`--version`, else `config.env` `BDUS_VERSION`),
  `BDUS_PORT`, `BRADYPUS_ALLOW_NEW_APP`, and for a Postgres instance
  `POSTGRES_USER/DB` + a **generated** `POSTGRES_PASSWORD` (+ `POSTGRES_PORT`
  if `INSTANCE_<n>_POSTGRES_PORT` is set — publishes Postgres itself, with
  TLS, see below); for a Martin instance, `MARTIN_PORT`
- writes `bdus.override.yml` (env passthrough, `no-new-privileges`, `mem_limit`,
  the bind mounts above, and — when `INSTANCE_<n>_POSTGRES=1` — a
  `postgis/postgis:16-3.4-alpine` service instead of plain `postgres`; any
  database can `CREATE EXTENSION postgis` or not, at no cost either way)
- when `INSTANCE_<n>_MARTIN=1` (requires `POSTGRES=1`): adds the `martin`
  service, `gis-data/` (bind mount for styles/sprites/fonts, mounted only into
  `martin`, never `api`), and a `martin-config.yaml` scaffold — written once,
  never overwritten, so hand-added per-app sources survive re-running `init`.
  Martin refuses to start with zero configured tile sources, so the scaffold
  includes a permanent no-op bootstrap function (`bdus init` creates it in the
  shared `postgres` maintenance database) that keeps it running before any app
  opts in. See "Vector tiles (Martin)" below
- `docker compose pull && up -d` (postgres first, then — when
  `INSTANCE_<n>_POSTGRES_PORT` is set — a self-signed TLS cert for it, then
  the Martin bootstrap function, then everything else, when Martin is
  enabled — otherwise martin's first boot can race the function's creation),
  restarts `bdus-fw` (needs sudo; warns otherwise), waits up to 90 s for
  health

`.env` is written **once**. Re-running refreshes `bradypus.yml` and
`bdus.override.yml` but keeps `.env` (holds the generated password) unless
`--force` — **never use `--force` just to pick up a bind-mount/Martin change
on an existing instance**, it rotates `POSTGRES_PASSWORD` while the database
itself still has the old one. The one exception: flipping `MARTIN=1` or
setting `POSTGRES_PORT` on an instance that already has an `.env` appends
the corresponding `MARTIN_PORT`/`POSTGRES_PORT` line to it (only if missing)
without touching anything else, so plain `bdus init <instance>` (no
`--force`) is always the right call for enabling a new flag on an existing
instance.

### Vector tiles (Martin)

Opt-in per instance (`INSTANCE_<n>_MARTIN=1` + `_MARTIN_PORT`), for serving
data that's maintained *outside* BraDypUS (typically QGIS) but relevant to a
project — not a feature of the app itself. Martin has no built-in
authentication; exposure is the published port filtered by the same
`bdus-fw` IP allowlist as `BDUS_PORT`, not a reverse-proxy change.

Attaching an app is managed (`bdus app gis <instance> <app> [--write]` — see
above), not hand-typed SQL: it provisions the `gis` schema and the
`<app>_martin`/`<app>_gis` roles. The one step that stays manual is wiring
the actual tile source: add a `postgres:` entry to `martin-config.yaml`
scoped to `<app>_martin` with `auto_publish.from_schemas: [gis]`. Martin
re-reads its config on its own (`reload_interval`, 10 min default) — no
restart required. Style/sprite/font files go in `gis-data/<app>/styles/`
etc. via plain `rsync`/`scp` — no dedicated command. Full walkthrough:
`DEPLOY-RUNBOOK.md` §18.

`<app>_martin` only needs to be reachable *from Martin* (same compose
network — no external exposure needed). `<app>_gis`, meant for QGIS Desktop
connecting directly over the Postgres wire protocol, needs Postgres itself
published: set `INSTANCE_<n>_POSTGRES_PORT` (same IP-allowlisted-by-`bdus-fw`
model as `MARTIN_PORT`/`BDUS_PORT` — see the config keys table below).
Without it, the `<app>_gis` role exists but nothing outside the compose
network can reach it.

### TLS on the published Postgres port

Setting `INSTANCE_<n>_POSTGRES_PORT` also enables TLS on Postgres itself —
unconditionally, no separate flag: publishing Postgres externally implies
wanting it encrypted. `bdus init` generates a self-signed cert once (`openssl`
run inside the `postgres` container itself, since `initdb` refuses to start
against a non-empty `PGDATA`, ruling out placing it there before first boot),
stores it at `data/pgdata/tls/` (rides along with the rest of the cluster's
data — same bind mount, same backups), and sets `ssl_cert_file`/`ssl_key_file`
in the postgres service's `command:`. This needs a container restart to take
effect (SSL settings aren't reloadable) — `bdus init` handles that, including
the first time you flip `POSTGRES_PORT` on for an instance that already has
data. Re-running `bdus init` afterwards is a no-op: the cert isn't
regenerated and the container isn't recreated once TLS is already active.

Client-side, add `sslmode=require` to the connection string (QGIS: "SSL mode"
→ "require" in the connection settings) — that's enough to get an encrypted
channel with the self-signed cert, no need to distribute it to clients.
**Not in scope**: this doesn't touch `pg_hba.conf` to *require* TLS
server-side — a client connecting without `sslmode=require` still gets a
plaintext connection today. Enforcing that (a custom `pg_hba.conf` with
`hostssl` rules) is a real follow-up, not implemented here.

Keeping `gis` (not the app's own tables) in the same database as BraDypUS's
data — rather than a separate database — is deliberate: schema-level `GRANT`s
give Martin's and QGIS's roles the same isolation a separate database would,
but joins/views between BraDypUS's own tables and `gis` stay native (a
separate database would need `postgres_fdw`/`dblink`), and the existing
`bdus backup`/`app export`/`app import` already operate at database
granularity, so `gis` rides along for free.

## `bdus status`

Read-only. Per instance: container states + running image, health endpoint,
Postgres `pg_isready`, Martin `/health` (if enabled), newest `*-files-*.tar.gz`
backup and its age. Warns when the running api image does not match the `.env`
pin. **Exit `1`** if any container is not running, health fails, Postgres or
Martin fails, or the newest backup is older than `STALE_BACKUP_DAYS`. Suitable
for a cron heartbeat.

## `bdus update <instance|all> <X.Y.Z> [--yes] [--no-backup]`

1. Aborts unless `API_IMAGE:<ver>` **and** `APP_IMAGE:<ver>` exist on GHCR
   (`docker manifest inspect`).
2. For each instance in `INSTANCES` order (so `demo` before `prod`):
   - `bdus backup <instance> --no-rsync` first (skip with `--no-backup`)
   - `sed` `BDUS_VERSION` in `.env`, `docker compose pull`, `up -d`
   - poll health up to 120 s
   - **on failure**: restore the previous `.env` pin, `up -d`, and stop with a
     non-zero exit. The DB is *not* rolled back — migrations for the new version
     may already have run; check the backup.
3. `--yes` skips the confirmation asked before every instance (all but the first
   when the target is `all`).

## `bdus backup [instance|all] [--no-rsync]`

Into `<instance>/backups/`:

- always `<project>-files-<ts>.tar.gz` — `data/projects/`
  (`config.json`, `.jwt_secret`, uploaded files, sqlite DBs), produced by
  `docker-backup.sh` inside the running `api` container
- for a Postgres instance, also `<project>-pgall-<ts>.sql.gz` — `pg_dumpall`
  (every database + roles — this already covers each app's `gis` schema, no
  separate step needed)
- for a Martin instance, also `<project>-gis-<ts>.tar.gz` — a plain host `tar`
  of `gis-data/` (styles/sprites/fonts), no container involved

Keeps the newest `BACKUP_RETENTION` of each kind. If `BACKUP_RSYNC_TARGET` is set
and `--no-rsync` is not given, `rsync -a --delete` the folder to
`<target>/<project>/`.

## `bdus restore <instance> [--db FILE] [--files FILE] [--yes]`

`docker compose stop api` → restore → `start api` → wait health.

- `--files` defaults to the newest `<project>-files-*.tar.gz`; extracted into
  `data/projects/` via `docker-restore.sh` (files not in the archive are left
  alone)
- `--db` (Postgres instances) defaults to the newest `<project>-pgall-*.sql.gz`;
  replayed with `psql -d postgres` (recreates databases as dumped)
- confirms unless `--yes`

`gis-data/` isn't restored by this command (it's a plain directory, not a
volume) — untar the `-gis-` backup over it by hand if needed.

For a full disaster-recovery restore into a fresh Postgres, `bdus init` the
instance first, then `bdus restore`.

## `bdus app add <instance> --name <slug> --engine sqlite|pgsql --email <admin> [--db-name X] [--db-user R] [--password-stdin] [--gis] [--gis-write]`

Wraps `vendor/add-app.sh` → `bin/create-app.php` inside the `api` container: no
HTTP, no `BRADYPUS_ALLOW_NEW_APP` toggle, no restart, no window. Admin password:
hidden prompt, or `--password-stdin`. **Requires the api image ≥ 5.4.6.**

For `pgsql` (image ≥ 5.4.8) it provisions an **isolated** role, as the shared
superuser (`POSTGRES_USER` in the instance `.env`):

```
CREATE ROLE "<slug>" LOGIN PASSWORD <generated>   -- no superuser, no createdb
CREATE DATABASE "<slug>" OWNER "<slug>"
REVOKE CONNECT ON DATABASE "<slug>" FROM PUBLIC;  GRANT CONNECT ... TO "<slug>"
```

and hands only that role to the app. The generated password is printed once and
stored (by BraDypUS) in `projects/<slug>/config.json` only. `--db-name`
overrides the database name (default `<slug>`, no prefix); `--db-user
<existing-role>` (+ `BDUS_DB_PASS`) reuses a role you manage yourself. Refuses
if the app, role, or database already exists. The superuser never reaches the
app — it is used only here and by `bdus backup` (`pg_dumpall` includes roles).

`--gis` / `--gis-write` (pgsql only): after creation, also runs the `gis`
subcommand below (`--gis-write` implies `--gis`) — see there for exactly what
it provisions. Skip both if the app has no use for vector tiles or external
GIS editing; add them later with `bdus app gis` if it turns out it does.

## `bdus app gis <instance> <app> [--write]`

Provisions PostGIS support for an existing pgsql app — the retrofit path for
an app created without `--gis`/`--gis-write`, and also what those flags call
internally at creation time. Idempotent and incremental: safe to re-run, and
running it again later with `--write` only adds what's missing without
touching (or rotating the password of) a role created by an earlier call.

- `CREATE EXTENSION IF NOT EXISTS postgis` and `CREATE SCHEMA IF NOT EXISTS gis`
  on the app's own database.
- A read-only role, `<app>_martin` (`GRANT USAGE` on the schema, `SELECT` on
  its tables/sequences, plus default privileges so *future* tables the
  read-write role below creates are automatically covered too) — intended for
  a `martin-config.yaml` `postgres:` entry (see "Vector tiles (Martin)"
  above), never the shared superuser.
- The app's own role also gets the same read-only access, for joins/views
  between its own tables (`public`) and `gis`.
- With `--write`: a read-write role, `<app>_gis` (`USAGE, CREATE` on the
  schema, `ALL` on its tables/sequences) — for QGIS or similar remote-editing
  clients. Scoped to `gis` only; it can never see or touch the app's own
  tables.
- Credentials are generated (`openssl rand -hex 24`) and stored in
  `projects/<app>/gis-config.json` (chmod 600) — printed once here too, same
  posture as the app's own DB password in `config.json`. Living inside
  `projects/<app>/` means it travels for free with `app export`/`import`
  (below), since that directory is already tarred wholesale. Missed the
  one-time printout? Read it back any time — since `data/projects` is a
  host bind mount, a plain
  `cat <instance-dir>/data/projects/<app>/gis-config.json` on the host works,
  no Docker needed (or `docker compose exec api cat projects/<app>/gis-config.json`
  from inside the instance directory, if you'd rather go through the container).

This only provisions the *role* — actually serving tiles still needs a manual
`postgres:` entry in `martin-config.yaml` (`DEPLOY-RUNBOOK.md` §18), since
that file stays hand-maintained by design.

## `bdus app to-pgsql <instance> <app> [--yes]`

Converts a live sqlite app to pgsql in place — same app name, same URL,
same `config.json` path. Structure always comes from BraDypUS's own schema
code (`bdus app add`'s native DDL), never from an auto-translated guess —
only the *data* transfer is delegated to [pgloader](https://pgloader.io/)
(official `dimitri/pgloader` image, run as an ephemeral container on the
instance's own compose network).

1. Exports a safety copy first (mandatory, no opt-out), then asks you to
   type the app name to confirm — this changes a live app's engine in place.
2. `projects/<app>` → `projects/<app>-sqlite` (rename, not copy) — this both
   preserves the original as a rollback safety net and is what unblocks the
   next step (`bdus app add` refuses if the directory already exists).
3. A fresh pgsql app is created under the same name — correct native schema
   (all 24 system tables, BraDypUS's own FK/index naming) and `config.json`,
   with a disposable placeholder admin.
4. `files/` and `geodata/` are restored from the renamed-aside copy.
5. A **trimmed copy** of the sqlite database (never the original) has
   `bdus_log`, `bdus_versions`, `bdus_queries`, and `bdus_migrations` dropped
   — these are deliberately not migrated: the first two are pure audit trail,
   `bdus_migrations` must reflect *this* schema build's state (not the
   source app's history), and `bdus_queries` holds free-text saved SQL that
   may use SQLite-only syntax, not reliably portable to Postgres.
6. The four system tables `bdus app add` seeds with real rows —
   `bdus_users`, `bdus_cfg_app`, `bdus_cfg_tables`, `bdus_cfg_fields` — are
   truncated so the placeholder admin/seed doesn't collide with the real
   data about to load.
7. pgloader runs **twice**: once scoped to `bdus_*` tables with
   `create no tables` (data only — verified live that this preserves the
   *existing* FK constraint names exactly, e.g. `fl_file_fk`, rather than
   inventing new ones), and once scoped to everything else (project tables,
   which don't exist yet, so pgloader creates them from the trimmed sqlite
   schema).

`projects/<app>-sqlite/` is kept, not deleted — remove it by hand once
you've verified the converted app. **After converting, log in as an admin
once** — a freshly built native schema always shows a full pending-migrations
list on first login (`POST /api/upgrade/minor` resolves it); this is normal
bootstrap behavior for any new app, not specific to this command, but easy
to mistake for something having gone wrong.

## `bdus app list [instance|all]`

Lists `projects/*` in each instance with engine and (pgsql) database name, read
from each app's `config.json`.

## `bdus app export <instance> <app> [--out FILE]`

Bundles a single app into one portable archive (`<app>-<instance>-<ts>.bdusapp.tgz`
in `<instance>/exports/`, or `--out`):

- `manifest` — `app`, `engine`, `db_name`, `db_user`, `source_instance`, `bdus_version`, `exported_at`
- `files.tar.gz` — `projects/<app>/` from `data/projects/` (`config.json`, `.jwt_secret`, `files/`, `gis-config.json` if `bdus app gis` was ever run, and for sqlite `db/bdus.sqlite`), via `docker-backup.sh <app>`
- `db.dump` — for pgsql, `pg_dump -Fc` of the app's database (data + users) — this already includes the `gis` schema and its data, since a `pg_dump` of a database covers every schema in it

An app is self-contained, so the archive is everything, GIS/Martin roles
included. Hot export: `pg_dump` is a consistent snapshot; `files/` is captured
as-is.

## `bdus app import <instance> <archive> [--force] [--new-jwt]`

The reverse — into the same or a **different** instance (target `bdus_version`
should be ≥ the source):

1. extracts `projects/<app>/` via `docker-restore.sh` (files not in the archive
   are left alone)
2. for pgsql: reads `db_name` / `db_username` / `db_password` from the restored
   `config.json`, creates the role (`CREATE ROLE … LOGIN PASSWORD`, from that
   cleartext) and database (`OWNER`, `REVOKE CONNECT FROM PUBLIC`) if missing;
   if the restored tree has a `gis-config.json`, also recreates `<app>_martin`/
   `<app>_gis` (same stored passwords) and pre-creates the PostGIS extension,
   *before* restoring — the dump's own `CREATE ROLE`-dependent GRANTs and
   geometry-typed objects need those to already exist. Then
   `pg_restore --no-owner --role=<user>` (a PostGIS-enabled dump throws a
   handful of expected, harmless warnings here — the extension's own comment
   and `spatial_ref_sys` are owned by the restoring superuser, not `<user>`,
   and pg_restore's exit code reflects that even though nothing is actually
   missing). Finally re-runs `bdus app gis`'s own provisioning logic once
   more to reconcile the schema grants and default-privileges pg_restore
   couldn't set (same reason: those specific statements need the superuser).
3. `--new-jwt` deletes `.jwt_secret` (regenerated on next login) — use when
   cloning to a different site
4. no restart; BraDypUS serves `projects/<app>/` on the next request

`--force` replaces an app that already exists on the target (drops its dir,
database — `WITH (FORCE)`, terminating any live connections — and role first,
plus any `<app>_martin`/`<app>_gis` roles). Every instance's Postgres is
PostGIS-enabled by default now, so PostGIS-using apps import cleanly; any
other, less common extension must still pre-exist on the target server.

## `bdus app delete <instance> <app> [--yes] [--no-backup] [--keep-role]`

Removes a single app. Irreversible.

1. **`bdus app export` first** into `<instance>/exports/` (skip with `--no-backup`)
2. prompts you to **type the app name** to confirm (skip with `--yes`)
3. `rm -rf projects/<app>` in the api container
4. for pgsql: `DROP DATABASE "<db_name>" WITH (FORCE)` (terminates live
   connections), then `DROP ROLE "<db_user>"` — **skipped** when `<db_user>` is
   the shared `POSTGRES_USER`, or with `--keep-role`. A `DROP ROLE` that fails
   (role still owns objects in another database) is reported, not fatal.
5. if `bdus app gis` was ever run for this app: also `DROP ROLE` for
   `<app>_martin`/`<app>_gis` (no `--keep-role` exemption — these are always
   dedicated to this one app, never shared), and a reminder to remove the
   app's entry from `martin-config.yaml` by hand if it had one.

No restart.

## `bdus logs <instance> [args…]`

`cd <instance> && docker compose logs "$@"`. e.g. `bdus logs prod -f --tail=200`.

## `bdus psql <instance> [dbname]`

`docker compose exec postgres psql -U <user> -d <dbname>` (default `postgres`).
App databases are named `<app>` (no prefix, since `app add` v5.4.8 — see below).

## `bdus start | stop | restart | pull <instance|all>`

Thin wrappers over `docker compose up -d` / `stop` / `restart` / `pull` in the
right directory.

## `bdus doctor`

Checks invariants and exits non-zero on failure: docker enabled + `live-restore`,
`ufw` active, `bdus-fw.sh` + `bdus-fw.service` present/enabled, `DOCKER-USER`
DROP rules present, backup cron installed, rsync target reachable; per instance:
dir + `.env` (perms `600`) + `bdus.override.yml`, compose config valid, `api`
running, `data/projects/` present, Postgres healthy + `data/pgdata/` owned by
uid 70 (if enabled), `gis-data/` present + Martin healthy (if enabled). Some
host checks need passwordless `sudo` for `iptables`/`ufw`; they degrade to
warnings otherwise.

---

## config.env keys

| key | meaning |
|---|---|
| `BDUS_ROOT` | directory holding one subdir per instance |
| `INSTANCES` | space-separated names; **order = update order** |
| `API_IMAGE` / `APP_IMAGE` | GHCR image names |
| `GHCR_YAML_REF` | git ref for the fetched `bradypus.yml` |
| `BDUS_VERSION` | default pin written by `bdus init` |
| `HEALTH_PATH` | unauthenticated 200 endpoint for health checks |
| `STALE_BACKUP_DAYS` | `bdus status` fails if the newest backup is older |
| `BACKUP_RETENTION` | archives kept per instance per kind |
| `BACKUP_RSYNC_TARGET` | `user@host:/path` for off-box copy; empty disables |
| `PROXY_ALLOW_IPS` | IPs allowed through `DOCKER-USER` to the published ports |
| `INSTANCE_<n>_PORT` | `<ip>:<port>` bind for the frontend |
| `INSTANCE_<n>_POSTGRES` | `1` adds a shared Postgres (PostGIS-enabled) service, `0` sqlite only |
| `INSTANCE_<n>_ALLOW_NEW_APP` | `0` (prod) or `1` (demo/edu) |
| `INSTANCE_<n>_MEM_API` / `_MEM_FRONT` | container memory limits |
| `INSTANCE_<n>_MARTIN` | `1` adds a Martin (vector tile) service — requires `POSTGRES=1` |
| `INSTANCE_<n>_MARTIN_PORT` | `<ip>:<port>` bind for Martin (only used when `MARTIN=1`) |
| `INSTANCE_<n>_POSTGRES_PORT` | optional `<ip>:<port>` to publish Postgres itself, with TLS (e.g. for QGIS via `<app>_gis` — requires `POSTGRES=1`); empty (default) keeps it internal-only — see "TLS on the published Postgres port" above |
