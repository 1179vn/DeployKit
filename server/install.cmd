@echo off
rem DeployKit - cai lan dau tren VPS: install.cmd -HostName ten.mien.vn  (chay tu thu muc deploy\ cua goi da giai nen)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
