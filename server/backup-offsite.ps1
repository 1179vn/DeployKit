# DeployKit – chép sao lưu ra ngoài VPS (T-4: có sẵn, MẶC ĐỊNH TẮT). Task Scheduler (install.ps1 tạo, đang tắt) chạy hằng đêm 02:30 bằng SYSTEM.
# Bật: deploy.json → "Offsite": { "Enabled": true, "Remote": "onedrive:Backup/SiSuNext", "KeepDays": 30 } + cài rclone (rclone.exe trong PATH hoặc
# "Rclone": "C:\\Tools\\rclone.exe") + "rclone config" tạo remote (OneDrive / Google Drive) cho tài khoản SYSTEM (--config <file> qua "RcloneConfig")
# rồi bật task trong Task Scheduler. Chép: bản sao lưu CSDL mới trong 48 giờ (BackupDir) + shared\App_Data (cấu hình, khóa mã hóa); xóa bản trên đích
# cũ hơn KeepDays. Ghi kết quả vào shared\offsite-last.json (Tình trạng hệ thống / giám sát đọc được).
param([switch]$Force)

. "$PSScriptRoot\common.ps1"
$cfg = Read-Config $PSScriptRoot
$layout = Get-Layout $cfg
$state = Join-Path $layout.Shared 'offsite-last.json'

$off = $cfg.Offsite
if (-not $off -or (-not $off.Enabled -and -not $Force)) { Write-Host 'Sao lưu ra ngoài đang tắt (deploy.json → Offsite.Enabled).'; exit 0 }
if (-not $off.Remote) { throw 'Offsite.Remote trống (ví dụ onedrive:Backup/SiSuNext).' }
$rclone = if ($off.Rclone) { $off.Rclone } else { 'rclone' }
$common = @()
if ($off.RcloneConfig) { $common += @('--config', $off.RcloneConfig) }
$keep = if ($off.KeepDays) { [int]$off.KeepDays } else { 30 }

$result = [ordered]@{ at = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz'); remote = $off.Remote; ok = $false; message = '' }
try {
    if ($cfg.BackupDir) {
        & $rclone copy $cfg.BackupDir "$($off.Remote)/db" --max-age 48h --include '*.bak' @common
        if ($LASTEXITCODE -ne 0) { throw "rclone copy sao lưu CSDL lỗi ($LASTEXITCODE)." }
    }
    $appData = Join-Path $layout.Shared 'App_Data'
    if (Test-Path $appData) {
        & $rclone sync $appData "$($off.Remote)/App_Data/$(Get-Date -Format yyyyMMdd)" @common
        if ($LASTEXITCODE -ne 0) { throw "rclone sync App_Data lỗi ($LASTEXITCODE)." }
    }
    & $rclone delete $off.Remote --min-age "$($keep)d" @common
    $result.ok = $true; $result.message = "Đã chép, giữ $keep ngày."
}
catch { $result.message = $_.Exception.Message }
[IO.File]::WriteAllText($state, ($result | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
Write-Host $result.message
if (-not $result.ok) { exit 1 }
