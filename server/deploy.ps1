# DeployKit – phát hành / quay lại trên VPS IIS (Windows PowerShell 5.1+). Bố cục: <Root>\releases\<phiên bản>\, <Root>\current (junction – IIS trỏ
# vào đây), <Root>\shared\ (dữ liệu sống), <Root>\incoming\ (chép gói zip vào đây), <Root>\deploy\ (script này, deploy.json, history.jsonl).
#   deploy.cmd                      gói <Tên>-*.zip MỚI NHẤT trong <Root>\incoming\ (chép từ máy dev – cách chính)
#   deploy.cmd -Package <zip>       một gói chỉ định (file zip hoặc thư mục gói đã giải nén)
#   deploy.cmd -GitHub [-Version x] bản trên GitHub Release (tùy chọn – cần "Source": "GitHub" hoặc token đã lưu)
#   rollback.cmd [-To <phiên bản>]  quay lại bản trước (hoặc bản chỉ định) – chỉ đổi khe, không chép file
# Khác: -Yes (không hỏi), -NoPause.
# Các bước: kiểm SHA-256 (file .sha256 cạnh gói) → giải nén vào releases\<ver> (không bao giờ chép đè) → kiểm tra máy → --preflight của bản mới
# (chỉ đọc) → dừng app pool → đổi junction → khởi động → chờ /health đúng phiên bản + sẵn sàng → lỗi thì tự đổi về bản trước. Ghi history.jsonl,
# giữ N bản; gói đã cài chuyển sang incoming\da-cai\.
param(
    [string]$Version,
    [string]$Package,
    [switch]$GitHub,
    [switch]$Rollback,
    [string]$To,
    [switch]$Yes,
    [switch]$NoPause
)

. "$PSScriptRoot\common.ps1"
Assert-Admin $PSBoundParameters $PSCommandPath

$logFile = Join-Path $env:TEMP ("deploykit-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
Start-Transcript -Path $logFile -Append | Out-Null
function Done($code) {
    try { Stop-Transcript | Out-Null } catch { }
    if (-not $NoPause) { Write-Host ''; Read-Host 'Nhấn Enter để đóng' | Out-Null }
    exit $code
}
function Ask($question, [bool]$default) {
    if ($Yes) { return $default }
    $a = Read-Host "$question $(if ($default) { '(Y/n)' } else { '(y/N)' })"
    if (-not $a) { return $default }
    return $a -match '^(y|c|co|có|yes)$'
}

try {
    $cfg = Read-Config $PSScriptRoot
    $layout = Get-Layout $cfg
    Use-Iis
    if (-not (Test-Path "IIS:\Sites\$($cfg.SiteName)")) { throw "Chưa có site IIS '$($cfg.SiteName)' – chạy install.cmd trước (cài lần đầu)." }
    $appEnv = Get-AppEnvironment $cfg $layout
    $from = Get-CurrentVersionFromJunction $layout
    Write-Host "$($cfg.Name) – đang chạy: $(if ($from) { $from } else { '(chưa có)' })"

    # -------------------------------------------------------------- chọn bản
    if ($Rollback) {
        $all = @(Get-Releases $layout)
        if ($To) { $target = $To }
        else { $target = $all | Where-Object { $_ -ne $from } | Select-Object -First 1 }
        if (-not $target -or $all -notcontains $target) { throw "Không có bản để quay lại$(if ($To) { " ($To)" })." }
        Write-Host "Quay lại: $from → $target" -ForegroundColor Yellow
    }
    else {
        Step 'Lấy bản phát hành'
        $tmp = Join-Path $env:TEMP ("deploykit-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp | Out-Null
        $incomingZip = $null; $zip = $null
        if ($Package) {
            $zip = (Resolve-Path $Package).Path   # file zip, hoặc thư mục gói đã giải nén (install.cmd)
        }
        elseif (-not $GitHub -and $cfg.Source -ne 'GitHub') {
            # Cách chính: gói chép từ máy dev vào incoming\ – lấy gói mới nhất (theo phiên bản trong tên)
            New-Item -ItemType Directory -Force -Path $layout.Incoming | Out-Null
            $candidates = @(Get-ChildItem $layout.Incoming -File -Filter "$($cfg.Name)-*.zip")
            if (-not $candidates) { throw "Chưa có gói $($cfg.Name)-*.zip trong $($layout.Incoming) – chép gói từ máy dev vào đó rồi chạy lại." }
            $incomingZip = $candidates | Sort-Object { ConvertTo-VersionKey ($_.BaseName.Substring($cfg.Name.Length + 1)) } -Descending | Select-Object -First 1
            $zip = $incomingZip.FullName
            if ($candidates.Count -gt 1) { Info "Có $($candidates.Count) gói trong incoming\ – chọn bản mới nhất." }
        }
        if ($zip -and (Test-Path $zip -PathType Leaf)) {
            Info "Gói: $zip ($([math]::Round((Get-Item $zip).Length / 1MB, 1)) MB)"
            $sumFile = "$zip.sha256"
            if (Test-Path $sumFile) {
                $expected = ((Get-Content $sumFile -TotalCount 1) -split '\s+')[0].ToLowerInvariant()
                $actual = (Get-Sha256 $zip)
                if ($expected -ne $actual) { throw 'Mã kiểm tra SHA-256 không khớp – gói chép thiếu / hỏng. Chép lại gói (cùng file .sha256) rồi chạy lại.' }
                Info 'SHA-256 khớp.'
            }
            else { Warn "Không có $(Split-Path $sumFile -Leaf) cạnh gói – không kiểm được gói chép có đủ không." }
        }
        if (-not $zip) {
            $token = Read-Token $layout
            if (-not $token) { throw "Chưa có token GitHub (chạy install.cmd -Token) – hoặc dùng -Package <zip>." }
            $headers = @{ Authorization = "Bearer $token"; Accept = 'application/vnd.github+json'; 'User-Agent' = 'DeployKit' }
            $api = "https://api.github.com/repos/$($cfg.Repo)/releases/" + $(if ($Version) { "tags/v$Version" } else { 'latest' })
            $release = Invoke-RestMethod -Uri $api -Headers $headers
            $zipAsset = $release.assets | Where-Object { $_.name -like "$($cfg.Name)-*.zip" } | Select-Object -First 1
            $sumAsset = $release.assets | Where-Object { $_.name -eq 'SHA256SUMS' } | Select-Object -First 1
            if (-not $zipAsset -or -not $sumAsset) { throw "Release $($release.tag_name) thiếu gói zip / SHA256SUMS." }
            $dl = @{ Authorization = "Bearer $token"; Accept = 'application/octet-stream'; 'User-Agent' = 'DeployKit' }
            $zip = Join-Path $tmp $zipAsset.name
            Info "Tải $($zipAsset.name) ($([math]::Round($zipAsset.size / 1MB, 1)) MB) – $($release.tag_name)"
            Invoke-WebRequest -Uri $zipAsset.url -Headers $dl -OutFile $zip -UseBasicParsing
            Invoke-WebRequest -Uri $sumAsset.url -Headers $dl -OutFile (Join-Path $tmp 'SHA256SUMS') -UseBasicParsing
            $expected = ((Get-Content (Join-Path $tmp 'SHA256SUMS') | Where-Object { $_ -match [regex]::Escape($zipAsset.name) }) -split '\s+')[0]
            $actual = (Get-Sha256 $zip)
            if ($expected -ne $actual) { throw "Mã kiểm tra SHA-256 không khớp – gói hỏng / bị sửa. Không cài." }
            Info 'SHA-256 khớp.'
        }
        # Giải nén vào thư mục tạm cạnh releases rồi đổi tên – bản trong releases\ luôn đầy đủ
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $staging = Join-Path $layout.Releases ('.dang-giai-nen-' + [guid]::NewGuid().ToString('N'))
        if (Test-Path $zip -PathType Container) {
            New-Item -ItemType Directory -Path $staging | Out-Null
            Copy-Item (Join-Path $zip '*') $staging -Recurse
        }
        else { [IO.Compression.ZipFile]::ExtractToDirectory($zip, $staging) }
        # Bỏ cờ "tải từ Internet / máy khác" (chép qua Remote Desktop, trình duyệt) – tránh hộp cảnh báo khi chạy script của bản này
        Get-ChildItem $staging -Recurse -File | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Stream Zone.Identifier -ErrorAction SilentlyContinue }
        $manifest = Get-Content (Join-Path $staging 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($manifest.Name -ne $cfg.Name) { Remove-Item -Recurse -Force $staging; throw "Gói của '$($manifest.Name)', không phải '$($cfg.Name)'." }
        $target = $manifest.Version
        $dest = Join-Path $layout.Releases $target
        if (Test-Path $dest) {
            if ($target -eq $from) { Remove-Item -Recurse -Force $staging; Write-Host "Bản $target đang chạy – không có gì để cài." -ForegroundColor Green; Done 0 }
            Remove-Item -Recurse -Force $dest   # cài lại một bản cũ / bản hỏng lần trước
        }
        Rename-Item $staging $dest
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
        Info "Bản $target ($($manifest.InformationalVersion), build $($manifest.BuiltAt)$(if ($manifest.BuiltOn) { ", đóng gói trên $($manifest.BuiltOn)" })$(if ($manifest.Dirty) { ' – CÓ THAY ĐỔI CHƯA COMMIT' }))"

        # -------------------------------------------------------------- kiểm tra máy
        Step 'Kiểm tra máy chủ'
        if (-not (Get-WebGlobalModule -Name 'AspNetCoreModuleV2' -ErrorAction SilentlyContinue)) { throw 'IIS chưa có AspNetCoreModuleV2 – cài ASP.NET Core Hosting Bundle, iisreset.' }
        if ($manifest.AspNetCore) {
            $major = ($manifest.AspNetCore.Split('.')[0..1]) -join '.'
            $have = @(Get-ChildItem (Join-Path $env:ProgramFiles 'dotnet\shared\Microsoft.AspNetCore.App') -Directory -ErrorAction SilentlyContinue | Where-Object Name -like "$major.*")
            if (-not $have) { throw "Chưa cài ASP.NET Core $major (gói cần $($manifest.AspNetCore)) – cài Hosting Bundle $major." }
        }
        $free = (Get-PSDrive -Name $layout.Root.Substring(0, 1)).Free
        if ($free -lt 2GB) { Warn ("Ổ đĩa chỉ còn {0:N0} MB." -f ($free / 1MB)) }
        Info 'OK'
    }

    # -------------------------------------------------------------- chạy thử bản sẽ chuyển sang (chỉ đọc)
    $appDir = Join-Path (Join-Path $layout.Releases $target) 'app'
    Step "Chạy thử bản $target (--preflight, không ghi gì)"
    $psi = New-Object Diagnostics.ProcessStartInfo 'dotnet', "`"$(Join-Path $appDir $cfg.AppDll)`" $(if ($cfg.Preflight) { $cfg.Preflight } else { '--preflight' })"
    $psi.WorkingDirectory = $appDir; $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.EnvironmentVariables['ASPNETCORE_ENVIRONMENT'] = 'Production'
    foreach ($k in $appEnv.Keys) { $psi.EnvironmentVariables[$k] = $appEnv[$k] }
    $proc = [Diagnostics.Process]::Start($psi)
    $out = $proc.StandardOutput.ReadToEnd(); $err = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    $line = ($out -split "`r?`n") | Where-Object { $_ -like 'PREFLIGHT *' } | Select-Object -Last 1
    if (-not $line) { throw "Bản $target không chạy được --preflight (mã $($proc.ExitCode)). $err $($out.Substring(0, [Math]::Min(800, $out.Length)))" }
    $pre = $line.Substring(10) | ConvertFrom-Json
    if ($pre.setupRequired) { Info 'Chưa cài đặt (chưa có cấu hình CSDL) – sau khi chuyển, mở /cai-dat để cài.' }
    else {
        Info "CSDL hệ thống: $($pre.systemPending) migration chờ"
        foreach ($t in $pre.tenants) {
            $note = if ($t.problem) { " – $($t.problem)" } elseif ($t.pending) { " – $($t.pending) migration (nâng cấp nền sau khi chuyển, sao lưu trước)" } else { '' }
            Info "$($t.code) [$($t.status)]$note"
        }
    }
    if (-not $pre.ok) {
        Write-Host "Bản $target KHÔNG chạy được trên dữ liệu hiện tại: $($pre.problem)" -ForegroundColor Red
        if ($Rollback) {
            Write-Host 'CSDL đã qua migration phá vỡ của bản mới hơn – muốn quay lại bản này phải khôi phục bản sao lưu "truoc-cap-nhat" của từng doanh nghiệp' -ForegroundColor Red
            Write-Host '(Quản trị hệ thống → Doanh nghiệp → Khôi phục) rồi chạy lại rollback.cmd. Bản đang chạy giữ nguyên.' -ForegroundColor Red
        }
        Done 2
    }
    if (-not (Ask "`nChuyển $(if ($from) { $from } else { '(chưa có)' }) → $target ?" $true)) { Write-Host 'Đã hủy – bản đang chạy giữ nguyên.'; Done 1 }

    # -------------------------------------------------------------- đổi khe
    Step 'Đổi khe'
    Set-PoolEnvironment $layout $appEnv
    Stop-App $layout
    Set-CurrentRelease $layout $target
    Start-WebAppPool $layout.Pool
    $started = Get-Date
    Info "current → releases\$target\app"

    Step "Chờ /health (bản $target sẵn sàng)"
    $ready = if ($cfg.UpgradeTimeoutMinutes) { [int]$cfg.UpgradeTimeoutMinutes } else { 30 }
    $status = if ($pre.setupRequired) { 'skip' } else { Wait-Health $cfg $target 120 $ready }

    $entry = [ordered]@{
        at = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz'); user = "$env:USERDOMAIN\$env:USERNAME"; action = $(if ($Rollback) { 'rollback' } else { 'deploy' })
        from = $from; to = $target; result = $status; seconds = [int]((Get-Date) - $started).TotalSeconds
    }
    if ($status -eq 'ok' -or $status -eq 'skip') {
        Write-History $layout $entry
        if (-not $Rollback) {
            # Script của bản mới thay script đang dùng (giữ token, lịch sử)
            Copy-Item (Join-Path (Join-Path $layout.Releases $target) 'deploy\*') $layout.Deploy -Recurse -Force -Exclude 'token.dat', 'history.jsonl'
            $keep = if ($cfg.KeepReleases) { [int]$cfg.KeepReleases } else { 5 }
            Get-Releases $layout | Where-Object { $_ -notin @($target, $from) } | Select-Object -Skip ([Math]::Max(0, $keep - 2)) |
                ForEach-Object { Remove-Item -Recurse -Force (Join-Path $layout.Releases $_); Info "xóa bản cũ $_" }
            # Gói đã cài: chuyển khỏi incoming\ (lần sau không chọn lại), giữ 5 gói gần nhất
            if ($incomingZip) {
                $done = Join-Path $layout.Incoming 'da-cai'
                New-Item -ItemType Directory -Force -Path $done | Out-Null
                Move-Item $incomingZip.FullName $done -Force
                if (Test-Path "$($incomingZip.FullName).sha256") { Move-Item "$($incomingZip.FullName).sha256" $done -Force }
                Get-ChildItem $done -File -Filter '*.zip' | Sort-Object LastWriteTime -Descending | Select-Object -Skip 5 |
                    ForEach-Object { Remove-Item -Force $_.FullName, "$($_.FullName).sha256" -ErrorAction SilentlyContinue }
            }
        }
        Write-Host ''
        Write-Host "XONG – $($cfg.Name) $target đang chạy ($($entry.seconds) giây)." -ForegroundColor Green
        Done 0
    }

    # -------------------------------------------------------------- lỗi → tự quay lại
    Write-Host "Bản $target không lên được (kết quả: $status)." -ForegroundColor Red
    if ($status -eq 'not-ready') {
        # Đã chạy nhưng nâng cấp CSDL quá lâu – không quay lại (doanh nghiệp đang migrate); theo dõi ở Quản trị hệ thống
        Warn 'Ứng dụng đã chạy, còn doanh nghiệp đang nâng cấp CSDL quá thời gian chờ – theo dõi ở Quản trị hệ thống, không quay lại.'
        $entry.result = 'running-upgrading'; Write-History $layout $entry; Done 3
    }
    if ($from -and $from -ne $target) {
        Step "Tự quay lại $from"
        Stop-App $layout
        Set-CurrentRelease $layout $from
        Start-WebAppPool $layout.Pool
        $back = Wait-Health $cfg $from 120 $ready
        $entry.result = "failed:$status;reverted:$back"; Write-History $layout $entry
        Write-Host "Đã quay lại $from (kiểm tra: $back). Bản $target giữ trong releases\ để xem lỗi (log ở shared\logs, Event Viewer)." -ForegroundColor Yellow
        Done 4
    }
    $entry.result = "failed:$status"; Write-History $layout $entry
    Done 5
}
catch {
    Write-Host ''
    Write-Host "LỖI: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Nhật ký: $logFile"
    Done 1
}
