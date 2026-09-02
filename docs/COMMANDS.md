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

- fetches `bradypus.yml` (ref `GHCR_YAML_REF`) — kept intact
- writes `.env` (`chmod 600`): `COMPOSE_PROJECT_NAME=bdus-<instance>`,
  `COMPOSE_FILE`, `BDUS_VERSION` (`--version`, else `config.env` `BDUS_VERSION`),
  `BDUS_PORT`, `BRADYPUS_ALLOW_NEW_APP`, and for a Postgres instance
  `POSTGRES_USER/DB` + a **generated** `POSTGRES_PASSWORD`
- writes `bdus.override.yml` (env passthrough, `no-new-privileges`, `mem_limit`,
  and the `postgres:16-alpine` service when `INSTANCE_<n>_POSTGRES=1`)
- `docker compose pull && up -d`, restarts `bdus-fw` (needs sudo; warns otherwise),
  waits up to 90 s for health

`.env` is written **once**. Re-running refreshes `bradypus.yml` and
`bdus.override.yml` but keeps `.env` (holds the generated password) unless
`--force`.

## `bdus status`

Read-only. Per instance: container states + running image, health endpoint,
Postgres `pg_isready`, newest `*-files-*.tar.gz` backup and its age. Warns when
the running api image does not match the `.env` pin. **Exit `1`** if any
container is not running, health fails, Postgres fails, or the newest backup is
older than `STALE_BACKUP_DAYS`. Suitable for a cron heartbeat.

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

- always `<project>-files-<ts>.tar.gz` — the `projects_data` volume
  (`config.json`, `.jwt_secret`, uploaded files, sqlite DBs), produced by
  `docker-backup.sh` inside the running `api` container
- for a Postgres instance, also `<project>-pgall-<ts>.sql.gz` — `pg_dumpall`
  (every database + roles)

Keeps the newest `BACKUP_RETENTION` of each kind. If `BACKUP_RSYNC_TARGET` is set
and `--no-rsync` is not given, `rsync -a --delete` the folder to
`<target>/<project>/`.

## `bdus restore <instance> [--db FILE] [--files FILE] [--yes]`

`docker compose stop api` → restore → `start api` → wait health.

- `--files` defaults to the newest `<project>-files-*.tar.gz`; extracted into
  `projects_data` via `docker-restore.sh` (files not in the archive are left
  alone)
- `--db` (Postgres instances) defaults to the newest `<project>-pgall-*.sql.gz`;
  replayed with `psql -d postgres` (recreates databases as dumped)
- confirms unless `--yes`

For a full disaster-recovery restore into a fresh Postgres volume, `bdus init`
the instance first, then `bdus restore`.

## `bdus app add <instance> --name <slug> --engine sqlite|pgsql --email <admin> [--db-name X] [--db-user R] [--password-stdin]`

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

## `bdus app list [instance|all]`

Lists `projects/*` in each instance with engine and (pgsql) database name, read
from each app's `config.json`.

## `bdus app export <instance> <app> [--out FILE]`

Bundles a single app into one portable archive (`<app>-<instance>-<ts>.bdusapp.tgz`
in `<instance>/exports/`, or `--out`):

- `manifest` — `app`, `engine`, `db_name`, `db_user`, `source_instance`, `bdus_version`, `exported_at`
- `files.tar.gz` — `projects/<app>/` from the volume (`config.json`, `.jwt_secret`, `files/`, and for sqlite `db/bdus.sqlite`), via `docker-backup.sh <app>`
- `db.dump` — for pgsql, `pg_dump -Fc` of the app's database (data + users)

An app is self-contained, so the archive is everything. Hot export: `pg_dump` is
a consistent snapshot; `files/` is captured as-is.

## `bdus app import <instance> <archive> [--force] [--new-jwt]`

The reverse — into the same or a **different** instance (target `bdus_version`
should be ≥ the source):

1. extracts `projects/<app>/` via `docker-restore.sh` (files not in the archive
   are left alone)
2. for pgsql: reads `db_name` / `db_username` / `db_password` from the restored
   `config.json`, creates the role (`CREATE ROLE … LOGIN PASSWORD`, from that
   cleartext) and database (`OWNER`, `REVOKE CONNECT FROM PUBLIC`) if missing,
   then `pg_restore --no-owner --role=<user>`
3. `--new-jwt` deletes `.jwt_secret` (regenerated on next login) — use when
   cloning to a different site
4. no restart; BraDypUS serves `projects/<app>/` on the next request

`--force` replaces an app that already exists on the target (drops its dir and,
for pgsql, its database and role first). PostGIS or other extensions must
pre-exist on the target server.

## `bdus app delete <instance> <app> [--yes] [--no-backup] [--keep-role]`

Removes a single app. Irreversible.

1. **`bdus app export` first** into `<instance>/exports/` (skip with `--no-backup`)
2. prompts you to **type the app name** to confirm (skip with `--yes`)
3. `rm -rf projects/<app>` in the api container
4. for pgsql: `DROP DATABASE "<db_name>" WITH (FORCE)` (terminates live
   connections), then `DROP ROLE "<db_user>"` — **skipped** when `<db_user>` is
   the shared `POSTGRES_USER`, or with `--keep-role`. A `DROP ROLE` that fails
   (role still owns objects in another database) is reported, not fatal.

No restart.

## `bdus logs <instance> [args…]`

`cd <instance> && docker compose logs "$@"`. e.g. `bdus logs prod -f --tail=200`.

## `bdus psql <instance> [dbname]`

`docker compose exec postgres psql -U <user> -d <dbname>` (default `postgres`).
App databases are `bdus_<app>`.

## `bdus start | stop | restart | pull <instance|all>`

Thin wrappers over `docker compose up -d` / `stop` / `restart` / `pull` in the
right directory.

## `bdus doctor`

Checks invariants and exits non-zero on failure: docker enabled + `live-restore`,
`ufw` active, `bdus-fw.sh` + `bdus-fw.service` present/enabled, `DOCKER-USER`
DROP rules present, backup cron installed, rsync target reachable; per instance:
dir + `.env` (perms `600`) + `bdus.override.yml`, compose config valid, `api`
running, Postgres healthy. Some host checks need passwordless `sudo` for
`iptables`/`ufw`; they degrade to warnings otherwise.

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
| `INSTANCE_<n>_POSTGRES` | `1` adds a shared Postgres service, `0` sqlite only |
| `INSTANCE_<n>_ALLOW_NEW_APP` | `0` (prod) or `1` (demo/edu) |
| `INSTANCE_<n>_MEM_API` / `_MEM_FRONT` | container memory limits |
