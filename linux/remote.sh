#!/usr/bin/env bash
# ============================================================
#  remote.sh v2.1 — пульт управления ПК владельца.
#  Связь: ssh к Windows через SOCKS5 Tailscale (userspace).
#
#  Конфиг ищется: сначала рядом со скриптом, потом в ~/arena-bridge
#  (переопределение: ARENA_BRIDGE_DIR или BRIDGE_HOST/BRIDGE_PORT/BRIDGE_SOCKS)
#    host.txt  — адрес ПК в tailnet (напр. 100.108.234.88)
#    port.txt  — порт ssh (22)
#    socks.txt — socks5 Tailscale (127.0.0.1:1055)
#
#  Режимы:
#    ./remote.sh ping | cmd '...' | ps < file | psc '...'
#    ./remote.sh get 'C:/p/f' ./loc   |   ./remote.sh put ./loc 'C:/p/d/'
#    ./remote.sh elev '...' | elev - < file | elev-check | elev-out ID | elev-stop
# ============================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
RUNTIME="${ARENA_BRIDGE_DIR:-$HOME/arena-bridge}"

cfg() {  # $1 = имя файла: ищем в двух местах, отдаём первую строку
  local d
  for d in "$HERE" "$RUNTIME"; do
    if [ -s "$d/$1" ]; then head -n1 "$d/$1" | tr -d ' \r\n'; return; fi
  done
}

PORT="${BRIDGE_PORT:-$(cfg port.txt)}"
HOST="${BRIDGE_HOST:-$(cfg host.txt)}"
SOCKS="${BRIDGE_SOCKS:-$(cfg socks.txt)}"
RUSER="${BRIDGE_USER:-gamer}"
KEY="${BRIDGE_KEY:-$HOME/.ssh/agent_ed25519}"
HOST="${HOST:-desktop-gd5kfio}"

if [ -z "$PORT" ]; then echo "ERR: нет порта (port.txt / BRIDGE_PORT)" >&2; exit 3; fi

SSH_BASE=( -i "$KEY" -p "$PORT"
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile="$HOME/.ssh/known_hosts"
  -o ConnectTimeout=15 -o ServerAliveInterval=30 -o BatchMode=yes
  -o ControlMaster=auto -o "ControlPath=$HOME/.ssh/cm-%r@%h:%p" -o ControlPersist=55 )
if [ -n "$SOCKS" ]; then
  SSH_BASE+=( -o "ProxyCommand=nc -X 5 -x $SOCKS %h %p" )
fi
SCP_BASE=( "${SSH_BASE[@]}" )
SCP_BASE[2]="-P"   # scp требует -P для порта

WIN_FWD="C:/Users/$RUSER/agent-bridge/elev"
WIN_BS="C:\\Users\\$RUSER\\agent-bridge\\elev"

rsh() { ssh "${SSH_BASE[@]}" "$RUSER@$HOST" "$@"; }

b64read() {  # удалённый файл -> base64 одной строкой (пусто при ошибке)
  rsh "powershell -NoProfile -Command \"try { [Convert]::ToBase64String([IO.File]::ReadAllBytes('$1')) } catch { }\"" 2>/dev/null \
    | tr -d '\r\n'
}
rd() { b64read "$1" | base64 -d 2>/dev/null || true; }

mode="${1:-}"; shift || true

case "$mode" in
  ping)
    rsh 'echo PONG'
    ;;

  cmd)
    exec ssh "${SSH_BASE[@]}" "$RUSER@$HOST" "$*"
    ;;

  ps)
    exec ssh "${SSH_BASE[@]}" "$RUSER@$HOST" powershell -NoProfile -ExecutionPolicy Bypass -Command -
    ;;

  psc)
    exec ssh "${SSH_BASE[@]}" "$RUSER@$HOST" powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand \
      "$(printf '%s' "$*" | iconv -t UTF-16LE | base64 -w0)"
    ;;

  get)
    exec scp "${SCP_BASE[@]}" "$RUSER@$HOST:$1" "$2"
    ;;

  put)
    exec scp "${SCP_BASE[@]}" "$1" "$RUSER@$HOST:$2"
    ;;

  elev-check)
    hb="$(rd "$WIN_BS\\hb.txt" | tr -cd '0-9')"
    busy="$(rd "$WIN_BS\\busy.txt" | tr -d '\r\n')"
    if [ -z "$hb" ]; then
      echo "runner: NOT RUNNING (нет heartbeat-файла)"
      exit 1
    fi
    age=$(( $(date +%s) - hb ))
    echo "runner: пульс ${age}с назад"
    if [ -n "$busy" ]; then echo "занят: $busy"; else echo "свободен"; fi
    if [ "$age" -gt 30 ]; then
      echo "WARN: пульс устарел (долгое задание или раннер остановлен)"
      exit 1
    fi
    ;;

  elev-stop)
    rsh "powershell -NoProfile -Command \"Set-Content -LiteralPath '$WIN_BS\\STOP' -Value stop -Force\"" \
      && echo "STOP создан — раннер остановится после текущего задания"
    ;;

  elev-out)
    id="${1:-}"
    [ -z "$id" ] && { echo "usage: $0 elev-out <job-id>" >&2; exit 2; }
    rd "$WIN_BS\\out\\$id.ps1.out"
    d="$(rd "$WIN_BS\\out\\$id.ps1.done" | tr -d '\r\n')"
    echo ""
    echo "=== состояние: ${d:-RUNNING}"
    ;;

  elev)
    if [ "${1:-}" = "-" ] || [ -z "${1:-}" ]; then body="$(cat)"; else body="$*"; fi
    body="${body%$'\n'}"

    # раннер жив?
    hb="$(rd "$WIN_BS\\hb.txt" | tr -cd '0-9')"
    if [ -z "$hb" ]; then
      echo "[elev] раннер молчит — пробую запустить задачу..."
      rsh 'cmd /c schtasks /run /tn ArenaElev' >/dev/null 2>&1 || true
      sleep 4
      hb="$(rd "$WIN_BS\\hb.txt" | tr -cd '0-9')"
      if [ -z "$hb" ]; then
        echo "[elev] раннер НЕ работает. Попроси владельца: windows/enable-elev.ps1 (админ) один раз." >&2
        exit 4
      fi
    fi
    age=$(( $(date +%s) - hb ))
    [ "$age" -gt 30 ] && echo "[elev] пульс ${age}с — возможно, идёт долгое задание"

    id="j$(date -u +%Y%m%d-%H%M%S)-$$-$RANDOM"
    tmp="$(mktemp)"
    {
      printf '[Console]::OutputEncoding=[Text.Encoding]::UTF8\n'
      printf '$OutputEncoding=[Text.Encoding]::UTF8\n'
      printf '%s\n' "$body"
    } > "$tmp"

    scp "${SCP_BASE[@]}" -q "$tmp" "$RUSER@$HOST:$WIN_FWD/in/$id.ps1.tmp" \
      || { echo "[elev] загрузка не удалась" >&2; rm -f "$tmp"; exit 5; }
    rm -f "$tmp"
    rsh "cmd /c ren \"$WIN_BS\\in\\$id.ps1.tmp\" \"$id.ps1\"" >/dev/null 2>&1
    echo "[elev] задание $id отправлено"

    prev=0; waited=0; max="${ELEV_MAX:-1200}"
    outf="$(mktemp)"
    while [ "$waited" -lt "$max" ]; do
      resp="$(rsh "powershell -NoProfile -Command \"try { [Convert]::ToBase64String([IO.File]::ReadAllBytes('$WIN_BS\\out\\$id.ps1.out')) } catch { }; '===M==='; if (Test-Path '$WIN_BS\\out\\$id.ps1.done') { 'DONE' } else { 'RUN' }\"" 2>/dev/null || true)"

      b64="$(printf '%s\n' "$resp" | sed '/^===M===[[:space:]]*$/,$d' | tr -d '\r\n')"
      flag="$(printf '%s\n' "$resp" | awk 'f{print} /^===M===/{f=1}' | tr -d '\r\n ')"

      [ -n "$b64" ] && printf '%s' "$b64" | base64 -d > "$outf" 2>/dev/null || true
      len=$(wc -c < "$outf" 2>/dev/null || echo 0)
      if [ "$len" -gt "$prev" ]; then
        tail -c +$((prev+1)) "$outf"
        prev=$len
      fi

      if [ "$flag" = "DONE" ]; then
        d="$(rd "$WIN_BS\\out\\$id.ps1.done" | tr -d '\r\n')"
        echo ""
        echo "[elev] ${d:-DONE}"
        rm -f "$outf"
        exit 0
      fi

      waited=$((waited+1))
      sleep 1
    done
    echo ""
    echo "[elev] всё ещё выполняется (>${max}с) — задание $id продолжает работать"
    echo "[elev] проверить позже: $0 elev-out $id"
    rm -f "$outf"
    ;;

  *)
    echo "usage: $0 {ping|cmd|ps|psc|get|put|elev|elev-check|elev-out|elev-stop} ..." >&2
    exit 2
    ;;
esac
