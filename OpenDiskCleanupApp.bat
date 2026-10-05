@echo off
chcp 65001 >nul
:: OpenDiskCleanupApp.bat
:: ดับเบิลคลิกไฟล์นี้ได้เลย - โปรแกรมจะขอสิทธิ์ Admin เอง (UAC) แล้วเปิดหน้าต่างให้
:: ใช้ start เพื่อให้หน้าต่าง cmd นี้ปิดไปทันที ไม่ค้างอยู่ระหว่างใช้งาน
:: -ExecutionPolicy Bypass มีผลเฉพาะการรันครั้งนี้เท่านั้น

start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0DiskCleanupApp.ps1"
