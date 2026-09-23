# ================================================================
#  dashboard.ps1  -  ScreenConnect-style web dashboard (v2)
#  Live status + refresh, name-sync with CONNECT.bat,
#  in-page rename, and Lock screen text/color/image per client.
#  Local + private (127.0.0.1 only).
# ================================================================

$port      = 8760
$login     = 'svc'
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
    $lines = & $tsExe status 2>$null
    $out = @(); $i = 0
    foreach ($l in $lines) {
        if ($l -match '^(100\.\d+\.\d+\.\d+)\s+(\S+)\s+(\S+)\s+(\S+)\s*(.*)$') {
            $ip = $matches[1]; $chost = $matches[2]
            if ($i -eq 0) { $i++; continue }
            $i++
            $online = ($l -notmatch 'offline')
            $name = if ($names.ContainsKey($chost.ToUpper())) { $names[$chost.ToUpper()] } elseif ($names.ContainsKey($ip)) { $names[$ip] } else { $chost }
            $out += [pscustomobject]@{ ip = $ip; host = $chost; name = $name; online = $online }
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

$reportPs = @'
$os=(Get-CimInstance Win32_OperatingSystem).Caption
$cs=Get-CimInstance Win32_ComputerSystem
$ram=[math]::Round($cs.TotalPhysicalMemory/1GB,1)
$d=Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
$free=[math]::Round($d.FreeSpace/1GB,1);$tot=[math]::Round($d.Size/1GB,1)
$up=(Get-Date)-(Get-CimInstance Win32_OperatingSystem).LastBootUpTime
"$env:COMPUTERNAME`n$os`nRAM ${ram}GB`nC: ${free}/${tot}GB free`nUptime $([int]$up.TotalHours)h"
'@

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
if(Test-Path `$f){ `$k=Get-Content `$f | Where-Object {`$_ -notmatch '^LOCK_TEXT=' -and `$_ -notmatch '^LOCK_COLOR=' -and `$_ -notmatch '^LOCK_IMAGE='} }
`$k+='LOCK_TEXT=$text'
`$k+='LOCK_COLOR=$color'
`$k+='LOCK_IMAGE=$img'
if(-not (Test-Path (Split-Path `$f))){ New-Item -ItemType Directory -Path (Split-Path `$f) -Force | Out-Null }
Set-Content `$f `$k -Encoding UTF8
"@
    SSH-Run $ip ('powershell -NoProfile -EncodedCommand ' + (Enc $rps)) | Out-Null
    return "Saved. Press Lock to see it."
}

function Do-Action($ip, $action) {
    switch ($action) {
        'terminal' { $u = Login-For $ip; Start-Process cmd "/k ssh -l $u $ip"; return "Opened terminal window." }
        'screen'   {
            $id = (SSH-Run $ip '"C:\Program Files (x86)\AnyDesk\AnyDesk.exe" --get-id 2>NUL').Trim()
            if ($id -match '\d{6,}') { Start-Process 'anydesk.exe' "$($matches[0])"; return "Opening AnyDesk..." }
            return "Open screen needs RustDesk (coming). AnyDesk ID can't be read over SSH."
        }
        'restart'  { SSH-Run $ip 'shutdown /r /t 0' | Out-Null; return "Restart sent." }
        'shutdown' { SSH-Run $ip 'shutdown /s /t 0' | Out-Null; return "Shutdown sent." }
        'health'   { return (SSH-Run $ip ('powershell -NoProfile -EncodedCommand ' + (Enc $reportPs))) }
        'who'      { return (SSH-Run $ip 'query user') }
        'lock'     { SSH-Run $ip 'cmd /c echo.> C:\ProgramData\RemoteSupport\LOCK.flag' | Out-Null; return "Lock sent - client screen is locking." }
        'unlock'   { SSH-Run $ip 'cmd /c del /f /q C:\ProgramData\RemoteSupport\LOCK.flag' | Out-Null; return "Unlock sent - client screen released." }
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
    <div class="rowflex"><p id="count">Loading...</p><button class="rbtn" onclick="load()">Refresh</button></div>
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
    d.innerHTML='<span class="dot '+(c.online?'on':'off')+'"></span><div><div class="rname">'+esc(c.name)+'</div><div class="rhost">'+esc(c.host)+' - '+c.ip+'</div></div>';
    d.onclick=()=>{sel=c;render();panel();};list.appendChild(d);
  });
}
function syncBadge(){
  if(!sel)return;const c=clients.find(x=>x.ip===sel.ip);if(!c)return;sel.online=c.online;
  const b=document.getElementById('badge');if(b){b.className='badge '+(c.online?'on':'off');b.textContent=c.online?'Online':'Offline';}
}
function panel(){
  const r=document.getElementById('right');if(!sel){r.innerHTML='<div id="empty">Select a client</div>';return;}
  r.innerHTML=`
   <div class="rtop"><div><div class="big">${esc(sel.name)}</div><div class="sub">${esc(sel.host)} - ${sel.ip}</div></div>
     <span id="badge" class="badge ${sel.online?'on':'off'}">${sel.online?'Online':'Offline'}</span>
     <button class="rn" onclick="rename()">Rename</button></div>
   <div class="acts">
     ${btn('screen','Open screen','go')}
     ${btn('terminal','Terminal','')}
     ${btn('lock','Lock screen','go')}
     ${btn('unlock','Unlock','')}
     ${btn('health','Health / specs','')}
     ${btn('who','Who is logged in','')}
     ${btn('restart','Restart','danger')}
     ${btn('shutdown','Shutdown','danger')}
   </div>
   <div id="out">Ready.</div>
   <div class="lockbox">
     <h3>Lock screen settings for this client</h3>
     <div class="fld"><label>Message text</label><input type="text" id="lktext" placeholder="Maintenance in progress"></div>
     <div class="fld"><label>Background color</label><input type="color" id="lkcolor" value="#0f172a"></div>
     <div class="fld"><label>Background image link (optional)</label><input type="url" id="lkimg" placeholder="https://.../your-image.png"></div>
     <button class="savebtn" onclick="saveLock()">Save lock settings</button>
     <div class="hint">Leave blank to use defaults (navy + "Maintenance in progress"). Image must be a direct link ending in .png/.jpg.</div>
   </div>`;
  loadLock();
}
function btn(a,label,cls){return `<button class="act ${cls}" onclick="act('${a}')">${label}</button>`;}
async function act(a){
  const o=document.getElementById('out');o.textContent='Working...';
  try{const r=await fetch('/api/action',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({ip:sel.ip,action:a})});
  const j=await r.json();o.textContent=j.output||'(no output)';}catch(e){o.textContent='Error: '+e;}
}
async function loadLock(){
  try{const r=await fetch('/api/lockget?ip='+sel.ip);const j=await r.json();
  if(j.text)document.getElementById('lktext').value=j.text;
  if(j.color)document.getElementById('lkcolor').value=j.color;
  if(j.image)document.getElementById('lkimg').value=j.image;}catch(e){}
}
async function saveLock(){
  const o=document.getElementById('out');o.textContent='Saving lock settings...';
  const body={ip:sel.ip,text:document.getElementById('lktext').value,color:document.getElementById('lkcolor').value,image:document.getElementById('lkimg').value};
  try{const r=await fetch('/api/lockset',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
  const j=await r.json();o.textContent=j.output||'Saved.';}catch(e){o.textContent='Error: '+e;}
}
async function rename(){
  const n=prompt('New name for this client:',sel.name);if(!n)return;
  await fetch('/api/rename',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({host:sel.host,ip:sel.ip,name:n})});
  sel.name=n;await load();panel();
}
function esc(s){return (s||'').replace(/[&<>]/g,m=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[m]));}
load();setInterval(load,8000);
</script></body></html>
'@

# ---------- server ----------
$listener = New-Object System.Net.HttpListener
$prefix = "http://127.0.0.1:$port/"
$listener.Prefixes.Add($prefix)
try { $listener.Start() } catch { Write-Host "Could not start on $prefix - maybe already running?"; exit }
Write-Host "Dashboard running at $prefix   (close this window to stop)"
Start-Process $prefix

function Send($ctx, $text, $type='text/html; charset=utf-8') {
    $buf = [Text.Encoding]::UTF8.GetBytes($text)
    $ctx.Response.ContentType = $type
    $ctx.Response.ContentLength64 = $buf.Length
    $ctx.Response.OutputStream.Write($buf, 0, $buf.Length)
    $ctx.Response.OutputStream.Close()
}
function Body($ctx) { (New-Object IO.StreamReader($ctx.Request.InputStream)).ReadToEnd() | ConvertFrom-Json }

while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    $path = $ctx.Request.Url.AbsolutePath
    try {
        if ($path -eq '/') { Send $ctx $html }
        elseif ($path -eq '/api/clients') { Send $ctx ((Get-Clients | ConvertTo-Json -Compress)) 'application/json' }
        elseif ($path -eq '/api/action') {
            $b = Body $ctx; Send $ctx (@{ output = (Do-Action $b.ip $b.action) } | ConvertTo-Json -Compress) 'application/json'
        }
        elseif ($path -eq '/api/lockget') {
            $ip = $ctx.Request.QueryString['ip']; Send $ctx ((Get-Lock $ip) | ConvertTo-Json -Compress) 'application/json'
        }
        elseif ($path -eq '/api/lockset') {
            $b = Body $ctx; Send $ctx (@{ output = (Set-Lock $b.ip $b.text $b.color $b.image) } | ConvertTo-Json -Compress) 'application/json'
        }
        elseif ($path -eq '/api/rename') {
            $b = Body $ctx; Save-Name $b.host $b.name; Send $ctx (@{ ok = $true } | ConvertTo-Json -Compress) 'application/json'
        }
        else { $ctx.Response.StatusCode = 404; Send $ctx 'not found' 'text/plain' }
    } catch {
        Send $ctx (@{ output = "Error: $($_.Exception.Message)" } | ConvertTo-Json -Compress) 'application/json'
    }
}
