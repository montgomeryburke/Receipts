#!/usr/bin/env bash
# =============================================================================
#  NAS Uploader — server setup for a Proxmox LXC container (Debian / Ubuntu)
# =============================================================================
#  Run this as root INSIDE the container that holds your media — the one
#  Jellyfin reads its libraries from (Proxmox web UI → the container → Console).
#
#  It installs a WebDAV server (Apache) for the folder Jellyfin uses, makes sure
#  uploads stay readable by Jellyfin, makes it reachable from outside your home,
#  and prints the exact settings to paste into the extension's config.js.
#
#    bash setup-webdav.sh                       # asks a few questions
#    bash setup-webdav.sh --access funnel       # Tailscale Funnel: no router changes
#    bash setup-webdav.sh --access port-forward --domain NAME.duckdns.org \
#         --email you@example.com --duckdns-token TOKEN
#    bash setup-webdav.sh --access local        # home network only (self-signed HTTPS)
#    bash setup-webdav.sh --uninstall           # remove (your files are never touched)
#
#  Other options:
#    --folder PATH        folder to share, e.g. /mnt/mirror for a drive added just for this
#                         (default: offers Jellyfin's library folder and other mounted drives)
#    --user NAME          WebDAV username (default: uploader)
#    --password PASS      password (default: keep the existing one, or generate one)
#    --port N             HTTPS port for local/port-forward (default 443)
#    --access proxy --public-url https://files.example.com/
#                         behind your own reverse proxy (Nginx Proxy Manager, Caddy…)
#    --local-port N       plain-HTTP port Apache uses behind Funnel / a proxy (default 8090)
#    --yes                don't ask questions; use defaults
#
#  Safe to run again (e.g. to change the password or the folder).
# =============================================================================
set -euo pipefail

FOLDER=""
WEB_USER="uploader"
WEB_PASS=""
ACCESS=""
DOMAIN=""
EMAIL=""
DUCKDNS_TOKEN=""
PORT="443"
LOCAL_PORT="8090"
PUBLIC_URL=""
ASSUME_YES=0
UNINSTALL=0
SKIP_TAILSCALE=0 # for testing the Apache side of Funnel mode without Tailscale

SITE=/etc/apache2/sites-available/nas-uploader.conf
HTPASSWD=/etc/apache2/nas-uploader.htpasswd
STATE_DIR=/etc/nas-uploader
LOCK_DIR=/var/lib/nas-uploader
CERT_DIR=/etc/ssl/nas-uploader
SUMMARY=/root/nas-uploader-settings.txt

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m !\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m ✗ %s\033[0m\n' "$*" >&2; exit 1; }

usage() {
  if [[ -f "$0" ]]; then sed -n '2,32p' "$0" | sed 's/^#  \{0,1\}//'; else echo "See the comments at the top of setup-webdav.sh for options."; fi
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --folder) FOLDER="${2:?}"; shift 2 ;;
    --user) WEB_USER="${2:?}"; shift 2 ;;
    --password) WEB_PASS="${2:?}"; shift 2 ;;
    --access) ACCESS="${2:?}"; shift 2 ;;
    --domain) DOMAIN="${2:?}"; shift 2 ;;
    --email) EMAIL="${2:?}"; shift 2 ;;
    --duckdns-token) DUCKDNS_TOKEN="${2:?}"; shift 2 ;;
    --port) PORT="${2:?}"; shift 2 ;;
    --local-port) LOCAL_PORT="${2:?}"; shift 2 ;;
    --public-url) PUBLIC_URL="${2:?}"; shift 2 ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --skip-tailscale) SKIP_TAILSCALE=1; shift ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 2 ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Run this as root (in the Proxmox container console you already are root)."
command -v apt-get >/dev/null || die "This script supports Debian/Ubuntu containers (apt-get not found)."

ask() { # ask "question" default -> echoes answer
  local q="$1" def="${2:-}" a
  if [[ $ASSUME_YES -eq 1 ]]; then echo "$def"; return; fi
  read -r -p "$q${def:+ [$def]}: " a </dev/tty || true
  echo "${a:-$def}"
}
confirm() { # confirm "question" -> 0 if yes
  [[ $ASSUME_YES -eq 1 ]] && return 0
  local a; read -r -p "$1 [Y/n]: " a </dev/tty || true
  [[ -z "$a" || "$a" =~ ^[Yy] ]]
}

have_systemd() { [[ -d /run/systemd/system ]]; }
apache_reload() {
  apache2ctl configtest >/dev/null 2>&1 || { apache2ctl configtest; die "Apache configuration test failed (see above)."; }
  if have_systemd; then
    systemctl enable apache2 >/dev/null 2>&1 || true
    systemctl restart apache2
  else
    apache2ctl -k stop >/dev/null 2>&1 || true
    sleep 1
    apache2ctl -k start
  fi
}

# ----------------------------------------------------------------------------- uninstall
if [[ $UNINSTALL -eq 1 ]]; then
  say "Removing the NAS Uploader server (your files are not touched)"
  a2dissite nas-uploader >/dev/null 2>&1 || true
  rm -f "$SITE" "$HTPASSWD" /etc/cron.d/nas-uploader-duckdns /usr/local/sbin/nas-uploader-duckdns
  if [[ -f "$STATE_DIR/envvars.backup" ]]; then cp "$STATE_DIR/envvars.backup" /etc/apache2/envvars; fi
  if command -v tailscale >/dev/null && [[ -f "$STATE_DIR/funnel" ]]; then
    tailscale funnel --https=443 off >/dev/null 2>&1 || tailscale funnel reset >/dev/null 2>&1 || true
  fi
  rm -rf "$STATE_DIR"
  apache_reload || true
  ok "Removed. Apache itself is still installed (apt-get remove apache2 to remove it too)."
  exit 0
fi

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

# ----------------------------------------------------------------------------- 1. which folder
say "Looking for the folder Jellyfin uses"
declare -a CANDIDATES=()
JELLYFIN_HERE=0
if [[ -d /var/lib/jellyfin ]] || id jellyfin >/dev/null 2>&1; then JELLYFIN_HERE=1; fi

common_parent() { # common_parent path... -> longest shared directory
  local first="$1"; shift
  local prefix="$first"
  for p in "$@"; do
    while [[ "$p/" != "$prefix/"* ]]; do prefix="${prefix%/*}"; [[ -z "$prefix" ]] && { echo "/"; return; }; done
  done
  echo "$prefix"
}

declare -a LIBS=()
if [[ -d /var/lib/jellyfin/root/default ]]; then
  while IFS= read -r p; do [[ -n "$p" && -d "$p" ]] && LIBS+=("$p"); done < <(
    { grep -ho '<Path>[^<]*</Path>' /var/lib/jellyfin/root/default/*/options.xml 2>/dev/null | sed 's/<\/\{0,1\}Path>//g'
      cat /var/lib/jellyfin/root/default/*/*.mblink 2>/dev/null; echo; } | sed '/^$/d' | sort -u)
fi
if [[ ${#LIBS[@]} -gt 0 ]]; then
  ok "Jellyfin libraries in this container: ${LIBS[*]}"
  parent="$(common_parent "${LIBS[@]}")"
  if [[ ${#LIBS[@]} -gt 1 && "$parent" != "/" ]]; then CANDIDATES+=("$parent"); fi
  CANDIDATES+=("${LIBS[@]}")
fi
# Proxmox mount points (mp0, mp1, …) show up as mounts; typical media locations too.
while IFS= read -r m; do
  [[ -d "$m" ]] && CANDIDATES+=("$m")
done < <(awk '$2 ~ "^/(mnt|media|srv|data|storage|tank)(/|$)" {print $2}' /proc/mounts 2>/dev/null | sort -u)
for d in /mnt/media /media /srv/media /data /mnt/data /mnt/storage; do [[ -d "$d" ]] && CANDIDATES+=("$d"); done
# de-duplicate, keep order
declare -A seen=(); declare -a UNIQUE=()
for c in "${CANDIDATES[@]}"; do [[ -z "${seen[$c]:-}" ]] && { seen[$c]=1; UNIQUE+=("$c"); }; done

if [[ -z "$FOLDER" ]]; then
  if [[ ${#UNIQUE[@]} -eq 0 ]]; then
    [[ $ASSUME_YES -eq 1 ]] && die "Couldn't find a media folder. Run again with --folder /path/to/media"
    FOLDER="$(ask 'Which folder should the uploader write into? (full path)')"
  else
    echo "Folders found:"
    for i in "${!UNIQUE[@]}"; do echo "  $((i + 1))) ${UNIQUE[$i]}"; done
    choice="$(ask 'Number of the folder to share, or type a path' 1)"
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#UNIQUE[@]} )); then FOLDER="${UNIQUE[$((choice - 1))]}"; else FOLDER="$choice"; fi
  fi
fi
FOLDER="$(realpath -m "$FOLDER")"
[[ -d "$FOLDER" ]] || die "$FOLDER does not exist (or isn't a folder) in this container."
[[ "$FOLDER" != "/" && "$FOLDER" != "/etc" && "$FOLDER" != "/root" && "$FOLDER" != "/var" ]] || die "Refusing to share $FOLDER."
ok "Sharing: $FOLDER"

# ----------------------------------------------------------------------------- 2. install
say "Installing Apache with WebDAV"
export DEBIAN_FRONTEND=noninteractive
FRESH_APACHE=0
dpkg -s apache2 >/dev/null 2>&1 || FRESH_APACHE=1
PKGS=(apache2 apache2-utils openssl curl ca-certificates acl)
missing=()
for p in "${PKGS[@]}"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
if [[ ${#missing[@]} -gt 0 ]]; then
  apt-get update -qq
  apt-get install -y -qq "${missing[@]}" >/dev/null
fi
a2enmod -q dav dav_fs auth_basic authn_file headers ssl >/dev/null
# Silence Apache's "could not determine the server's fully qualified domain name" notice.
if ! grep -rqsE '^\s*ServerName\s' /etc/apache2/apache2.conf /etc/apache2/conf-enabled/; then
  echo 'ServerName localhost' > /etc/apache2/conf-available/nas-uploader-servername.conf
  a2enconf -q nas-uploader-servername >/dev/null
fi
# A freshly installed Apache only serves Debian's placeholder page; switch that off.
if [[ $FRESH_APACHE -eq 1 ]]; then a2dissite -q 000-default >/dev/null 2>&1 || true; fi
ok "Apache installed"

# ----------------------------------------------------------------------------- 3. permissions
say "Checking that uploads can be written to $FOLDER"
owner_uid="$(stat -c %u "$FOLDER")"
owner="$(stat -c %U "$FOLDER")"
group="$(stat -c %G "$FOLDER")"
if [[ "$owner_uid" == "65534" || "$owner" == "nobody" ]]; then
  cat >&2 <<EOF

  ✗ Inside this container, $FOLDER belongs to "nobody".

  That happens with an *unprivileged* Proxmox container whose media folder is owned on
  the Proxmox host by a user the container can't see, so nothing in here can write to it.
  Fix it once on the Proxmox HOST (not in this container), then run this script again:

    1. Find the host path of the folder:      pct config <CTID> | grep mp
    2. Give it to this container's users:      chown -R 100000:100000 /host/path/to/media
       (100000 = root inside an unprivileged container; Jellyfin and this uploader can then
        both read it, and this script will grant write access)

EOF
  exit 1
fi

RUN_USER="www-data"
RUN_GROUP="www-data"
as_user() { setpriv --reuid="$1" --regid="$(id -g "$1")" --init-groups -- "${@:2}"; }
can_write() { as_user "$1" sh -c "touch '$FOLDER/.nas-uploader-test' && rm -f '$FOLDER/.nas-uploader-test'" 2>/dev/null; }

if [[ "$owner_uid" != "0" ]] && id "$owner" >/dev/null 2>&1; then
  # Run the WebDAV server as the folder's owner, so uploads look exactly like the files already there.
  RUN_USER="$owner"
  RUN_GROUP="$group"
  can_write "$RUN_USER" || die "$owner owns $FOLDER but can't write to it (check its permissions: ls -ld '$FOLDER')."
  ok "Uploads will be owned by $owner:$group, like the existing files"
elif can_write www-data; then
  ok "The web server can already write here"
else
  # Root-owned media folder: give the web server write access to the folders (not the files) with ACLs.
  say "Granting the web server write access to the folders in $FOLDER (file contents are not changed)"
  if find "$FOLDER" -type d -exec setfacl -m u:www-data:rwx -m d:u:www-data:rwx {} + 2>/dev/null && can_write www-data; then
    ok "Write access granted with ACLs"
  else
    warn "This filesystem doesn't support ACLs (common for ZFS datasets with acltype=off)."
    if confirm "Make the group 'www-data' co-own the FOLDERS in $FOLDER (chgrp + group write; files untouched)?"; then
      find "$FOLDER" -type d -exec chgrp www-data {} + -exec chmod g+rwxs {} +
      can_write www-data || die "Still can't write to $FOLDER. Check its permissions on the Proxmox host."
      ok "Write access granted via the www-data group"
    else
      die "No write access to $FOLDER. Re-run when you're ready, or pick another folder with --folder."
    fi
  fi
fi

if [[ ! -f "$STATE_DIR/envvars.backup" ]]; then cp /etc/apache2/envvars "$STATE_DIR/envvars.backup"; fi
sed -i -E "s/^export APACHE_RUN_USER=.*/export APACHE_RUN_USER=$RUN_USER/; s/^export APACHE_RUN_GROUP=.*/export APACHE_RUN_GROUP=$RUN_GROUP/" /etc/apache2/envvars
mkdir -p "$LOCK_DIR" /var/lock/apache2
# The WebDAV lock database only holds short-lived locks; start it fresh if the server's user changed.
if [[ "$(cat "$STATE_DIR/run-user" 2>/dev/null)" != "$RUN_USER" ]]; then rm -f "$LOCK_DIR"/DavLock*; fi
echo "$RUN_USER" > "$STATE_DIR/run-user"
chown -R "$RUN_USER:$RUN_GROUP" "$LOCK_DIR" /var/lock/apache2

# Subfolders the web server can't write to (e.g. owned by someone else) are worth knowing about.
unwritable=()
while IFS= read -r -d '' d; do
  as_user "$RUN_USER" test -w "$d" 2>/dev/null || unwritable+=("$d")
done < <(find "$FOLDER" -mindepth 1 -maxdepth 1 -type d ! -name lost+found -print0 2>/dev/null)
if [[ ${#unwritable[@]} -gt 0 ]]; then warn "Not writable by the uploader (uploads into these will fail): ${unwritable[*]}"; fi

# ----------------------------------------------------------------------------- 4. credentials
say "Setting up the login"
if [[ -z "$WEB_PASS" && -f "$HTPASSWD" ]] && grep -q "^$WEB_USER:" "$HTPASSWD" && [[ -f "$STATE_DIR/password" ]]; then
  WEB_PASS="$(cat "$STATE_DIR/password")"
  ok "Keeping the existing password for $WEB_USER"
else
  if [[ -z "$WEB_PASS" ]]; then
    WEB_PASS="$(tr -dc 'A-HJ-NP-Za-km-z2-9' </dev/urandom | head -c 20)"
  fi
  htpasswd -iBc "$HTPASSWD" "$WEB_USER" <<<"$WEB_PASS" >/dev/null 2>&1
  printf '%s' "$WEB_PASS" > "$STATE_DIR/password"
  ok "User $WEB_USER created"
fi
chown "root:$RUN_GROUP" "$HTPASSWD"
chmod 640 "$HTPASSWD"
chmod 600 "$STATE_DIR/password"

# ----------------------------------------------------------------------------- 5. how to reach it
if [[ -z "$ACCESS" ]]; then
  if [[ -n "$PUBLIC_URL" ]]; then ACCESS=proxy
  elif [[ $ASSUME_YES -eq 1 ]]; then ACCESS=local
  else
    cat <<'EOF'

How should the offsite computer reach this? (With every choice, the offsite computer
needs nothing but Chrome and the extension. Nothing gets installed there.)
  1) Port forward on your router + free DuckDNS name + Let's Encrypt certificate.
     Fastest, best for very large mirrors. Needs access to your router (ports 443 and 80).
  2) Tailscale Funnel: Tailscale runs on THIS machine only and publishes a normal
     https:// address. No router changes. Tailscale limits the speed somewhat.
  3) Home network only for now (self-signed certificate). You can re-run later.
EOF
    case "$(ask 'Choose 1, 2 or 3' 1)" in
      1) ACCESS=port-forward ;;
      2) ACCESS=funnel ;;
      *) ACCESS=local ;;
    esac
  fi
fi
case "$ACCESS" in funnel|port-forward|local|proxy) ;; *) die "--access must be funnel, port-forward, local or proxy";; esac

LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
LAN_IP="${LAN_IP:-127.0.0.1}"
CERT=""
KEY=""

self_signed() {
  mkdir -p "$CERT_DIR"
  local cn="${DOMAIN:-$LAN_IP}"
  if [[ ! -f "$CERT_DIR/cert.pem" ]] || ! openssl x509 -in "$CERT_DIR/cert.pem" -noout -text | grep -q "$cn"; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$cn" \
      -addext "subjectAltName=DNS:${DOMAIN:-localhost},DNS:localhost,IP:$LAN_IP,IP:127.0.0.1" \
      -addext "basicConstraints=critical,CA:FALSE" -addext "extendedKeyUsage=serverAuth" \
      -keyout "$CERT_DIR/key.pem" -out "$CERT_DIR/cert.pem" >/dev/null 2>&1
    chmod 600 "$CERT_DIR/key.pem"
  fi
  CERT="$CERT_DIR/cert.pem"
  KEY="$CERT_DIR/key.pem"
}

if [[ "$ACCESS" == "funnel" ]]; then
  if [[ $SKIP_TAILSCALE -eq 0 ]]; then
    say "Setting up Tailscale Funnel"
    if ! command -v tailscale >/dev/null; then
      curl -fsSL https://tailscale.com/install.sh | sh
    fi
    if [[ ! -c /dev/net/tun ]]; then
      # Unprivileged containers usually have no TUN device; Funnel works fine in userspace mode.
      warn "No /dev/net/tun in this container: running Tailscale in userspace mode (fine for Funnel)."
      if [[ -f /etc/default/tailscaled ]] && ! grep -q 'userspace-networking' /etc/default/tailscaled; then
        sed -i -E 's/^FLAGS="(.*)"/FLAGS="\1 --tun=userspace-networking"/' /etc/default/tailscaled
      fi
    fi
    if have_systemd; then systemctl enable --now tailscaled >/dev/null 2>&1 || true; systemctl restart tailscaled; fi
    if ! tailscale status >/dev/null 2>&1; then
      say "Sign this container in to your Tailscale account: open the link below on any device."
      tailscale up
    fi
    TS_NAME="$(tailscale status --json --peers=false 2>/dev/null | sed -n 's/.*"DNSName": *"\([^"]*\)".*/\1/p' | head -1)"
    TS_NAME="${TS_NAME%.}"
    [[ -n "$TS_NAME" ]] || die "Couldn't read this machine's Tailscale name (tailscale status)."
    PUBLIC_URL="https://$TS_NAME/"
  else
    [[ -n "$PUBLIC_URL" ]] || die "--skip-tailscale needs --public-url"
  fi
elif [[ "$ACCESS" == "port-forward" ]]; then
  [[ -n "$DOMAIN" ]] || DOMAIN="$(ask 'Public name for your home (e.g. myhome.duckdns.org)')"
  [[ -n "$DOMAIN" ]] || die "port-forward needs a name (--domain). Get a free one at https://www.duckdns.org"
  if [[ "$DOMAIN" == *.duckdns.org && -z "$DUCKDNS_TOKEN" ]]; then
    DUCKDNS_TOKEN="$(ask 'DuckDNS token (from duckdns.org, keeps the name pointing at your home; Enter to skip)')"
  fi
  if [[ -n "$DUCKDNS_TOKEN" ]]; then
    say "Keeping $DOMAIN pointed at your home's internet address (DuckDNS, every 5 minutes)"
    sub="${DOMAIN%.duckdns.org}"
    printf 'DOMAIN=%s\nTOKEN=%s\n' "$sub" "$DUCKDNS_TOKEN" > "$STATE_DIR/duckdns.env"
    chmod 600 "$STATE_DIR/duckdns.env"
    cat > /usr/local/sbin/nas-uploader-duckdns <<'EOF'
#!/bin/sh
. /etc/nas-uploader/duckdns.env
curl -fsS --max-time 30 "https://www.duckdns.org/update?domains=$DOMAIN&token=$TOKEN&ip="
EOF
    chmod 700 /usr/local/sbin/nas-uploader-duckdns
    echo '*/5 * * * * root /usr/local/sbin/nas-uploader-duckdns >/dev/null 2>&1' > /etc/cron.d/nas-uploader-duckdns
    if [[ "$(/usr/local/sbin/nas-uploader-duckdns 2>/dev/null || true)" == OK* ]]; then ok "DuckDNS updated"; else warn "DuckDNS update failed. Check the token at duckdns.org."; fi
  fi
  PUBLIC_URL="https://$DOMAIN$([[ "$PORT" != 443 ]] && echo ":$PORT")/"
elif [[ "$ACCESS" == "proxy" ]]; then
  [[ -n "$PUBLIC_URL" ]] || die "--access proxy needs --public-url https://your.address/"
else
  PUBLIC_URL="https://$LAN_IP$([[ "$PORT" != 443 ]] && echo ":$PORT")/"
fi
PUBLIC_URL="${PUBLIC_URL%/}/"

# ----------------------------------------------------------------------------- 6. Apache site
say "Writing the web server configuration"
COMMON=$(cat <<EOF
    DocumentRoot "$FOLDER"
    DavLockDB "$LOCK_DIR/DavLock"
    # No upload size limit (Apache 2.4.54+ otherwise stops at 1 GB), and patience for slow links.
    LimitRequestBody 0
    Timeout 600
    <Directory "$FOLDER">
        Dav On
        Options None
        AllowOverride None
        <IfModule mod_dir.c>
            DirectorySlash Off
        </IfModule>
        AuthType Basic
        AuthName "NAS Uploader"
        AuthBasicProvider file
        AuthUserFile "$HTPASSWD"
        Require valid-user
        # Never run anything that gets uploaded.
        <IfModule mod_mime.c>
            RemoveHandler .php .phtml .cgi .pl .py .sh
        </IfModule>
        <IfModule php_module>
            php_admin_flag engine off
        </IfModule>
        <IfModule php7_module>
            php_admin_flag engine off
        </IfModule>
    </Directory>
    ErrorLog \${APACHE_LOG_DIR}/nas-uploader-error.log
    CustomLog \${APACHE_LOG_DIR}/nas-uploader-access.log combined
EOF
)

if [[ "$ACCESS" == "funnel" || "$ACCESS" == "proxy" ]]; then
  # Behind Tailscale / a reverse proxy, Apache speaks plain HTTP on localhost. Telling it its public https://
  # address keeps redirects and WebDAV renames (MOVE) working.
  pu="${PUBLIC_URL%/}"
  pu_host="${pu#https://}"; pu_host="${pu_host#http://}"
  [[ "$pu_host" == *:* ]] || pu_host="$pu_host:$([[ "$pu" == https://* ]] && echo 443 || echo 80)"
  scheme="${pu%%://*}"
  LISTEN_ADDR="127.0.0.1:$LOCAL_PORT"
  [[ "$ACCESS" == "proxy" ]] && LISTEN_ADDR="0.0.0.0:$LOCAL_PORT"
  cat > "$SITE" <<EOF
# Managed by NAS Uploader setup-webdav.sh. Re-run the script instead of editing.
Listen $LISTEN_ADDR
<VirtualHost $LISTEN_ADDR>
    ServerName $scheme://$pu_host
    UseCanonicalName On
$COMMON
</VirtualHost>
EOF
else
  if [[ "$ACCESS" == "port-forward" ]]; then
    say "Getting a free Let's Encrypt certificate for $DOMAIN (needs port 80 forwarded to $LAN_IP)"
    dpkg -s certbot >/dev/null 2>&1 || apt-get install -y -qq certbot python3-certbot-apache >/dev/null
    a2ensite -q 000-default >/dev/null 2>&1 || true
    apache_reload
    if certbot certonly --apache -d "$DOMAIN" --non-interactive --agree-tos ${EMAIL:+-m "$EMAIL"} ${EMAIL:---register-unsafely-without-email} \
        --deploy-hook "apache2ctl -k graceful" >/dev/null 2>&1; then
      CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
      KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
      ok "Certificate issued (renews automatically)"
    else
      warn "Let's Encrypt failed. Is TCP port 80 forwarded from your router to $LAN_IP, and does $DOMAIN point at your home?"
      warn "Using a self-signed certificate for now; just run this script again once the port forward works."
      self_signed
    fi
  else
    self_signed
  fi
  LISTEN_LINE=""
  if ! grep -qE "^\s*Listen\s+$PORT\b" /etc/apache2/ports.conf; then LISTEN_LINE="Listen $PORT"; fi
  HTTP_VHOST=""
  if [[ "$ACCESS" == "port-forward" ]]; then
    # Port 80 only redirects to HTTPS, except for Let's Encrypt's renewal checks.
    a2dissite -q 000-default >/dev/null 2>&1 || true
    HTTP_VHOST="<VirtualHost *:80>
    ServerName $DOMAIN
    RedirectMatch 301 ^/(?!\.well-known/acme-challenge/)(.*)\$ ${PUBLIC_URL}\$1
</VirtualHost>"
  fi
  cat > "$SITE" <<EOF
# Managed by NAS Uploader setup-webdav.sh. Re-run the script instead of editing.
$LISTEN_LINE
$HTTP_VHOST
<VirtualHost *:$PORT>
    ServerName ${DOMAIN:-$LAN_IP}
    ServerAlias localhost $LAN_IP
    SSLEngine on
    SSLCertificateFile "$CERT"
    SSLCertificateKeyFile "$KEY"
$COMMON
</VirtualHost>
EOF
fi
a2ensite -q nas-uploader >/dev/null
apache_reload
ok "Web server running"

if [[ "$ACCESS" == "funnel" && $SKIP_TAILSCALE -eq 0 ]]; then
  say "Publishing it on $PUBLIC_URL"
  tailscale funnel --bg --https=443 "http://127.0.0.1:$LOCAL_PORT" || die "Funnel didn't start. If it printed a link, open it to allow Funnel for this machine, then run this script again."
  touch "$STATE_DIR/funnel"
fi

# Brute-force protection when the server is directly on the internet.
if [[ "$ACCESS" == "port-forward" ]]; then
  if dpkg -s fail2ban >/dev/null 2>&1 || apt-get install -y -qq fail2ban >/dev/null 2>&1; then
    cat > /etc/fail2ban/jail.d/nas-uploader.conf <<'EOF'
[apache-auth]
enabled  = true
port     = http,https
logpath  = /var/log/apache2/nas-uploader-error.log
maxretry = 10
findtime = 10m
bantime  = 1h
EOF
    if fail2ban-client -t >/dev/null 2>&1; then
      { have_systemd && systemctl restart fail2ban; } || true
      ok "Failed logins are blocked after 10 tries (fail2ban)"
    else
      rm -f /etc/fail2ban/jail.d/nas-uploader.conf
      warn "fail2ban configuration test failed; skipped."
    fi
  fi
fi

# ----------------------------------------------------------------------------- 7. self-test
say "Testing"
if [[ "$ACCESS" == "funnel" || "$ACCESS" == "proxy" ]]; then TEST_URL="http://127.0.0.1:$LOCAL_PORT/"; else TEST_URL="https://127.0.0.1:$PORT/"; fi
code="$(curl -sk -o /dev/null -w '%{http_code}' -X PROPFIND -H 'Depth: 0' -u "$WEB_USER:$WEB_PASS" "$TEST_URL")"
[[ "$code" == 207 ]] || die "The server answered $code instead of 207. See /var/log/apache2/nas-uploader-error.log"
probe=".nas-uploader-selftest-$$.txt"
code="$(curl -sk -o /dev/null -w '%{http_code}' -T - -u "$WEB_USER:$WEB_PASS" "$TEST_URL$probe" <<<"self-test")"
[[ "$code" == 201 || "$code" == 204 ]] || die "Uploading a test file failed with $code. See /var/log/apache2/nas-uploader-error.log"
if [[ $JELLYFIN_HERE -eq 1 ]] && id jellyfin >/dev/null 2>&1; then
  if as_user jellyfin test -r "$FOLDER/$probe"; then ok "Jellyfin can read uploaded files"; else warn "The jellyfin user can't read uploaded files; check folder permissions."; fi
fi
curl -sk -o /dev/null -X DELETE -u "$WEB_USER:$WEB_PASS" "$TEST_URL$probe" || true
ok "Upload test passed"

# ----------------------------------------------------------------------------- 8. summary
{
  echo "NAS Uploader server settings ($(date))"
  echo "Folder shared: $FOLDER"
  echo "Access:        $ACCESS"
  echo
  echo "Paste this into config.js of the Chrome extension:"
  echo
  echo "  serverUrl: '$PUBLIC_URL',"
  echo "  username: '$WEB_USER',"
  echo "  password: '$WEB_PASS',"
  echo "  startFolder: '/',"
} > "$SUMMARY"
chmod 600 "$SUMMARY"

echo
echo "────────────────────────────────────────────────────────────────────"
cat "$SUMMARY"
echo "────────────────────────────────────────────────────────────────────"
echo "(Saved to $SUMMARY, readable only by root.)"
case "$ACCESS" in
  port-forward)
    echo
    echo "On your router, forward TCP ports 443 and 80 to $LAN_IP (this container)."
    echo "Give this container a fixed address in your router's DHCP settings so the forward keeps working." ;;
  local)
    echo
    echo "This only works on your home network. Run the script again with --access funnel or"
    echo "--access port-forward when you want to reach it from outside."
    echo "The certificate is self-signed: on each computer, click \"Open the NAS address in a tab\""
    echo "in the extension once and accept the warning." ;;
  funnel)
    echo
    echo "Reachable from anywhere at $PUBLIC_URL with a real certificate. No router changes needed." ;;
esac
if [[ $JELLYFIN_HERE -eq 1 ]]; then
  echo
  echo "Jellyfin: turn on \"Real time monitoring\" for your libraries (Dashboard → Libraries → … → Manage library)"
  echo "so uploads show up right away; otherwise they appear after the next library scan."
fi
