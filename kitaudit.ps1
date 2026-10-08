# ===== Remote-support-kit daily health audit =====
# Runs once a day on THIS (admin) PC via a scheduled task. Checks for problems across the
# whole kit and, if anything is wrong, sends Rohit a Telegram message FIRST - it never
# fixes anything by itself. Stays silent on a clean day (no "all good" spam).
$ErrorActionPreference = 'SilentlyContinue'
$base      = 'C:\Users\rohit\Downloads\CONECTTTTTT'
$namesFile = "$env:APPDATA\client-names.txt"
$loginFile = "$env:APPDATA\client-logins.txt"
$logFile   = Join-Path $base 'audit-log.txt'
$tsExe     = 'tailscale'
if (Test-Path 'C:\Program Files\Tailscale\tailscale.exe') { $tsExe = 'C:\Program Files\Tailscale\tailscale.exe' }

function Login-For($ip) {
    if (Test-Path $loginFile) { foreach ($l in Get-Content $loginFile) { if ($l -match "^\s*$([regex]::Escape($ip))\s*=\s*(.+?)\s*$") { return $matches[1] } } }
    return 'svc'
}

$issues = @()

# 1) Is the local dashboard.ps1 out of sync with what's on GitHub?
try {
    $remote = (Invoke-WebRequest 'https://raw.githubusercontent.com/kaal9009/rsupport/main/dashboard.ps1' -UseBasicParsing -TimeoutSec 15).Content
    $localF = Join-Path $base 'dashboard.ps1'
    if (Test-Path $localF) {
        $local = Get-Content $localF -Raw
        if ($remote.Trim() -ne $local.Trim()) { $issues += 'dashboard.ps1 on this PC is out of sync with GitHub - a newer version exists that has not been applied here yet.' }
    }
} catch { $issues += 'Could not reach GitHub to check for a newer dashboard.ps1 (internet or GitHub may be down).' }

# 2) Is the dashboard currently running?
$running = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -EA 0 | Where-Object { $_.CommandLine -like '*dashboard.ps1*' }
if (-not $running) { $issues += 'DASHBOARD.bat is not currently running on this PC.' }

# 3) Build the known-client list from Tailscale (same source the dashboard itself uses)
$clients = @()
$raw = & $tsExe status --json 2>$null
if ($raw) {
    try {
        $j = ($raw | Out-String) | ConvertFrom-Json
        foreach ($prop in $j.Peer.PSObject.Properties) {
            $p = $prop.Value
            $ip = @($p.TailscaleIPs | Where-Object { $_ -match '^100\.' })[0]
            if (-not $ip) { continue }
            $clients += [pscustomobject]@{ ip = $ip; host = $p.HostName; online = [bool]$p.Online }
        }
    } catch {}
}

# 4) Which known clients are unreachable right now, and - from the first reachable one -
#    pick up the Telegram bot token/chat id it already carries (pushed earlier via "ua"),
#    so this script needs no secret of its own and nothing new to configure.
$names = @{}
if (Test-Path $namesFile) { Get-Content $namesFile | ForEach-Object { if ($_ -match '^(.+?)=(.+)$') { $names[$matches[1].Trim().ToUpper()] = $matches[2].Trim() } } }
$down = @()
$tgToken = $null; $tgChat = $null
$logIssues = @()
foreach ($c in $clients) {
    $friendly = if ($names.ContainsKey($c.host.ToUpper())) { $names[$c.host.ToUpper()] } else { $c.host }
    if (-not $c.online) { $down += $friendly; continue }
    $u = Login-For $c.ip
    $sshOpts = @('-o','StrictHostKeyChecking=no','-o','BatchMode=yes','-o','ConnectTimeout=5')
    if (-not $tgToken) {
        try {
            $r = & ssh @sshOpts "$u@$($c.ip)" 'powershell -NoProfile -Command "if(Test-Path C:\ProgramData\RemoteSupport\tg.txt){Get-Content C:\ProgramData\RemoteSupport\tg.txt -Raw}"' 2>$null
            foreach ($l in (($r | Out-String) -split "`n")) {
                if ($l -match '^token=(.+)$') { $tgToken = $matches[1].Trim() }
                elseif ($l -match '^chat=(.+)$') { $tgChat = $matches[1].Trim() }
            }
        } catch {}
    }
    # 5) scan today's heal-log.txt on this client for anything logged as an error
    try {
        $log = & ssh @sshOpts "$u@$($c.ip)" 'powershell -NoProfile -Command "if(Test-Path C:\ProgramData\RemoteSupport\heal-log.txt){Get-Content C:\ProgramData\RemoteSupport\heal-log.txt -Tail 40}"' 2>$null
        $today = (Get-Date).ToString('yyyy-MM-dd')
        $hits = @($log) | Where-Object { $_ -match 'error' -and $_ -match [regex]::Escape($today) }
        if ($hits) { $logIssues += ($friendly + ': ' + (($hits | Select-Object -First 2) -join ' | ')) }
    } catch {}
}
if ($down.Count) { $issues += ('Unreachable right now: ' + ($down -join ', ')) }
if ($logIssues.Count) { $issues += ('Error(s) logged today on: ' + ($logIssues -join ' || ')) }

# Report - Telegram first if we have the credentials, else fall back to a local log file
# so nothing is silently lost even if no client was reachable to fetch them from.
if ($issues.Count) {
    $msg = "Remote-support-kit daily audit found an issue:`n- " + ($issues -join "`n- ") + "`n(Nothing was changed automatically - checked only.)"
    $sent = $false
    if ($tgToken -and $tgChat) {
        try { Invoke-RestMethod -Method Post -Uri "https://api.telegram.org/bot$tgToken/sendMessage" -Body @{ chat_id = $tgChat; text = $msg } | Out-Null; $sent = $true } catch {}
    }
    Add-Content $logFile ("$(Get-Date -Format s) ISSUES (telegram sent: $sent): " + ($issues -join ' | '))
} else {
    Add-Content $logFile ("$(Get-Date -Format s) clean - no issues found.")
}
