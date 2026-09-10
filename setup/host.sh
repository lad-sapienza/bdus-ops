#!/usr/bin/env bash
# setup/host.sh — one-time host prep for a BraDypUS app VM. Run via `bdus setup host`
# (which re-execs it under sudo). Idempotent: safe to re-run.
#
#   --bdus-root DIR    instances root                (default /srv/bradypus)
#   --allow-ips "IPs"  space-separated IPs allowed to reach the published ports
#   --user NAME        non-root user to add to the docker group and own BDUS_ROOT
#   --with-unattended  also configure unattended-upgrades
#   --skip-ufw         do not touch ufw
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run via: bdus setup host" >&2; exit 1; }

ROOT=/srv/bradypus; ALLOW=""; USR="${SUDO_USER:-}"; UNATT=0; DO_UFW=1
while [ $# -gt 0 ]; do
  case "$1" in
    --bdus-root) ROOT="$2"; shift 2 ;;
    --allow-ips) ALLOW="$2"; shift 2 ;;
    --user)      USR="$2"; shift 2 ;;
    --with-unattended) UNATT=1; shift ;;
    --skip-ufw)  DO_UFW=0; shift ;;
    *) echo "host.sh: unknown option $1" >&2; exit 2 ;;
  esac
done
grn(){ printf '\033[32m✓\033[0m %s\n' "$*"; }
inf(){ printf '\033[36m%s\033[0m\n' "$*"; }

# ── docker: group + boot ───────────────────────────────────────────────────
if [ -n "$USR" ] && ! grep -qx docker < <(id -nG "$USR" | tr ' ' '\n'); then
  usermod -aG docker "$USR"; grn "added $USR to the docker group (re-login to take effect)"
fi
systemctl enable --now docker containerd >/dev/null 2>&1 || true
grn "docker enabled on boot"

# ── daemon.json: log rotation + live-restore ───────────────────────────────
DJ=/etc/docker/daemon.json
want='{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true
}'
if [ ! -f "$DJ" ] || ! diff -q <(printf '%s\n' "$want") "$DJ" >/dev/null 2>&1; then
  mkdir -p /etc/docker
  printf '%s\n' "$want" > "$DJ"
  systemctl restart docker
  grn "daemon.json written, docker restarted"
else
  grn "daemon.json already current"
fi

# ── backup tooling: jq + restic (>= 0.17, for `restic backup --stdin-from-command`)
# `bdus backup` needs both. Prefer the distro packages; fall back to a pinned
# restic release binary only when the packaged one is missing or too old. A
# failure here must NOT abort the rest of host prep — `bdus doctor` / `bdus
# backup` flag a missing restic loudly anyway.
command -v jq >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq jq; }
grn "jq present"

_restic_ok() {   # 0 if `restic` on PATH is >= 0.17
  local v maj min
  v="$(restic version 2>/dev/null | awk '{print $2}')" || return 1
  [ -n "$v" ] || return 1
  IFS=. read -r maj min _ <<<"$v"
  [ "${maj:-0}" -gt 0 ] || { [ "${maj:-0}" -eq 0 ] && [ "${min:-0}" -ge 17 ]; }
}

RESTIC_VER=0.17.3   # pinned fallback only
if _restic_ok; then
  grn "restic $(restic version | awk '{print $2}') present"
else
  apt-get install -y -qq restic >/dev/null 2>&1 || true
  if _restic_ok; then
    grn "restic $(restic version | awk '{print $2}') from apt"
  else
    inf "apt restic missing/old — fetching pinned v${RESTIC_VER} binary"
    command -v bunzip2 >/dev/null 2>&1 || apt-get install -y -qq bzip2 || true
    t="$(mktemp -d)"; f="restic_${RESTIC_VER}_linux_amd64.bz2"
    # pinned version over HTTPS from the project's own releases — same trust
    # model as the bradypus.yml fetch in `bdus init`. Optional integrity check:
    #   curl -fsSL "https://github.com/restic/restic/releases/download/v${RESTIC_VER}/SHA256SUMS" \
    #     | ( cd "$t" && grep " $f\$" | sha256sum -c - )
    if command -v bunzip2 >/dev/null 2>&1 \
       && curl -fsSL -o "$t/$f" "https://github.com/restic/restic/releases/download/v${RESTIC_VER}/$f" \
       && bunzip2 "$t/$f"; then
      install -m 0755 "$t/restic_${RESTIC_VER}_linux_amd64" /usr/local/bin/restic
      grn "restic ${RESTIC_VER} installed"
    else
      inf "could not install restic — run 'apt-get install restic' or drop a binary in /usr/local/bin, then re-run"
    fi
    rm -rf "$t"
  fi
fi

# ── ufw: host services (does NOT cover Docker-published ports) ─────────────
if [ "$DO_UFW" -eq 1 ]; then
  command -v ufw >/dev/null || { apt-get update -qq && apt-get install -y -qq ufw; }
  ufw --force default deny incoming  >/dev/null
  ufw --force default allow outgoing >/dev/null
  ufw allow OpenSSH >/dev/null
  grep -q '^Status: active' < <(ufw status) || ufw --force enable >/dev/null
  grn "ufw active (SSH allowed; container ports handled by DOCKER-USER below)"
fi

# ── DOCKER-USER firewall: only ALLOW ips reach the instances' published ports
FW=/usr/local/sbin/bdus-fw.sh
cat > "$FW" <<EOF
#!/bin/sh
# Managed by bdus-ops (setup/host.sh). Restricts the ports published by the
# BraDypUS instances to ALLOW_IPS only. Ports are discovered from each
# <instance>/.env at runtime (any "*_PORT=<ip>:<port>" line — BDUS_PORT,
# MARTIN_PORT, and any future one), so adding an instance or a new service
# needs only a restart, never an edit here.
set -eu
ALLOW_IPS="${ALLOW}"
ROOT="${ROOT}"

iptables -nL DOCKER-USER >/dev/null 2>&1 || { iptables -N DOCKER-USER; iptables -I FORWARD -j DOCKER-USER; }

ports=\$(sed -n 's/^[A-Z_]*_PORT=.*:\([0-9][0-9]*\)\$/\1/p' "\$ROOT"/*/.env 2>/dev/null | sort -u)
[ -n "\$ports" ] || exit 0

for p in \$ports; do
  # drop our previous rules for this port
  while r=\$(iptables -S DOCKER-USER | grep -E -- "--ctorigdstport \$p " | head -1); [ -n "\$r" ]; do
    # shellcheck disable=SC2086
    iptables -D DOCKER-USER \$(printf '%s' "\$r" | sed 's/^-A DOCKER-USER //')
  done
  iptables -I DOCKER-USER -p tcp -m conntrack --ctstate NEW --ctorigdstport "\$p" -j DROP
  for ip in \$ALLOW_IPS; do
    iptables -I DOCKER-USER -p tcp -m conntrack --ctstate NEW --ctorigdstport "\$p" -s "\$ip" -j RETURN
  done
done
EOF
chmod +x "$FW"

cat > /etc/systemd/system/bdus-fw.service <<'EOF'
[Unit]
Description=Restrict BraDypUS published ports to the allowed IPs
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/bdus-fw.sh

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now bdus-fw.service >/dev/null
grn "bdus-fw.sh + bdus-fw.service (allow: ${ALLOW:-<none set>})"

# supersede a hand-installed runbook firewall unit, if present
if systemctl list-unit-files --no-legend 2>/dev/null | grep -q '^bradypus-fw\.service'; then
  systemctl disable --now bradypus-fw.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/bradypus-fw.service /usr/local/sbin/bradypus-fw.sh
  systemctl daemon-reload
  grn "disabled the old bradypus-fw.service (replaced by bdus-fw.service)"
fi

# ── instances root ─────────────────────────────────────────────────────────
mkdir -p "$ROOT"
[ -n "$USR" ] && chown -R "$USR:$USR" "$ROOT"
chmod 750 "$ROOT"
grn "$ROOT ready"

# ── unattended-upgrades (opt-in) ──────────────────────────────────────────
if [ "$UNATT" -eq 1 ]; then
  apt-get install -y -qq unattended-upgrades
  dpkg-reconfigure -f noninteractive unattended-upgrades
  grn "unattended-upgrades configured"
fi

inf "host prep done. Next:  bdus init <instance>  for each of your instances."
