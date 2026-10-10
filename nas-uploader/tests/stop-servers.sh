#!/usr/bin/env bash
DATA="${NAS_TEST_DATA:-/var/tmp/nas-uploader-test}"
[ -f "$DATA/apache.conf" ] && apache2 -f "$DATA/apache.conf" -k stop 2>/dev/null
for p in wsgidav proxy-flaky proxy-throttle proxy-tls; do
  [ -f "$DATA/$p.pid" ] && kill "$(cat "$DATA/$p.pid")" 2>/dev/null
done
sleep 0.5
echo "stopped"
