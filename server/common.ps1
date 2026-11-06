# DeployKit – hàm dùng chung cho deploy.ps1 / install.ps1 / backup-offsite.ps1 (Windows PowerShell 5.1+). Dot-source: . "$PSScriptRoot\common.ps1"

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Lệnh ngoài (cmd, appcmd, icacls…): Windows PowerShell 5.1 coi MỌI dòng stderr là lỗi dừng script khi ErrorActionPreference = Stop (kể cả đã chuyển
# hướng 2>$null) – chạy trong Continue, gom stderr thành chữ; người gọi tự xét $LASTEXITCODE.
function Invoke-Native([scriptblock]$block) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $block 2>&1 | ForEach-Object { "$_" } }
    finally { $ErrorActionPreference = $old }
}

function Step($text) { Write-Host ''; Write-Host "==> $text" -ForegroundColor Cyan }
function Info($text) { Write-Host "   $text" }
function Warn($text) { Write-Host "   ! $text" -ForegroundColor Yellow }

function Assert-Admin($bound, [string]$script) {
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($admin) { return }
    Write-Host 'Cần quyền Administrator – đang mở lại...' -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$script`"")
    foreach ($kv in $bound.GetEnumerator()) {
        if ($kv.Value -is [switch]) { if ($kv.Value) { $argList += "-$($kv.Key)" } }
        else { $argList += "-$($kv.Key)"; $argList += "`"$($kv.Value)`"" }
    }
    Start-Process powershell -Verb RunAs -ArgumentList $argList
    exit 0
}

# ------------------------------------------------------------------ cấu hình + bố cục
function Read-Config([string]$dir) {
    $file = Join-Path $dir 'deploy.json'
    if (-not (Test-Path $file)) { throw "Thiếu $file." }
    $cfg = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($k in 'Name', 'AppDll', 'Root', 'SiteName', 'HealthPath') { if (-not $cfg.$k) { throw "deploy.json thiếu '$k'." } }
    return $cfg
}

function Get-Layout($cfg) {
    $root = $cfg.Root.TrimEnd('\')
    [pscustomobject]@{
        Root     = $root
        Releases = Join-Path $root 'releases'
        Current  = Join-Path $root 'current'
        Shared   = Join-Path $root 'shared'
        Deploy   = Join-Path $root 'deploy'
        Incoming = Join-Path $root 'incoming'
        History  = Join-Path $root 'deploy\history.jsonl'
        Token    = Join-Path $root 'deploy\token.dat'
        Pool     = if ($cfg.AppPool) { $cfg.AppPool } else { $cfg.SiteName }
    }
}

# Biến môi trường của ứng dụng: {shared} → <Root>\shared
function Get-AppEnvironment($cfg, $layout) {
    $vars = [ordered]@{}
    if ($cfg.Environment) {
        foreach ($p in $cfg.Environment.PSObject.Properties) { $vars[$p.Name] = ([string]$p.Value).Replace('{shared}', $layout.Shared) }
    }
    return $vars
}

# Khóa so sánh phiên bản yyyy.M.d[.n]: theo SỐ (2026.11.20 mới hơn 2026.11.6 – so chuỗi thì ngược lại)
function ConvertTo-VersionKey([string]$text) {
    $v = $null
    if ([version]::TryParse($text, [ref]$v)) { return $v }
    return [version]'0.0'
}

# Các bản trong releases\ (bỏ thư mục tạm .*), mới nhất trước
function Get-Releases($layout) {
    @(Get-ChildItem $layout.Releases -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike '.*' -and (Test-Path (Join-Path $_.FullName 'app')) } |
        Sort-Object { ConvertTo-VersionKey $_.Name } -Descending | ForEach-Object Name)
}

# ------------------------------------------------------------------ khe "current" (junction)
function Set-CurrentRelease($layout, [string]$version) {
    $target = Join-Path $layout.Releases $version
    if (-not (Test-Path (Join-Path $target 'app'))) { throw "Không có bản $version trong $($layout.Releases)." }
    if (Test-Path $layout.Current) { Invoke-Native { cmd /c rmdir "`"$($layout.Current)`"" } | Out-Null }   # chỉ gỡ junction, không đụng thư mục đích
    $out = Invoke-Native { cmd /c mklink /J "`"$($layout.Current)`"" "`"$target\app`"" }
    if ($LASTEXITCODE -ne 0) { throw "Không tạo được junction $($layout.Current) → $target\app: $out" }
}

function Get-CurrentVersionFromJunction($layout) {
    $item = Get-Item $layout.Current -ErrorAction SilentlyContinue
    if (-not $item) { return $null }
    $target = @($item.Target)[0]
    if (-not $target) { return $null }
    $version = Split-Path (Split-Path $target -Parent) -Leaf    # ...\releases\<ver>\app → <ver>
    if ($version -like '.*') { return $null }                    # khe tạm lúc cài lần đầu
    return $version
}

# ------------------------------------------------------------------ IIS
function Use-Iis { Import-Module WebAdministration -ErrorAction Stop }

function Restart-App($layout) {
    $pool = $layout.Pool
    if ((Get-WebAppPoolState $pool).Value -ne 'Stopped') { Stop-WebAppPool $pool }
    for ($i = 0; $i -lt 60 -and (Get-WebAppPoolState $pool).Value -ne 'Stopped'; $i++) { Start-Sleep -Seconds 1 }
    Start-WebAppPool $pool
}

function Stop-App($layout) {
    $pool = $layout.Pool
    if ((Get-WebAppPoolState $pool).Value -ne 'Stopped') { Stop-WebAppPool $pool }
    for ($i = 0; $i -lt 60 -and (Get-WebAppPoolState $pool).Value -ne 'Stopped'; $i++) { Start-Sleep -Seconds 1 }
}

function Set-PoolEnvironment($layout, $vars) {
    $appcmd = Join-Path $env:windir 'System32\inetsrv\appcmd.exe'
    foreach ($name in $vars.Keys) {
        # Gỡ giá trị cũ (chưa có thì appcmd báo lỗi – bỏ qua) rồi thêm giá trị mới
        Invoke-Native { & $appcmd set config -section:system.applicationHost/applicationPools "/-[name='$($layout.Pool)'].environmentVariables.[name='$name']" /commit:apphost } | Out-Null
        $out = Invoke-Native { & $appcmd set config -section:system.applicationHost/applicationPools "/+[name='$($layout.Pool)'].environmentVariables.[name='$name',value='$($vars[$name])']" /commit:apphost }
        if ($LASTEXITCODE -ne 0) { throw "Không đặt được biến môi trường $name cho app pool $($layout.Pool): $out" }
    }
}

function Get-HealthUrls($cfg) {
    $urls = @()
    foreach ($b in (Get-Website -Name $cfg.SiteName).bindings.Collection) {
        if ($b.protocol -notin 'http', 'https') { continue }
        $parts = $b.bindingInformation.Split(':')   # ip:port:host
        $h = if ($parts[2]) { $parts[2] } elseif ($parts[0] -and $parts[0] -ne '*') { $parts[0] } else { 'localhost' }
        $urls += "$($b.protocol)://${h}:$($parts[1])$($cfg.HealthPath)"
    }
    return $urls
}

# Chờ /health của bản mong đợi: 200 + version khớp + ready (nếu có trường ready). Trả 'ok' | 'wrong-version' | 'timeout' | 'http <mã>'.
function Wait-Health($cfg, [string]$expectVersion, [int]$startSeconds, [int]$readyMinutes) {
    [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }   # chỉ để kiểm tra qua localhost / IP
    $urls = @(Get-HealthUrls $cfg)
    if (-not $urls) { Warn 'Site không có binding http/https – bỏ qua kiểm tra.'; return 'skip' }
    $started = Get-Date
    $up = $false; $last = 'timeout'; $lastNote = ''
    while ($true) {
        $elapsed = ((Get-Date) - $started).TotalSeconds
        if (-not $up -and $elapsed -gt $startSeconds) { return $last }
        if ($up -and $elapsed -gt $readyMinutes * 60) { return 'not-ready' }
        foreach ($u in $urls) {
            try {
                $r = Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 30 -MaximumRedirection 0
                $json = $r.Content | ConvertFrom-Json
                if ($expectVersion -and -not ([string]$json.version).StartsWith($expectVersion)) { $last = "wrong-version ($($json.version))"; continue }
                $up = $true
                if ($null -ne $json.ready -and -not $json.ready) {
                    $note = "đang nâng cấp CSDL: $($json.upgradingTenants) doanh nghiệp"
                    if ($note -ne $lastNote) { Info $note; $lastNote = $note }
                    continue
                }
                if ($json.failedTenants -gt 0) { Warn "$($json.failedTenants) doanh nghiệp lỗi cập nhật CSDL – xem Quản trị hệ thống (doanh nghiệp khác vẫn chạy)." }
                Info "$u → 200, phiên bản $($json.version)"
                return 'ok'
            }
            catch {
                $resp = $_.Exception.Response
                if ($resp) { $last = "http $([int]$resp.StatusCode)" }
            }
        }
        Start-Sleep -Seconds 3
    }
}

# ------------------------------------------------------------------ token GitHub (chỉ đọc) – mã hóa DPAPI theo máy
function Save-Token($layout, [Security.SecureString]$secure) {
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
    Add-Type -AssemblyName System.Security
    $bytes = [Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($plain), $null, 'LocalMachine')
    [IO.File]::WriteAllBytes($layout.Token, $bytes)
    Invoke-Native { icacls $layout.Token /inheritance:r /grant:r 'Administrators:F' 'SYSTEM:F' "$([Security.Principal.WindowsIdentity]::GetCurrent().Name):F" } | Out-Null
}

function Read-Token($layout) {
    if (-not (Test-Path $layout.Token)) { return $null }
    Add-Type -AssemblyName System.Security
    $bytes = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($layout.Token), $null, 'LocalMachine')
    return [Text.Encoding]::UTF8.GetString($bytes)
}

function Write-History($layout, $entry) {
    $line = ($entry | ConvertTo-Json -Compress)
    Add-Content -Path $layout.History -Value $line -Encoding UTF8
}
