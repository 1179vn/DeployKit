@echo off
rem DeployKit - nhap dup de quay lai ban truoc (chi doi khe, vai giay). Them: -To 2026.11.06
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy.ps1" -Rollback %*
