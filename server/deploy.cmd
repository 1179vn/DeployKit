@echo off
rem DeployKit - nhap dup de cai goi moi nhat trong <Root>\incoming\ (tu xin quyen Administrator). Them: -Package <zip>
rem PSModulePath ke thua tu PowerShell 7 lam Windows PowerShell nap sai module - xoa de dung mac dinh
set "PSModulePath="
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy.ps1" %*
