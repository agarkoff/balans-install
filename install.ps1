# Установка Баланса одной командой (PowerShell, Windows):
#
#   irm https://raw.githubusercontent.com/agarkoff/balans-install/main/install.ps1 | iex
#
# Скрипт скачивает установщик в папку C:\Баланс (другая - через переменную
# BALANS_DIR) и запускает его. Само приложение скачивается установщиком из
# реестра образов, здесь только compose.yml, установщик и обновлятор.
# Повторный запуск - обновление: файлы заменяются, база, настройки и выписки
# (.env, data) не трогаются.
#
# Файл в UTF-8 с BOM - иначе PowerShell 5.1 ломает русский текст при запуске из файла.

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Base = "https://raw.githubusercontent.com/agarkoff/balans-install/main"
$Files = @(
    "compose.yml",
    "tools/balans.ps1",
    "tools/updater/run.sh",
    "Установить.cmd",
    "Как установить.txt"
)
$Dir = if ($env:BALANS_DIR) { $env:BALANS_DIR } else { Join-Path $env:SystemDrive "Баланс" }

function Say([string]$text, [string]$color = "Cyan") { Write-Host $text -ForegroundColor $color }

Say "Баланс: скачиваю установщик в $Dir ..."
foreach ($file in $Files) {
    $target = Join-Path $Dir ($file -replace "/", "\")
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
    $url = "$Base/" + (($file -split "/" | ForEach-Object { [uri]::EscapeDataString($_) }) -join "/")
    $ok = $false
    for ($attempt = 1; $attempt -le 3 -and -not $ok; $attempt++) {
        try {
            Invoke-WebRequest -Uri $url -OutFile $target -UseBasicParsing
            $ok = ((Get-Item $target).Length -gt 0)
        } catch {
            if ($attempt -eq 3) { throw "Не скачался файл ${file}: $($_.Exception.Message)" }
            Start-Sleep -Seconds (2 * $attempt)
        }
    }
}

if ($env:BALANS_NO_RUN) { Say "Файлы скачаны (BALANS_NO_RUN): установщик не запускаю." "Yellow"; return }

Say "Запускаю установщик. Откроется окно с ходом установки." "Green"
Start-Process powershell.exe -ArgumentList @(
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden",
    "-File", "`"$(Join-Path $Dir 'tools\balans.ps1')`"", "install"
)
