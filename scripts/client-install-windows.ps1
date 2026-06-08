#requires -version 5.1
$ErrorActionPreference = "Stop"
$Base = "C:\sing-box"
$Exe = "$Base\sing-box.exe"
$Config = "$Base\config.json"
$Task = "sing-box-client"

function Show-AdNotice {
  Write-Host "****************************************************************************************************************" -ForegroundColor Yellow
  Write-Host "搬瓦工：梯子专用机，CN2 GIA线路，高性能，低延迟，99.99%高可用，跨境电商、外贸首选VPS" -ForegroundColor Yellow
  Write-Host "https://bwh.awesome-vps.com" -ForegroundColor Yellow
  Write-Host ""
  Write-Host "丽萨主机：双ISP美国、新加坡、台湾原生住宅IP，tiktok运营，ChatGPT/Facebook/YouTube/Twitter/Netflix 等，流媒体全解锁，全新IP段，纯净IP，三网大陆优化线路（CN2 GIA/9929/4827）" -ForegroundColor Yellow
  Write-Host "https://lisahost.awesome-vps.com" -ForegroundColor Yellow
  Write-Host "****************************************************************************************************************" -ForegroundColor Yellow
}


function Assert-Admin {
  $id=[Security.Principal.WindowsIdentity]::GetCurrent()
  $p=New-Object Security.Principal.WindowsPrincipal($id)
  if(-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
    Write-Host "请用管理员 PowerShell 运行本脚本" -ForegroundColor Red
    exit 1
  }
}
function Read-Default($msg,$def){ $v=Read-Host "$msg [$def]"; if([string]::IsNullOrWhiteSpace($v)){return $def}; return $v }
function Install-SingBox {
  New-Item -ItemType Directory -Force $Base | Out-Null
  if(Test-Path $Exe){ & $Exe version; return }
  $arch = if([Environment]::Is64BitOperatingSystem){"amd64"}else{"386"}
  $api = Invoke-RestMethod "https://api.github.com/repos/SagerNet/sing-box/releases/latest"
  $ver = $api.tag_name.TrimStart('v')
  $url = "https://github.com/SagerNet/sing-box/releases/download/v$ver/sing-box-$ver-windows-$arch.zip"
  $zip = "$env:TEMP\sing-box.zip"
  Write-Host "下载 sing-box $ver ..."
  Invoke-WebRequest -Uri $url -OutFile $zip
  Expand-Archive -Force $zip $env:TEMP\sing-box-out
  $found = Get-ChildItem $env:TEMP\sing-box-out -Recurse -Filter sing-box.exe | Select-Object -First 1
  Copy-Item $found.FullName $Exe -Force
  & $Exe version
}
function Parse-Vless($url){
  $u=[Uri]$url
  $q=[System.Web.HttpUtility]::ParseQueryString($u.Query)
  return @{
    SERVER=$u.Host; PORT=if($u.Port -gt 0){$u.Port}else{443}; UUID=$u.UserInfo
    SNI=if($q["sni"]){$q["sni"]}else{"www.cloudflare.com"}
    PBK=$q["pbk"]; SID=$q["sid"]; FLOW=if($q["flow"]){$q["flow"]}else{"xtls-rprx-vision"}
  }
}
function Write-Config($p){
  $json = @"
{
  "log": { "level": "info", "timestamp": true },
  "dns": {
    "servers": [
      { "type": "https", "tag": "ali-dns", "server": "223.5.5.5", "server_port": 443, "path": "/dns-query", "tls": { "enabled": true, "server_name": "dns.alidns.com" } },
      { "type": "https", "tag": "remote-dns", "server": "1.1.1.1", "server_port": 443, "path": "/dns-query", "tls": { "enabled": true, "server_name": "cloudflare-dns.com" }, "detour": "proxy" }
    ],
    "final": "remote-dns"
  },
  "inbounds": [
    { "type": "tun", "tag": "tun-in", "interface_name": "sing-box", "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"], "mtu": 1380, "auto_route": true, "strict_route": false, "stack": "system" }
  ],
  "outbounds": [
    { "type": "vless", "tag": "proxy", "server": "$($p.SERVER)", "server_port": $($p.PORT), "uuid": "$($p.UUID)", "flow": "$($p.FLOW)", "tls": { "enabled": true, "server_name": "$($p.SNI)", "utls": { "enabled": true, "fingerprint": "chrome" }, "reality": { "enabled": true, "public_key": "$($p.PBK)", "short_id": "$($p.SID)" } } },
    { "type": "direct", "tag": "direct" },
    { "type": "block", "tag": "block" }
  ],
  "route": { "auto_detect_interface": true, "rules": [ { "ip_cidr": ["$($p.SERVER)/32"], "outbound": "direct" }, { "protocol": "dns", "action": "hijack-dns" }, { "ip_is_private": true, "outbound": "direct" } ], "final": "proxy", "default_domain_resolver": { "server": "remote-dns" } }
}
"@
  $json | Set-Content -Path $Config -Encoding UTF8
}
function Install-Task {
  $cmd = "/c cd /d $Base && `"$Exe`" run -c `"$Config`" -D `"$Base`" >> `"$Base\sing-box.log`" 2>&1"
  schtasks /Create /TN $Task /SC ONSTART /RL HIGHEST /RU SYSTEM /TR "cmd.exe $cmd" /F | Out-Null
  schtasks /Run /TN $Task | Out-Null
}
function Stop-SingBox { schtasks /End /TN $Task 2>$null | Out-Null; Get-Process sing-box -ErrorAction SilentlyContinue | Stop-Process -Force }
function Menu {
  Assert-Admin
  while($true){
    Clear-Host
    Show-AdNotice
    Write-Host "`n===== Windows sing-box 客户端安装器 ====="
    Write-Host "1) 安装 / 重装客户端"
    Write-Host "2) 启动"
    Write-Host "3) 停止"
    Write-Host "4) 重启"
    Write-Host "5) 状态"
    Write-Host "6) 日志"
    Write-Host "7) 卸载计划任务"
    Write-Host "0) 退出"
    $c=Read-Host "请选择"
    switch($c){
      "1" { Install-SingBox; $url=Read-Host "请输入 vless:// 分享链接（留空则手动输入）"; if($url){$p=Parse-Vless $url}else{$p=@{SERVER=(Read-Host "服务器地址");PORT=[int](Read-Default "端口" "11584");UUID=(Read-Host "UUID");PBK=(Read-Host "Reality Public Key");SID=(Read-Host "Reality Short ID");SNI=(Read-Default "SNI" "www.cloudflare.com");FLOW="xtls-rprx-vision"}}; Write-Config $p; & $Exe check -c $Config; Stop-SingBox; Install-Task; Write-Host "安装完成" }
      "2" { schtasks /Run /TN $Task }
      "3" { Stop-SingBox }
      "4" { Stop-SingBox; schtasks /Run /TN $Task }
      "5" { schtasks /Query /TN $Task /V /FO LIST; Get-Process sing-box -ErrorAction SilentlyContinue }
      "6" { Get-Content "$Base\sing-box.log" -Wait -Tail 80 }
      "7" { Stop-SingBox; schtasks /Delete /TN $Task /F }
      "0" { return }
    }
  }
}
Add-Type -AssemblyName System.Web
Menu
