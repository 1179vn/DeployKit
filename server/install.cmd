@echo off
rem DeployKit - cai lan dau tren VPS: install.cmd -HostName ten.mien.vn  (chay tu thu muc deploy\ cua goi da giai nen)
rem PSModulePath ke thua tu PowerShell 7 lam Windows PowerShell nap sai module - xoa de dung mac dinh
set "PSModulePath="
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
