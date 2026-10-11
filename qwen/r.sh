#!/bin/bash
# ============================================================
#  qwen/r.sh — пульт управления ПК владельца из песочницы Qwen/Arena.
#  Обёртка над linux/remote.sh: сама выставляет HOME, ARENA_BRIDGE_DIR и путь
#  к ключу, а также применяет патч ControlPath (сокет мультиплексирования
#  обязан лежать в /tmp — см. QWEN.md §1). Работает прямо из клона:
#
#    ai-bridge/qwen/r ping
#    ai-bridge/qwen/r cmd 'ver'
#    ai-bridge/qwen/r psc '[Console]::OutputEncoding=[Text.Encoding]::UTF8; Get-Service sshd'
#    ai-bridge/qwen/r ps < script.ps1
#    ai-bridge/qwen/r get 'C:/Users/gamer/file.txt' ./
#    ai-bridge/qwen/r put ./file.txt 'C:/Users/gamer/agent-bridge/'
#    ai-bridge/qwen/r elev - < task.ps1
#
#  Переопределения: ARENA_BRIDGE_DIR, BRIDGE_REPO, BRIDGE_HOME, BRIDGE_KEY,
#                   BRIDGE_USER, BRIDGE_HOST, BRIDGE_PORT, BRIDGE_SOCKS
# ============================================================
set -u
QWEN_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="${BRIDGE_REPO:-$(dirname "$QWEN_DIR")}"
WORKSPACE="$(dirname "$REPO")"
RUNTIME="${ARENA_BRIDGE_DIR:-$WORKSPACE/arena-bridge}"

export HOME="${BRIDGE_HOME:-$WORKSPACE}"
export ARENA_BRIDGE_DIR="$RUNTIME"
export BRIDGE_KEY="${BRIDGE_KEY:-$HOME/.ssh/agent_ed25519}"

mkdir -p "$RUNTIME" "$HOME/.ssh" 2>/dev/null
chmod 700 "$HOME/.ssh" 2>/dev/null

RS="$RUNTIME/remote.sh"
if [ ! -f "$RS" ] || ! grep -q 'ControlPath=/tmp/cm-%C' "$RS" 2>/dev/null; then
  if [ -f "$REPO/linux/remote.sh" ]; then
    sed 's|ControlPath=$HOME/.ssh/cm-%r@%h:%p|ControlPath=/tmp/cm-%C|' \
      "$REPO/linux/remote.sh" > "$RS" && chmod +x "$RS"
  fi
fi
[ -f "$RS" ] || { echo "ERR: remote.sh не найден ни в $RUNTIME, ни в $REPO/linux" >&2; exit 3; }

exec "$RS" "$@"
