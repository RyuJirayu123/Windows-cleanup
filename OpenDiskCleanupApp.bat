@echo off
chcp 65001 >nul
:: OpenDiskCleanupApp.bat
:: ดับเบิลคลิกไฟล์นี้ได้เลย - จะขอสิทธิ์ Admin อัตโนมัติแล้วเปิดโปรแกรมให้

:: เช็คว่ามีสิทธิ์ Admin หรือยัง ถ้ายังไม่มีให้ relaunch ตัวเองแบบ Admin
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo กำลังขอสิทธิ์ Admin...
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

:: รันสคริปต์ GUI โดยไม่ต้องผ่าน security warning (bypass เฉพาะการรันครั้งนี้)
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "DiskCleanupApp.ps1"
