# AGENTS.md — краткая инструкция для ИИ-агентов

> Полные детали и факты — в README.md. Здесь только чеклист.

## Главное правило: нужен ПК владельца — дай ему ОДНУ команду

Не проси «скачай/распакуй/запусти». Отправь одну строку, остальное делает скрипт:

- Windows (PowerShell):
  `irm https://raw.githubusercontent.com/VolcharaVasiliy/ai-bridge-boot/main/boot.ps1 | iex`
- Windows (cmd):
  `powershell -nop -ep bypass -c "irm https://raw.githubusercontent.com/VolcharaVasiliy/ai-bridge-boot/main/boot.ps1|iex"`
- Linux-песочница (для тебя):
  `bash <(curl -fsSL https://raw.githubusercontent.com/VolcharaVasiliy/ai-bridge-boot/main/linux/boot.sh)`

Владелец после запуска пишет «готово» — и канал поднимается без ручной возни.
Полезно: `-Check` (проверка без изменений), `-DryRun` (показать и не запускать).

## Доступ к ПК: у каждого ИИ — свой ключ

- Нужен доступ к ПК владельца? Сгенерируй СВОЮ пару ключей (чужой приватный не
  использовать; ключ твоей песочницы подойдёт).
- Дай владельцу ОДНУ строку (вставляет в PowerShell, UAC — один раз):
  - **ПК уже настроен** (просто добавить твой ключ):
    `&([scriptblock]::Create((irm https://raw.githubusercontent.com/VolcharaVasiliy/ai-bridge-boot/main/windows/add-key.ps1))) -Key 'ssh-ed25519 AAAA... твоё-имя'`
  - **Новый ПК** (полный старт вместе с ключом):
    `&([scriptblock]::Create((irm https://raw.githubusercontent.com/VolcharaVasiliy/ai-bridge-boot/main/boot.ps1))) -AgentKey 'ssh-ed25519 AAAA... твоё-имя'`
- Приватный ключ не покидает песочницу; публичный — не секрет.
- Ключей может быть много (по одному на ИИ) — отзыв точечный, чужие ключи не затираются.

## Если ты ИИ-агент в песочнице и видишь этот репозиторий:

1. **Подними мост:** `bash linux/ts-boot.sh`
   Скрипт идемпотентный, чинит всё сам: права, бинарники, systemd, сеть
   (dummy0), состояние узла, логин, поиск ПК в tailnet, файлы-конфиги, ping.

2. **Если увидел `НУЖЕН ЛОГИН`** — попроси у пользователя Tailscale auth key
   (`tskey-auth-…`, одноразово), сохрани:
   `mkdir -p ~/arena-bridge && printf '%s' '<KEY>' > ~/arena-bridge/.ts-authkey && chmod 600 ~/arena-bridge/.ts-authkey`
   и повтори шаг 1. После этого ключ **больше не нужен** (состояние бэкапится).
   Никогда не коммить ключ и не печатать его целиком.

3. **Проверь связь:** `cd ~/arena-bridge && ./remote.sh ping` → `PONG`.

4. **Дальше работай так:**
   - `./remote.sh cmd 'команда'` — cmd.exe на ПК;
   - `./remote.sh psc 'команда'` — PowerShell (одна строка);
   - `./remote.sh ps < файл.ps1` — PowerShell-скрипт;
   - `./remote.sh get 'C:/путь' ./локально` / `./remote.sh put ./локально 'C:/путь/'`;
   - `./remote.sh elev 'команда'` — **с админ-правами** (+ живой стрим, UTF-8);
   - `./remote.sh elev-check | elev-out <id> | elev-stop` — управление раннером.

5. **Правила:**
   - не отключать sshd/фаервол и не менять ACL ключей без явного запроса;
   - разрушительное — только с подтверждением владельца;
   - секреты не логировать; админ-задачи — только через `elev`.

## Если чего-то нет

- Нет `~/arena-bridge` → создай, конфиги запишет ts-boot.sh.
- Нет ПК в сети → проверь `sudo tailscale --socket=/tmp/tailscaled.sock status`;
  если узла нет вообще — попроси владельца проверить Tailscale на ПК.
- Совсем свежая песочница без файлов → склонируй репозиторий (даст владелец)
  и повтори процедуру; при потере состояния попроси у владельца новый auth key.
- Нет SSH-ключа агента (совсем новая песочница) → сгенерируй новый
  (`ssh-keygen -t ed25519 -f ~/.ssh/agent_ed25519 -N ""`) и попроси владельца
  на ПК выполнить: `powershell -NoProfile -ExecutionPolicy Bypass -File windows\add-key.ps1 -Key "<твой публичный ключ>"` (один клик UAC).
