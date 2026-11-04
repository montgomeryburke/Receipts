#!/usr/bin/env bash
# Tests server/setup-webdav.sh for real: it installs/configures the SYSTEM Apache and creates users, so only run
# it in a throwaway container (CI_OK_TO_MODIFY_SYSTEM=1). Simulates the HP's Proxmox container: a media folder
# owned by a normal user plus a Jellyfin install whose libraries point into it.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../server/setup-webdav.sh"
WORK="${NAS_TEST_WORK:-$(mktemp -d)}"
export NAS_TEST_WORK="$WORK"
PASS='Setup pw 123!'
[[ "${CI_OK_TO_MODIFY_SYSTEM:-}" == 1 ]] || { echo "This changes /etc/apache2 and adds users. Run with CI_OK_TO_MODIFY_SYSTEM=1 in a throwaway container."; exit 2; }
[[ $EUID -eq 0 ]] || { echo "run as root"; exit 2; }

failures=0
pass() { printf '  \033[32m✔\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✘ %s\033[0m\n' "$*"; failures=$((failures + 1)); }
check() { local name="$1"; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }
propfind() { curl -sk -o /dev/null -w '%{http_code}' -X PROPFIND -H 'Depth: 0' -u "uploader:$PASS" "$1"; }

echo "• preparing a container that looks like the HP's (media owned by a user, Jellyfin libraries)"
id mediauser >/dev/null 2>&1 || useradd -u 1500 -M -s /usr/sbin/nologin mediauser
id jellyfin >/dev/null 2>&1 || useradd -r -M -s /usr/sbin/nologin jellyfin
rm -rf /srv/test-media /srv/test-media-root /srv/test-media-nobody /var/lib/jellyfin
mkdir -p "/srv/test-media/Movies/Old Film (1999)" /srv/test-media/TV /var/lib/jellyfin/root/default/{Movies,Shows}
echo existing > "/srv/test-media/Movies/Old Film (1999)/Old Film (1999).mkv"
chown -R mediauser:mediauser /srv/test-media && chmod -R u=rwX,go=rX /srv/test-media
printf '<LibraryOptions><PathInfos><MediaPathInfo><Path>/srv/test-media/Movies</Path></MediaPathInfo></PathInfos></LibraryOptions>' > /var/lib/jellyfin/root/default/Movies/options.xml
printf '<LibraryOptions><PathInfos><MediaPathInfo><Path>/srv/test-media/TV</Path></MediaPathInfo></PathInfos></LibraryOptions>' > /var/lib/jellyfin/root/default/Shows/options.xml
"$SCRIPT" --uninstall >/dev/null 2>&1 || true
rm -f /etc/nas-uploader/password

echo "• local mode (self-signed HTTPS) with the detected Jellyfin folder"
out="$("$SCRIPT" --yes --access local --port 18490 --password "$PASS" 2>&1)"; rc=$?
check "script succeeded" [ $rc -eq 0 ]
check "detected Jellyfin libraries" grep -q "Jellyfin libraries in this container" <<<"$out"
check "shares their common folder" grep -q "Sharing: /srv/test-media$" <<<"$out"
check "runs as the folder owner" grep -q "owned by mediauser:mediauser" <<<"$out"
check "self-test: Jellyfin can read uploads" grep -q "Jellyfin can read uploaded files" <<<"$out"
check "prints config for the extension" grep -q "serverUrl: 'https://" <<<"$out"
check "WebDAV answers 207 with the password" [ "$(propfind https://127.0.0.1:18490/)" = 207 ]
check "wrong password gets 401" [ "$(curl -sk -o /dev/null -w '%{http_code}' -X PROPFIND -u uploader:nope https://127.0.0.1:18490/)" = 401 ]
check "no login: 401" [ "$(curl -sk -o /dev/null -w '%{http_code}' -X PROPFIND https://127.0.0.1:18490/)" = 401 ]
check "uploaded scripts are not executed" bash -c "printf '<?php echo 1+1; ?>' | curl -sk -o /dev/null -T - -u 'uploader:$PASS' https://127.0.0.1:18490/x.php && [ \"\$(curl -sk -u 'uploader:$PASS' https://127.0.0.1:18490/x.php)\" = '<?php echo 1+1; ?>' ] && curl -sk -o /dev/null -X DELETE -u 'uploader:$PASS' https://127.0.0.1:18490/x.php"
check "no 1 GB upload limit configured" grep -q "LimitRequestBody 0" /etc/apache2/sites-available/nas-uploader.conf
check "automatic security updates switched on" bash -c "apt-config dump | grep -q 'APT::Periodic::Unattended-Upgrade \"1\"'"
out2="$("$SCRIPT" --yes --access local --port 18490 2>&1)"
check "re-run keeps the existing password" grep -q "Keeping the existing password" <<<"$out2"
check "still answers after re-run" [ "$(propfind https://127.0.0.1:18490/)" = 207 ]

echo "• Chrome extension against that server (upload + mirror into the library)"
( cd "$HERE" && [ -d "$WORK/dataset" ] || node make-dataset.cjs "$WORK/dataset" --no-big >/dev/null
  SETUP_LOCAL_URL=https://127.0.0.1:18490/ SETUP_ROOT=/srv/test-media SETUP_PASS="$PASS" SETUP_OWNER=mediauser \
    node e2e.cjs "server from setup-webdav.sh: upload" ) | grep -E "✔|✘|Assertion" ; [ "${PIPESTATUS[0]}" -eq 0 ] || failures=$((failures + 1))

echo "• Funnel mode (Apache on localhost behind an HTTPS proxy; Tailscale itself can't run here)"
out="$("$SCRIPT" --yes --access funnel --skip-tailscale --public-url https://127.0.0.1:18447/ --local-port 18491 2>&1)"; rc=$?
check "script succeeded" [ $rc -eq 0 ]
check "only listens on localhost" grep -q "Listen 127.0.0.1:18491" /etc/apache2/sites-available/nas-uploader.conf
check "knows its public https address" grep -q "ServerName https://127.0.0.1:18447" /etc/apache2/sites-available/nas-uploader.conf
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/tls-key.pem" -out "$WORK/tls-cert.pem" -days 2 -subj /CN=127.0.0.1 >/dev/null 2>&1
node "$HERE/proxy.cjs" --listen 18447 --target 18491 --mode tls --cert "$WORK/tls-cert.pem" --key "$WORK/tls-key.pem" >/dev/null 2>&1 &
PROXY_PID=$!
sleep 1
check "reachable through the proxy" [ "$(propfind https://127.0.0.1:18447/)" = 207 ]
check "folder without trailing slash: no broken http:// redirect" [ "$(propfind https://127.0.0.1:18447/TV)" = 207 ]
( cd "$HERE" && SETUP_PROXY_URL=https://127.0.0.1:18447/ SETUP_ROOT=/srv/test-media SETUP_PASS="$PASS" \
    node e2e.cjs "behind an HTTPS proxy \(Funnel" ) | grep -E "✔|✘|Assertion" ; [ "${PIPESTATUS[0]}" -eq 0 ] || failures=$((failures + 1))
kill $PROXY_PID 2>/dev/null

echo "• root-owned media folder (common on Proxmox): web server gets write access via ACLs or group"
mkdir -p /srv/test-media-root/Movies && chown -R root:root /srv/test-media-root && chmod -R 755 /srv/test-media-root
out="$("$SCRIPT" --yes --access local --port 18492 --folder /srv/test-media-root 2>&1)"; rc=$?
check "script succeeded" [ $rc -eq 0 ]
check "granted write access" grep -qE "Write access granted|can already write" <<<"$out"
code="$(curl -sk -o /dev/null -w '%{http_code}' -T - -u "uploader:$PASS" https://127.0.0.1:18492/Movies/new.txt <<<'hello')"
check "upload into a subfolder works ($code)" [ "$code" = 201 ]
check "jellyfin can read it" setpriv --reuid=jellyfin --regid=jellyfin --init-groups -- test -r /srv/test-media-root/Movies/new.txt
check "existing file ownership untouched" [ "$(stat -c %U /srv/test-media-root/Movies)" = root ]

echo "• a new drive added just for the mirror (fresh ext4 mount point: root-owned, locked lost+found)"
rm -rf /srv/test-mirror-disk && mkdir -p /srv/test-mirror-disk/lost+found && chmod 700 /srv/test-mirror-disk/lost+found && chown -R root:root /srv/test-mirror-disk
out="$("$SCRIPT" --yes --access local --port 18494 --folder /srv/test-mirror-disk 2>&1)"; rc=$?
check "script succeeded" [ $rc -eq 0 ]
check "shares only the new drive" grep -q 'DocumentRoot "/srv/test-mirror-disk"' /etc/apache2/sites-available/nas-uploader.conf
check "no warning about lost+found" bash -c "! grep -q 'Not writable' <<<\"\$1\"" _ "$out"
code="$(curl -sk -o /dev/null -w '%{http_code}' -X MKCOL -u "uploader:$PASS" "https://127.0.0.1:18494/Laptop%20Backup/")"
check "create a folder on the drive ($code)" [ "$code" = 201 ]
code="$(curl -sk -o /dev/null -w '%{http_code}' -T - -u "uploader:$PASS" "https://127.0.0.1:18494/Laptop%20Backup/notes.txt" <<<'hello')"
check "upload onto the drive ($code)" [ "$code" = 201 ]
check "Jellyfin media not reachable through this login" [ "$(curl -sk -o /dev/null -w '%{http_code}' -u "uploader:$PASS" "https://127.0.0.1:18494/Movies/")" = 404 ]

echo "• port forward with real certificates from Let's Encrypt's test CA (Pebble) and a stand-in DuckDNS"
SP_GO="${PEBBLE_GOPATH:-}"
if [[ -n "$SP_GO" && -x "$SP_GO/bin/pebble" && -n "${CERTBOT_BIN_DIR:-}" ]]; then
  PEB_MOD="$(ls -d "$SP_GO"/pkg/mod/github.com/letsencrypt/pebble/v2@*/ | tail -1)"
  ACME="$WORK/acme-test"; rm -rf "$ACME"; mkdir -p "$ACME"
  # Pebble's bundled HTTPS certificate lacks an Authority Key Identifier, which Python 3.13 rejects; make a
  # standards-compliant one for its API instead (this only concerns the test CA's own API, not issued certificates).
  ( cd "$ACME" && openssl req -x509 -newkey rsa:2048 -nodes -days 3 -subj "/CN=Pebble test API CA" -keyout ca.key -out ca.pem \
      -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" -addext "subjectKeyIdentifier=hash" &&
    openssl req -newkey rsa:2048 -nodes -subj "/CN=localhost" -keyout api.key -out api.csr &&
    printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid\n' > ext.cnf &&
    openssl x509 -req -in api.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 3 -extfile ext.cnf -out api.pem ) >/dev/null 2>&1
  sed -e "s#test/certs/localhost/cert.pem#$ACME/api.pem#" -e "s#test/certs/localhost/key.pem#$ACME/api.key#" -e 's/"httpPort": 5002/"httpPort": 80/' "$PEB_MOD/test/config/pebble-config.json" > "$ACME/pebble.json"
  "$SP_GO/bin/pebble-challtestsrv" -defaultIPv4 127.0.0.1 -defaultIPv6 "" -dns01 :8053 -management :8055 -http01 "" -https01 "" -tlsalpn01 "" -doh "" >"$ACME/challtestsrv.log" 2>&1 &
  CTS_PID=$!
  PEBBLE_VA_NOSLEEP=1 PEBBLE_WFE_NONCEREJECT=0 "$SP_GO/bin/pebble" -config "$ACME/pebble.json" -dnsserver 127.0.0.1:8053 >"$ACME/pebble.log" 2>&1 &
  PEB_PID=$!
  node "$HERE/acme/mock-duckdns.cjs" --listen 18600 --token testtoken-123 --challtestsrv http://127.0.0.1:8055 >"$ACME/duckdns.log" 2>&1 &
  DUCK_PID=$!
  sleep 2
  rm -rf /etc/letsencrypt /etc/nas-uploader/duckdns.env
  export PATH="$CERTBOT_BIN_DIR:$PATH" REQUESTS_CA_BUNDLE="$ACME/ca.pem" NAS_UPLOADER_DUCKDNS_URL=http://127.0.0.1:18600 NAS_UPLOADER_DNS_WAIT=1
  # The test names only exist on this machine: never send them through an outbound proxy.
  export NO_PROXY="${NO_PROXY:-},hp-test.duckdns.org,bad-test.duckdns.org,files.example.test" no_proxy="${no_proxy:-},hp-test.duckdns.org,bad-test.duckdns.org,files.example.test"
  ROOT_PEM="$ACME/root.pem"
  verify_cert() { # verify_cert host port -> 0 if the served certificate chains to Pebble's root and matches host
    curl -s --cacert "$ROOT_PEM" --resolve "$1:$2:127.0.0.1" -o /dev/null -w '%{http_code}' -X PROPFIND -H 'Depth: 0' -u "uploader:$PASS" "https://$1:$2/" | grep -q 207
  }
  serial() { openssl s_client -connect "127.0.0.1:$2" -servername "$1" </dev/null 2>/dev/null | openssl x509 -noout -serial; }

  out="$("$SCRIPT" --yes --access port-forward --domain hp-test.duckdns.org --duckdns-token testtoken-123 --folder /srv/test-mirror-disk --port 18495 --acme-server https://localhost:14000/dir 2>&1)"; rc=$?
  curl -s --cacert "$ACME/ca.pem" https://localhost:15000/roots/0 > "$ROOT_PEM"
  check "DuckDNS method: script succeeded" [ $rc -eq 0 ]
  check "DuckDNS name updated" grep -q "DuckDNS updated" <<<"$out"
  check "certificate issued through DuckDNS (no port 80)" grep -q "Certificate issued" <<<"$out"
  check "tells you port 80 isn't needed" grep -q "Port 80 isn't needed" <<<"$out"
  check "server presents a valid certificate for the name" verify_cert hp-test.duckdns.org 18495
  check "DuckDNS kept up to date every 5 minutes" grep -q nas-uploader-duckdns /etc/cron.d/nas-uploader-duckdns
  s1="$(serial hp-test.duckdns.org 18495)"
  certbot renew --force-renewal --cert-name hp-test.duckdns.org >"$ACME/renew.log" 2>&1; rc=$?
  sleep 2
  s2="$(serial hp-test.duckdns.org 18495)"
  check "automatic renewal works and the server picks up the new certificate" [ $rc -eq 0 -a -n "$s2" -a "$s1" != "$s2" ]
  check "renewed certificate is valid" verify_cert hp-test.duckdns.org 18495
  out2="$("$SCRIPT" --yes --access port-forward --domain hp-test.duckdns.org --folder /srv/test-mirror-disk --port 18495 --acme-server https://localhost:14000/dir 2>&1)"
  check "re-run reuses the certificate and remembers the DuckDNS token" bash -c 'grep -q "from an earlier run" <<<"$1" && grep -q "DuckDNS updated" <<<"$1"' _ "$out2"
  check "fail2ban configured for the uploader's login" fail2ban-client -t
  curl -sk -o /dev/null -X PROPFIND -u uploader:wrong-password https://127.0.0.1:18495/
  check "fail2ban recognises failed logins" bash -c "fail2ban-regex /var/log/apache2/nas-uploader-error.log /etc/fail2ban/filter.d/apache-auth.conf | grep -qE 'Failregex: [1-9][0-9]* total'"

  echo "  · extension against it (Chrome resolves hp-test.duckdns.org to this machine)"
  ( cd "$HERE" && SETUP_LOCAL_URL=https://hp-test.duckdns.org:18495/ SETUP_ROOT=/srv/test-mirror-disk SETUP_PASS="$PASS" SETUP_OWNER=www-data \
      SETUP_CHROME_ARGS='["--host-resolver-rules=MAP hp-test.duckdns.org 127.0.0.1","--no-proxy-server"]' SETUP_NO_JELLYFIN_DIRS=1 \
      node e2e.cjs "server from setup-webdav.sh: upload" ) | grep -E "✔|✘|Assertion" ; [ "${PIPESTATUS[0]}" -eq 0 ] || failures=$((failures + 1))

  out="$("$SCRIPT" --yes --access port-forward --domain bad-test.duckdns.org --duckdns-token wrong-token --folder /srv/test-mirror-disk --port 18497 --acme-server https://localhost:14000/dir 2>&1)"; rc=$?
  check "wrong DuckDNS token: still finishes (self-signed for now)" [ $rc -eq 0 ]
  check "wrong DuckDNS token: says what to check" grep -q "Check the DuckDNS name and token" <<<"$out"

  rm -f /etc/nas-uploader/duckdns.env
  out="$("$SCRIPT" --yes --access port-forward --domain files.example.test --folder /srv/test-mirror-disk --port 18496 --acme-server https://localhost:14000/dir 2>&1)"; rc=$?
  check "own domain (port 80 method): certificate issued" grep -q "Certificate issued" <<<"$out"
  check "own domain: valid certificate served" verify_cert files.example.test 18496
  check "own domain: port 80 redirects everything else to HTTPS" bash -c "[ \"\$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' -H 'Host: files.example.test' http://127.0.0.1/some/path)\" = '301 https://files.example.test:18496/some/path' ]"
  kill $CTS_PID $PEB_PID $DUCK_PID 2>/dev/null
else
  echo "  (skipped: set PEBBLE_GOPATH and CERTBOT_BIN_DIR; see tests/README in the main README)"
fi

echo "• folder owned by 'nobody' (unprivileged container, unmapped owner): explains the Proxmox fix"
mkdir -p /srv/test-media-nobody && chown nobody:nogroup /srv/test-media-nobody
out="$("$SCRIPT" --yes --access local --port 18493 --folder /srv/test-media-nobody 2>&1)"; rc=$?
check "refuses with exit code 1" [ $rc -eq 1 ]
check "explains the fix on the Proxmox host" grep -q "Proxmox HOST" <<<"$out"

echo "• uninstall"
"$SCRIPT" --uninstall >/dev/null 2>&1
check "site removed" [ ! -e /etc/apache2/sites-available/nas-uploader.conf ]
check "no longer answers" [ "$(propfind https://127.0.0.1:18492/)" != 207 ]
check "media files untouched" [ -f "/srv/test-media/Movies/Old Film (1999)/Old Film (1999).mkv" ]

echo
if [[ $failures -eq 0 ]]; then echo "setup script: all checks passed"; else echo "setup script: $failures check(s) failed"; fi
exit $(( failures > 0 ))
