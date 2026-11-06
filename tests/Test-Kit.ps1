# DeployKit – tự kiểm tra trên máy dev / CI (không cần IIS): cú pháp mọi script (Windows PowerShell 5.1), đổi khe junction + đọc phiên bản đang chạy,
# biến môi trường {shared}, token DPAPI. Có -Repo: đóng gói thật ứng dụng đó (tools\package.ps1 -Local), kiểm tra nội dung gói, chạy --preflight của bản
# trong gói với biến môi trường -PreflightEnv (ví dụ SISUNEXT_APPDATA=D:\...\dev-data\App_Data).
#   powershell -File tests\Test-Kit.ps1 [-Repo D:\GITHUB\SiSuNext-Solutions -PreflightEnv @{ SISUNEXT_APPDATA = '...' }]
param([string]$Repo, [hashtable]$PreflightEnv = @{})

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$kit = Split-Path $PSScriptRoot -Parent
$failed = 0
function Check([string]$name, [scriptblock]$body) {
    try { & $body; Write-Host "  ✓ $name" -ForegroundColor Green }
    catch { $script:failed++; Write-Host "  ✗ $name – $($_.Exception.Message)" -ForegroundColor Red }
}
function Equal($expected, $actual) { if ("$expected" -ne "$actual") { throw "mong đợi '$expected', thực tế '$actual'" } }

Write-Host 'Cú pháp (PowerShell 5.1), BOM UTF-8'
foreach ($f in Get-ChildItem $kit -Recurse -Filter *.ps1 | Where-Object FullName -notmatch '\\tests\\') {
    Check $f.Name {
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors)
        if ($errors) { throw ($errors | ForEach-Object { "dòng $($_.Extent.StartLineNumber): $($_.Message)" }) -join '; ' }
        $bom = [IO.File]::ReadAllBytes($f.FullName)[0..2]
        if (-not ($bom[0] -eq 0xEF -and $bom[1] -eq 0xBB -and $bom[2] -eq 0xBF)) { throw 'thiếu BOM UTF-8 – PowerShell 5.1 đọc sai tiếng Việt' }
    }
}

. (Join-Path $kit 'server\common.ps1')
$root = Join-Path $env:TEMP ('deploykit-test-' + [guid]::NewGuid().ToString('N'))
$cfg = [pscustomobject]@{ Name = 'Thu'; AppDll = 'Thu.dll'; Root = $root; SiteName = 'Thu'; HealthPath = '/health'
    Environment = [pscustomobject]@{ APP_DATA = '{shared}\App_Data'; KHAC = 'giu nguyen' } }
$layout = Get-Layout $cfg
New-Item -ItemType Directory -Force -Path $layout.Releases, $layout.Deploy | Out-Null

Write-Host 'Khe current (junction)'
Check 'chưa có khe → không có phiên bản' { Equal '' (Get-CurrentVersionFromJunction $layout) }
foreach ($v in '2026.11.06', '2026.11.20') { New-Item -ItemType Directory -Force -Path (Join-Path $layout.Releases "$v\app") | Out-Null; Set-Content (Join-Path $layout.Releases "$v\app\ban.txt") $v }
Check 'đổi sang 2026.11.06' { Set-CurrentRelease $layout '2026.11.06'; Equal '2026.11.06' (Get-CurrentVersionFromJunction $layout); Equal '2026.11.06' (Get-Content (Join-Path $layout.Current 'ban.txt')) }
Check 'đổi sang 2026.11.20 – bản cũ còn nguyên' {
    Set-CurrentRelease $layout '2026.11.20'
    Equal '2026.11.20' (Get-Content (Join-Path $layout.Current 'ban.txt'))
    Equal '2026.11.06' (Get-Content (Join-Path $layout.Releases '2026.11.06\app\ban.txt'))
}
Check 'bản không có → lỗi, khe giữ nguyên' {
    try { Set-CurrentRelease $layout '2099.1.1'; throw 'không báo lỗi' } catch { if ($_.Exception.Message -eq 'không báo lỗi') { throw } }
    Equal '2026.11.20' (Get-CurrentVersionFromJunction $layout)
}
Check 'khe tạm (.chua-co-ban) → không có phiên bản' {
    New-Item -ItemType Directory -Force -Path (Join-Path $layout.Releases '.chua-co-ban\app') | Out-Null
    cmd /c rmdir "`"$($layout.Current)`"" | Out-Null
    cmd /c mklink /J "`"$($layout.Current)`"" "`"$(Join-Path $layout.Releases '.chua-co-ban\app')`"" | Out-Null
    Equal '' (Get-CurrentVersionFromJunction $layout)
}

Write-Host 'Thứ tự phiên bản (theo số, không theo chuỗi)'
Check '2026.11.20 mới hơn 2026.11.6; .HHmm cùng ngày' {
    foreach ($v in '2026.11.7', '2026.11.6.1530', '2026.11.6.930') { New-Item -ItemType Directory -Force -Path (Join-Path $layout.Releases "$v\app") | Out-Null }
    Equal '2026.11.20 2026.11.7 2026.11.6.1530 2026.11.6.930 2026.11.06' ((Get-Releases $layout) -join ' ')
}

Write-Host 'Biến môi trường, token'
Check '{shared} → <Root>\shared' {
    $vars = Get-AppEnvironment $cfg $layout
    Equal (Join-Path $root 'shared\App_Data') $vars['APP_DATA']
    Equal 'giu nguyen' $vars['KHAC']
}
Check 'token DPAPI theo máy: ghi / đọc lại' {
    Save-Token $layout (ConvertTo-SecureString 'github_pat_thu_nghiem' -AsPlainText -Force)
    Equal 'github_pat_thu_nghiem' (Read-Token $layout)
    if ([Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($layout.Token)) -match 'github_pat') { throw 'token lưu dạng rõ' }
}
cmd /c rmdir "`"$($layout.Current)`"" | Out-Null
Remove-Item -Recurse -Force $root

if ($Repo) {
    Write-Host "Đóng gói thật: $Repo"
    $out = Join-Path $env:TEMP ('deploykit-pkg-' + [guid]::NewGuid().ToString('N'))
    $appCfg = Get-Content (Join-Path $Repo 'deploy\deploy.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Check 'package.ps1 (gói máy dev)' { & (Join-Path $kit 'tools\package.ps1') -Repo $Repo -Version '2099.1.1' -OutDir $out -Local -AllowDirty | Out-Host }
    Check 'file .sha256 đi kèm gói khớp' {
        Equal (Get-Sha256 (Join-Path $out "$($appCfg.Name)-2099.1.1.zip")) `
            ((Get-Content (Join-Path $out "$($appCfg.Name)-2099.1.1.zip.sha256")) -split '\s+')[0]
    }
    $zip = Join-Path $out "$($appCfg.Name)-2099.1.1.zip"
    Check 'SHA256SUMS khớp' {
        $line = Get-Content (Join-Path $out 'SHA256SUMS')
        Equal (Get-Sha256 $zip) ($line -split '\s+')[0]
    }
    $x = Join-Path $out 'x'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $x)
    Check 'manifest: phiên bản, cờ gói máy dev' {
        $m = Get-Content (Join-Path $x 'manifest.json') -Raw | ConvertFrom-Json
        Equal '2099.1.1' $m.Version; Equal 'True' $m.Local
        if (-not $m.AspNetCore) { throw 'thiếu phiên bản ASP.NET Core' }
    }
    Check '--preflight của bản trong gói (chỉ đọc)' {
        $psi = New-Object Diagnostics.ProcessStartInfo 'dotnet', "`"$(Join-Path $x "app\$($appCfg.AppDll)")`" --preflight"
        $psi.WorkingDirectory = Join-Path $x 'app'; $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
        $psi.EnvironmentVariables['ASPNETCORE_ENVIRONMENT'] = 'Production'
        foreach ($k in $PreflightEnv.Keys) { $psi.EnvironmentVariables[$k] = $PreflightEnv[$k] }
        $p = [Diagnostics.Process]::Start($psi); $o = $p.StandardOutput.ReadToEnd(); $p.WaitForExit()
        $line = ($o -split "`r?`n") | Where-Object { $_ -like 'PREFLIGHT *' } | Select-Object -Last 1
        if (-not $line) { throw "không có dòng PREFLIGHT (mã $($p.ExitCode)): $o" }
        $r = $line.Substring(10) | ConvertFrom-Json
        Write-Host "    ok=$($r.ok) setupRequired=$($r.setupRequired) phiên bản=$($r.version) doanh nghiệp=$(@($r.tenants).Count)"
        if (-not ([string]$r.version).StartsWith('2099.1.1')) { throw "phiên bản trong ứng dụng '$($r.version)' không theo gói" }
        if (-not $r.ok) { throw $r.problem }
    }
    Remove-Item -Recurse -Force $out
}

Write-Host ''
if ($failed) { Write-Host "$failed kiểm tra lỗi." -ForegroundColor Red; exit 1 }
Write-Host 'Tất cả đạt.' -ForegroundColor Green
