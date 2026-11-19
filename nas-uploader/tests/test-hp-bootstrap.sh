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

echo "• the NAS container and an \"llm\" container with Ollama"
fake_pct $'VMID       Status     Lock         Name\n101        running                 jellyfin\n105        running                 llm'
out="$(PATH="$WORK/bin:$PATH" bash "$SCRIPT" --dry-run 2>&1)"; rc=$?
check "succeeded" [ $rc -eq 0 ]
check "found the local AI container" grep -q "Local AI: http://192.168.1.50:11434 (qwen2.5:7b)" <<<"$out"
check "Ollama listens on the network with a 16k context" grep -q 'OLLAMA_HOST=0.0.0.0.*OLLAMA_CONTEXT_LENGTH=16384' <<<"$out"
check "pulls the model only if missing" grep -q "grep -qx 'qwen2.5:7b' || ollama pull 'qwen2.5:7b'" <<<"$out"
check "NAS setup with Funnel, commands, the mirror folder and the local AI" grep -q "bash /root/setup-webdav.sh --access funnel --enable-commands --folder /mnt/mirror --yes --llm-url http://192.168.1.50:11434" <<<"$out"
check "changes nothing in a dry run" bash -c "! grep -q '(ran in' <<<\"\$1\"" _ "$out"

echo "• no local AI container"
fake_pct $'VMID       Status     Lock         Name\n101        running                 jellyfin'
out="$(PATH="$WORK/bin:$PATH" bash "$SCRIPT" --dry-run 2>&1)"; rc=$?
check "succeeded" [ $rc -eq 0 ]
check "says it skips the local model" grep -q 'No container named like "llm"' <<<"$out"
check "NAS setup without --llm-url" bash -c "grep -q 'setup-webdav.sh --access funnel --enable-commands' <<<\"\$1\" && ! grep -q -- '--llm-url' <<<\"\$1\"" _ "$out"

echo "• the NAS container is stopped"
fake_pct $'VMID       Status     Lock         Name\n101        stopped                 jellyfin'
out="$(PATH="$WORK/bin:$PATH" bash "$SCRIPT" --dry-run 2>&1)"; rc=$?
check "stops with a clear message" bash -c "[ $rc -ne 0 ] && grep -q \"Container 101 (the NAS) isn't running\" <<<\"\$1\"" _ "$out"

echo "• bad options are refused"
out="$(PATH="$WORK/bin:$PATH" bash "$SCRIPT" --dry-run --nas-ct 'x;rm' 2>&1)"; rc=$?
check "container number checked" [ $rc -ne 0 ]
out="$(PATH="$WORK/bin:$PATH" bash "$SCRIPT" --dry-run --model 'a b' 2>&1)"; rc=$?
check "model name checked" [ $rc -ne 0 ]

echo
if [[ $failures -eq 0 ]]; then echo "hp bootstrap: all checks passed"; else echo "hp bootstrap: $failures check(s) failed"; fi
exit $(( failures > 0 ))
