@echo off
rem DeployKit - nhap dup de quay lai ban truoc (chi doi khe, vai giay). Them: -To 2026.11.06
rem PSModulePath ke thua tu PowerShell 7 lam Windows PowerShell nap sai module - xoa de dung mac dinh
set "PSModulePath="
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy.ps1" -Rollback %*
