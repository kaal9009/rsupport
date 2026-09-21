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
