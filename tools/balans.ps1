# Баланс: установка и запуск на Windows одной кнопкой, с окном хода.
#
#   balans.ps1 install  — поставить подсистему Linux (WSL) и Docker Desktop
#                         (если их нет; нужны права администратора — UAC),
#                         создать .env, собрать и запустить систему, ярлыки на
#                         рабочем столе. Если установка требует перезагрузки,
#                         спросит, перезагрузит и сама продолжит при следующем
#                         входе в Windows (RunOnce); повторный запуск безопасен.
#   balans.ps1 start    — запустить и открыть в браузере (ярлык «Баланс»)
#   balans.ps1 stop     — остановить (ярлык «Баланс — остановить»)
#   balans.ps1 update   — скачать выписки банков (ярлык «Обновить выписки»):
#                         окно Яндекс Браузера со своим профилем, сборщики
#                         в контейнере collector, Т-Инвестиции — по токену
#   balans.ps1 shortcuts — только ярлыки на рабочем столе для этой папки
#                         (у разработчика: система уже стоит, ставить нечего)
#
# Настройки запуска в .env (по умолчанию — как у установленной системы):
#   COMPOSE_PROJECT — имя compose-проекта (balans);
#   APP_SERVICES    — что поднимать (db api); у разработчика — db api-dev web;
#   APP_URL         — что открывать (http://127.0.0.1:PORT); у разработчика —
#                     Vite, http://127.0.0.1:VITE_PORT;
#   BROWSER_PROFILE, COLLECTOR_API_URL — см. «Обновить выписки».
#
# Файл в UTF-8 с BOM: без BOM Windows PowerShell 5.1 читает его в cp1251 и
# русский текст ломает разбор скрипта. Повторный запуск безопасен: что уже
# сделано, пропускается. Журнал — install.log рядом с compose.yml.
#
# Окно не зависает на долгих командах (сборка — минуты): каждая внешняя
# команда идёт отдельным процессом, её вывод читается из файла, а окно
# между чтениями обрабатывает свои события.

param([ValidateSet("install", "start", "stop", "update", "shortcuts")][string]$Action = "start")

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"   # полоса Invoke-WebRequest в 5.1 тормозит запросы
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$Root = Split-Path -Parent $PSScriptRoot
$Project = "balans"   # или COMPOSE_PROJECT из .env (у разработчика — свой проект)
$EnvFile = Join-Path $Root ".env"
$LogFile = Join-Path $Root "install.log"
$DockerExe = Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe"
# Дочерние процессы внешних команд (docker и т.п.): при закрытии окна их
# добиваем — иначе контейнеры сборщиков остаются жить на демоне (Stop-Collectors).
$script:children = New-Object System.Collections.ArrayList

function Read-EnvValue([string]$key, [string]$file = $EnvFile) {
    if (-not (Test-Path $file)) { return $null }
    foreach ($line in [IO.File]::ReadAllLines($file)) {
        if ($line -match "^$key=(.*)$") { return $Matches[1] }
    }
    return $null
}

function Set-EnvValue([string]$key, [string]$value) {
    $lines = @(if (Test-Path $EnvFile) { [IO.File]::ReadAllLines($EnvFile) })
    $found = $false
    $lines = @($lines | ForEach-Object { if ($_ -match "^$key=") { $found = $true; "$key=$value" } else { $_ } })
    if (-not $found) { $lines += "$key=$value" }
    [IO.File]::WriteAllLines($EnvFile, $lines, (New-Object System.Text.UTF8Encoding($false)))
}

# Источник сборщика (scrape/update.py) → номер шага в окне «Обновить выписки»
# и название банка. Какие качать — галочки в окне, запоминаются в
# UPDATE_SOURCES (.env): банки есть не у всех.
$SourceSteps = [ordered]@{ tbank = 2; sber_invest = 3; sber = 4; vtb = 5; ozon = 6;
                           alfa = 7; wb = 8; x5 = 9; wb_orders = 10; yandex_feed = 11;
                           ozon_orders = 12; mco = 13; plati = 14; market_orders = 15;
                           sovcombank = 17; bspb = 18 }
$SourceTitles = @{ tbank = "Т-Банк"; sber_invest = "Сбер Инвестиции"; sber = "Сбербанк";
                   vtb = "ВТБ"; ozon = "Озон"; alfa = "Альфа-Банк"; wb = "WB Банк";
                   x5 = "X5 Клуб"; wb_orders = "WB (покупки)"; yandex_feed = "Яндекс Пэй";
                   ozon_orders = "Озон (заказы)"; mco = "Мои чеки онлайн";
                   plati = "Plati.Market"; market_orders = "Яндекс Маркет";
                   sovcombank = "Совкомбанк"; bspb = "Банк Санкт-Петербург" }
$savedSources = Read-EnvValue "UPDATE_SOURCES"
$ChosenSources = if ($savedSources -ne $null) { @($savedSources -split "," | Where-Object { $_ }) } else { @($SourceSteps.Keys) }

# --------------------------------------------------------------- окно

$Steps = @{
    install = @("Подсистема Linux (WSL)", "Docker Desktop", "Запуск Docker", "Настройки",
                "Сборка и запуск (первый раз — 5–10 минут)", "Ярлыки на рабочем столе")
    start   = @("Запуск Docker", "Запуск системы")
    stop    = @("Остановка системы")
    update  = @("Система", "Окно Яндекс Браузера", "Т-Банк", "Сбер Инвестиции", "Сбербанк",
                "ВТБ", "Озон", "Альфа-Банк", "WB Банк", "X5 Клуб", "WB (покупки)",
                "Яндекс Пэй", "Озон (заказы)", "Мои чеки онлайн", "Plati.Market",
                "Яндекс Маркет", "Т-Инвестиции", "Совкомбанк", "Банк Санкт-Петербург")
    shortcuts = @("Ярлыки на рабочем столе")
}[$Action]
$Titles = @{ install = "Установка Баланса"; start = "Запуск Баланса"; stop = "Остановка Баланса"
             update = "Обновление выписок"; shortcuts = "Ярлыки Баланса" }

$form = New-Object System.Windows.Forms.Form
$form.Text = $Titles[$Action]
$form.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.ClientSize = New-Object System.Drawing.Size(640, $(if ($Action -eq "update") { 150 + $Steps.Count * 28 } elseif ($Action -eq "install") { 520 } else { 300 }))

$y = 16
$stepLabels = @()
$sourceByStep = @{}
if ($Action -eq "update") { foreach ($k in $SourceSteps.Keys) { $sourceByStep[$SourceSteps[$k]] = $k } }
foreach ($s in $Steps) {
    $i = $stepLabels.Count
    if ($sourceByStep.ContainsKey($i)) {
        # банк — галочка: качать или нет
        $l = New-Object System.Windows.Forms.CheckBox
        $l.Checked = $ChosenSources -contains $sourceByStep[$i]
        $l.Text = $s
    } else {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = "○  $s"
    }
    $l.AutoSize = $true
    $l.Location = New-Object System.Drawing.Point(20, $y)
    $l.ForeColor = [System.Drawing.Color]::$(if ($l -is [System.Windows.Forms.CheckBox]) { "Black" } else { "Gray" })
    $form.Controls.Add($l)
    $stepLabels += $l
    $y += 28
}

$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Style = "Marquee"
$progress.MarqueeAnimationSpeed = 30
$progress.Location = New-Object System.Drawing.Point(20, ($y + 6))
$progress.Size = New-Object System.Drawing.Size(600, 14)
$form.Controls.Add($progress)

$status = New-Object System.Windows.Forms.Label
$status.Location = New-Object System.Drawing.Point(20, ($y + 28))
$status.Size = New-Object System.Drawing.Size(600, 44)
$form.Controls.Add($status)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Multiline = $true
$logBox.ScrollBars = "Vertical"
$logBox.ReadOnly = $true
$logBox.WordWrap = $false
$logBox.Font = New-Object System.Drawing.Font("Consolas", 8.5)
$logBox.Location = New-Object System.Drawing.Point(20, ($y + 76))
$logBox.Size = New-Object System.Drawing.Size(600, ($form.ClientSize.Height - $y - 136))
$form.Controls.Add($logBox)

$openButton = New-Object System.Windows.Forms.Button
$openButton.Text = "Открыть Баланс"
$openButton.Size = New-Object System.Drawing.Size(160, 32)
$openButton.Location = New-Object System.Drawing.Point(290, ($form.ClientSize.Height - 48))
$openButton.Enabled = $false
$form.Controls.Add($openButton)

# «Я вошёл — продолжить»: видна, только пока сборщики ждут входа в банк
$continueButton = New-Object System.Windows.Forms.Button
$continueButton.Text = "Я вошёл — продолжить"
$continueButton.Size = New-Object System.Drawing.Size(250, 32)
$continueButton.Location = New-Object System.Drawing.Point(20, ($form.ClientSize.Height - 48))
$continueButton.Visible = $false
$script:continued = $false
$continueButton.Add_Click({ $script:continued = $true })
$form.Controls.Add($continueButton)

$closeButton = New-Object System.Windows.Forms.Button
$closeButton.Text = "Закрыть"
$closeButton.Size = New-Object System.Drawing.Size(160, 32)
$closeButton.Location = New-Object System.Drawing.Point(460, ($form.ClientSize.Height - 48))
# Просто $form.Close() не закрывает окно, пока обработчик Add_Shown крутит
# DoEvents: ShowDialog вернётся только после его конца. Поэтому кнопка ставит
# флаг, а Pump обрывает работу (throw) — обработчик завершается, окно уходит.
$script:cancelled = $false
$closeButton.Add_Click({ $script:cancelled = $true; $form.Close() })
$form.Controls.Add($closeButton)
# крестик в заголовке (Alt+F4) закрывает окно мимо кнопки — тот же флаг
$form.Add_FormClosing({ $script:cancelled = $true })

class Cancelled : System.Exception { Cancelled() : base("Закрыто пользователем") {} }
function Pump {
    if ($script:cancelled) { throw [Cancelled]::new() }
    [System.Windows.Forms.Application]::DoEvents()
}

function Pause-Ui([double]$seconds) {
    $until = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $until) { Pump; Start-Sleep -Milliseconds 100 }
}

function Log([string]$text) {
    Add-Content -Path $LogFile -Value $text -Encoding UTF8
    $logBox.AppendText($text + "`r`n")
    Pump
}

function Set-Status([string]$text, [string]$color = "Black") {
    $status.Text = $text
    $status.ForeColor = [System.Drawing.Color]::$color
    Log ">> $text"
}

$script:current = -1
function Step([int]$index) {
    if ($script:current -ge 0) {
        $stepLabels[$script:current].Text = "✓  " + $Steps[$script:current]
        $stepLabels[$script:current].ForeColor = [System.Drawing.Color]::Green
    }
    $script:current = $index
    if ($index -lt $Steps.Count) {
        $stepLabels[$index].Text = "◐  " + $Steps[$index]
        $stepLabels[$index].ForeColor = [System.Drawing.Color]::Black
        $stepLabels[$index].Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    }
    Pump
}

# Отметка шага не по порядку (источники выписок идут независимо друг от друга).
function Mark([int]$index, [string]$state) {
    $look = @{
        run     = @("◐", "Black")
        ok      = @("✓", "Green")
        login   = @("!", "DarkOrange")
        error   = @("✗", "Firebrick")
        changed = @("✗", "Firebrick")
        skip    = @("–", "Gray")
    }[$state]
    $stepLabels[$index].Text = $look[0] + "  " + $Steps[$index]
    $stepLabels[$index].ForeColor = [System.Drawing.Color]::($look[1])
    Pump
}

class StepFailed : System.Exception { StepFailed([string]$m) : base($m) {} }
function Fail([string]$text) { throw [StepFailed]::new($text) }

# --------------------------------------------------------------- команды

# Внешняя команда отдельным процессом; вывод — в журнал и в окно по мере
# появления, каждая строка — ещё и в $OnLine (ход сборщиков). Возвращает код выхода.
function Run([string]$exe, [string]$arguments, [switch]$Quiet, [scriptblock]$OnLine) {
    $out = [IO.Path]::GetTempFileName()
    $err = [IO.Path]::GetTempFileName()
    if (-not $Quiet) { Log "$ $exe $arguments" }
    $p = Start-Process -FilePath $exe -ArgumentList $arguments -NoNewWindow -PassThru `
        -WorkingDirectory $Root -RedirectStandardOutput $out -RedirectStandardError $err
    $null = $p.Handle   # без этого ExitCode у Start-Process бывает пустым
    $null = $script:children.Add($p)
    $seen = @{ $out = 0; $err = 0 }
    $flush = {
        foreach ($f in @($out, $err)) {
            $fs = [IO.File]::Open($f, "Open", "Read", "ReadWrite")
            try {
                if ($fs.Length -gt $seen[$f]) {
                    $fs.Seek($seen[$f], "Begin") | Out-Null
                    $reader = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
                    $chunk = $reader.ReadToEnd()
                    $seen[$f] = $fs.Length
                    if (-not $Quiet -and $chunk.Trim()) { Log $chunk.TrimEnd() }
                    if ($OnLine) {
                        foreach ($line in ($chunk -split "`r?`n")) { if ($line) { & $OnLine $line } }
                    }
                }
            } finally { $fs.Dispose() }
        }
    }
    while (-not $p.HasExited) { & $flush; Pause-Ui 0.3 }
    $p.WaitForExit()
    & $flush
    $null = $script:children.Remove($p)
    Remove-Item $out, $err -ErrorAction SilentlyContinue
    return $p.ExitCode
}

# Базовые ключи docker compose: файл настроек, .env и папка проекта — всегда из
# папки установки, а не из текущей папки процесса. Без явного -f compose ищет
# compose.yml в текущей папке, и относительный RAW_DIR=./data/raw из .env
# разворачивался бы от чужого файла: выписки уходили не в data\raw рядом с .env.
# Функция, а не строка: имя проекта ($Project) уточняется из .env уже после загрузки.
function Get-ComposeBase {
    $base = "--project-directory `"$Root`" -f `"$(Join-Path $Root 'compose.yml')`""
    # Исходники рядом (система разработчика): образ собирается на месте.
    if (Test-BuildMode) { $base += " -f `"$(Join-Path $Root 'compose.build.yml')`"" }
    return "$base --env-file `"$EnvFile`" -p $Project"
}

# Есть compose.build.yml — образ собирается из исходников рядом, иначе его
# скачивают из реестра (так у пользователя по архиву: исходников в нём нет).
function Test-BuildMode { return (Test-Path (Join-Path $Root "compose.build.yml")) }

function Compose([string]$composeArgs) {
    $code = Run "docker" "compose $(Get-ComposeBase) $composeArgs"
    if ($code -ne 0) { Fail "Не получилось: docker compose $composeArgs (код $code). Подробности — в журнале ниже." }
}

function Test-DockerRunning { return ((Run "docker" "info" -Quiet) -eq 0) }

function Test-PortFree([int]$port) {
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $port)
    try { $listener.Start(); $listener.Stop(); return $true } catch { return $false }
}

function Find-FreePort([int]$from) {
    for ($p = $from; $p -lt $from + 100; $p++) { if (Test-PortFree $p) { return $p } }
    Fail "Не нашёлся свободный порт начиная с $from."
}

# Разбор кодировки вывода внешних программ. wsl.exe на русской Windows пишет
# UTF-16 без BOM (кириллица — байты вида 14 04, старший байт не ноль), docker —
# UTF-8. UTF-16 узнаём по управляющим символам, которые выходят, если прочитать
# UTF-16 как UTF-8.
function Decode-Text([byte[]]$bytes) {
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        return [Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2).Trim()
    }
    $utf8 = [Text.Encoding]::UTF8.GetString($bytes)
    if ($utf8 -match "[\x00-\x08\x0B\x0C\x0E-\x1F]") {
        return [Text.Encoding]::Unicode.GetString($bytes).Trim([char]0).Trim()
    }
    return $utf8.Trim()
}

# Вывод короткой команды целиком (без журнала) — для вопросов к Docker и WSL.
# Код выхода — в $script:captureExit (у Start-Process с редиректом его иначе не
# достать).
function Capture([string]$exe, [string]$arguments) {
    $out = [IO.Path]::GetTempFileName()
    $p = Start-Process -FilePath $exe -ArgumentList $arguments -NoNewWindow -PassThru `
        -RedirectStandardOutput $out -RedirectStandardError ([IO.Path]::GetTempFileName())
    $null = $p.Handle
    while (-not $p.HasExited) { Pause-Ui 0.2 }
    $script:captureExit = $p.ExitCode
    $bytes = [IO.File]::ReadAllBytes($out)
    Remove-Item $out -ErrorAction SilentlyContinue
    return Decode-Text $bytes
}

function Ask([string]$text, [string]$buttons = "YesNoCancel", [string]$icon = "Question") {
    return [System.Windows.Forms.MessageBox]::Show($form, $text, $form.Text, $buttons, $icon)
}

# --------------------------------------------------------------- шаги

# $true — Docker уже был; $false — только что поставлен, нужна перезагрузка.
function Install-Docker {
    if (Get-Command docker -ErrorAction SilentlyContinue) { Log "Docker уже установлен."; return $true }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Fail ("Нет winget. Установите Docker Desktop вручную с https://www.docker.com/products/docker-desktop/ " +
              "и запустите Установить.cmd ещё раз.")
    }
    Set-Status "Устанавливаю Docker Desktop — несколько минут; Windows может спросить разрешение."
    $code = Run "winget" "install -e --id Docker.DockerDesktop --accept-package-agreements --accept-source-agreements"
    if ($code -ne 0) { Fail "Docker Desktop не установился (winget, код $code)." }
    return $false
}

# --------------------------------------------------------------- WSL и права

# Текст временного файла вывода — с разбором кодировки (см. Decode-Text).
function Read-Text([string]$path) {
    if (-not (Test-Path $path)) { return "" }
    return Decode-Text ([IO.File]::ReadAllBytes($path))
}

# Строки вывода повышенной команды — в журнал; временный файл удаляется.
function Log-Elevated([string]$outFile) {
    foreach ($line in ((Read-Text $outFile) -split "`r?`n")) {
        if ($line.Trim()) { Log "  $($line.Trim())" }
    }
    Remove-Item $outFile, "$outFile.err" -ErrorAction SilentlyContinue
}

# Текст разового скрипта для повышенного процесса: команда и пути — прямо в
# тексте, а не в командной строке. Через командную строку дочернему PowerShell
# не передать аргументы вида «--install» (они принимаются за имена параметров),
# да и кавычки по пути теряются. Вынесено отдельно, чтобы проверять.
# Файл — UTF-8 с BOM: в пути встречается кириллица («Записная книжка»).
function New-ElevatedScript([string]$exe, [string]$arguments, [string]$outFile, [string]$codeFile) {
    $exeQ = $exe -replace "'", "''"
    $argQ = $arguments -replace "'", "''"
    $outQ = $outFile -replace "'", "''"
    $codeQ = $codeFile -replace "'", "''"
    $first = "`$ErrorActionPreference = 'Continue'"
    $run = "`$p = Start-Process -FilePath '$exeQ' -ArgumentList '$argQ' -NoNewWindow " +
           "-Wait -PassThru -RedirectStandardOutput '$outQ' -RedirectStandardError '$outQ.err'"
    $save = "[IO.File]::WriteAllText('$codeQ', [string]`$p.ExitCode)"
    return ($first + "`r`n" + $run + "`r`n" + $save)
}

# Выполнить команду с правами администратора (Windows покажет запрос UAC) и
# дождаться конца. Возвращает код выхода команды; 1223 — запрос UAC отклонён.
# Код выхода пишется в файл: у повышенного процесса родитель его не видит.
function Invoke-Elevated([string]$exe, [string]$arguments, [string]$outFile) {
    $tag = [guid]::NewGuid().ToString("N")
    $codeFile = Join-Path $env:TEMP "balans-code-$tag.txt"
    $helper = Join-Path $env:TEMP "balans-elevated-$tag.ps1"
    Remove-Item $codeFile, $outFile -ErrorAction SilentlyContinue
    [IO.File]::WriteAllText($helper, (New-ElevatedScript $exe $arguments $outFile $codeFile),
        (New-Object System.Text.UTF8Encoding($true)))
    try {
        $null = Start-Process powershell -Verb RunAs -Wait -WindowStyle Hidden -ArgumentList @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $helper)
    } catch {
        Remove-Item $helper, $codeFile, $outFile -ErrorAction SilentlyContinue
        return 1223
    }
    $code = 1
    if (Test-Path $codeFile) { $code = [int]((Read-Text $codeFile).Trim()) }
    Remove-Item $helper, $codeFile -ErrorAction SilentlyContinue
    return $code
}

# Подсистема Linux: без неё не работает Docker Desktop. «wsl --status» отвечает
# кодом 0, когда подсистема есть; на машине без неё — строка «not installed».
function Test-Wsl {
    if (-not (Get-Command wsl -ErrorAction SilentlyContinue)) { return $false }
    $status = Capture "wsl" "--status"
    if ($script:captureExit -ne 0) { return $false }
    if ($status -match "(?i)not installed|не установлен") { return $false }
    return $true
}

# $true — WSL уже был; $false — только что поставлен, нужна перезагрузка.
function Install-Wsl {
    if (Test-Wsl) { Log "Подсистема Linux (WSL) уже есть."; return $true }
    Set-Status "Устанавливаю подсистему Linux (WSL). Windows спросит разрешение — нажмите «Да»."
    $out = [IO.Path]::GetTempFileName()
    $code = Invoke-Elevated "wsl" "--install --no-distribution" $out
    Log-Elevated $out
    if ($code -eq 1223) { Fail "Установка отменена: запрос прав администратора (UAC) отклонён." }
    if ($code -ne 0) {
        # старые сборки Windows 10 не знают «wsl --install» — включаем компоненты напрямую
        Log "«wsl --install» не сработал (код $code) — включаю компоненты Windows напрямую."
        foreach ($feature in @("Microsoft-Windows-Subsystem-Linux", "VirtualMachinePlatform")) {
            $code = Invoke-Elevated "dism" "/online /enable-feature /featurename:$feature /all /norestart" $out
            Log-Elevated $out
            # 3010 — успех, но нужна перезагрузка
            if ($code -ne 0 -and $code -ne 3010) { Fail "Не удалось включить компонент «$feature» (код $code)." }
        }
    }
    if (Test-Wsl) { Log "Подсистема Linux (WSL) готова."; return $true }
    return $false
}

# --------------------------------------------------------------- перезагрузка

# После перезагрузки установка продолжается сама: запись RunOnce запускает
# установщик при следующем входе в Windows. Снимается, когда установка дошла
# до конца (или при штатном успешном завершении; повторный запуск безопасен).
$RunOnceKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce"
function Set-ResumeAfterReboot {
    if (-not (Test-Path $RunOnceKey)) { New-Item -Path $RunOnceKey -Force | Out-Null }
    $cmd = "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" install"
    Set-ItemProperty -Path $RunOnceKey -Name "BalansInstall" -Value $cmd
    Log "Установка продолжится сама после следующего входа в Windows."
}
function Clear-ResumeAfterReboot {
    Remove-ItemProperty -Path $RunOnceKey -Name "BalansInstall" -ErrorAction SilentlyContinue
}

# Спросить про перезагрузку; при согласии — перезагрузить компьютер.
# $true — перезагружаемся (вызывающий должен завершиться, не продолжая шаги).
function Ask-Reboot([string]$reason) {
    Set-ResumeAfterReboot
    $answer = Ask ("$reason`n`nПерезагрузить компьютер сейчас? Установка продолжится " +
        "автоматически после входа в Windows.") "YesNo" "Question"
    if ($answer -eq "Yes") {
        Set-Status "Перезагружаю. После входа установка продолжится сама." "DarkGreen"
        Log "Перезагрузка по запросу установщика."
        Start-Process "shutdown" -ArgumentList "-r -t 20"
        Pause-Ui 3
        $form.Close()
        return $true
    }
    Set-Status ("Перезагрузите компьютер, когда удобно: установка продолжится сама после " +
        "входа в Windows. Если не начнётся — запустите Установить.cmd ещё раз.") "DarkGreen"
    return $false
}

function Start-Docker {
    if (Test-DockerRunning) { Log "Docker работает."; return }
    if (-not (Test-Path $DockerExe)) { Fail "Docker не отвечает, а Docker Desktop не найден: $DockerExe" }
    Set-Status "Запускаю Docker Desktop..."
    Start-Process $DockerExe
    for ($i = 0; $i -lt 90; $i++) {
        Pause-Ui 2
        if (Test-DockerRunning) { Log "Docker запущен."; return }
    }
    Fail ("Docker Desktop не запустился за 3 минуты. Откройте его из меню «Пуск»: при первом " +
          "запуске он просит принять условия. Потом запустите ещё раз.")
}

# База одна на компьютер (том balans_pgdata) и помнит пароль первой
# установки. Новая папка без .env при живой базе — это обновление в другое
# место: пароль и порты надо взять у прежней установки, иначе сервер в базу
# не войдёт. Папку прежней установки помнит сам Docker (метка compose).
# Возвращает .env прежней установки, $null — начать с чистой базы.
function Resolve-PreviousInstall {
    if ((Run "docker" "volume inspect ${Project}_pgdata" -Quiet) -ne 0) { return $null }
    $dirs = Capture "docker" ("ps -a --filter label=com.docker.compose.project=$Project " +
        "--format `"{{.Label \`"com.docker.compose.project.working_dir\`"}}`"")
    $prev = ($dirs -split "`r?`n" | Where-Object { $_ -and $_ -ne $Root -and -not $_.StartsWith("/") } | Select-Object -First 1)
    $prevEnv = if ($prev) { Join-Path $prev ".env" } else { $null }
    if ($prevEnv -and (Test-Path $prevEnv)) {
        $answer = Ask ("Найдена прежняя установка Баланса:`n$prev`n`n" +
            "Да — перенести её сюда: та же база, настройки и выписки (рекомендуется).`n" +
            "Нет — начать с чистой базы. Все прежние данные будут удалены.`n" +
            "Отмена — ничего не делать.")
    } else {
        $answer = Ask ("На компьютере есть база от прежней установки Баланса, но её папка не найдена. " +
            "Без её файла .env база не откроется.`n`n" +
            "Да — указать папку прежней установки.`n" +
            "Нет — начать с чистой базы. Все прежние данные будут удалены.`n" +
            "Отмена — ничего не делать.")
        if ($answer -eq "Yes") {
            $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
            $dialog.Description = "Папка прежней установки Баланса (в ней лежит Установить.cmd и файл .env)"
            if ($dialog.ShowDialog($form) -ne "OK") { Fail "Установка отменена." }
            $prev = $dialog.SelectedPath
            $prevEnv = Join-Path $prev ".env"
            if (-not (Test-Path $prevEnv)) { Fail "В папке $prev нет файла .env — это не папка установки Баланса." }
        }
    }
    if ($answer -eq "Cancel") { Fail "Установка отменена — ничего не изменено." }
    if ($answer -eq "No") {
        $sure = Ask "Точно удалить прежнюю базу со всеми данными? Это не отменить." "YesNo" "Warning"
        if ($sure -ne "Yes") { Fail "Установка отменена — ничего не изменено." }
        Set-Status "Удаляю прежнюю базу..."
        # напрямую, по метке проекта: compose из этой папки без .env не разберёт файл
        $ids = (Capture "docker" "ps -aq --filter label=com.docker.compose.project=$Project") -split "\s+" | Where-Object { $_ }
        if ($ids) { $null = Run "docker" ("rm -f " + ($ids -join " ")) }
        if ((Run "docker" "volume rm ${Project}_pgdata") -ne 0) { Fail "Не удалось удалить прежнюю базу (том ${Project}_pgdata)." }
        return $null
    }
    Set-Status "Переношу выписки и бэкапы из $prev ..."
    foreach ($dir in @("raw", "backup")) {
        $from = Join-Path $prev "data\$dir"
        if (Test-Path $from) {
            # robocopy: код меньше 8 — успех (0 — нечего копировать, 1 — скопировано, …)
            $code = Run "robocopy" "`"$from`" `"$(Join-Path $Root "data\$dir")`" /E /NFL /NDL /NJH /NJS /NP"
            if ($code -ge 8) { Fail "Не удалось скопировать $from (robocopy, код $code)." }
        }
    }
    return $prevEnv
}

# Машинный токен сборщика выписок (D100): у API включён вход, поэтому сервер
# отвечает сборщику только по заголовку Authorization: Bearer. Случайная
# строка; человеку её знать не нужно — она только между сборщиком и сервером.
function New-ApiToken { return ([guid]::NewGuid().ToString("N") + [guid]::NewGuid().ToString("N")) }

# Заголовки для вызовов API из ярлыка «Обновить выписки» (сервер под входом).
function Api-Headers {
    $token = Read-EnvValue "API_TOKEN"
    if ($token) { return @{ Authorization = "Bearer $token" } }
    return @{}
}

function New-EnvFile {
    if (Test-Path $EnvFile) {
        Log ".env уже есть — оставляю."
        # У API включён вход: сборщику нужен машинный токен. Добавляем, если нет.
        if (-not (Read-EnvValue "API_TOKEN")) {
            Set-EnvValue "API_TOKEN" (New-ApiToken)
            Log "Добавлен API_TOKEN для сборщика выписок."
        }
        return
    }
    $prevEnv = Resolve-PreviousInstall
    # Значения — заранее, строки — только подстановкой: «"X=" + (…),» внутри
    # @() PowerShell разбирает как два элемента, и значение уходит на свою строку.
    $data = (Join-Path $Root "data") -replace "\\", "/"
    if ($prevEnv) {
        # прежние контейнеры пересоздаются из этой папки — их порты освобождаются
        $port = Read-EnvValue "PORT" $prevEnv
        $dbPort = Read-EnvValue "DB_PORT" $prevEnv
        $password = Read-EnvValue "POSTGRES_PASSWORD" $prevEnv
    } else {
        $port = Find-FreePort 8000
        $dbPort = Find-FreePort 5433
        $password = [guid]::NewGuid().ToString("N")
    }
    # Токен сборщика переносим от прежней установки, если он там был
    $apiToken = if ($prevEnv) { Read-EnvValue "API_TOKEN" $prevEnv } else { $null }
    if (-not $apiToken) { $apiToken = New-ApiToken }
    $lines = @(
        "# Создан установщиком. Логин и пароль владельца задаются в самой системе;",
        "# здесь — пароль базы и машинный токен сборщика выписок.",
        "POSTGRES_DB=budget",
        "POSTGRES_USER=budget",
        "POSTGRES_PASSWORD=$password",
        "PORT=$port",
        "DB_PORT=$dbPort",
        "ALLOWED_ORIGIN=http://127.0.0.1:$port",
        "API_TOKEN=$apiToken",
        "RAW_DIR=$data/raw",
        "BACKUP_DIR=$data/backup",
        "APP_TZ=Europe/Moscow",
        "LOG_LEVEL=INFO"
    )
    # без BOM: docker compose читает .env как UTF-8, BOM испортил бы первую строку
    [IO.File]::WriteAllLines($EnvFile, $lines, (New-Object System.Text.UTF8Encoding($false)))
    Log "Создан .env, порт $port$(if ($prevEnv) { ', пароль и порты — от прежней установки' })."
}

function New-DataDirs {
    foreach ($dir in @("data\raw", "data\raw\tinvest", "data\backup")) {
        New-Item -ItemType Directory -Force -Path (Join-Path $Root $dir) | Out-Null
    }
}

# Иконка рисуется при установке, а не лежит картинкой в репозитории: плитка
# с закруглёнными углами и белым знаком. ICO из PNG-кадров 16…256 px —
# так Windows берёт чёткий кадр под любой размер ярлыка.
function New-Icon([string]$path, [string]$color, [string]$glyph) {
    $frames = @()
    foreach ($size in @(16, 24, 32, 48, 64, 256)) {
        $bmp = New-Object System.Drawing.Bitmap($size, $size)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = "AntiAlias"
        $g.TextRenderingHint = "AntiAliasGridFit"
        $r = [Math]::Max(2, [int]($size * 0.22))
        $tile = New-Object System.Drawing.Drawing2D.GraphicsPath
        $d = $size - 1
        $tile.AddArc(0, 0, $r * 2, $r * 2, 180, 90)
        $tile.AddArc($d - $r * 2, 0, $r * 2, $r * 2, 270, 90)
        $tile.AddArc($d - $r * 2, $d - $r * 2, $r * 2, $r * 2, 0, 90)
        $tile.AddArc(0, $d - $r * 2, $r * 2, $r * 2, 90, 90)
        $tile.CloseFigure()
        $g.FillPath((New-Object System.Drawing.SolidBrush([System.Drawing.ColorTranslator]::FromHtml($color))), $tile)
        $white = [System.Drawing.Brushes]::White
        if ($glyph -eq "stop") {
            $s = [int]($size * 0.36)
            $o = [int](($size - $s) / 2)
            $g.FillRectangle($white, $o, $o, $s, $s)
        } else {
            $font = New-Object System.Drawing.Font("Segoe UI", [float]($size * 0.62), [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
            $fmt = New-Object System.Drawing.StringFormat
            $fmt.Alignment = "Center"; $fmt.LineAlignment = "Center"
            $g.DrawString($glyph, $font, $white, (New-Object System.Drawing.RectangleF(0, [float]($size * 0.03), $size, $size)), $fmt)
        }
        $g.Dispose()
        $ms = New-Object IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        $frames += , @($size, $ms.ToArray())
    }
    $out = New-Object IO.MemoryStream
    $w = New-Object IO.BinaryWriter($out)
    $w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$frames.Count)
    $offset = 6 + 16 * $frames.Count
    foreach ($f in $frames) {
        $dim = if ($f[0] -ge 256) { 0 } else { $f[0] }
        $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
        $w.Write([uint16]1); $w.Write([uint16]32)
        $w.Write([uint32]$f[1].Length); $w.Write([uint32]$offset)
        $offset += $f[1].Length
    }
    foreach ($f in $frames) { $w.Write([byte[]]$f[1]) }
    $w.Flush()
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
    [IO.File]::WriteAllBytes($path, $out.ToArray())
}

$IconDir = Join-Path $Root "tools\icons"
$AppIcon = Join-Path $IconDir "balans.ico"
$StopIcon = Join-Path $IconDir "stop.ico"
$UpdateIcon = Join-Path $IconDir "update.ico"

function New-Icons {
    New-Icon $AppIcon "#1C7ED6" ([string][char]0x20BD)      # ₽
    New-Icon $StopIcon "#868E96" "stop"
    New-Icon $UpdateIcon "#2F9E44" ([string][char]0x2193)   # ↓
}

function New-Shortcut([string]$name, [string]$action, [string]$description, [string]$icon) {
    $desktop = [Environment]::GetFolderPath("Desktop")
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut((Join-Path $desktop "$name.lnk"))
    $lnk.TargetPath = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" $action"
    $lnk.WorkingDirectory = $Root
    $lnk.Description = $description
    $lnk.IconLocation = "$icon,0"
    $lnk.Save()
    Log "Ярлык: $desktop\$name.lnk"
}

function Wait-App([string]$url) {
    Set-Status "Жду, пока система ответит..."
    for ($i = 0; $i -lt 90; $i++) {
        try {
            $r = Invoke-WebRequest -Uri "$url/api/health" -UseBasicParsing -TimeoutSec 2
            if ($r.StatusCode -eq 200) { return }
        } catch { }
        Pause-Ui 2
    }
    Fail "Система не ответила за 3 минуты. Журнал сервера: docker compose -p $Project logs api"
}

function Get-AppUrl {
    $url = Read-EnvValue "APP_URL"
    if ($url) { return $url.TrimEnd("/") }
    return "http://127.0.0.1:" + (Read-EnvValue "PORT")
}

# Что поднимать: у установленной системы — база и сервер со встроенным
# интерфейсом; у разработчика — свой набор (APP_SERVICES в .env).
function Get-AppServices {
    $services = Read-EnvValue "APP_SERVICES"
    if ($services) { return $services }
    # updater — обновление из интерфейса; без реестра (режим сборки) обновлять нечего
    if (Test-BuildMode) { return "db api" }
    return "db api updater"
}

function Test-Url([string]$url) {
    try { return ((Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 2).StatusCode -eq 200) } catch { return $false }
}

# --------------------------------------------------------------- выписки

$BrowserPort = 9333

function Find-YandexBrowser {
    foreach ($p in @(
        (Join-Path $env:LOCALAPPDATA "Yandex\YandexBrowser\Application\browser.exe"),
        (Join-Path $env:ProgramFiles "Yandex\YandexBrowser\Application\browser.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "Yandex\YandexBrowser\Application\browser.exe"))) {
        if ($p -and (Test-Path $p)) { return $p }
    }
    return $null
}

# Отдельное окно Яндекс Браузера со своим профилем и отладочным портом: к
# нему подключаются сборщики из контейнера. Яндекс — потому что части
# страниц Т-Банка нужны сертификаты Минцифры, а в нём они встроены.
# Профиль — BROWSER_PROFILE из .env или data\browser-profile: вход в банки
# делается в этом окне один раз и живёт, пока банк не завершит сессию.
function Start-ScrapeBrowser {
    if (Test-Url "http://127.0.0.1:$BrowserPort/json/version") { Log "Окно браузера для выписок уже открыто."; return }
    $exe = Find-YandexBrowser
    if (-not $exe) {
        Set-Status "Устанавливаю Яндекс Браузер — часть страниц Т-Банка открывается только в нём."
        $code = Run "winget" "install -e --id Yandex.Browser --accept-package-agreements --accept-source-agreements"
        $exe = Find-YandexBrowser
        if (-not $exe) { Fail "Яндекс Браузер не установился (winget, код $code). Установите его с browser.yandex.ru и запустите ещё раз." }
    }
    $browserProfile = Read-EnvValue "BROWSER_PROFILE"
    if (-not $browserProfile) { $browserProfile = Join-Path $Root "data\browser-profile" }
    $browserProfile = [Environment]::ExpandEnvironmentVariables($browserProfile)
    Set-Status "Открываю окно Яндекс Браузера для выписок..."
    Start-Process $exe -ArgumentList ("--user-data-dir=`"$browserProfile`" --remote-debugging-port=$BrowserPort " +
        "--no-first-run --no-default-browser-check")
    for ($i = 0; $i -lt 30; $i++) {
        Pause-Ui 1
        if (Test-Url "http://127.0.0.1:$BrowserPort/json/version") { return }
    }
    Fail "Окно Яндекс Браузера открылось, но не отвечает (порт $BrowserPort). Закройте его и запустите ещё раз."
}

# Сборщики в контейнере; ход — строками «@@ источник состояние текст».
function Invoke-Collectors([string[]]$sources) {
    foreach ($s in $sources) { $script:results.Remove($s) }   # уже скачанные остаются
    $onLine = {
        param($line)
        if ($line -match '^@@ (\S+) (\S+) ?(.*)$' -and $SourceSteps.Contains($Matches[1])) {
            $src = $Matches[1]; $state = $Matches[2]; $text = $Matches[3]
            $i = $SourceSteps[$src]
            if ($state -eq "start") {
                Mark $i "run"
                Set-Status "Скачиваю: $($Steps[$i])... Не закрывайте окно браузера."
            } else {
                Mark $i $state
                $script:results[$src] = @($state, $text)
            }
        }
    }
    # --build: образ сборщиков — с текущим кодом (у разработчика код меняется
    # между запусками; без изменений сборка берётся из кэша за секунды)
    $null = Run "docker" ("compose $(Get-ComposeBase) run --rm -T $(if (Test-BuildMode) { '--build ' })collector " +
        "python scrape/update.py " + ($sources -join " ")) -OnLine $onLine
}

# --------------------------------------------------------------- сценарии

# Готовый образ приложения из реестра. Закрытый пакет просит токен доступа
# (классический, право read:packages): спрашиваем один раз, Docker запоминает
# вход сам. Открытый скачивается без токена.
$RegistryHost = "ghcr.io"
$RegistryUser = "agarkoff"

function Pull-Images {
    Set-Status "Скачиваю приложение из реестра образов..."
    if ((Run "docker" "compose $(Get-ComposeBase) pull api") -eq 0) { return }
    Add-Type -AssemblyName Microsoft.VisualBasic
    $token = [Microsoft.VisualBasic.Interaction]::InputBox(
        ("Не удалось скачать приложение из реестра $RegistryHost.`n`n" +
         "Если пакет закрытый, вставьте токен доступа (GitHub, право read:packages), " +
         "который вам прислали. Если нет сети, закройте окно и повторите установку позже."),
        $form.Text, "")
    if (-not $token.Trim()) { Fail "Приложение не скачано. Нужен токен доступа к реестру или подключение к сети." }
    $env:BALANS_REGISTRY_TOKEN = $token.Trim()
    try {
        $code = Run "cmd.exe" "/c echo %BALANS_REGISTRY_TOKEN%| docker login $RegistryHost -u $RegistryUser --password-stdin" -Quiet
    } finally { Remove-Item Env:\BALANS_REGISTRY_TOKEN -ErrorAction SilentlyContinue }
    if ($code -ne 0) { Fail "Реестр не принял токен (docker login, код $code)." }
    Compose "pull api"
}

function Run-Install {
    Step 0
    if (-not (Install-Wsl)) {
        Step 1
        if (-not (Ask-Reboot "Подсистема Linux (WSL) установлена.")) { Step $Steps.Count }
        return
    }
    Step 1
    if (-not (Install-Docker)) {
        Step 2
        if (-not (Ask-Reboot "Docker Desktop установлен.")) { Step $Steps.Count }
        return
    }
    Step 2; Start-Docker
    Step 3; New-EnvFile; New-DataDirs
    Step 4
    Set-Status "Собираю и запускаю. Первый раз Docker скачивает и собирает образы — 5–10 минут."
    if (Test-BuildMode) {
        Compose "up -d --build db api"
        Compose "build collector"   # образ сборщиков выписок — тот же код
    } else {
        Pull-Images
        Compose "up -d $(Get-AppServices)"
    }
    Wait-App (Get-AppUrl)
    Step 5
    New-Shortcuts
    Step $Steps.Count
    Clear-ResumeAfterReboot
    Finish-Open "Готово. На рабочем столе — ярлыки «Баланс», «Обновить выписки» и «Баланс — остановить»."
}

function New-Shortcuts {
    New-Shortcut "Баланс" "start" "Запустить Баланс и открыть в браузере" $AppIcon
    New-Shortcut "Обновить выписки" "update" "Скачать выписки банков, чеки и заказы (окно подскажет, где войти)" $UpdateIcon
    New-Shortcut "Баланс — остановить" "stop" "Остановить Баланс" $StopIcon
}

function Run-Shortcuts {
    Step 0
    New-Shortcuts
    Step $Steps.Count
    $progress.Style = "Blocks"; $progress.Value = 100
    Set-Status "Ярлыки «Баланс», «Обновить выписки» и «Баланс — остановить» ведут в $Root." "DarkGreen"
}

function Run-Start {
    Step 0; Start-Docker
    Step 1
    Compose "up -d $(Get-AppServices)"
    Wait-App (Get-AppUrl)
    Step $Steps.Count
    Finish-Open "Баланс запущен."
    Pause-Ui 2
    $form.Close()
}

function Run-Stop {
    Step 0
    if (Test-DockerRunning) { Compose "stop" } else { Log "Docker не запущен — останавливать нечего." }
    Step $Steps.Count
    $progress.Style = "Blocks"; $progress.Value = 100
    Set-Status "Баланс остановлен." "DarkGreen"
    Pause-Ui 2
    $form.Close()
}

function Wait-Continue([string]$buttonText) {
    $continueButton.Text = $buttonText
    $continueButton.Visible = $true
    $script:continued = $false
    while (-not $script:continued -and $form.Visible) { Pause-Ui 0.2 }
    $continueButton.Visible = $false
    return $form.Visible
}

# Закрытие окна гасит сборщики немедленно. Контейнер `compose run` живёт на
# демоне отдельно от CLI, поэтому одного убийства дочернего `docker` мало —
# удаляем контейнеры сервиса collector по метке проекта.
function Stop-Collectors {
    foreach ($c in @($script:children)) {
        if ($c -and -not $c.HasExited) { try { $c.Kill() } catch { } }
    }
    $script:children.Clear()
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return }
    $ids = @(& docker ps -aq `
        --filter "label=com.docker.compose.project=$Project" `
        --filter "label=com.docker.compose.service=collector" 2>$null)
    if ($ids.Count -gt 0) {
        & docker rm -f @ids 2>$null | Out-Null
        Add-Content -Path $LogFile -Value "Сборщики остановлены (окно закрыто)." -Encoding UTF8
    }
}

function Run-Update {
    # какие банки качать: галочки, выбор запоминается
    $progress.Style = "Blocks"; $progress.Value = 0
    Set-Status "Отметьте банки, выписки которых скачивать, и нажмите «Скачать». Выбор запомнится."
    if (-not (Wait-Continue "Скачать")) { return }
    $selected = @($SourceSteps.Keys | Where-Object { $stepLabels[$SourceSteps[$_]].Checked })
    Set-EnvValue "UPDATE_SOURCES" ($selected -join ",")
    foreach ($k in $SourceSteps.Keys) {
        $stepLabels[$SourceSteps[$k]].Enabled = $false
        if ($selected -notcontains $k) { Mark $SourceSteps[$k] "skip" }
    }
    $progress.Style = "Marquee"

    Mark 0 "run"
    Start-Docker
    $url = Get-AppUrl
    # у разработчика сервер уже работает (api-dev) — второй не поднимаем
    if (-not (Test-Url "$url/api/health")) { Compose "up -d $(Get-AppServices)"; Wait-App $url }
    Mark 0 "ok"
    if (-not $selected.Count) { Mark 1 "skip" }

    # Сборщики докачивают только новое с прошлой выписки (scrape/common.since):
    # перезапуск после сбоя одного банка у остальных быстрый.
    $script:results = @{}
    $pending = $selected
    if ($pending.Count) { Mark 1 "run"; Start-ScrapeBrowser; Mark 1 "ok" }
    while ($pending.Count) {
        Invoke-Collectors $pending
        foreach ($s in $pending) { if (-not $script:results[$s]) { Mark $SourceSteps[$s] "error" } }
        $login = @($pending | Where-Object { $script:results[$_] -and $script:results[$_][0] -eq "login" })
        if (-not $login.Count) { break }
        $names = ($login | ForEach-Object { $SourceTitles[$_] }) -join ", "
        Set-Status ("Войдите в окне Яндекс Браузера: $names — вкладки уже открыты. " +
                    "Затем нажмите «Я вошёл — продолжить».") "DarkOrange"
        $progress.Style = "Blocks"; $progress.Value = 0
        if (-not (Wait-Continue "Я вошёл — продолжить")) { return }
        $progress.Style = "Marquee"
        $pending = $login
    }

    Mark 15 "run"
    $headers = Api-Headers
    $setup = Invoke-RestMethod "$url/api/settings/setup" -Headers $headers
    if ($setup.tinvest) {
        $null = Invoke-RestMethod -Method Post "$url/api/jobs/tinvest_fetch" -Headers $headers -ContentType "application/json" -Body "{}"
        Log "Т-Инвестиции: скачивание поставлено, сервер качает сам."
        Mark 15 "ok"
    } else {
        Log "Т-Инвестиции: токен не задан (Настройки → Т-Инвестиции) — пропускаю."
        Mark 15 "skip"
    }

    $progress.Style = "Blocks"; $progress.Value = 100
    $failed = @($selected | Where-Object { -not $script:results[$_] -or $script:results[$_][0] -ne "ok" })
    $openButton.Enabled = $true
    $openButton.Add_Click({ Start-Process (Get-AppUrl) })
    if ($failed.Count) {
        $why = ($failed | ForEach-Object {
            $r = $script:results[$_]
            "$($Steps[$SourceSteps[$_]]): $(if ($r) { $r[1] } else { 'сборщик не ответил' })"
        }) -join "; "
        $changed = @($failed | Where-Object { $script:results[$_] -and $script:results[$_][0] -eq "changed" })
        if ($changed.Count) {
            $names = ($changed | ForEach-Object { $Steps[$SourceSteps[$_]] }) -join ", "
            $prefix = "Требуют правки сборщики (сайт изменился): $names. "
        } else {
            $prefix = ""
        }
        Set-Status "$prefix`Cкачано не всё. $why. Подробности — в журнале ниже." "Firebrick"
    } else {
        Set-Status "Выписки скачаны. Система разберёт их сама — ход виден в разделе «Импорт»." "DarkGreen"
    }
}

function Finish-Open([string]$text) {
    $url = Get-AppUrl
    $progress.Style = "Blocks"; $progress.Value = 100
    Set-Status "$text  $url" "DarkGreen"
    $openButton.Enabled = $true
    $openButton.Add_Click({ Start-Process (Get-AppUrl) })
    Start-Process $url
}

$envProject = Read-EnvValue "COMPOSE_PROJECT"
if ($envProject) { $Project = $envProject }

$form.Add_Shown({
    Log ("==== " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + " $Action, $Root")
    try {
        if (-not ((Test-Path $AppIcon) -and (Test-Path $StopIcon) -and (Test-Path $UpdateIcon))) { New-Icons }
        $iconFile = switch ($Action) { "stop" { $StopIcon } "update" { $UpdateIcon } default { $AppIcon } }
        $form.Icon = New-Object System.Drawing.Icon($iconFile)
        switch ($Action) {
            "install" { Run-Install }
            "update"  { Run-Update }
            "shortcuts" { Run-Shortcuts }
            "start"   { Run-Start }
            "stop"    { Run-Stop }
        }
    } catch {
        # Любое завершение (закрытие окна или ошибка) не оставляет сборщиков
        # висеть: контейнеры collector гасятся сразу.
        Stop-Collectors
        if ($_.Exception -is [Cancelled]) {
            # окно (и контролы на нём) уже уничтожены — только журнал, без Pump
            Add-Content -Path $LogFile -Value "Закрыто пользователем." -Encoding UTF8
            return
        }
        if ($script:current -ge 0 -and $script:current -lt $Steps.Count) {
            $stepLabels[$script:current].Text = "✗  " + $Steps[$script:current]
            $stepLabels[$script:current].ForeColor = [System.Drawing.Color]::Firebrick
        }
        $progress.Style = "Blocks"; $progress.Value = 0
        $message = if ($_.Exception -is [StepFailed]) { $_.Exception.Message } else { "Ошибка: $($_.Exception.Message)" }
        Set-Status $message "Firebrick"
        Log $_.ScriptStackTrace
    }
})

[void]$form.ShowDialog()
