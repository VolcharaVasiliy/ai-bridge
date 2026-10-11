#!/bin/bash
# ============================================================
#  ts-boot.sh v3 — САМОВОССТАНОВЛЕНИЕ моста «ИИ ↔ ПК» за секунды.
#  Идемпотентен: запускай в начале каждого хода.
#
#   1) права (после пересборки песочницы всё сбрасывается)
#   2) бинарники tailscale/netcat (перекачает, если стёрли)
#   3) systemd-юниты (пересоздаст, если стёрли)
#   4) сеть: dummy0 (иначе tailscaled «не видит сеть» и логин виснет)
#   5) состояние узла из бэкапа; логин по ~/arena-bridge/.ts-authkey
#   6) автопоиск ПК (windows) в tailnet → host.txt/port.txt/socks.txt
#   7) ping-тест; 8) бэкап состояния
#
#  Секреты/рантайм: ~/arena-bridge (переопределяется ARENA_BRIDGE_DIR)
# ============================================================
set -u
RUNTIME="${ARENA_BRIDGE_DIR:-$HOME/arena-bridge}"
HERE="$(cd "$(dirname "$0")" && pwd)"

TS=/usr/local/bin/tailscale
TSD=/usr/local/bin/tailscaled
SOCK=/tmp/tailscaled.sock
STATE=/var/lib/tailscale/tailscaled.state
BACKUP="$RUNTIME/ts-backup/tailscaled.state"
AUTHKEY="$RUNTIME/.ts-authkey"
VER="${TS_VER:-1.104.1}"

mkdir -p "$RUNTIME" "$RUNTIME/ts-backup"

echo "== 0. права =="
chmod 600 "$HOME/.ssh/agent_ed25519" 2>/dev/null && echo "ssh-ключ → 600" || true
[ -f "$AUTHKEY" ] && chmod 600 "$AUTHKEY" && echo "auth-key → 600" || true
chmod +x "$HERE/remote.sh" "$RUNTIME/remote.sh" 2>/dev/null && echo "скрипты → +x" || true
[ -x "$RUNTIME/remote.sh" ] || cp -f "$HERE/remote.sh" "$RUNTIME/remote.sh" 2>/dev/null || true

echo "== 1. бинарники =="
if [ ! -x "$TS" ] || [ ! -x "$TSD" ]; then
  echo "перекачиваю tailscale $VER ..."
  ( cd /tmp && curl -sL -m 150 -o ts.tgz "https://pkgs.tailscale.com/stable/tailscale_${VER}_amd64.tgz" \
    && tar xzf ts.tgz && D=$(ls -d tailscale_${VER}_amd64 | head -1) \
    && sudo install -m 755 "$D/tailscale" "$TS" && sudo install -m 755 "$D/tailscaled" "$TSD" ) \
    && echo "бинарники восстановлены" || echo "!! не удалось скачать бинарники"
else
  echo "tailscale на месте"
fi
command -v nc >/dev/null 2>&1 || { sudo apt-get install -y -qq netcat-openbsd >/dev/null 2>&1 && echo "netcat установлен"; }

echo "== 2. systemd юниты =="
if [ ! -f /etc/systemd/system/tailscaled.service ]; then
  sudo tee /etc/systemd/system/tailscaled.service >/dev/null <<'EOF'
[Unit]
Description=Tailscale node agent (userspace, SOCKS5 :1055)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=/bin/sh -c '/bin/mkdir -p /var/lib/tailscale; ip link show dummy0 >/dev/null 2>&1 || ip link add dummy0 type dummy; ip link set dummy0 up; ip addr show dev dummy0 | grep -q 192.0.2.1 || ip addr add 192.0.2.1/32 dev dummy0'
ExecStart=/usr/local/bin/tailscaled --tun=userspace-networking --socks5-server=127.0.0.1:1055 --state=/var/lib/tailscale/tailscaled.state --socket=/tmp/tailscaled.sock
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  echo "юнит tailscaled.service пересоздан"
fi
if [ ! -f /etc/systemd/system/tailscale-backup.service ]; then
  sudo tee /etc/systemd/system/tailscale-backup.service >/dev/null <<'EOF'
[Unit]
Description=Copy tailscale state into the workspace backup
[Service]
Type=oneshot
ExecStart=/bin/sh -c '/bin/cp /var/lib/tailscale/tailscaled.state /home/user/arena-bridge/ts-backup/tailscaled.state && /bin/chown user:user /home/user/arena-bridge/ts-backup/tailscaled.state'
EOF
  sudo tee /etc/systemd/system/tailscale-backup.timer >/dev/null <<'EOF'
[Unit]
Description=Periodic tailscale state backup
[Timer]
OnCalendar=*:0/10
Unit=tailscale-backup.service
[Install]
WantedBy=timers.target
EOF
  echo "таймер бэкапа пересоздан"
fi

echo "== 3. сеть (dummy0) =="
ip link show dummy0 >/dev/null 2>&1 || sudo ip link add dummy0 type dummy
sudo ip link set dummy0 up
ip addr show dev dummy0 | grep -q "192.0.2.1" || sudo ip addr add 192.0.2.1/32 dev dummy0
echo "dummy0 ok"

echo "== 4. состояние =="
sudo mkdir -p /var/lib/tailscale
if [ ! -s "$STATE" ] && [ -s "$BACKUP" ]; then
  sudo cp "$BACKUP" "$STATE" && echo "восстановлено из бэкапа"
elif [ -s "$STATE" ]; then
  echo "на месте"
else
  echo "состояния нет (потребуется логин/ключ)"
fi

echo "== 5. демон =="
sudo systemctl daemon-reload
sudo systemctl enable --now tailscaled.service tailscale-backup.timer >/dev/null 2>&1
systemctl is-active --quiet tailscaled.service || { sudo systemctl restart tailscaled.service; sleep 3; }
echo "tailscaled: $(systemctl is-active tailscaled.service)"

echo "== 6. логин =="
if sudo $TS --socket="$SOCK" status 2>&1 | grep -qi "logged out"; then
  if [ -s "$AUTHKEY" ]; then
    echo "логинюсь по auth-key ..."
    sudo timeout 60 $TS --socket="$SOCK" up --authkey="$(cat "$AUTHKEY")" --hostname=arena-agent --accept-dns=false 2>&1 | head -3
  else
    echo ""
    echo "*** НУЖЕН ЛОГИН ***"
    echo "Попроси у пользователя Tailscale auth key (tskey-auth-…), сохрани:"
    echo "  mkdir -p $RUNTIME && printf '%s' '<KEY>' > $AUTHKEY && chmod 600 $AUTHKEY"
    echo "и повтори этот скрипт."
    echo "(или, если пользователь рядом: sudo $TS --socket=$SOCK up --hostname=arena-agent --accept-dns=false — даст ссылку)"
  fi
fi
sudo $TS --socket="$SOCK" status 2>&1 | head -8

echo "== 7. поиск ПК (windows) в tailnet =="
PEER="$(sudo $TS --socket="$SOCK" status --json 2>/dev/null | python3 -c '
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
' 2>/dev/null)"
if [ -n "$PEER" ]; then
  echo "$PEER" > "$RUNTIME/host.txt"
  echo "22" > "$RUNTIME/port.txt"
  echo "127.0.0.1:1055" > "$RUNTIME/socks.txt"
  echo "ПК найден: $PEER (записан в host.txt/port.txt/socks.txt)"
else
  echo "ПК (windows) в tailnet не найден — проверь, что Tailscale на ПК онлайн"
fi

echo "== 8. ping =="
if [ -x "$RUNTIME/remote.sh" ] && [ -s "$RUNTIME/host.txt" ]; then
  timeout 40 "$RUNTIME/remote.sh" ping 2>&1 | head -3 || true
fi

echo "== 9. бэкап состояния =="
sudo cp "$STATE" "$BACKUP" 2>/dev/null && sudo chown user:user "$BACKUP" && echo "обновлён" || echo "(не критично)"

echo ""
echo "ГОТОВО. Работать: $RUNTIME/remote.sh ping|cmd|psc|ps|get|put|elev ..."
