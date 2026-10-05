@echo off
chcp 65001 >nul
title Disk Cleanup Toolkit — Setup Shortcut
echo.
echo  กำลังสร้าง Desktop Shortcut พร้อมไอคอน...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0CreateShortcut.ps1"
echo.
pause
