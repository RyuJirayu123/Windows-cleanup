# 💿 Disk Cleanup Toolkit

<div align="center">

![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?style=for-the-badge&logo=powershell&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-10%2F11-0078D4?style=for-the-badge&logo=windows&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-green?style=for-the-badge)
![Admin Required](https://img.shields.io/badge/Requires-Admin-red?style=for-the-badge&logo=windows)

**เครื่องมือทำความสะอาดดิสก์ Windows แบบครบวงจร ดีไซน์ Modern Dark Dashboard**

[🇹🇭 ภาษาไทย](#-ภาษาไทย) · [🇬🇧 English](#-english)

</div>

---

## 🇹🇭 ภาษาไทย

### ✨ คุณสมบัติหลัก

- 🎨 **Modern Dark UI** — ออกแบบด้วย WPF ธีมมืดสไตล์ Windows 11 Fluent Design สวยงามและอ่านง่าย
- 📊 **Drive Status Bar** — แสดงพื้นที่ใช้งาน/ว่างของไดรฟ์ C: แบบ Real-time พร้อม Progress Bar
- ⚡ **Quick Clean** — ล้างไฟล์ขยะที่ปลอดภัย (Temp + Windows Update Cache) ในคลิกเดียว
- 🧹 **Custom Cache Manager** — เลือก Checkbox ได้ว่าต้องการล้างอะไร: Temp, Steam Cache, GPU Shader Cache ฯลฯ
- ⚙️ **Deep System Clean** — เครื่องมือขั้นสูง: วิเคราะห์และล้าง WinSxS ด้วย DISM, ลบไดรเวอร์เก่าซ้ำซ้อน
- 🗃️ **Windows.old Remover** — ตรวจและลบโฟลเดอร์ Windows เวอร์ชันเก่าอย่างปลอดภัย
- 🖥️ **Dark Terminal Output** — กล่อง Log แสดงผลสวยงาม พร้อมปุ่ม Copy และ Clear

### 🛡️ ความปลอดภัย

| รายการที่ล้าง | ความปลอดภัย | คำอธิบาย |
|---|---|---|
| Windows Temp `%WINDIR%\Temp` | ✅ ปลอดภัยมาก | ไฟล์ชั่วคราว Windows สร้างใหม่ได้ |
| User Temp `%TEMP%` | ✅ ปลอดภัยมาก | ไฟล์ชั่วคราวผู้ใช้ สร้างใหม่ได้ |
| Windows Update Cache | ✅ ปลอดภัยมาก | ไฟล์ดาวน์โหลดอัปเดต ดาวน์โหลดใหม่ได้ |
| Steam Shader/HTML Cache | ✅ ปลอดภัย | Steam สร้างใหม่โดยอัตโนมัติ (เกมอาจโหลดช้าครั้งแรก) |
| NVIDIA/AMD Shader Cache | ✅ ปลอดภัย | GPU สร้าง Cache ใหม่โดยอัตโนมัติ |
| WinSxS (DISM Cleanup) | ⚠️ ระมัดระวัง | ใช้ DISM อย่างเป็นทางการ ปลอดภัยแต่ใช้เวลานาน |
| Duplicate Drivers | ⚠️ ระมัดระวัง | ลบเฉพาะเวอร์ชันเก่า เก็บใหม่สุดไว้ |
| Windows.old | ❌ ถาวร | ลบแล้วไม่สามารถ Rollback ได้ |

### 🚀 วิธีใช้งาน

#### สำหรับผู้ใช้ทั่วไป (ง่ายมาก!)
1. ดับเบิลคลิก **`OpenDiskCleanupApp.bat`**
2. กด **"ใช่"** หรือ **"Yes"** เมื่อ Windows ถามสิทธิ์ Admin
3. กดปุ่ม **⚡ Quick Clean** เพื่อล้างแบบเร็วและปลอดภัย — เสร็จ! 🎉

#### สำหรับผู้ใช้ขั้นสูง
1. เปิดโปรแกรม → กด **"สแกนดูพื้นที่ Cache"** ดูก่อนว่ามีอะไรให้ล้างบ้าง
2. ติ๊ก Checkbox เลือกสิ่งที่ต้องการล้าง → กด **"ล้างที่เลือก"**
3. (ตัวเลือก) Deep Clean: เช็ค WinSxS → ล้าง DISM → เช็ค Driver → ลบ Driver ซ้ำ

### 📋 ความต้องการระบบ

- **OS**: Windows 10 หรือ Windows 11
- **สิทธิ์**: Administrator (ขอให้อัตโนมัติผ่าน UAC)
- **PowerShell**: เวอร์ชัน 5.1 ขึ้นไป (มาพร้อม Windows แล้ว)
- **ไม่ต้องติดตั้ง**: ไม่ต้องลงโปรแกรมเพิ่มเติมใดๆ

### 🗂️ โครงสร้างไฟล์

```
windows-cleanup-toolkit/
├── DiskCleanupApp.ps1      # สคริปต์หลัก WPF UI
├── OpenDiskCleanupApp.bat  # ตัวเปิดโปรแกรม (ดับเบิลคลิกได้เลย)
├── README.md               # คู่มือนี้
└── LICENSE                 # MIT License
```

---

## 🇬🇧 English

### ✨ Features

- 🎨 **Modern Dark UI** — WPF-based Windows 11 Fluent Design dark dashboard
- 📊 **Real-time Drive Status** — C: drive usage bar with live percentage
- ⚡ **One-Click Quick Clean** — safely clears Temp files & Update cache instantly
- 🧹 **Custom Cache Manager** — checkbox selection for Steam, GPU caches, Temp, Update
- ⚙️ **Deep System Clean** — DISM WinSxS analysis/cleanup + duplicate driver removal
- 🗃️ **Windows.old Remover** — safely detects and removes old Windows installations
- 🖥️ **Dark Terminal Output** — color-coded log with Copy & Clear buttons

### 🚀 Quick Start

1. Double-click **`OpenDiskCleanupApp.bat`**
2. Click **"Yes"** when prompted for Administrator privileges
3. Use **⚡ Quick Clean** for instant safe cleanup, or choose specific items with checkboxes

### 📋 Requirements

- **OS**: Windows 10 or Windows 11
- **Privileges**: Administrator (auto-requested via UAC)  
- **PowerShell**: 5.1+ (built-in on Windows)
- **No install needed**: zero external dependencies

### 🤝 Contributing

Pull requests are welcome! For major changes, please open an issue first to discuss what you'd like to change.

1. Fork this repository
2. Create your feature branch: `git checkout -b feature/my-feature`
3. Commit your changes: `git commit -m "Add some feature"`
4. Push to the branch: `git push origin feature/my-feature`
5. Open a Pull Request

---

## 📄 License

This project is licensed under the **MIT License** — see the [LICENSE](LICENSE) file for details.

---

<div align="center">
Made with ❤️ for Windows users who love a clean system.
</div>
# Windows-cleanup
