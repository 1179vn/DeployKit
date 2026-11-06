# DeployKit – phát hành từ máy dev: kiểm tra nhánh sạch + đã đẩy, tạo tag vYYYY.M.D (trùng ngày thì .2, .3…), hỏi xác nhận rồi đẩy tag → GitHub Actions
# build + test + tạo Release (workflow release.yml của DeployKit). Không build gì trên máy dev.
#   powershell -File ..\DeployKit\tools\release-tag.ps1 -Repo . [-Yes]
param([string]$Repo = '.', [switch]$Yes)

# Windows PowerShell 5.1: với ErrorActionPreference = Stop, mọi dòng git ghi ra stderr (tiến độ push, "No names found" khi chưa có tag…) – kể cả đã
# chuyển hướng – thành lỗi dừng script. Gọi git qua Invoke-Git: gom stderr thành chữ, quyết định lỗi theo mã thoát.
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$script:GitExit = 0
function Invoke-Git {
    $output = & git.exe @args 2>&1 | ForEach-Object { "$_" }
    $script:GitExit = $LASTEXITCODE
    return $output
}
function Must($what) { if ($script:GitExit -ne 0) { throw "$what (git mã $script:GitExit)." } }

Push-Location $Repo
try {
    $branch = "$(Invoke-Git rev-parse --abbrev-ref HEAD)".Trim(); Must 'Không đọc được nhánh hiện tại'
    if ($branch -ne 'main') { throw "Đang ở nhánh '$branch' – phát hành từ main." }
    if (Invoke-Git status --porcelain --untracked-files=no) { throw 'Còn thay đổi chưa commit.' }
    Invoke-Git fetch --quiet origin main --tags | Out-Null; Must 'Không lấy được origin/main'
    $ahead = [int]"$(Invoke-Git rev-list --count origin/main..HEAD)"
    $behind = [int]"$(Invoke-Git rev-list --count HEAD..origin/main)"
    if ($behind -gt 0) { throw "main sau origin/main $behind commit – pull trước." }
    if ($ahead -gt 0) { throw "Còn $ahead commit chưa đẩy lên origin/main – push trước (CI của main phải xanh)." }

    $base = 'v' + (Get-Date -Format 'yyyy.M.d')
    $tag = $base; $n = 1
    while (Invoke-Git tag --list $tag) { $n++; $tag = "$base.$n" }
    $previous = "$(Invoke-Git describe --tags --abbrev=0)".Trim()
    if ($script:GitExit -ne 0) { $previous = $null }   # chưa có tag nào – lần phát hành đầu
    Write-Host "Phát hành $tag – commit $("$(Invoke-Git rev-parse --short HEAD)".Trim())$(if ($previous) { ", sau $previous" } else { ' (lần đầu)' })"
    if ($previous) { Invoke-Git log --pretty='  - %s' "$previous..HEAD" | Select-Object -First 30 | ForEach-Object { Write-Host $_ } }
    if (-not $Yes) {
        $a = Read-Host "Tạo và đẩy tag $tag? (y/N)"
        if ($a -notmatch '^(y|c|co|có|yes)$') { Write-Host 'Đã hủy.'; exit 1 }
    }
    Invoke-Git tag -a $tag -m "Phát hành $tag" | Out-Null; Must "Không tạo được tag $tag"
    Invoke-Git push origin $tag | ForEach-Object { Write-Host "   $_" }
    if ($script:GitExit -ne 0) { Invoke-Git tag -d $tag | Out-Null; throw 'Không đẩy được tag (đã xóa tag tạo tạm).' }
    $remote = "$(Invoke-Git remote get-url origin)".Trim() -replace '\.git$', '' -replace '^git@github\.com:', 'https://github.com/'
    Write-Host ''
    Write-Host "Đã đẩy $tag. Theo dõi: $remote/actions – xong có Release: $remote/releases/tag/$tag" -ForegroundColor Green
    Write-Host 'Trên VPS: nhấp đúp <Root>\deploy\deploy.cmd'
}
catch {
    Write-Host "LỖI: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
finally { Pop-Location }
