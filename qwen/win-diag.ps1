<#
  win-diag.ps1 — диагностика и починка авторизации SSH-ключа агента на этом ПК.
  ---------------------------------------------------------------------------
  Нужен, когда агент в песочнице получает `Permission denied (publickey)`,
  хотя ключ вроде бы добавлен: обычно виноваты унаследованные ACL на
  administrators_authorized_keys (sshd с StrictModes такой файл не читает),
  разбитая на несколько строк запись ключа или не перезапущенный sshd.

  Запуск ОТ АДМИНИСТРАТОРА:
    только диагностика (ничего не менять):
      powershell -NoProfile -ExecutionPolicy Bypass -File win-diag.ps1 -Check
    диагностика + починка конкретного ключа:
      powershell -NoProfile -ExecutionPolicy Bypass -File win-diag.ps1 -Key "ssh-ed25519 AAAA... arena-agent"

  Скрипт идемпотентен: дубли и битые строки с тем же тегом убираются,
  ключ кладётся одной строкой, ACL выставляются по SID, sshd перезапускается.
#>

param(
  [string]$Key = '',
  [switch]$Check
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

$Adm = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
$Usr = Join-Path $env:USERPROFILE '.ssh\authorized_keys'
$Cfg = Join-Path $env:ProgramData 'ssh\sshd_config'
$Tag = ''
if ($Key.Trim()) {
  $Key = $Key.Trim()
  $parts = $Key -split '\s+'
  if ($parts.Count -ge 3) { $Tag = $parts[2] } else { $Tag = $parts[1] }
}

function H([string]$t) { Write-Host ""; Write-Host "=== $t ===" -ForegroundColor White }

H 'КТО ЗАПУСТИЛ'
whoami
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr = New-Object Security.Principal.WindowsPrincipal($id)
$isAdmin = $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Host ("admin: {0}    USERPROFILE: {1}" -f $isAdmin, $env:USERPROFILE)
Write-Host ("sid: {0}" -f $id.User.Value)

H "ФАЙЛ АДМИНИСТРАТОРОВ: $Adm"
if (Test-Path $Adm) {
  $lines = @(Get-Content $Adm -ErrorAction SilentlyContinue)
  Write-Host ("строк: {0}" -f $lines.Count)
  $lines | ForEach-Object { Write-Host ("|{0}|" -f $_) -ForegroundColor DarkGray }
  Write-Host '--- icacls ---'
  icacls $Adm
  Write-Host ("владелец: {0}" -f (Get-Acl $Adm).Owner)
} else { Write-Host 'НЕТ ФАЙЛА' -ForegroundColor Red }

H "ФАЙЛ ПОЛЬЗОВАТЕЛЯ: $Usr"
if (Test-Path $Usr) {
  @(Get-Content $Usr -ErrorAction SilentlyContinue) | ForEach-Object { Write-Host ("|{0}|" -f $_) -ForegroundColor DarkGray }
} else { Write-Host 'НЕТ ФАЙЛА' -ForegroundColor Yellow }

H 'СЛУЖБЫ'
foreach ($s in @('sshd','ssh-agent')) {
  $sv = Get-Service $s -ErrorAction SilentlyContinue
  if ($sv) { Write-Host ("  {0}: {1} (тип запуска: {2})" -f $s, $sv.Status, $sv.StartType) }
  else { Write-Host "  $s : НЕ УСТАНОВЛЕНА" -ForegroundColor Red }
}

H 'sshd_config — ключевые строки'
if (Test-Path $Cfg) {
  Select-String -Path $Cfg -Pattern '^\s*(PubkeyAuthentication|AuthorizedKeysFile|StrictModes|PasswordAuthentication|AllowUsers|DenyUsers|Match|Subsystem|Port)' |
    ForEach-Object { Write-Host ("  {0,4}: {1}" -f $_.LineNumber, $_.Line) }
} else { Write-Host '  sshd_config не найден' -ForegroundColor Red }

H 'Журнал OpenSSH (последние записи про авторизацию)'
try {
  Get-WinEvent -LogName 'OpenSSH/Operational' -MaxEvents 40 -ErrorAction Stop |
    Where-Object { $_.Message -match 'auth|key|denied|ownership|invalid|refused' } |
    Select-Object -First 12 |
    ForEach-Object { Write-Host ("  {0}  {1}" -f $_.TimeCreated.ToString('MM-dd HH:mm:ss'), ($_.Message -replace "`r`n", ' ')) -ForegroundColor DarkGray }
} catch { Write-Host ("  журнал недоступен: {0}" -f $_.Exception.Message) -ForegroundColor Yellow }

if ($Check) {
  Write-Host ''; Write-Host 'РЕЖИМ ПРОВЕРКИ — ничего не менялось.' -ForegroundColor Cyan
  return
}
if (-not $Key) {
  Write-Host ''; Write-Host 'Не указан -Key, поэтому только диагностика.' -ForegroundColor Yellow
  return
}
if (-not $isAdmin) {
  Write-Host ''; Write-Host 'Для починки нужны права администратора — перезапустите от админа.' -ForegroundColor Red
  return
}
if ($Key -notmatch '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|sk-)') {
  Write-Host ''; Write-Host 'Похоже, это не публичный ключ — починка отменена.' -ForegroundColor Red
  return
}

H 'ПОЧИНКА'
foreach ($f in @($Adm, $Usr)) {
  $keep = @()
  if (Test-Path $f) {
    $keep = @(Get-Content $f -ErrorAction SilentlyContinue |
      Where-Object { $_.Trim() -ne '' -and (-not $Tag -or $_ -notmatch [regex]::Escape($Tag)) })
  }
  $keep += $Key
  New-Item -ItemType Directory -Force -Path (Split-Path $f) | Out-Null
  Set-Content -LiteralPath $f -Value $keep -Encoding Ascii
  Write-Host ("  [ok] перезаписан {0} (строк: {1})" -f $f, $keep.Count) -ForegroundColor Green
}

icacls $Adm /inheritance:r 2>&1 | Out-Null
icacls $Adm /grant '*S-1-5-32-544:F' '*S-1-5-18:F' 2>&1 | Out-Null
icacls $Adm /setowner '*S-1-5-32-544' 2>&1 | Out-Null
icacls $Usr /inheritance:r 2>&1 | Out-Null
icacls $Usr /grant "${env:USERNAME}:F" '*S-1-5-32-544:F' '*S-1-5-18:F' 2>&1 | Out-Null
Write-Host '  [ok] ACL выставлены (Administrators + SYSTEM, наследование снято)' -ForegroundColor Green
Write-Host '--- icacls после починки ---'
icacls $Adm

if (Test-Path $Cfg) {
  if (-not (Select-String -Path $Cfg -Pattern 'administrators_authorized_keys' -Quiet)) {
    Add-Content -Path $Cfg -Encoding Ascii -Value "`r`nMatch Group administrators`r`n       AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys"
    Write-Host '  [ok] в sshd_config добавлен блок Match Group administrators' -ForegroundColor Green
  }
  Set-Service sshd -StartupType Automatic -ErrorAction SilentlyContinue
  Restart-Service sshd -Force
  Start-Sleep -Seconds 2
  Write-Host ("  [ok] sshd: {0}" -f (Get-Service sshd).Status) -ForegroundColor Green
}

Write-Host ''
Write-Host ("Готово. Ключ ""{0}"" должен приниматься. Агенту можно сказать: проверь." -f $Tag) -ForegroundColor Cyan
