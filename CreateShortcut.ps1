<#
.SYNOPSIS
    CreateShortcut.ps1
    สร้าง Shortcut บน Desktop พร้อมไอคอน Custom และ Run as Administrator
    รันครั้งเดียวก็พอ — หลังจากนั้นใช้ Shortcut แทน .bat ได้เลย
#>

# ============================================================
# CONFIG
# ============================================================
$projectDir  = Split-Path -Parent $MyInvocation.MyCommand.Definition
$batFile     = Join-Path $projectDir "OpenDiskCleanupApp.bat"
$jpgSource   = Join-Path $projectDir "icon_source.jpg"
$icoFile     = Join-Path $projectDir "icon.ico"
$shortcutDst = Join-Path ([Environment]::GetFolderPath("Desktop")) "Disk Cleanup Toolkit.lnk"

# ============================================================
# STEP 1: แปลง JPG → ICO (256x256 + 64x64 + 32x32 + 16x16)
# ============================================================
Write-Host ""
Write-Host "  [1/3] แปลงไฟล์ภาพ → icon.ico ..." -ForegroundColor Cyan

Add-Type -AssemblyName System.Drawing

function ConvertTo-MultiSizeIco {
    param(
        [string]$SourcePath,
        [string]$OutputPath
    )

    $srcImg = [System.Drawing.Image]::FromFile($SourcePath)
    $sizes  = @(256, 64, 48, 32, 16)

    # สร้าง MemoryStream สำหรับแต่ละขนาด แล้วรวมเป็น ICO format ด้วยมือ
    # ICO Header: 6 bytes | Directory Entry: 16 bytes x n | PNG data per size
    $pngStreams = [System.Collections.Generic.List[byte[]]]::new()

    foreach ($sz in $sizes) {
        $bmp = New-Object System.Drawing.Bitmap($sz, $sz, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g   = [System.Drawing.Graphics]::FromImage($bmp)
        $g.InterpolationMode  = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.SmoothingMode      = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        $g.DrawImage($srcImg, 0, 0, $sz, $sz)
        $g.Dispose()

        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $pngStreams.Add($ms.ToArray())
        $ms.Dispose()
        $bmp.Dispose()
    }
    $srcImg.Dispose()

    # เขียน ICO file format ด้วยมือ
    $n = $pngStreams.Count
    $headerSize    = 6
    $dirEntrySize  = 16
    $dataOffset    = $headerSize + ($dirEntrySize * $n)

    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)

    # ICO Header (6 bytes)
    $bw.Write([uint16]0)      # Reserved
    $bw.Write([uint16]1)      # Type: 1 = ICO
    $bw.Write([uint16]$n)     # Number of images

    # Directory entries
    $offset = $dataOffset
    for ($i = 0; $i -lt $n; $i++) {
        $sz   = $sizes[$i]
        $data = $pngStreams[$i]
        $w    = if ($sz -ge 256) { 0 } else { $sz }   # 0 = 256 ใน ICO spec
        $h    = if ($sz -ge 256) { 0 } else { $sz }

        $bw.Write([byte]$w)          # Width
        $bw.Write([byte]$h)          # Height
        $bw.Write([byte]0)           # Color count
        $bw.Write([byte]0)           # Reserved
        $bw.Write([uint16]1)         # Planes
        $bw.Write([uint16]32)        # Bit count
        $bw.Write([uint32]$data.Length)
        $bw.Write([uint32]$offset)
        $offset += $data.Length
    }

    # Image data
    foreach ($data in $pngStreams) {
        $bw.Write($data)
    }

    $bw.Flush()
    [System.IO.File]::WriteAllBytes($OutputPath, $ms.ToArray())
    $bw.Dispose()
    $ms.Dispose()
}

try {
    ConvertTo-MultiSizeIco -SourcePath $jpgSource -OutputPath $icoFile
    Write-Host "  ✅ สร้าง icon.ico สำเร็จ (256/64/48/32/16 px)" -ForegroundColor Green
} catch {
    Write-Host "  ❌ แปลงไอคอนล้มเหลว: $_" -ForegroundColor Red
    Write-Host "  ใช้ไอคอน Windows Defender แทน..." -ForegroundColor Yellow
    $icoFile = "C:\Windows\System32\imageres.dll,109"
}

# ============================================================
# STEP 2: สร้าง Shortcut (.lnk)
# ============================================================
Write-Host ""
Write-Host "  [2/3] สร้าง Shortcut บน Desktop ..." -ForegroundColor Cyan

$shell     = New-Object -ComObject WScript.Shell
$shortcut  = $shell.CreateShortcut($shortcutDst)

$shortcut.TargetPath       = $batFile
$shortcut.WorkingDirectory = $projectDir
$shortcut.Description      = "Disk Cleanup Toolkit — Windows System Maintenance"
$shortcut.WindowStyle      = 7          # 7 = Minimized (ซ่อนหน้าต่าง cmd)

# ใส่ไอคอน
if ($icoFile -like "*.ico" -and (Test-Path $icoFile)) {
    $shortcut.IconLocation = "$icoFile,0"
} else {
    $shortcut.IconLocation = $icoFile   # กรณีเป็น dll,index
}

$shortcut.Save()

# ============================================================
# STEP 3: ตั้ง Run as Administrator flag ใน .lnk binary
# (Byte 0x15 bit 5 = runas flag)
# ============================================================
Write-Host ""
Write-Host "  [3/3] ตั้ง 'Run as Administrator' flag ..." -ForegroundColor Cyan

try {
    $bytes        = [System.IO.File]::ReadAllBytes($shortcutDst)
    $bytes[0x15]  = $bytes[0x15] -bor 0x20    # Set bit 5 = request admin elevation
    [System.IO.File]::WriteAllBytes($shortcutDst, $bytes)
    Write-Host "  ✅ ตั้งค่า Run as Admin สำเร็จ" -ForegroundColor Green
} catch {
    Write-Host "  ⚠️  ตั้งค่า Run as Admin ล้มเหลว: $_" -ForegroundColor Yellow
    Write-Host "  (ให้ Right-click Shortcut → Properties → Advanced → Run as administrator)" -ForegroundColor Gray
}

# ============================================================
# DONE
# ============================================================
Write-Host ""
Write-Host "  ════════════════════════════════════════" -ForegroundColor DarkGray
Write-Host "  🎉 เสร็จแล้ว! Shortcut อยู่ที่ Desktop:" -ForegroundColor Green
Write-Host "     📎 Disk Cleanup Toolkit.lnk" -ForegroundColor White
Write-Host ""
Write-Host "  ดับเบิลคลิก Shortcut บน Desktop ได้เลยครับ" -ForegroundColor Cyan
Write-Host "  ════════════════════════════════════════" -ForegroundColor DarkGray
Write-Host ""

Start-Sleep -Seconds 2
