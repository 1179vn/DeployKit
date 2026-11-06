# DeployKit – đóng gói bản phát hành (dùng chung cho CI và máy dev; Windows PowerShell 5.1+ / pwsh).
#   CI (workflow release.yml) và máy dev (dự phòng) cho RA CÙNG MỘT ĐỊNH DẠNG:
#     <Name>-<Version>.zip   app\ (bản publish) + deploy\ (script VPS của kit) + manifest.json
#     <Name>-<Version>.manifest.json, SHA256SUMS
#   Dùng: powershell -File tools\package.ps1 -Repo <thư mục repo ứng dụng> -Version 2026.11.20 [-OutDir <thư mục>] [-Local]
# Cấu hình ứng dụng: <repo>\deploy\deploy.json (xem README.md của DeployKit).
param(
    [Parameter(Mandatory)] [string]$Repo,
    [Parameter(Mandatory)] [string]$Version,
    [string]$OutDir,
    [switch]$Local
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$kit = Split-Path $PSScriptRoot -Parent
$Repo = (Resolve-Path $Repo).Path
$cfg = Get-Content (Join-Path $Repo 'deploy\deploy.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $OutDir) { $OutDir = Join-Path $Repo 'artifacts\release' }
if ($Version -notmatch '^\d{4}\.\d{1,2}\.\d{1,2}(\.\d+)?$') { throw "Phiên bản '$Version' không đúng dạng yyyy.M.d[.n] (tag v2026.11.20 hoặc v2026.11.20.2)." }

function Step($t) { Write-Host ''; Write-Host "==> $t" -ForegroundColor Cyan }

Push-Location $Repo
try {
    $sha = (git rev-parse HEAD).Trim()
    $dirty = [bool](git status --porcelain --untracked-files=no)
    if ($dirty -and -not $Local) { throw 'Còn thay đổi chưa commit – CI không bao giờ như vậy.' }
    if ($dirty) { Write-Warning 'Có thay đổi chưa commit – gói dự phòng này ghi "dirty" trong manifest.' }
}
finally { Pop-Location }

$name = "$($cfg.Name)-$Version"
$work = Join-Path $OutDir $name
if (Test-Path $work) { Remove-Item -Recurse -Force $work }
New-Item -ItemType Directory -Force -Path (Join-Path $work 'app') | Out-Null

Step "Publish $($cfg.Project) – $Version ($($sha.Substring(0, 7)))"
$informational = "$Version+$($sha.Substring(0, 7))$(if ($dirty) { '.dirty' })"
& dotnet publish (Join-Path $Repo $cfg.Project) -c Release -r win-x64 --self-contained false -o (Join-Path $work 'app') --nologo -v q `
    "-p:Version=$Version" "-p:InformationalVersion=$informational" "-p:IncludeSourceRevisionInInformationalVersion=false"
if ($LASTEXITCODE -ne 0) { throw 'Publish thất bại.' }

# Không mang cấu hình / dữ liệu của máy dev: chỉ appsettings.json; thư mục dữ liệu sống nằm ở shared\ trên VPS
foreach ($f in @('appsettings.Development.json', 'appsettings.Production.json', 'appsettings.Staging.json')) {
    $p = Join-Path $work "app\$f"; if (Test-Path $p) { Remove-Item -Force $p }
}
foreach ($d in @($cfg.SharedDirs)) {
    $p = Join-Path $work "app\$d"; if (Test-Path $p) { Remove-Item -Recurse -Force $p }
}

$runtime = Get-Content (Join-Path $work "app\$([IO.Path]::GetFileNameWithoutExtension($cfg.AppDll)).runtimeconfig.json") -Raw | ConvertFrom-Json
$frameworks = @($runtime.runtimeOptions.framework) + @($runtime.runtimeOptions.frameworks) | Where-Object { $_ }
$aspnet = ($frameworks | Where-Object { $_.name -eq 'Microsoft.AspNetCore.App' } | Select-Object -First 1).version

Step 'Script VPS + manifest'
Copy-Item (Join-Path $kit 'server') (Join-Path $work 'deploy') -Recurse
Copy-Item (Join-Path $Repo 'deploy\deploy.json') (Join-Path $work 'deploy\deploy.json')
$kitVersion = (Get-Content (Join-Path $kit 'VERSION') -Raw).Trim()
$manifest = [ordered]@{
    Name             = $cfg.Name
    Version          = $Version
    InformationalVersion = $informational
    Commit           = $sha
    Dirty            = $dirty
    Local            = [bool]$Local
    BuiltAt          = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
    BuiltOn          = $env:COMPUTERNAME
    AspNetCore       = $aspnet
    AppDll           = $cfg.AppDll
    Kit              = $kitVersion
}
$manifestJson = $manifest | ConvertTo-Json
[IO.File]::WriteAllText((Join-Path $work 'manifest.json'), $manifestJson, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $work 'app\version.txt'), "$informational`r`n", [Text.UTF8Encoding]::new($false))

Step 'Nén + mã kiểm tra'
$zip = Join-Path $OutDir "$name.zip"
if (Test-Path $zip) { Remove-Item -Force $zip }
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($work, $zip, [IO.Compression.CompressionLevel]::Optimal, $false)
Copy-Item (Join-Path $work 'manifest.json') (Join-Path $OutDir "$name.manifest.json") -Force
Remove-Item -Recurse -Force $work

# Tự kiểm tra gói
$archive = [IO.Compression.ZipFile]::OpenRead($zip)
try { $entries = @($archive.Entries | ForEach-Object { $_.FullName -replace '\\', '/' }) } finally { $archive.Dispose() }
$need = @('manifest.json', 'deploy/deploy.ps1', 'deploy/deploy.cmd', 'deploy/rollback.cmd', 'deploy/install.ps1', 'deploy/deploy.json', "app/$($cfg.AppDll)")
$missing = $need | Where-Object { $entries -notcontains $_ }
if ($missing) { Remove-Item -Force $zip; throw "Gói thiếu: $($missing -join ', ')" }
$leaked = @($entries | Where-Object { $_ -match '^app/(appsettings\.(Development|Production|Staging)\.json|App_Data/)' })
if ($leaked) { Remove-Item -Force $zip; throw "Gói chứa file của máy dev: $($leaked -join ', ')" }

$hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText((Join-Path $OutDir 'SHA256SUMS'), "$hash  $name.zip`n", [Text.UTF8Encoding]::new($false))
Write-Host ''
Write-Host ("XONG: {0} ({1:N1} MB, sha256 {2})" -f $zip, ((Get-Item $zip).Length / 1MB), $hash.Substring(0, 12)) -ForegroundColor Green
