#!/usr/bin/env bash
# Dry runs of server/hp-bootstrap.sh against a stand-in "pct" (the Proxmox container tool): it finds the NAS and
# local-AI containers, configures Ollama, and runs the NAS setup with the right options — nothing is changed.
#   bash tests/test-hp-bootstrap.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../server/hp-bootstrap.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
failures=0
pass() { printf '  \033[32m✔\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✘ %s\033[0m\n' "$*"; failures=$((failures + 1)); }
check() { local name="$1"; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }

fake_pct() { # $1: the container list
  mkdir -p "$WORK/bin"
  printf '%s\n' "$1" > "$WORK/list"
  cat > "$WORK/bin/pct" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  list) cat "$(dirname "$0")/../list" ;;
  status) grep -q "^$2 .*running" "$(dirname "$0")/../list" && echo "status: running" || echo "status: stopped" ;;
  exec)
    all="$*"
    case "$all" in
      *"command -v ollama"*) [[ "$2" == 105 ]] ;;
      *"hostname -I"*) echo "192.168.1.50 fd00::5" ;;
      *"test -d /mnt/mirror"*) exit 0 ;;
      *) echo "(ran in $2)" ;;
    esac ;;
esac
EOF
  chmod +x "$WORK/bin/pct"
}

echo "• the NAS container (other containers, like an \"llm\" one, are left alone)"
fake_pct $'VMID       Status     Lock         Name\n101        running                 jellyfin\n105        running                 llm'
out="$(PATH="$WORK/bin:$PATH" bash "$SCRIPT" --dry-run 2>&1)"; rc=$?
check "succeeded" [ $rc -eq 0 ]
check "NAS setup with Funnel, commands and the mirror folder, no AI model" grep -q "bash /root/setup-webdav.sh --access funnel --enable-commands --no-llm --folder /mnt/mirror --yes" <<<"$out"
check "never touches another container" bash -c "! grep -qE 'in_ct 105|exec 105|ollama' <<<\"\$1\"" _ "$out"
check "changes nothing in a dry run" bash -c "! grep -q '(ran in' <<<\"\$1\"" _ "$out"

echo "• the NAS container is stopped"
fake_pct $'VMID       Status     Lock         Name\n101        stopped                 jellyfin'
out="$(PATH="$WORK/bin:$PATH" bash "$SCRIPT" --dry-run 2>&1)"; rc=$?
check "stops with a clear message" bash -c "[ $rc -ne 0 ] && grep -q \"Container 101 (the NAS) isn't running\" <<<\"\$1\"" _ "$out"

echo "• bad options are refused"
out="$(PATH="$WORK/bin:$PATH" bash "$SCRIPT" --dry-run --nas-ct 'x;rm' 2>&1)"; rc=$?
check "container number checked" [ $rc -ne 0 ]
out="$(PATH="$WORK/bin:$PATH" bash "$SCRIPT" --dry-run --folder 'x; rm -rf /' 2>&1)"; rc=$?
check "folder checked" [ $rc -ne 0 ]

echo
if [[ $failures -eq 0 ]]; then echo "hp bootstrap: all checks passed"; else echo "hp bootstrap: $failures check(s) failed"; fi
exit $(( failures > 0 ))
