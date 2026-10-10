#!/usr/bin/env bash
# Starts the WebDAV test servers used by e2e.cjs. Requires apache2 (mod_dav) and python wsgidav.
#   :18081  Apache mod_dav, WebDAV at the root (like Synology / QNAP)
#   :18082  Apache mod_dav, WebDAV under "/my dav/" (base path with a space, like Nextcloud-style URLs)
#   :18083  WsgiDAV (a second, independent WebDAV implementation)
#   :18084  flaky proxy -> :18081 (injects 503s, dropped connections, 502s, permanent 403s)
#   :18085  throttling proxy -> :18081 (slow uploads, for pause/resume/cancel tests)
#   :18443  Apache mod_dav over HTTPS with a self-signed certificate (same data as :18081)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DATA="${NAS_TEST_DATA:-/var/tmp/nas-uploader-test}"
WSGIDAV="${WSGIDAV:-wsgidav}"
USER_NAME="nasuser"
PASSWORD="${NAS_TEST_PASSWORD:-pässwörd:with colon}"

"$HERE/stop-servers.sh" >/dev/null 2>&1 || true
rm -rf "$DATA"
mkdir -p "$DATA"/{root1,root2,root3,davlock,logs}
htpasswd -bc "$DATA/htpasswd" "$USER_NAME" "$PASSWORD" >/dev/null 2>&1
chown -R www-data:www-data "$DATA/root1" "$DATA/root2" "$DATA/davlock"
chmod 755 "$DATA"
chmod 644 "$DATA/htpasswd"
# Self-signed certificate, like many home NAS boxes use out of the box.
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$DATA/key.pem" -out "$DATA/cert.pem" -days 3 -subj "/CN=127.0.0.1" >/dev/null 2>&1

M=/usr/lib/apache2/modules
cat > "$DATA/apache.conf" <<CONF
ServerRoot "/etc/apache2"
ServerName localhost
PidFile "$DATA/apache.pid"
Listen 127.0.0.1:18081
Listen 127.0.0.1:18082
Listen 127.0.0.1:18443
LoadModule ssl_module $M/mod_ssl.so
LoadModule socache_shmcb_module $M/mod_socache_shmcb.so
LoadModule mpm_event_module $M/mod_mpm_event.so
LoadModule authz_core_module $M/mod_authz_core.so
LoadModule authn_core_module $M/mod_authn_core.so
LoadModule authn_file_module $M/mod_authn_file.so
LoadModule authz_user_module $M/mod_authz_user.so
LoadModule auth_basic_module $M/mod_auth_basic.so
LoadModule dav_module $M/mod_dav.so
LoadModule dav_fs_module $M/mod_dav_fs.so
LoadModule alias_module $M/mod_alias.so
LoadModule dir_module $M/mod_dir.so
LoadModule mime_module $M/mod_mime.so
TypesConfig /etc/mime.types
User www-data
Group www-data
ErrorLog "$DATA/logs/apache-error.log"
LogFormat "%h %u \"%r\" %>s %b" common
CustomLog "$DATA/logs/apache-access.log" common
DavLockDB "$DATA/davlock/DavLock"
LimitRequestBody 0
Timeout 600
<Directory "$DATA/root1">
  Dav On
  AuthType Basic
  AuthName "NAS"
  AuthUserFile "$DATA/htpasswd"
  Require valid-user
  Options Indexes
  AllowOverride None
</Directory>
<Directory "$DATA/root2">
  Dav On
  AuthType Basic
  AuthName "NAS"
  AuthUserFile "$DATA/htpasswd"
  Require valid-user
  Options Indexes
  AllowOverride None
</Directory>
<VirtualHost 127.0.0.1:18081>
  DocumentRoot "$DATA/root1"
</VirtualHost>
<VirtualHost 127.0.0.1:18082>
  DocumentRoot "$DATA/root2"
  Alias "/my dav" "$DATA/root2"
</VirtualHost>
<VirtualHost 127.0.0.1:18443>
  DocumentRoot "$DATA/root1"
  SSLEngine on
  SSLCertificateFile "$DATA/cert.pem"
  SSLCertificateKeyFile "$DATA/key.pem"
</VirtualHost>
CONF
apache2 -f "$DATA/apache.conf" -k start

cat > "$DATA/wsgidav.yaml" <<CONF
host: 127.0.0.1
port: 18083
verbose: 1
logging:
  enable: true
provider_mapping:
  "/":
    root: "$DATA/root3"
    readonly: false
http_authenticator:
  accept_basic: true
  accept_digest: false
  default_to_digest: false
simple_dc:
  user_mapping:
    "*":
      "$USER_NAME":
        password: "$PASSWORD"
dir_browser:
  enable: false
CONF
nohup "$WSGIDAV" --config "$DATA/wsgidav.yaml" > "$DATA/logs/wsgidav.log" 2>&1 &
echo $! > "$DATA/wsgidav.pid"

nohup node "$HERE/proxy.cjs" --listen 18084 --target 18081 --mode flaky > "$DATA/logs/proxy-flaky.log" 2>&1 &
echo $! > "$DATA/proxy-flaky.pid"
nohup node "$HERE/proxy.cjs" --listen 18085 --target 18081 --mode throttle --rate 3000000 > "$DATA/logs/proxy-throttle.log" 2>&1 &
echo $! > "$DATA/proxy-throttle.pid"

for port in 18081 18082 18083 18084 18085 18443; do
  scheme=http; [ "$port" = 18443 ] && scheme=https
  for i in $(seq 1 50); do
    if curl -sk -o /dev/null "$scheme://127.0.0.1:$port/"; then break; fi
    sleep 0.2
  done
done
echo "Test servers running. Data in $DATA"
