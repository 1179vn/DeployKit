# DeployKit – phát hành từ máy dev: kiểm tra nhánh sạch + đã đẩy, tạo tag vYYYY.M.D (trùng ngày thì .2, .3…), hỏi xác nhận rồi đẩy tag → GitHub Actions
# build + test + tạo Release (workflow release.yml của DeployKit). Không build gì trên máy dev.
#   powershell -File ..\DeployKit\tools\release-tag.ps1 -Repo . [-Yes]
param([string]$Repo = '.', [switch]$Yes)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
Push-Location $Repo
try {
    $branch = (git rev-parse --abbrev-ref HEAD).Trim()
    if ($branch -ne 'main') { throw "Đang ở nhánh '$branch' – phát hành từ main." }
    if (git status --porcelain --untracked-files=no) { throw 'Còn thay đổi chưa commit.' }
    git fetch --quiet origin main --tags
    $ahead = [int](git rev-list --count origin/main..HEAD)
    $behind = [int](git rev-list --count HEAD..origin/main)
    if ($behind -gt 0) { throw "main sau origin/main $behind commit – pull trước." }
    if ($ahead -gt 0) { throw "Còn $ahead commit chưa đẩy lên origin/main – push trước (CI của main phải xanh)." }

    $base = 'v' + (Get-Date -Format 'yyyy.M.d')
    $tag = $base; $n = 1
    while (git tag --list $tag) { $n++; $tag = "$base.$n" }
    $previous = git describe --tags --abbrev=0 2>$null
    Write-Host "Phát hành $tag – commit $((git rev-parse --short HEAD).Trim())$(if ($previous) { ", sau $previous" })"
    if ($previous) { git log --pretty='  - %s' "$previous..HEAD" | Select-Object -First 30 | ForEach-Object { Write-Host $_ } }
    if (-not $Yes) {
        $a = Read-Host "Tạo và đẩy tag $tag? (y/N)"
        if ($a -notmatch '^(y|c|co|có|yes)$') { Write-Host 'Đã hủy.'; exit 1 }
    }
    git tag -a $tag -m "Phát hành $tag"
    git push origin $tag
    if ($LASTEXITCODE -ne 0) { git tag -d $tag | Out-Null; throw 'Không đẩy được tag.' }
    $remote = (git remote get-url origin).Trim() -replace '\.git$', '' -replace '^git@github\.com:', 'https://github.com/'
    Write-Host ''
    Write-Host "Đã đẩy $tag. Theo dõi: $remote/actions – xong có Release: $remote/releases/tag/$tag" -ForegroundColor Green
    Write-Host 'Trên VPS: nhấp đúp <Root>\deploy\deploy.cmd'
}
finally { Pop-Location }
