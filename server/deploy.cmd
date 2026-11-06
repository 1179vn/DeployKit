@echo off
rem DeployKit - nhap dup de cai ban moi nhat tu GitHub Release (tu xin quyen Administrator). Them tham so: -Version 2026.11.20 | -Package <zip>
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy.ps1" %*
