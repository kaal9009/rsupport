# ===== Remote-support-kit health audit =====
# Daily mode (scheduled task, no args): checks the whole kit, and ONLY if something is wrong
#   sends Rohit a Telegram message first - never fixes anything by itself, stays silent on a
#   clean day.
# Manual mode (run with -Manual): always produces a FULL report (clean items too), sends it
#   to Telegram, and writes it to audit-report.txt so it can be read back and shown in chat.
param([switch]$Manual)
$ErrorActionPreference = 'SilentlyContinue'
$base       = 'C:\Users\rohit\Downloads\CONECTTTTTT'
$namesFile  = "$env:APPDATA\client-names.txt"
$loginFile  = "$env:APPDATA\client-logins.txt"
$logFile    = Join-Path $base 'audit-log.txt'
$reportFile = Join-Path $base 'audit-report.txt'
$tsExe      = 'tailscale'
if (Test-Path 'C:\Program Files\Tailscale\tailscale.exe') { $tsExe = 'C:\Program Files\Tailscale\tailscale.exe' }

function Login-For($ip) {
    if (Test-Path $loginFile) { foreach ($l in Get-Content $loginFile) { if ($l -match "^\s*$([regex]::Escape($ip))\s*=\s*(.+?)\s*$") { return $matches[1] } } }
    return 'svc'
}

$issues = @()   # problems only
$ok     = @()   # things confirmed fine (shown only in the full/manual report)

# 1) Is the local dashboard.ps1 out of sync with what's on GitHub?
try {
    $remote = (Invoke-WebRequest 'https://raw.githubusercontent.com/kaal9009/rsupport/main/dashboard.ps1' -UseBasicParsing -TimeoutSec 15).Content
    $localF = Join-Path $base 'dashboard.ps1'
    if (Test-Path $localF) {
        $local = Get-Content $localF -Raw
        if ($remote.Trim() -ne $local.Trim()) { $issues += 'dashboard.ps1 on this PC is OUT OF SYNC with GitHub - a newer version exists that has not been applied here yet.' }
        else { $ok += 'dashboard.ps1 is in sync with GitHub.' }
    } else { $issues += 'dashboard.ps1 not found in the CONECTTTTTT folder.' }
} catch { $issues += 'Could not reach GitHub to check for a newer dashboard.ps1 (internet or GitHub may be down).' }

# 2) Is the dashboard currently running?
$running = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -EA 0 | Where-Object { $_.CommandLine -like '*dashboard.ps1*' }
if (-not $running) { $issues += 'DASHBOARD.bat is NOT currently running on this PC.' }
else { $ok += 'DASHBOARD.bat is running.' }

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
if (-not $clients.Count) { $issues += 'Tailscale returned no clients (Tailscale may be down/logged out on this PC).' }

# 4) Which known clients are unreachable right now, and - from the first reachable one -
#    pick up the Telegram bot token/chat id it already carries (pushed earlier via "ua"),
#    so this script needs no secret of its own and nothing new to configure.
$names = @{}
if (Test-Path $namesFile) { Get-Content $namesFile | ForEach-Object { if ($_ -match '^(.+?)=(.+)$') { $names[$matches[1].Trim().ToUpper()] = $matches[2].Trim() } } }
$down = @(); $up = @()
$tgToken = $null; $tgChat = $null
$logIssues = @()
foreach ($c in $clients) {
    $friendly = if ($names.ContainsKey($c.host.ToUpper())) { $names[$c.host.ToUpper()] } else { $c.host }
    if (-not $c.online) { $down += $friendly; continue }
    $up += $friendly
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
if ($down.Count) { $issues += ('Offline right now: ' + ($down -join ', ')) }
if ($logIssues.Count) { $issues += ('Error(s) logged today on: ' + ($logIssues -join ' || ')) }
if ($clients.Count) { $ok += ("Clients: " + $clients.Count + " total, " + $up.Count + " online" + $(if($up.Count){' (' + ($up -join ', ') + ')'}else{''})) }
if ($clients.Count -and -not $logIssues.Count) { $ok += 'No errors logged on any online client today.' }

$stamp = Get-Date -Format 'yyyy-MM-dd HH:mm'
function Send-TG($text) {
    if ($tgToken -and $tgChat) {
        try { Invoke-RestMethod -Method Post -Uri "https://api.telegram.org/bot$tgToken/sendMessage" -Body @{ chat_id = $tgChat; text = $text } | Out-Null; return $true } catch { return $false }
    }
    return $false
}

if ($Manual) {
    # Full report always, whether clean or not.
    $head = if ($issues.Count) { "Kit audit ($stamp) - $($issues.Count) ISSUE(S) FOUND:" } else { "Kit audit ($stamp) - ALL CLEAR, no issues:" }
    $lines = @($head)
    if ($issues.Count) { $lines += ''; $lines += 'PROBLEMS:'; foreach ($i in $issues) { $lines += "  - $i" } }
    $lines += ''; $lines += 'CHECKED OK:'; foreach ($o in $ok) { $lines += "  - $o" }
    $lines += ''; $lines += '(Manual audit - nothing was changed, checked only.)'
    $report = ($lines -join "`n")
    $sent = Send-TG $report
    Set-Content -Path $reportFile -Value ($report + "`n`nTelegram sent: $sent") -Encoding UTF8
    Add-Content $logFile ("$stamp MANUAL audit (telegram sent: $sent): " + $(if($issues.Count){'ISSUES - ' + ($issues -join ' | ')}else{'clean'}))
}
else {
    # Daily mode: only speak up on problems.
    if ($issues.Count) {
        $msg = "Remote-support-kit daily audit found an issue:`n- " + ($issues -join "`n- ") + "`n(Nothing was changed automatically - checked only.)"
        $sent = Send-TG $msg
        Add-Content $logFile ("$stamp ISSUES (telegram sent: $sent): " + ($issues -join ' | '))
    } else {
        Add-Content $logFile ("$stamp clean - no issues found.")
    }
}
