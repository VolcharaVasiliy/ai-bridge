# QWEN.md — правила и факты для агента Qwen (песочница Arena)

Дополнение к корневому `AGENTS.md` и `README.md`. Общий порядок работы с мостом —
там; здесь только то, что отличается именно в песочнице Qwen/Arena, готовые скрипты
под неё и жёсткие правила.

Проверено реальным прогоном 2026-10-11: Debian 12, root, kata-containers, overlay-fs.

## 0. Быстрый старт

```bash
# 1) клон — в корень workspace (это единственное персистентное место)
git clone https://github.com/VolcharaVasiliy/ai-bridge.git

# 2) поднять мост: пакеты, tailscaled, логин, конфиги, ping
bash ai-bridge/qwen/boot.sh

# 3) работать
ai-bridge/qwen/r.sh ping                 # → PONG
ai-bridge/qwen/r.sh cmd 'ver'
ai-bridge/qwen/r.sh psc 'Get-Service sshd | Select-Object Status'
ai-bridge/qwen/r.sh elev - < task.ps1
```

Если `boot.sh` напечатал `*** НУЖЕН ЛОГИН ***` — попроси у владельца Tailscale auth
key (`tskey-auth-…`), сохрани в `<runtime>/.ts-authkey` (`chmod 600`) и повтори шаг 2.
Ключ не коммитить, в чат целиком не выводить, в логах маскировать.

`<runtime>` по умолчанию — каталог `arena-bridge` рядом с клоном (переопределяется
переменной `ARENA_BRIDGE_DIR`). Внутри: `host.txt`, `port.txt`, `socks.txt`,
`remote.sh`, `r`, `.ts-authkey`, `ts-backup/tailscaled.state`.

## 1. Отличия среды от той, под которую писали linux/ts-boot.sh

| Факт о среде | Следствие |
|---|---|
| root, но нет `sudo` | `sudo` из `ts-boot.sh` падает; все команды и так от root |
| Нет systemd (`/run/systemd` отсутствует) | Юниты и таймеры бесполезны: `tailscaled` демоном через `setsid nohup ... & disown` |
| Нет `CAP_NET_ADMIN` | `ip link add dummy0` даёт `RTNETLINK answers: Operation not permitted`. И не нужно: есть `eth0` с глобальным IP |
| Нет TUN | Только `--tun=userspace-networking` плюс `--socks5-server=127.0.0.1:1055` |
| Персистентен только workspace, `$HOME=/tmp` эфемерен | Ключи, `known_hosts`, конфиги и состояние узла держать в workspace |
| Пути workspace транслируются в длинный внутренний путь (`$ARENA_WORKSPACE`, overlay) | `ControlPath=$HOME/.ssh/cm-%r@%h:%p` даёт `ControlPath too long (… >= 108 bytes)`, хотя на вид путь короткий. Сокет мультиплексирования — только `/tmp/cm-%C` |
| Литерал пути workspace в тексте bash-команды подменяется на `"$ARENA_WORKSPACE"` | В скриптах пути выводить из `dirname $0`, не хардкодить; heredoc и inline-python с такими путями ломаются |
| apt-кэш пуст, зеркало `mirrors.aliyun.com` | Перед `apt-get install` обязательно `apt-get update` |
| Из коробки нет `curl ssh scp nc ip ps` | `boot.sh` ставит `openssh-client netcat-openbsd curl iproute2 procps ca-certificates` |
| Фоновые процессы могут не пережить вызов инструмента | Демон через `setsid nohup`, каждый ход проверять `pgrep -x tailscaled` |
| Вывод PowerShell приходит в OEM-кодовой странице 866 | Кириллица: начинать команду с `[Console]::OutputEncoding=[Text.Encoding]::UTF8;` (режим `elev` делает это сам) |
| Вложенные кавычки в `psc '...'` и `elev '...'` ломаются | Многострочные задания — только через `r.sh ps < file.ps1` и `r.sh elev - < file.ps1` |

## 2. Правила

**Ключи и секреты**

1. Существующий ssh-ключ агента не пересоздавать: иначе владельцу придётся заново
   проходить UAC и `add-key.ps1`. Новый ключ — только если файла действительно нет.
2. Секреты (`.ts-authkey`, приватный ключ, `tailscaled.state`) держать только в
   `<runtime>`, `chmod 600`, никогда не коммитить и не выводить целиком. В отчётах —
   маска: `tskey-***`, `SHA256:D81ue/…`.
3. Auth-key нужен один раз на узел. После успешного логина напомнить владельцу
   отозвать его в админке Tailscale: отзыв ключа не отключает узлы, которые уже
   зарегистрированы в tailnet, так что доступ агента сохранится.
4. Не выводить содержимое `tailscaled.state` и не копировать его никуда, кроме
   `<runtime>/ts-backup/`.

**Что можно и нельзя на ПК**

5. Админ-задачи — только через `r.sh elev` (раннер `ArenaElev`), обычный `cmd`/`psc`
   идёт от пользователя без повышения.
6. Не отключать `sshd` и фаервол, не менять ACL файлов ключей и `sshd_config`
   без явного запроса владельца.
7. Разрушительные действия (удаление файлов, переустановка ОС-настроек, правка
   критичных веток реестра, остановка служб, удаление программ) — только после
   явного подтверждения владельца в чате.
8. Не ставить и не обновлять софт на ПК без запроса.
9. Без явной команды владельца: не пушить в репозиторий, не переписывать
   git-историю, не создавать ветки и релизы.
10. Временные файлы на ПК — в `C:\Users\gamer\agent-bridge\tmp\`, удалять за собой.
11. Не читать и не переносить в workspace личные данные (профили браузеров,
    документы, сохранённые пароли и токены), если это не требуется задачей.

**Ресурсы ПК**

12. RAM 12 GB, свободно часто меньше 1 GB: перед тяжёлой операцией проверить
    память, не запускать несколько ресурсоёмких задач параллельно.
13. Диск C: около 130 GB, свободно порядка 21 GB. Крупные загрузки и архивы —
    на F: (300 GB, свободно около 230 GB).

**Гигиена хода**

14. В начале хода — `bash qwen/boot.sh` (идемпотентен, занимает секунды) или
    как минимум `r.sh ping`.
15. Бэкап состояния узла обновляется шагом 10 `boot.sh`; после ручных операций с
    `tailscale` обновить его явно.
16. В отчёте владельцу: что выполнено, какие файлы на ПК изменены, что осталось.

## 3. Факты о ПК (чтобы не выяснять заново)

| Что | Значение |
|---|---|
| Узел в tailnet | `DESKTOP-GD5KFIO` → `100.108.234.88` |
| ОС | Windows 10 Pro, build 19045 (10.0.19045.6456), x64 |
| Железо | ASUSTeK PRIME Z370-A, 12 GB RAM |
| Диски | C: 130 GB (свободно около 21), D: 30 GB (около 21), F: 300 GB (около 230) |
| Пользователь SSH | `gamer`, входит в группу Administrators |
| SSH-сервер | OpenSSH_for_Windows_9.5, порт 22, только ключи |
| Файлы ключей | `C:\ProgramData\ssh\administrators_authorized_keys` и `C:\Users\gamer\.ssh\authorized_keys` |
| Раннер админ-задач | задача `ArenaElev` → `C:\Users\gamer\agent-bridge\elev\` (`hb.txt`, `in\`, `out\`, `run\`, `elev.log`) |
| git | 2.51, `F:\DevTools\Portable\MinGit\cmd\git.exe` |
| GitHub CLI | 2.68, `F:\DevTools\gh\bin\gh.exe`, аккаунт `VolcharaVasiliy`, протокол https, credential helper через `gh auth git-credential` |
| Клон этого репо на ПК | `C:\Users\gamer\ai-bridge`, ветка `main` |

Данные снимались 2026-10-11 и могут устареть: при расхождении сверять через `r.sh psc`.

## 4. Пульт `r.sh`

Обёртка над `linux/remote.sh` — сама выставляет `HOME`, `ARENA_BRIDGE_DIR`, путь к ключу
 и пропатченный `ControlPath`, поэтому работает прямо из клона.

| Команда | Назначение |
|---|---|
| `r.sh ping` | проверка связи, ждём `PONG` |
| `r.sh cmd 'команда'` | `cmd.exe` на ПК |
| `r.sh psc 'команда'` | PowerShell одной строкой (для кириллицы нужен префикс UTF-8) |
| `r.sh ps < file.ps1` | PowerShell-скрипт из stdin |
| `r.sh get 'C:/путь/файл' ./локально` | скачать файл с ПК |
| `r.sh put ./локально 'C:/путь/'` | загрузить файл на ПК |
| `r.sh elev 'команда'` | выполнить с правами администратора, стрим вывода |
| `r.sh elev - < file.ps1` | то же, скриптом из stdin (надёжный способ для многострочного) |
| `r.sh elev-check` | жив ли раннер (`hb.txt`), занят или свободен |
| `r.sh elev-out <id>` | вывод долгого задания |
| `r.sh elev-stop` | остановить раннер после текущего задания |

Пути в `scp` — с прямыми слэшами: `C:/Users/gamer/...`.

## 5. Диагностика

| Симптом | Причина и лечение |
|---|---|
| `pgrep tailscaled` пусто | `bash qwen/boot.sh` — поднимет демон заново |
| `Logged out` в `tailscale status` | нет состояния: нужен `.ts-authkey` и повторный `up` |
| `ControlPath too long` | сокет мультиплексирования попал в workspace; должен быть `/tmp/cm-%C` (патч делает `r.sh`/`boot.sh`) |
| `Permission denied (publickey)` | ключ агента не авторизован на ПК. Владелец запускает `windows/add-key.ps1 -Key "<pub>"`, при проблемах с ACL — `qwen/win-diag.ps1` |
| `No matching host key type` / `Host key verification failed` | удалить строку узла из `known_hosts` в workspace и переподключиться с `StrictHostKeyChecking=accept-new` |
| `Connection timed out` при живом tailnet | ПК ушёл в сон или Tailscale на нём выключен — попросить владельца проверить |
| Кириллица в выводе `psc` нечитаемая | добавить в начало команды `[Console]::OutputEncoding=[Text.Encoding]::UTF8;` |
| `ParserError` в задании `elev` | вложенные кавычки; передавать скрипт через `r.sh elev - < file.ps1` |
| `[elev] раннер НЕ работает` | владелец один раз запускает `windows/elev/enable-elev.ps1` от администратора |
| apt не находит пакеты | сначала `apt-get update` (зеркало aliyun) |

## 6. Файлы этой папки

| Файл | Назначение |
|---|---|
| `QWEN.md` | этот документ: факты о среде, правила, диагностика |
| `boot.sh` | самовосстановление моста: пакеты, бинарники tailscale, демон, логин, поиск ПК, конфиги, ping, бэкап состояния |
| `r.sh` | пульт: обёртка над `linux/remote.sh` с верными `HOME`/конфигом и патчем `ControlPath` |
| `win-diag.ps1` | диагностика и починка авторизации SSH-ключа на ПК (запускает владелец от администратора) |

## 7. Требования к файлам в этом репозитории

Форматы заданы в `.gitattributes`, но есть ловушка, на которую легко напороться:

- `*.ps1` — **UTF-8 с BOM** и CRLF. Windows PowerShell 5.1 без BOM читает файл как
  ANSI (в русской системе — CP1251), кириллица в строках превращается в мусор и
  разбор заканчивается ошибками вида «Непредвиденная лексема». Все существующие `.ps1` в репозитории начинаются с `EF BB BF` —
  при создании нового файла это нужно повторить.
- `*.sh`, `*.md`, `*.txt` — LF.
- Секреты и рантайм (`.ts-authkey`, `*.tskey*`, `ts-backup/`, `tailscaled.state`,
  `host.txt`, `port.txt`, `socks.txt`, логи) уже покрыты `.gitignore` — новый
  runtime-каталог `arena-bridge/` не должен попадать в репозиторий.
- Перед коммитом проверить: `git status --porcelain` пустой по секретам,
  `bash -n` для `.sh`, разбор через `[System.Management.Automation.Language.Parser]::ParseFile`
  для `.ps1`.
