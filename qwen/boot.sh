#!/bin/bash
# ============================================================
#  qwen/boot.sh — самовосстановление моста «ИИ ↔ ПК» в песочнице Qwen/Arena.
#  Адаптация linux/ts-boot.sh: без systemd, без sudo, без CAP_NET_ADMIN,
#  с учётом трансляции путей workspace (см. QWEN.md §1).
#
#  Все пути выводятся из расположения самого скрипта — ничего не зашито.
#  Идемпотентен: можно запускать в начале каждого хода.
#
#    0) окружение      1) пакеты apt   2) бинарники tailscale
#    3) ssh-ключ       4) состояние    5) демон     6) логин
#    7) поиск ПК       8) remote.sh+r  9) ping     10) бэкап состояния
#
#  Переопределения: ARENA_BRIDGE_DIR, BRIDGE_SSHDIR, BRIDGE_REPO, TS_VER,
#                   TS_HOSTNAME, TS_SOCKET, TS_STATE
# ============================================================
set -u
QWEN_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="${BRIDGE_REPO:-$(dirname "$QWEN_DIR")}"
WORKSPACE="$(dirname "$REPO")"
RUNTIME="${ARENA_BRIDGE_DIR:-$WORKSPACE/arena-bridge}"
SSHDIR="${BRIDGE_SSHDIR:-$WORKSPACE/.ssh}"

TS=/usr/local/bin/tailscale
TSD=/usr/local/bin/tailscaled
SOCK="${TS_SOCKET:-/tmp/tailscaled.sock}"
STATE="${TS_STATE:-/var/lib/tailscale/tailscaled.state}"
BACKUP="$RUNTIME/ts-backup/tailscaled.state"
AUTHKEY="$RUNTIME/.ts-authkey"
LOG=/var/log/tailscaled.log
VER="${TS_VER:-1.104.1}"

mkdir -p "$RUNTIME/ts-backup" "$SSHDIR"
chmod 700 "$SSHDIR" 2>/dev/null
[ -f "$SSHDIR/agent_ed25519" ] && chmod 600 "$SSHDIR/agent_ed25519"
[ -f "$AUTHKEY" ] && chmod 600 "$AUTHKEY"

echo "== 0. окружение =="
echo "  workspace : $WORKSPACE"
echo "  runtime   : $RUNTIME"
echo "  репо      : $REPO $([ -f "$REPO/linux/remote.sh" ] || echo '(НЕТ — сначала git clone)')"
[ "$(id -u)" = 0 ] || echo "  ВНИМАНИЕ: мы не root, а sudo в этой песочнице нет"

echo "== 1. пакеты =="
need=""
command -v ssh  >/dev/null 2>&1 || need="$need openssh-client"
command -v nc   >/dev/null 2>&1 || need="$need netcat-openbsd"
command -v curl >/dev/null 2>&1 || need="$need curl"
command -v ip   >/dev/null 2>&1 || need="$need iproute2"
command -v ps   >/dev/null 2>&1 || need="$need procps"
if [ -n "$need" ]; then
  apt-get update -qq >/dev/null 2>&1
  # shellcheck disable=SC2086
  apt-get install -y -qq $need ca-certificates >/dev/null 2>&1 \
    && echo "  поставлено:$need" || echo "  !! не удалось поставить:$need"
else
  echo "  всё на месте: ssh, nc, curl, ip, ps"
fi

echo "== 2. бинарники tailscale =="
if [ ! -x "$TS" ] || [ ! -x "$TSD" ]; then
  ( cd /tmp && curl -sL -m 200 -o ts.tgz "https://pkgs.tailscale.com/stable/tailscale_${VER}_amd64.tgz" \
    && tar xzf ts.tgz && D=$(ls -d "tailscale_${VER}_amd64" | head -1) \
    && install -m 755 "$D/tailscale" "$TS" && install -m 755 "$D/tailscaled" "$TSD" ) \
    && echo "  установлены ($VER)" || echo "  !! не удалось скачать бинарники"
else
  echo "  на месте ($("$TS" version 2>/dev/null | head -1))"
fi

echo "== 3. ssh-ключ агента =="
if [ -f "$SSHDIR/agent_ed25519" ]; then
  echo "  на месте — НЕ пересоздаю (иначе ключ придётся заново авторизовать на ПК)"
else
  ssh-keygen -q -t ed25519 -f "$SSHDIR/agent_ed25519" -N "" -C arena-agent
  echo "  СГЕНЕРИРОВАН НОВЫЙ. Владелец должен выполнить на ПК:"
  echo "    powershell -NoProfile -ExecutionPolicy Bypass -File windows\\add-key.ps1 -Key \"$(cat "$SSHDIR/agent_ed25519.pub")\""
fi
echo "  pub: $(cat "$SSHDIR/agent_ed25519.pub" 2>/dev/null)"

echo "== 4. состояние узла =="
mkdir -p "$(dirname "$STATE")"
if [ ! -s "$STATE" ] && [ -s "$BACKUP" ]; then
  cp "$BACKUP" "$STATE"; echo "  восстановлено из бэкапа"
elif [ -s "$STATE" ]; then
  echo "  на месте"
else
  echo "  пусто — потребуется логин"
fi

echo "== 5. демон tailscaled =="
if pgrep -x tailscaled >/dev/null 2>&1; then
  echo "  уже запущен (pid $(pgrep -x tailscaled | tr '\n' ' '))"
else
  # systemd здесь нет: держим демон сами
  setsid nohup "$TSD" --tun=userspace-networking --socks5-server=127.0.0.1:1055 \
    --state="$STATE" --socket="$SOCK" > "$LOG" 2>&1 < /dev/null &
  disown
  sleep 6
  if pgrep -x tailscaled >/dev/null 2>&1; then echo "  запущен (лог: $LOG)";
  else echo "  !! не поднялся, последние строки лога:"; tail -5 "$LOG" 2>/dev/null; fi
fi

echo "== 6. логин в tailnet =="
if "$TS" --socket="$SOCK" status 2>&1 | grep -qi "logged out"; then
  if [ -s "$AUTHKEY" ]; then
    timeout 90 "$TS" --socket="$SOCK" up --authkey="$(cat "$AUTHKEY")" \
      --hostname="${TS_HOSTNAME:-arena-agent}" --accept-dns=false >/dev/null 2>&1 \
      && echo "  вошёл по auth-key" || echo "  !! логин не удался: ключ одноразовый или истёк — нужен новый"
  else
    echo "  *** НУЖЕН ЛОГИН ***"
    echo "  Попроси у владельца Tailscale auth key (tskey-auth-…) и сохрани:"
    echo "    printf '%s' '<KEY>' > $AUTHKEY && chmod 600 $AUTHKEY"
    echo "  затем повтори этот скрипт."
  fi
else
  echo "  уже в сети"
fi
"$TS" --socket="$SOCK" status 2>&1 | head -8

echo "== 7. поиск ПК (windows) в tailnet =="
PEER="$("$TS" --socket="$SOCK" status --json 2>/dev/null | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
best=None
for k,v in (d.get("Peer") or {}).items():
    if v.get("OS")=="windows":
        ips=v.get("TailscaleIPs") or []
        if ips:
            if v.get("Online"): print(ips[0]); sys.exit(0)
            best=best or ips[0]
if best: print(best)
')"
if [ -n "${PEER:-}" ]; then
  printf '%s\n' "$PEER"        > "$RUNTIME/host.txt"
  printf '22\n'                > "$RUNTIME/port.txt"
  printf '127.0.0.1:1055\n'    > "$RUNTIME/socks.txt"
  echo "  ПК: $PEER (host.txt/port.txt/socks.txt записаны)"
else
  echo "  ПК (windows) в tailnet не найден — проверь, что Tailscale на ПК онлайн"
fi

echo "== 8. remote.sh + обёртка r =="
if [ -f "$REPO/linux/remote.sh" ]; then
  cp -f "$REPO/linux/remote.sh" "$RUNTIME/remote.sh" && chmod +x "$RUNTIME/remote.sh" \
    && echo "  скопирован из репозитория"
elif [ -f "$RUNTIME/remote.sh" ]; then
  echo "  использую имеющийся в runtime"
else
  echo "  !! remote.sh не найден ни в репо, ни в runtime"
fi
if [ -f "$RUNTIME/remote.sh" ]; then
  # ControlPath внутри workspace не влезает в лимит unix-сокета из-за трансляции
  # путей песочницы — переносим сокет мультиплексирования в /tmp (QWEN.md §1)
  sed -i 's|ControlPath=$HOME/.ssh/cm-%r@%h:%p|ControlPath=/tmp/cm-%C|' "$RUNTIME/remote.sh"
  grep -q 'ControlPath=/tmp/cm-%C' "$RUNTIME/remote.sh" && echo "  ControlPath -> /tmp/cm-%C"
fi

echo "== 9. ping =="
timeout 45 "$QWEN_DIR/r.sh" ping 2>&1 | head -3

echo "== 10. бэкап состояния узла =="
cp "$STATE" "$BACKUP" 2>/dev/null && chmod 600 "$BACKUP" && echo "  обновлён: $BACKUP"

echo
echo "ГОТОВО. Пульт: $QWEN_DIR/r.sh {ping|cmd|psc|ps|get|put|elev|elev-check|elev-out|elev-stop}"
