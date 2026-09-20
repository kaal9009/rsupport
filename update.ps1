# ==========================================================
#  rsupport update.ps1  (PUBLIC - keep it SECRET-FREE)
#  Runs on every client (as SYSTEM) each guardian cycle.
#  Reads secrets from the LOCAL config file, never from here.
#  To upgrade all clients: edit this file + bump version.txt.
# ==========================================================
$ErrorActionPreference = "SilentlyContinue"
$dir = "C:\ProgramData\RemoteSupport"
$log = "$dir\heal-log.txt"
function L($m){ Add-Content $log ((Get-Date).ToString("yyyy-MM-dd HH:mm")+"  "+$m) }

# read local secrets (written by setup) - key=value lines
$cfg=@{}
if(Test-Path "$dir\config.txt"){ foreach($l in Get-Content "$dir\config.txt"){ if($l.Contains('=')){ $cfg[$l.Split('=',2)[0]]=$l.Split('=',2)[1] } } }
$key=$cfg['TSKEY']; $adpw=$cfg['SVCPWD']; $tgt=$cfg['TGTOKEN']; $tgc=$cfg['TGCHAT']
function Alert($m){ if($tgt -and $tgc){ try{ [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest ("https://api.telegram.org/bot"+$tgt+"/sendMessage") -Method Post -Body @{chat_id=$tgc;text=("["+$env:COMPUTERNAME+"] "+$m)} -UseBasicParsing | Out-Null }catch{} } }

# keep SSH up
Start-Service sshd

# heal Tailscale (reinstall + reconnect using local key)
$ts=@("C:\Program Files\Tailscale\tailscale.exe","C:\Program Files (x86)\Tailscale IPN\tailscale.exe")|Where-Object{Test-Path $_}|Select-Object -First 1
if(-not $ts){
  L "Tailscale missing - reinstalling"; Alert "Tailscale was removed - reinstalling"
  try{[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
  Invoke-WebRequest "https://pkgs.tailscale.com/stable/tailscale-setup-latest.exe" -OutFile "C:\ts-heal.exe" -UseBasicParsing
  Start-Process "C:\ts-heal.exe" -ArgumentList "/quiet" -Wait; Start-Sleep 5; Remove-Item "C:\ts-heal.exe" -Force}catch{}
  $ts=@("C:\Program Files\Tailscale\tailscale.exe","C:\Program Files (x86)\Tailscale IPN\tailscale.exe")|Where-Object{Test-Path $_}|Select-Object -First 1
}
if($ts){ if(-not(& $ts ip -4)){ & $ts up --authkey $key --unattended; L "Tailscale reconnected" } }

# heal AnyDesk (only if it was set up before - marker file)
$adExe="C:\Program Files (x86)\AnyDesk\AnyDesk.exe"
if((Test-Path "$dir\anydesk.on") -and -not(Test-Path $adExe)){
  L "AnyDesk missing - reinstalling"; Alert "AnyDesk was removed - reinstalling"
  try{[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
  Invoke-WebRequest "https://download.anydesk.com/AnyDesk.exe" -OutFile "C:\ad-heal.exe" -UseBasicParsing
  Start-Process "C:\ad-heal.exe" -ArgumentList '--install "C:\Program Files (x86)\AnyDesk" --start-with-win --silent' -Wait; Start-Sleep 4}catch{}
  $conf="C:\ProgramData\AnyDesk\system.conf"
  "ad.security.interactive_access=2","ad.security.unattended_access=true","ad.security.allow_logon_token=true"|%{ if(-not(Select-String -Path $conf -SimpleMatch ($_ -split "=")[0] -Quiet)){Add-Content $conf $_} }
  $adpw|Out-File "C:\adp.txt" -Encoding ascii -NoNewline; cmd /c "type C:\adp.txt | `"$adExe`" --set-password"; Remove-Item "C:\adp.txt" -Force
  Restart-Service AnyDesk
}
if(Get-Service AnyDesk -ErrorAction SilentlyContinue){ Start-Service AnyDesk }

# ---- ADD FUTURE UPGRADES BELOW (they reach all clients automatically) ----
