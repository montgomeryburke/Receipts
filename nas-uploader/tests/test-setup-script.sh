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
