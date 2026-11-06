# DeployKit

Bộ phát hành / triển khai dùng chung cho các ứng dụng ASP.NET Core trên **VPS Windows + IIS** (SiSuNext, QuangPhuPortal). Thiết kế và lý do:
`SiSuNext-Solutions/docs/ThietKe-TrienKhai.md` (chốt T-1–T-4 ngày 06/11/2026; T-1: đóng gói trên máy dev, chép lên VPS – không dùng GitHub Release).

- **Đóng gói** (máy dev): `tools\package.ps1 -Test` – từ chối mã chưa commit, chạy **toàn bộ test**, publish, tạo `<Tên>-<yyyy.M.d.HHmm>.zip` + `.zip.sha256`.
  Test đỏ thì không có gói.
- **Triển khai** (VPS): chép hai file vào `<Root>\incoming\`, nhấp đúp `deploy.cmd` → lấy gói mới nhất, kiểm SHA-256, giải nén vào thư mục riêng của phiên bản
  (không bao giờ chép đè), chạy thử `--preflight` của bản mới (chỉ đọc), đổi *khe* `current` (junction) → chờ `/health` đúng phiên bản + sẵn sàng; lỗi →
  **tự quay lại** bản trước.
- **Quay lại**: `rollback.cmd` – đổi khe về bản trước (vài giây, không chép file); bản cũ tự kiểm tra trước (`--preflight`) có chạy được trên CSDL hiện tại.

## Cấu trúc

```
tools/package.ps1               đóng gói (máy dev) – -Test chạy test trước, phiên bản mặc định yyyy.M.d.HHmm
tools/release-tag.ps1           (tùy chọn) phát hành qua GitHub: tạo + đẩy tag
.github/workflows/release.yml   (tùy chọn) workflow GitHub dùng lại: tag → build, test, Release
server/                         đóng kèm vào mỗi gói (thư mục deploy\ trong zip), chạy trên VPS
  deploy.ps1 / deploy.cmd       cài gói mới nhất trong incoming\ | -Package <zip | thư mục> | -GitHub [-Version]
  rollback.cmd                  quay lại (-To <phiên bản>)
  install.ps1 / install.cmd     cài lần đầu: bố cục, app pool, site, quyền, lịch sao lưu ngoài (tắt); nhấp đúp – hỏi tên miền
  backup-offsite.ps1            chép sao lưu ra OneDrive / Google Drive bằng rclone – mặc định TẮT
  common.ps1                    hàm dùng chung
tests/Test-Kit.ps1              tự kiểm tra (không cần IIS); -Repo <repo> đóng gói thật + --preflight
VERSION                         phiên bản kit (ghi vào manifest)
```

## Bố cục trên VPS (mỗi ứng dụng)

```
<Root>\incoming\                   chép gói zip + .sha256 vào đây; gói đã cài chuyển sang incoming\da-cai\ (giữ 5)
<Root>\releases\<phiên bản>\app\   bản phát hành – bất biến (giữ KeepReleases bản)
<Root>\current  →  releases\<phiên bản>\app   (junction; site IIS trỏ vào đây)
<Root>\shared\<SharedDirs>         dữ liệu sống (App_Data, logs) – ứng dụng đọc qua biến môi trường của app pool
<Root>\deploy\                     script (tự cập nhật theo bản đang chạy), deploy.json, history.jsonl
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
  "Source": "Package",
  "Project": "src/SiSuNext",
  "AppDll": "SiSuNext.dll",
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

`"Source": "GitHub"` (+ `DotnetVersion`, `Prepare` cho runner) = tải bản từ GitHub Release bằng token chỉ đọc – tùy chọn, không dùng mặc định.

## Dùng

**Đóng gói** (máy dev, trong repo ứng dụng – kit clone cạnh repo):
`powershell -File ..\DeployKit\tools\package.ps1 -Repo . -Test` → `artifacts\release\<Tên>-<phiên bản>.zip` + `.zip.sha256`.

**Cài lần đầu** (VPS đã có IIS + ASP.NET Core Hosting Bundle + SQL Server): chép zip lên VPS (Remote Desktop: Ctrl+C / Ctrl+V), *Unblock* trong Properties, giải
nén, nhấp đúp `deploy\install.cmd` (hỏi tên miền). Sau đó: HTTPS bằng win-acme cho site; ứng dụng có wizard thì mở `/cai-dat`.

**Mỗi lần phát hành**: chép zip + `.sha256` vào `<Root>\incoming\`, nhấp đúp `<Root>\deploy\deploy.cmd`. **Quay lại**: `rollback.cmd`.
Lịch sử: `<Root>\deploy\history.jsonl`.

**Sao lưu ra ngoài VPS**: cài rclone, `rclone config` (OneDrive / Google Drive), đặt `Offsite.Enabled = true` trong deploy.json của repo, đóng gói + cài bản mới,
bật task *DeployKit <Tên> – sao lưu ra ngoài* trong Task Scheduler. Chạy thử: `powershell -File <Root>\deploy\backup-offsite.ps1 -Force`.

## Phiên bản kit

`VERSION` + tag `v1.x.y`; tag `v1` di động (trỏ bản `v1.x` mới nhất) cho workflow GitHub tùy chọn.
