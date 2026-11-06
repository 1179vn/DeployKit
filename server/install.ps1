# DeployKit – cài lần đầu trên VPS (Windows PowerShell 5.1+, tự xin quyền Administrator). Chạy từ thư mục deploy\ của một gói phát hành đã giải nén
# (gói tải tay từ GitHub Release hoặc gói build trên máy dev):
#   install.cmd -HostName sisunext.vidu.vn
# Làm (chạy lại được – bước nào đã có thì giữ nguyên):
#   1. Bố cục <Root>\releases, shared\<SharedDirs>, deploy\ (chép script + deploy.json); thư mục sao lưu CSDL (BackupDir).
#   2. App pool (No Managed Code, AlwaysRunning, không tắt khi rảnh, tái chế 3h, nạp hồ sơ người dùng) + biến môi trường của ứng dụng (thư mục dữ liệu ở
#      shared\ – không nằm trong bản phát hành nên không bao giờ bị ghi đè).
#   3. Site IIS trỏ <Root>\current, binding http :80 theo tên miền (HTTPS: win-acme sau khi DNS trỏ về – xem README).
#   4. Quyền: app pool ghi shared\ (+ thư mục sao lưu), đọc releases\; tài khoản SQL Server ghi thư mục sao lưu.
#   5. Token GitHub chỉ đọc (Contents: Read-only của repo ứng dụng) – mã hóa DPAPI theo máy, chỉ Administrators / SYSTEM đọc được.
#   6. Lịch "sao lưu ra ngoài" (Task Scheduler, mặc định TẮT – bật trong deploy.json → Offsite.Enabled).
#   7. Cài bản trong gói này (deploy.ps1 -Package).
param(
    [string]$HostName,
    [string]$SqlServiceAccount = 'NT Service\MSSQLSERVER',
    [switch]$Token,
    [switch]$Yes,
    [switch]$NoPause
)

. "$PSScriptRoot\common.ps1"
Assert-Admin $PSBoundParameters $PSCommandPath

try {
    $cfg = Read-Config $PSScriptRoot
    $layout = Get-Layout $cfg
    Use-Iis
    $package = Split-Path $PSScriptRoot -Parent   # thư mục gói đã giải nén: app\, deploy\, manifest.json
    Write-Host "Cài $($cfg.Name) vào $($layout.Root) (site IIS '$($cfg.SiteName)', app pool '$($layout.Pool)')"

    Step 'Bố cục thư mục'
    foreach ($d in @($layout.Root, $layout.Releases, $layout.Shared, $layout.Deploy)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    foreach ($d in @($cfg.SharedDirs)) { New-Item -ItemType Directory -Force -Path (Join-Path $layout.Shared $d) | Out-Null }
    if ($cfg.BackupDir) { New-Item -ItemType Directory -Force -Path $cfg.BackupDir | Out-Null }
    if ($PSScriptRoot.TrimEnd('\') -ne $layout.Deploy) {
        Copy-Item (Join-Path $PSScriptRoot '*') $layout.Deploy -Recurse -Force -Exclude 'token.dat', 'history.jsonl'
    }
    Info 'OK'

    Step 'App pool'
    $poolPath = "IIS:\AppPools\$($layout.Pool)"
    if (-not (Test-Path $poolPath)) { New-WebAppPool -Name $layout.Pool | Out-Null; Info "Tạo $($layout.Pool)" }
    Set-ItemProperty $poolPath managedRuntimeVersion ''
    Set-ItemProperty $poolPath startMode 'AlwaysRunning'
    Set-ItemProperty $poolPath processModel.idleTimeout ([TimeSpan]::Zero)
    Set-ItemProperty $poolPath processModel.loadUserProfile $true
    Set-ItemProperty $poolPath recycling.periodicRestart.time ([TimeSpan]::Zero)
    Clear-ItemProperty $poolPath -Name recycling.periodicRestart.schedule -ErrorAction SilentlyContinue
    Set-ItemProperty $poolPath -Name recycling.periodicRestart.schedule -Value @{ value = '03:00:00' }
    Set-PoolEnvironment $layout (Get-AppEnvironment $cfg $layout)
    Info 'No Managed Code, AlwaysRunning, idle 0, tái chế 3:00, biến môi trường dữ liệu → shared\'

    Step 'Site IIS'
    if (-not (Test-Path $layout.Current)) {
        # Khe tạm trỏ thư mục trống để tạo site; deploy.ps1 đổi sang bản thật
        $placeholder = Join-Path $layout.Releases '.chua-co-ban\app'
        New-Item -ItemType Directory -Force -Path $placeholder | Out-Null
        cmd /c mklink /J "`"$($layout.Current)`"" "`"$placeholder`"" | Out-Null
    }
    if (-not (Test-Path "IIS:\Sites\$($cfg.SiteName)")) {
        if (-not $HostName) { throw 'Cài lần đầu cần -HostName <tên miền> (binding http :80).' }
        New-Website -Name $cfg.SiteName -PhysicalPath $layout.Current -ApplicationPool $layout.Pool -HostHeader $HostName -Port 80 | Out-Null
        Info "Tạo site $($cfg.SiteName) – http://$HostName"
    }
    else {
        Set-ItemProperty "IIS:\Sites\$($cfg.SiteName)" physicalPath $layout.Current
        Set-ItemProperty "IIS:\Sites\$($cfg.SiteName)" applicationPool $layout.Pool
        Info "Site $($cfg.SiteName) có sẵn – trỏ lại $($layout.Current)"
    }
    Set-ItemProperty "IIS:\Sites\$($cfg.SiteName)" applicationDefaults.preloadEnabled $true

    Step 'Quyền'
    $identity = "IIS AppPool\$($layout.Pool)"
    icacls $layout.Shared /grant "${identity}:(OI)(CI)M" /T /Q | Out-Null
    icacls $layout.Releases /grant "${identity}:(OI)(CI)RX" /T /Q | Out-Null
    if ($cfg.BackupDir) {
        icacls $cfg.BackupDir /grant "${identity}:(OI)(CI)M" /T /Q | Out-Null
        icacls $cfg.BackupDir /grant "${SqlServiceAccount}:(OI)(CI)M" /T /Q 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { Warn "Không cấp được quyền ghi $($cfg.BackupDir) cho '$SqlServiceAccount' – instance khác: -SqlServiceAccount 'NT Service\MSSQL`$SQLEXPRESS'." }
    }
    icacls $layout.Deploy /inheritance:r /grant:r 'Administrators:(OI)(CI)F' 'SYSTEM:(OI)(CI)F' /Q | Out-Null
    Info "${identity}: ghi shared\ + sao lưu, đọc releases\; deploy\ chỉ Administrators"

    Step 'Token GitHub (chỉ đọc)'
    if ($Token -or -not (Test-Path $layout.Token)) {
        Write-Host "   Tạo fine-grained token: GitHub → Settings → Developer settings → Fine-grained tokens → repo $($cfg.Repo) → Contents: Read-only."
        $secure = Read-Host '   Dán token (Enter = bỏ qua, dùng -Package)' -AsSecureString
        if ($secure.Length -gt 0) { Save-Token $layout $secure; Info 'Đã lưu (DPAPI theo máy).' } else { Warn 'Chưa có token – deploy.cmd chỉ dùng được với -Package.' }
    }
    else { Info 'Đã có.' }

    Step 'Lịch sao lưu ra ngoài VPS'
    $taskName = "DeployKit $($cfg.Name) – sao lưu ra ngoài"
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $layout.Deploy 'backup-offsite.ps1')`""
    $trigger = New-ScheduledTaskTrigger -Daily -At '02:30'
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
    if (-not ($cfg.Offsite -and $cfg.Offsite.Enabled)) { Disable-ScheduledTask -TaskName $taskName | Out-Null; Info 'Đã tạo, đang TẮT (Offsite.Enabled = false).' }
    else { Info "Bật – đích $($cfg.Offsite.Remote)." }

    Step 'Cài bản trong gói'
    $deployArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $layout.Deploy 'deploy.ps1'), '-NoPause')
    if ($Yes) { $deployArgs += '-Yes' }
    # Chính gói đã giải nén này (không cần tải lại)
    $deployArgs += @('-Package', $package)
    & powershell @deployArgs
    Write-Host ''
    Write-Host "Cài xong. Lần sau: $($layout.Deploy)\deploy.cmd (bản mới nhất), rollback.cmd (quay lại)." -ForegroundColor Green
}
catch {
    Write-Host ''
    Write-Host "LỖI: $($_.Exception.Message)" -ForegroundColor Red
}
if (-not $NoPause) { Write-Host ''; Read-Host 'Nhấn Enter để đóng' | Out-Null }
