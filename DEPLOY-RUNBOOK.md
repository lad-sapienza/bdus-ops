# BraDypUS v5 — runbook di deploy (prod + demo dietro reverse proxy)

Portare in produzione l'istanza **prod** e l'istanza **demo/edu** sulla stessa VM
privata, isolate fra loro, raggiungibili solo dalla VM proxy che termina TLS e
mappa i domini. Comandi eseguibili in ordine; ogni fase è indipendente e ripetibile.

> Copia allineata all'artifact `https://claude.ai/code/artifact/a5bbd8a9-8e01-4283-b3ca-6f064e0371b7`.

| | |
|---|---|
| VM app | **192.168.4.39** — Debian 13, utente **debian**, Docker CE installato |
| VM proxy | **192.168.3.186** — nginx (< 1.25.1) + certbot, gestita a parte |
| Istanza **prod** | bind **192.168.4.39:8081** · **/srv/bradypus/prod** · progetto **bdus-prod** · volumi **bdus-prod_projects_data** + **bdus-prod_pgdata** · **Postgres condiviso**, engine per-app (sqlite o pgsql) |
| Istanza **demo** | bind **192.168.4.39:8082** · **/srv/bradypus/demo** · progetto **bdus-demo** · volume **bdus-demo_projects_data** · solo **sqlite** |
| Versione | BraDypUS **5.4.8** (immagini GHCR pinnate) |
| Nuove app | wizard HTTP → **sempre** `BRADYPUS_ALLOW_NEW_APP=1` (5.4.7) · `bdus app add` non apre finestra; pgsql = ruolo isolato per app (5.4.8) |
| Domini (sul proxy) | **bdus.lad-sapienza.it** (prod) · **demo.bdus.lad-sapienza.it** (demo) · cert SAN unico · file vhost **senza** `.conf` |

L'ordine conta: **firewall prima dei container**.

## 00 · Verifiche iniziali  
_Fase 00 VM APP_

Da eseguire come utente `debian` sulla VM app. Confermano che l'ambiente è quello atteso.

```bash
# chi sono e dove sono
id
hostname -I                    # deve comparire 192.168.4.39

# toolchain
docker --version
docker compose version         # plugin v2 (spazio, non trattino)
sudo docker run --rm hello-world   # il daemon risponde (già fatto)
```

## 01 · Docker: uso senza sudo, avvio al boot, verifica daemon  
_Fase 01 VM APP_

L'appartenenza al gruppo `docker` equivale a root: assegnala solo ad admin fidati. Dopo `usermod` serve riconnettere la sessione SSH.

```bash
sudo usermod -aG docker "$USER"

# avvio automatico e ripristino dopo reboot
sudo systemctl enable --now docker containerd

# --- ora disconnetti e riconnetti la sessione SSH, poi prosegui ---

# verifica la rotazione log + live-restore che hai già configurato
cat /etc/docker/daemon.json
docker info --format 'logging={{.LoggingDriver}} live-restore={{.LiveRestoreEnabled}}'
# atteso: logging=json-file live-restore=true
```

## 02 · Firewall dell'host (ufw)  
_Fase 02 VM APP_

Protegge i **servizi dell'host** (SSH e qualsiasi cosa girerà fuori da Docker). Le porte pubblicate dai container **non** passano da ufw: per quelle c'è la Fase 03.

> **Perché** — La VM non ha IP pubblico, quindi qui il firewall non ferma Internet ma riduce la superficie sulla **rete privata**: se un'altra macchina della LAN viene compromessa, non deve poter parlare coi servizi dell'host. `deny (incoming)` = ogni pacchetto diretto a un processo *dell'host* è bloccato salvo eccezioni; `allow (outgoing)` = l'host può aprire connessioni verso l'esterno (apt, pull immagini); `deny (routed)` = l'host non inoltra traffico fra reti (non è un router). **Il limite**: ufw filtra la catena `INPUT` di netfilter (traffico *per l'host*). Il traffico *verso i container* passa dalla catena `FORWARD`, che ufw non tocca → 8081/8082 restano aperte anche con ufw attivo. Le chiude la Fase 03.

```bash
sudo apt-get update && sudo apt-get install -y ufw

sudo ufw default deny incoming
sudo ufw default allow outgoing

# la VM non ha interfaccia pubblica: "any" qui = solo le reti private.
# se hai una subnet di management fissa, restringi:
#   sudo ufw allow proto tcp from 192.168.3.0/24 to any port 22
sudo ufw allow OpenSSH

sudo ufw --force enable
sudo ufw status verbose
```

## 03 · Firewall dei container — solo la VM proxy raggiunge 8081/8082  
_Fase 03 VM APP_

Docker pubblica le porte inserendo regole iptables che **scavalcano ufw**. La catena `DOCKER-USER` è l'unica che Docker valuta per prima e non tocca mai. `--ctorigdstport` intercetta la porta pubblicata originale (8081/8082) *prima* che il DNAT di Docker la riscriva a :80 del container.

> **Perché, riga per riga** — Quando pubblichi `8081:80`, Docker inserisce da sé regole iptables che (a) fanno **DNAT**: riscrivono `IP-host:8081` → `IP-container:80`, e (b) fanno **ACCEPT** nella catena `FORWARD`. Queste regole scavalcano ufw perché ufw sta in `INPUT`. `DOCKER-USER` è una catena che Docker crea, aggancia in cima a `FORWARD` e **non svuota mai**: è il punto ufficiale per le tue regole.
> - `--ctorigdstport 8081`: quando il pacchetto arriva qui il DNAT è **già avvenuto**, quindi `--dport` varrebbe `80` (inutile). `conntrack` ricorda la porta di destinazione *originale* → filtriamo su quella.
> - `--ctstate NEW`: filtriamo solo l'apertura di connessione; le risposte a connessioni già stabilite passano.
> - `! -s 192.168.3.186`: droppa tutto ciò che non arriva dalla VM proxy.
> Il servizio systemd riapplica le regole al boot (iptables non è persistente) ed è ordinato `After=docker.service` perché dockerd ricrea la catena all'avvio.

_/usr/local/sbin/bradypus-fw.sh_

```bash
sudo tee /usr/local/sbin/bradypus-fw.sh >/dev/null <<'EOF'
#!/bin/sh
# Limita le porte pubblicate di BraDypUS alla sola VM proxy.
set -eu
PROXY_IP="192.168.3.186"
PORTS="8081 8082"

iptables -nL DOCKER-USER >/dev/null 2>&1 || {
  iptables -N DOCKER-USER
  iptables -I FORWARD -j DOCKER-USER
}

for p in $PORTS; do
  while iptables -C DOCKER-USER -p tcp -m conntrack --ctstate NEW \
        --ctorigdstport "$p" ! -s "$PROXY_IP" -j DROP 2>/dev/null; do
    iptables -D DOCKER-USER -p tcp -m conntrack --ctstate NEW \
        --ctorigdstport "$p" ! -s "$PROXY_IP" -j DROP
  done
  iptables -I DOCKER-USER -p tcp -m conntrack --ctstate NEW \
      --ctorigdstport "$p" ! -s "$PROXY_IP" -j DROP
done
EOF
sudo chmod +x /usr/local/sbin/bradypus-fw.sh
```

_/etc/systemd/system/bradypus-fw.service_

```bash
sudo tee /etc/systemd/system/bradypus-fw.service >/dev/null <<'EOF'
[Unit]
Description=Restrict BraDypUS published ports to the proxy VM
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/bradypus-fw.sh

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now bradypus-fw.service
sudo iptables -S DOCKER-USER      # deve mostrare le 2 regole DROP
```

> **Nota** — Le regole in `DOCKER-USER` sopravvivono ai riavvii dei container e del daemon; il servizio le riapplica al boot. Dopo un raro `systemctl restart docker` manuale: `sudo systemctl restart bradypus-fw`. Se la rete privata è solo IPv4 non serve `ip6tables`.

> **Con `bdus-ops`**: `bdus setup host` installa la versione equivalente come `bdus-fw.sh` / `bdus-fw.service` (scopre le porte dai `.env` a runtime, ammette gli IP in `PROXY_ALLOW_IPS`) e disabilita `bradypus-fw.service` se lo trova. Se hai già fatto le Fasi 02–03 a mano, o le rifai con `bdus setup host` (idempotente) o le lasci così.

## 04 · Aggiornamenti di sicurezza automatici  
_Fase 04 VM APP_

Opzionale ma consigliato: patch del sistema base senza intervento manuale. Non tocca Docker né BraDypUS (quelli si aggiornano nella Fase 15).

```bash
sudo apt-get install -y unattended-upgrades
sudo dpkg-reconfigure -f noninteractive unattended-upgrades
```

## 05 · Struttura delle cartelle  
_Fase 05 VM APP_

In `/srv`, non in `~`: i dati veri (DB SQLite, file, `.jwt_secret`) stanno nei volumi Docker; qui vivono solo compose, `.env` e `backups/`, ma non devono sparire con l'utente di login.

```bash
sudo mkdir -p /srv/bradypus/prod /srv/bradypus/demo
sudo chown -R "$USER:$USER" /srv/bradypus
chmod 750 /srv/bradypus/prod /srv/bradypus/demo
```

## 06 · Scaricare `bradypus.yml` in ogni istanza  
_Fase 06 VM APP_

Il file di compose ufficiale, identico per le due istanze: resta **intatto** così `docker compose pull` continua a seguire l'upstream. Le differenze stanno tutte in `.env` e `bdus.override.yml`.

```bash
for d in prod demo; do
  curl -fsSL -o /srv/bradypus/$d/bradypus.yml \
    https://raw.githubusercontent.com/lad-sapienza/BraDypUS/v5/bradypus.yml
done
ls -l /srv/bradypus/*/bradypus.yml
```

## 07 · Istanza demo / edu  
_Fase 07 VM APP_

Si porta su per prima: creazione app aperta, rischio più basso. Due file, poi `up`.

**.env**

_/srv/bradypus/demo/.env_

```bash
cd /srv/bradypus/demo

cat > .env <<'EOF'
# ── Istanza demo / edu ──────────────────────────────────────────────
COMPOSE_PROJECT_NAME=bdus-demo
COMPOSE_FILE=bradypus.yml:bdus.override.yml

BDUS_VERSION=5.4.8
BDUS_PORT=192.168.4.39:8082

BRADYPUS_DEBUG=0
# visitatori/studenti possono creare le proprie app:
BRADYPUS_ALLOW_NEW_APP=1
EOF
chmod 600 .env
```

**bdus.override.yml**

Env passthrough (`bradypus.yml` cabla `ALLOW_NEW_APP=0`) + hardening. In 5.4.5 la rete è già isolata per progetto: **identico** nelle due cartelle.

_/srv/bradypus/demo/bdus.override.yml_

```bash
cat > bdus.override.yml <<'EOF'
services:
  api:
    environment:
      - BRADYPUS_DEBUG=${BRADYPUS_DEBUG:-0}
      - BRADYPUS_ALLOW_NEW_APP=${BRADYPUS_ALLOW_NEW_APP:-0}
    security_opt:
      - no-new-privileges:true
    mem_limit: 768m
  frontend:
    security_opt:
      - no-new-privileges:true
    mem_limit: 192m
EOF
```

**Upload > 64M (opzionale)**

L'immagine 5.4.5 spedisce già `upload_max_filesize 64M` / `post_max_size 72M`. Solo se ti servono file più grandi, aggiungi il volume all'`api` nell'override e crea il file **prima** dell'`up`:

```bash
# in bdus.override.yml, sotto  api:
    volumes:
      - ./php-uploads.ini:/usr/local/etc/php/conf.d/zz-bradypus.ini:ro

# poi, nella cartella dell'istanza:
cat > php-uploads.ini <<'EOF'
upload_max_filesize = 256M
post_max_size = 300M
memory_limit = 512M
EOF
```

**Validazione, pull, avvio**

```bash
# eseguire SEMPRE compose dalla cartella dell'istanza
docker compose config --quiet && echo "compose OK"
docker compose config | grep -E 'name:|projects_data|bdus-demo_bradypus-net|8082'

docker compose pull
docker compose up -d
docker compose ps
```

**Verifica demo**

```bash
curl -sS -o /dev/null -w 'http %{http_code}\n' http://192.168.4.39:8082/
curl -sS 'http://192.168.4.39:8082/api/new-app/status'; echo
# atteso: JSON con "permitted":true
docker compose logs --tail=20
```

## 08 · Istanza prod (con Postgres condiviso)  
_Fase 08 VM APP_

Come la demo, ma porta **8081**, `ALLOW_NEW_APP=0`, più RAM, e un container **Postgres**. BraDypUS resta multi-progetto: ogni app sceglie il suo engine — **sqlite** (dati in `projects_data`) o **pgsql** (un database dedicato sul Postgres condiviso). La 5432 non è pubblicata.

_/srv/bradypus/prod/{.env, bdus.override.yml}_

```bash
cd /srv/bradypus/prod

cat > .env <<'EOF'
# ── Istanza produzione ──────────────────────────────────────────────
COMPOSE_PROJECT_NAME=bdus-prod
COMPOSE_FILE=bradypus.yml:bdus.override.yml

BDUS_VERSION=5.4.8
BDUS_PORT=192.168.4.39:8081

BRADYPUS_DEBUG=0
# TENERE 0. Passare a 1 solo per i minuti necessari a creare
# un'app, poi tornare a 0 (vedi "Aggiungere un'app").
BRADYPUS_ALLOW_NEW_APP=0

# ── PostgreSQL — server condiviso, un database per app pgsql ────────
POSTGRES_USER=bdus
POSTGRES_PASSWORD=<password-robusta>
POSTGRES_DB=postgres        # solo db di servizio/healthcheck
EOF
chmod 600 .env

cat > bdus.override.yml <<'EOF'
services:
  api:
    environment:
      - BRADYPUS_DEBUG=${BRADYPUS_DEBUG:-0}
      - BRADYPUS_ALLOW_NEW_APP=${BRADYPUS_ALLOW_NEW_APP:-0}
    security_opt:
      - no-new-privileges:true
    mem_limit: 1g
    depends_on:
      postgres:
        condition: service_healthy
  frontend:
    security_opt:
      - no-new-privileges:true
    mem_limit: 192m
  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: ${POSTGRES_USER:-bdus}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?set POSTGRES_PASSWORD in .env}
      POSTGRES_DB: ${POSTGRES_DB:-postgres}
    volumes:
      - pgdata:/var/lib/postgresql/data
    shm_size: 256mb
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER:-bdus} -d ${POSTGRES_DB:-postgres}"]
      interval: 5s
      timeout: 5s
      retries: 12
    networks: [bradypus-net]
    restart: unless-stopped

volumes:
  pgdata:

networks:
  bradypus-net:
    driver: bridge
EOF

docker compose config --quiet && echo "compose OK"
docker compose config | grep -E 'name:|projects_data|pgdata|postgres|8081'
docker compose pull
docker compose up -d
docker compose ps          # 'postgres' deve risultare healthy
curl -sS -o /dev/null -w 'http %{http_code}\n' http://192.168.4.39:8081/
```

> **Nota** — `bdus` è superuser (default dell'immagine ufficiale) → può creare i database delle app pgsql. `postgres:16-alpine` = versione contro cui BraDypUS è testato; un salto major (16→17) richiederà dump/restore.

> **Nota (5.4.7)** — La creazione app richiede **sempre** `BRADYPUS_ALLOW_NEW_APP=1`, primo app incluso: con `=0` non c'è modo di crearne via HTTP. Il percorso senza-finestra è `bin/create-app.php` (vedi Fase 09 e "Aggiungere un'app"). Firewall-prima-dei-container (Fasi 02–03) e vhost prod offline fino a fine Fase 09 restano comunque buona pratica.

## 09 · Creare la prima applicazione di prod  
_Fase 09 VM APP_

Modo più semplice — **senza finestra**, senza wizard:

```bash
bdus app add prod --name siti_scavo --engine pgsql --email admin@lad-sapienza.it
# sqlite: --engine sqlite  (niente altro)
# pgsql : crea ruolo isolato + database "siti_scavo" (vedi "Aggiungere un'app")
```

In alternativa, il wizard (richiede la finestra `ALLOW_NEW_APP=1`, primo app incluso — vedi **"Aggiungere un'app"** in Parte C). Per arrivarci prima che il vhost pubblico esista:

```bash
# dalla tua workstation — tunnel verso l'istanza
ssh -L 8081:192.168.4.39:8081 debian@<host-ssh-vm-app>
# poi apri  http://localhost:8081/  → "Crea nuova applicazione"
```

## 10 · Backup automatici  
_Fase 10 VM APP_

Gestiti da **`bdus backup`** (in `bdus-ops`). Cosa contiene cosa: app **sqlite** → tutto nel tar di `projects_data` (`<progetto>-files-<ts>.tar.gz`); app **pgsql** → i database + ruoli in `<progetto>-pgall-<ts>.sql.gz` (`pg_dumpall` via il superuser `bdus`), i file/config/`.jwt_secret` nel tar. `bdus backup` sceglie la strategia per istanza, tiene gli ultimi `BACKUP_RETENTION`, e fa l'rsync off-box se `BACKUP_RSYNC_TARGET` è settato in `config.env`.

```bash
bdus backup all            # o: bdus backup prod  /  bdus backup demo
```

Cron (il repo ha il sample):

```bash
sudo cp /srv/bradypus/ops/etc/cron.d/bdus-backup /etc/cron.d/bdus-backup
# nel file: l'utente della riga cron dev'essere 'debian' (chi possiede il deploy), non root
```

> **Se vieni dalla vecchia procedura** (script `/usr/local/sbin/bradypus-backup*.sh` + `/etc/cron.d/bradypus-backup`): gli archivi hanno lo stesso nome/formato, quindi sono compatibili. Ritira i vecchi:
> ```bash
> sudo rm -f /usr/local/sbin/bradypus-backup.sh /usr/local/sbin/bradypus-backup-prod.sh /etc/cron.d/bradypus-backup
> ```

> **Attenzione** — `.jwt_secret` **e** (per app pgsql) la password del ruolo in chiaro in `config.json` sono negli archivi: proteggi la destinazione come dato sensibile.

**Restore**: `bdus restore <prod|demo>` (ferma `api` → ripristina l'ultimo backup, pgall + tar per prod → riavvia `api`). DR completo su volume Postgres fresco: `bdus init prod` e poi `bdus restore prod`.

## 11 · Verifica finale sulla VM app  
_Fase 11 VM APP_

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'   # postgres = healthy
docker network ls | grep bradypus-net    # bdus-prod_bradypus-net, bdus-demo_bradypus-net
docker volume ls  | grep -E 'projects_data|pgdata'
sudo iptables -S DOCKER-USER

# Postgres solo su rete interna (nessuna porta pubblicata)
( cd /srv/bradypus/prod && docker compose exec -T postgres pg_isready -U bdus )

# dalla VM app rispondono entrambe:
curl -sS -o /dev/null -w 'prod %{http_code}\n' http://192.168.4.39:8081/
curl -sS -o /dev/null -w 'demo %{http_code}\n' http://192.168.4.39:8082/
# da QUALSIASI host diverso dal proxy, 8081/8082 devono rifiutare/andare in timeout
```

## 12 · rate-limit + vhost minimi (:80, ACME)  
_Fase 12 VM PROXY_

BraDypUS non ha throttling sul login: il `limit_req` lo mette il proxy. `X-Forwarded-Proto https` è obbligatorio (in 5.4.5 l'OAuth dietro proxy ne dipende). Gli header `X-Content-Type-Options`/`X-Frame-Options`/`Referrer-Policy` li imposta già il frontend: qui basta HSTS. I file vhost su questo host **non** hanno estensione `.conf`.

> **Perché** — Un **reverse proxy** termina la connessione del client e ne apre una nuova verso il backend: il browser parla HTTPS col proxy, il proxy parla HTTP col container BraDypUS sulla rete privata. Il backend vede solo la connessione interna, quindi il proxy gli passa il contesto reale via header:
> - `Host $host` — l'hostname che il client ha digitato; BraDypUS lo usa per costruire URL assoluti (es. `redirect_uri` OAuth).
> - `X-Forwarded-Proto https` — "il client è su HTTPS"; senza, BraDypUS si crede in chiaro e genera link/redirect `http://`.
> - `X-Real-IP` / `X-Forwarded-For` — l'IP vero del client, altrimenti nei log c'è solo l'IP del proxy.
> `limit_req_zone` definisce un "secchiello" per IP (`rate=20r/s`, memoria `10m` ≈ 160k IP); `limit_req … burst=40 nodelay` lo applica: ~20 req/s di media, riserva di 40 per i picchi, oltre → `503`.
 I vhost minimi in `:80` servono solo a far passare la **challenge ACME** (Fase 13): Let's Encrypt verifica che controlli il dominio chiedendo a nginx di servire un token sotto `/.well-known/acme-challenge/` sulla porta 80.

```bash
echo 'limit_req_zone $binary_remote_addr zone=bdus_api:10m rate=20r/s;' \
  | sudo tee /etc/nginx/conf.d/bdus-limit.conf

for row in "prod bdus.lad-sapienza.it 8081" "demo demo.bdus.lad-sapienza.it 8082"; do
  set -- $row
  sudo tee /etc/nginx/sites-available/bdus-$1 >/dev/null <<EOF
server {
    listen 80;
    server_name $2;
    location / {
        proxy_pass http://192.168.4.39:$3;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Proto https;
    }
}
EOF
  sudo ln -sf /etc/nginx/sites-available/bdus-$1 /etc/nginx/sites-enabled/
done
sudo nginx -t && sudo systemctl reload nginx
```

## 13 · Certificati TLS (certbot `--nginx`) + vhost finali  
_Fase 13 VM PROXY_

Prerequisito: i due nomi risolvono già all'IP pubblico del proxy e la :80 è aperta. Un **unico cert SAN** per entrambi (lineage `bdus.lad-sapienza.it`).

> **Perché** — Let's Encrypt è una CA gratuita e automatica: certbot le chiede un certificato per i tuoi domini e prova il controllo servendo un token via HTTP (challenge `http-01`).
> - `certbot --nginx` (quello che hai usato): il plugin **modifica i tuoi vhost** aggiungendo i blocchi `:443` e il redirect. `certbot certonly` prende solo il certificato e non tocca la config.
> - **Certificato SAN**: con `-d nome1 -d nome2` ottieni **un solo** certificato valido per entrambi (lineage col nome del primo `-d`) → le due vhost puntano allo stesso path.
> - `/etc/letsencrypt/live/<lineage>/`: `fullchain.pem` = foglia + intermedi (quello che nginx serve), `privkey.pem` = chiave privata (0600), `options-ssl-nginx.conf` = parametri TLS moderni forniti da certbot, `ssl-dhparams.pem` = parametri Diffie-Hellman.
> - **Rinnovo**: certbot installa un timer systemd (`certbot.timer`, 2×/giorno) che rinnova quando restano <30 giorni. `certbot renew --dry-run` simula il rinnovo per verificare che la config regga.
> - **HSTS** (`Strict-Transport-Security`): dice al browser "d'ora in poi solo HTTPS per questo dominio" — blocca i downgrade a HTTP.
> - `listen 443 ssl http2;`: `http2` come parametro di `listen` funziona ovunque; `http2 on;` (riga separata) solo da nginx 1.25.1.

```bash
sudo apt-get install -y certbot python3-certbot-nginx
sudo certbot --nginx -d bdus.lad-sapienza.it -d demo.bdus.lad-sapienza.it
sudo certbot certificates      # 1 cert, Domains: bdus… demo.bdus…
```

`certbot --nginx` inietta i blocchi `:443` + il redirect. Ora **sostituisci** i due file con la versione finale, tenendo le 4 righe `# managed by Certbot`. Entrambe le vhost puntano allo **stesso** path `live/bdus.lad-sapienza.it/`.

_/etc/nginx/sites-available/bdus-prod_

```bash
sudo tee /etc/nginx/sites-available/bdus-prod >/dev/null <<'EOF'
server {
    listen 80;
    server_name bdus.lad-sapienza.it;
    return 301 https://$host$request_uri;
}
server {
    listen 443 ssl http2;                 # 'http2 on;' solo su nginx >= 1.25.1
    server_name bdus.lad-sapienza.it;

    ssl_certificate /etc/letsencrypt/live/bdus.lad-sapienza.it/fullchain.pem; # managed by Certbot
    ssl_certificate_key /etc/letsencrypt/live/bdus.lad-sapienza.it/privkey.pem; # managed by Certbot
    include /etc/letsencrypt/options-ssl-nginx.conf; # managed by Certbot
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem; # managed by Certbot

    add_header Strict-Transport-Security "max-age=31536000" always;
    client_max_body_size 100m;            # >= post_max_size (72M) del PHP

    location /api/ {
        limit_req zone=bdus_api burst=40 nodelay;
        proxy_pass http://192.168.4.39:8081;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 120s;
    }
    location / {
        proxy_pass http://192.168.4.39:8081;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 120s;
    }
}
EOF
```

_/etc/nginx/sites-available/bdus-demo_

```bash
sudo tee /etc/nginx/sites-available/bdus-demo >/dev/null <<'EOF'
server {
    listen 80;
    server_name demo.bdus.lad-sapienza.it;
    return 301 https://$host$request_uri;
}
server {
    listen 443 ssl http2;
    server_name demo.bdus.lad-sapienza.it;

    ssl_certificate /etc/letsencrypt/live/bdus.lad-sapienza.it/fullchain.pem; # managed by Certbot
    ssl_certificate_key /etc/letsencrypt/live/bdus.lad-sapienza.it/privkey.pem; # managed by Certbot
    include /etc/letsencrypt/options-ssl-nginx.conf; # managed by Certbot
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem; # managed by Certbot

    add_header Strict-Transport-Security "max-age=31536000" always;
    client_max_body_size 100m;

    location /api/ {
        limit_req zone=bdus_api burst=40 nodelay;
        proxy_pass http://192.168.4.39:8082;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 120s;
    }
    location / {
        proxy_pass http://192.168.4.39:8082;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 120s;
    }
}
EOF
sudo nginx -t && sudo systemctl reload nginx
sudo certbot renew --dry-run
```

## 14 · Test end-to-end  
_Fase 14 VM PROXY_

```bash
curl -sSI https://bdus.lad-sapienza.it/ | grep -Ei 'http/|strict-transport|x-frame|x-content'
curl -sS 'https://bdus.lad-sapienza.it/api/new-app/status'; echo       # prod
curl -sS 'https://demo.bdus.lad-sapienza.it/api/new-app/status'; echo  # demo → "permitted":true
```

Nel browser: login su prod, nessun avviso mixed-content, upload di un file > 2 MB a buon fine, vista *Info/Changelog* popolata, e (se configurato) login OAuth che torna su `https://`.

## 15 · Aggiornare BraDypUS  
_Fase 15 ESERCIZIO_

```bash
bdus update all 5.5.0
```

`bdus update` fa tutto in ordine: verifica che il tag esista su GHCR → **demo prima**, health check, conferma → **backup di prod** → `sed .env` + `pull` + `up -d` → poll health; se prod non torna su, ripristina il pin `.env` (il DB **non** viene rollbackato: le migrazioni per la nuova versione potrebbero essere già girate — in quel caso `bdus restore prod`).

> **Attenzione** — Al primo request dopo un cambio di versione BraDypUS esegue le **migrazioni** del DB (per ogni app). `bdus update` fa il backup di prod *prima* dell'`up -d` automaticamente; se aggiorni a mano, fallo tu.

## + · Aggiungere un'app (sqlite o pgsql)  
_Ricorrente ESERCIZIO_

Poco frequente. Da 5.4.7 la creazione HTTP richiede **sempre** `ALLOW_NEW_APP=1`, ma `add-app.sh` (immagine ≥ 5.4.6, isolamento ruolo da 5.4.8) non apre nessuna finestra.

**Consigliato — `bdus app add`** (avvolge `add-app.sh`):

```bash
bdus app add prod --name siti_scavo --engine pgsql --email admin@lad-sapienza.it
# sqlite:  --engine sqlite   (niente credenziali DB)
```

Per pgsql provisiona, come superuser `bdus` (che resta solo per ops/backup):

```
CREATE ROLE "siti_scavo" LOGIN PASSWORD <generata>   -- niente superuser/createdb
CREATE DATABASE "siti_scavo" OWNER "siti_scavo"
REVOKE CONNECT ON DATABASE "siti_scavo" FROM PUBLIC;  GRANT CONNECT ... TO "siti_scavo"
```

poi `bin/create-app.php` dentro `api` con quel ruolo (password DB via env, mai in `ps`; password admin da prompt nascosto o `--password-stdin`). La password del ruolo è stampata una volta e finisce solo in `projects/siti_scavo/config.json`. `--db-name` per cambiare il nome del DB; `--db-user <ruolo-esistente>` (+ `BDUS_DB_PASS`) per riusare un ruolo che gestisci a mano. Rifiuta se app/ruolo/DB esistono già.

**Alternativa — wizard (con finestra)** — usare `add-app.sh` è meglio; se proprio serve il wizard, prepara **a mano** ruolo+DB isolati prima:

```bash
cd /srv/bradypus/prod
docker compose exec postgres psql -U bdus -d postgres <<'SQL'
CREATE ROLE "NOMEAPP" LOGIN PASSWORD 'scegli-una-password';
CREATE DATABASE "NOMEAPP" OWNER "NOMEAPP";
REVOKE CONNECT ON DATABASE "NOMEAPP" FROM PUBLIC;
GRANT  CONNECT ON DATABASE "NOMEAPP" TO "NOMEAPP";
SQL

sed -i 's/^BRADYPUS_ALLOW_NEW_APP=0/BRADYPUS_ALLOW_NEW_APP=1/' .env
docker compose up -d
# wizard: Engine=PostgreSQL · Host=postgres · Port=5432 · DB=NOMEAPP · User=NOMEAPP · Password=<quella scelta>
sed -i 's/^BRADYPUS_ALLOW_NEW_APP=1/BRADYPUS_ALLOW_NEW_APP=0/' .env
docker compose up -d
```

> **Backup & rimozione** — `bdus backup` copre la nuova app senza modifiche (sqlite → nel tar; pgsql → in `pg_dumpall`, che dumpa ruoli inclusi) — fai un backup manuale subito dopo. Eliminando un'app pgsql dalla UI restano DB e ruolo: `docker compose exec postgres psql -U bdus -c 'DROP DATABASE IF EXISTS "NOMEAPP"; DROP ROLE IF EXISTS "NOMEAPP";'`

## 16 · Restore e note operative  
_Fase 16 ESERCIZIO_

```bash
bdus restore prod            # ultimo backup: pgall + tar. Chiede conferma.
bdus restore demo            # solo tar. --db F / --files F per un archivio preciso.
```

Ferma `api` → ripristina → riavvia `api` → attende health. DR completo su volume Postgres nuovo: `bdus init prod` e poi `bdus restore prod`. I file non presenti nell'archivio restano; il restore Postgres ricrea i database come dumpati.

- `bdus logs prod -f` — log in diretta (capped a 10m×3 dal `daemon.json`).
- `docker compose down` conserva il volume · `down -v` lo **distrugge**: mai su prod.
- `seed-demo.sh` (dataset dimostrativo) richiede il repo clonato e `BASE_URL` puntato a `http://192.168.4.39:8082`; funziona perché la demo ha `ALLOW_NEW_APP=1`.
- Revoca sessioni di un utente: endpoint `revokeToken` lato app (incrementa `token_version`) — non serve toccare i container.

---

_BraDypUS v5.4.8 · runbook aggiornato il 2026-09-02 · immagini ghcr.io/lad-sapienza/bdus-api · bdus-app_

