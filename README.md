# DeployKit

Bộ phát hành / triển khai dùng chung cho các ứng dụng ASP.NET Core trên **VPS Windows + IIS** (SiSuNext, QuangPhuPortal). Thiết kế và lý do:
`SiSuNext-Solutions/docs/ThietKe-TrienKhai.md` (chốt T-1–T-4 ngày 06/11/2026).

- **Phát hành**: đẩy tag `vYYYY.M.D[.n]` ở repo ứng dụng → GitHub Actions build, chạy **toàn bộ test**, đóng gói, tạo **GitHub Release** (`<Tên>-<phiên bản>.zip`,
  `manifest.json`, `SHA256SUMS`). Test đỏ thì không có bản.
- **Triển khai**: trên VPS nhấp đúp `deploy.cmd` → tải bản mới nhất (token chỉ đọc), kiểm SHA-256, giải nén vào thư mục riêng của phiên bản (không bao giờ chép
  đè), chạy thử `--preflight` của bản mới (chỉ đọc), đổi *khe* `current` (junction) → chờ `/health` đúng phiên bản + sẵn sàng; lỗi → **tự quay lại** bản trước.
- **Quay lại**: `rollback.cmd` – đổi khe về bản trước (vài giây, không chép file); bản cũ tự kiểm tra trước (`--preflight`) có chạy được trên CSDL hiện tại.

## Cấu trúc

```
.github/workflows/release.yml   workflow dùng lại (workflow_call)
tools/package.ps1               đóng gói – CI và máy dev (dự phòng) ra cùng định dạng
server/                         đóng kèm vào mỗi gói (thư mục deploy\ trong zip), chạy trên VPS
  deploy.ps1 / deploy.cmd       phát hành (bản mới nhất | -Version | -Package <zip | thư mục>)
  rollback.cmd                  quay lại (-To <phiên bản>)
  install.ps1 / install.cmd     cài lần đầu: bố cục, app pool, site, quyền, token, lịch sao lưu ngoài (tắt)
  backup-offsite.ps1            chép sao lưu ra OneDrive / Google Drive bằng rclone – mặc định TẮT
  common.ps1                    hàm dùng chung
VERSION                         phiên bản kit (ghi vào manifest)
```

## Bố cục trên VPS (mỗi ứng dụng)

```
<Root>\releases\<phiên bản>\app\   bản phát hành – bất biến
<Root>\current  →  releases\<phiên bản>\app   (junction; site IIS trỏ vào đây)
<Root>\shared\<SharedDirs>         dữ liệu sống (App_Data, logs) – ứng dụng đọc qua biến môi trường của app pool
<Root>\deploy\                     script (tự cập nhật theo bản đang chạy), deploy.json, token.dat (DPAPI), history.jsonl
```

## Hợp đồng ứng dụng (mỗi ứng dụng tự làm một lần)

| Yêu cầu | Ý nghĩa |
|---|---|
| `GET <HealthPath>` → JSON `{ "version": "<InformationalVersion>", "ready": true/false, ... }` | Script chờ `version` bắt đầu bằng phiên bản vừa cài và `ready` = true (bỏ trống `ready` = chỉ cần 200) |
| `dotnet <AppDll> --preflight` → một dòng `PREFLIGHT {"ok":…,"setupRequired":…,"problem":…}`, mã thoát 0 / 1 | Bản mới tự kiểm tra cấu hình / CSDL **chỉ đọc** trước khi được chuyển sang |
| Thư mục dữ liệu đọc từ biến môi trường (`Environment` trong deploy.json, `{shared}` = `<Root>\shared`) | Dữ liệu nằm ngoài bản phát hành |
| Migration chỉ *mở rộng*; migration phá vỡ được khai báo, CSDL ghi "thế hệ schema" | Quay lại bản cũ sau khi đã migrate vẫn chạy được |
| Sao lưu CSDL trước khi migrate | Khôi phục được khi buộc phải lùi CSDL |

## deploy.json (trong repo ứng dụng, thư mục `deploy/`)

```json
{
  "Name": "SiSuNext",
  "Repo": "1179vn/SiSuNext-Solutions",
  "Project": "src/SiSuNext",
  "AppDll": "SiSuNext.dll",
  "DotnetVersion": "10.0.x",
  "Prepare": ["sqllocaldb create MSSQLLocalDB -s"],
  "Test": ["dotnet test SiSuNext-Solutions.slnx -c Release"],
  "Root": "C:\\Apps\\SiSuNext",
  "SiteName": "SiSuNext",
  "HealthPath": "/health",
  "Preflight": "--preflight",
  "SharedDirs": ["App_Data", "logs"],
  "Environment": { "SISUNEXT_APPDATA": "{shared}\\App_Data" },
  "BackupDir": "C:\\Backup\\SiSuNext",
  "KeepReleases": 5,
  "UpgradeTimeoutMinutes": 30,
  "Offsite": { "Enabled": false, "Remote": "onedrive:Backup/SiSuNext", "KeepDays": 30 }
}
```

## Dùng

**Phát hành** (máy dev): `git tag v2026.11.20 && git push origin v2026.11.20` → theo dõi tab Actions → Release.
Dự phòng khi CI hỏng: `powershell -File ..\DeployKit\tools\package.ps1 -Repo . -Version 2026.11.20 -Local` → chép zip lên VPS → `deploy.cmd -Package <zip>`.

**Cài lần đầu** (VPS đã có IIS + ASP.NET Core Hosting Bundle + SQL Server): tải zip của release (trình duyệt), giải nén, chạy `deploy\install.cmd -HostName <tên miền>`
(dán token chỉ đọc khi được hỏi). Sau đó: HTTPS bằng win-acme cho site; ứng dụng có wizard thì mở `/cai-dat`.

**Mỗi lần phát hành**: nhấp đúp `<Root>\deploy\deploy.cmd`. **Quay lại**: `rollback.cmd`. Lịch sử: `<Root>\deploy\history.jsonl`.

**Sao lưu ra ngoài VPS**: cài rclone, `rclone config` (OneDrive / Google Drive), đặt `Offsite.Enabled = true` trong deploy.json của repo, phát hành bản mới, bật task
*DeployKit <Tên> – sao lưu ra ngoài* trong Task Scheduler. Chạy thử: `powershell -File <Root>\deploy\backup-offsite.ps1 -Force`.

## Phiên bản kit

Tag `v1` (di động – trỏ bản `v1.x` mới nhất), `v1.0.0`… Repo ứng dụng ghim `@v1` ở workflow; nâng lớn đổi `@v2`.
