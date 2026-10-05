<#
.SYNOPSIS
    DiskCleanupApp.ps1 — Modern WPF Dashboard สำหรับทำความสะอาดดิสก์
    ต้องรันแบบ Administrator
#>

#Requires -Version 5.1

# ============================================================
# ASSEMBLIES
# ============================================================
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

# ============================================================
# ADMIN CHECK
# ============================================================
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    [System.Windows.MessageBox]::Show(
        "กรุณาเปิดโปรแกรมแบบ `"Run as Administrator`" ก่อนครับ",
        "ต้องใช้สิทธิ์ Admin",
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Warning) | Out-Null
    exit 1
}

# ============================================================
# HELPER FUNCTIONS
# ============================================================
function Get-FolderSizeGB {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    $bytes = (Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue |
              Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
    if ($null -eq $bytes) { return 0 }
    return [math]::Round($bytes / 1GB, 2)
}

# ลบทุกอย่างภายในโฟลเดอร์ (แต่เก็บตัวโฟลเดอร์ไว้) ทีละรายการ
# ไฟล์ที่ถูกล็อกจะถูกข้ามและนับเป็น Locked แทนที่จะทำให้ทั้งโฟลเดอร์ล้มเหลว
function Remove-FolderContents {
    param([string]$Path)
    $deleted = 0; $locked = 0
    foreach ($item in Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue) {
        try {
            Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
            $deleted++
        } catch {
            if ($item.PSIsContainer) {
                # ลบไฟล์ข้างในที่ลบได้ ปล่อยไฟล์ที่ล็อกไว้
                Get-ChildItem -LiteralPath $item.FullName -Recurse -Force -File -ErrorAction SilentlyContinue | ForEach-Object {
                    try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop; $deleted++ } catch { $locked++ }
                }
            } else {
                $locked++
            }
        }
    }
    return @{ Deleted = $deleted; Locked = $locked }
}

# ล้าง Cache 1 รายการ: หยุด Service ที่ล็อกไฟล์ (ถ้ามี) → ลบ → เปิด Service คืน
function Invoke-CacheCleanup {
    param([hashtable]$Target)
    if (-not (Test-Path -LiteralPath $Target.Path)) {
        return @{ Found = $false; SavedGB = 0; Deleted = 0; Locked = 0 }
    }
    $sizeBefore = Get-FolderSizeGB $Target.Path

    $stopped = @()
    foreach ($svcName in @($Target.Services)) {
        if (-not $svcName) { continue }
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') {
            Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue
            $stopped += $svcName
        }
    }
    try {
        $r = Remove-FolderContents -Path $Target.Path
    } finally {
        foreach ($svcName in $stopped) { Start-Service -Name $svcName -ErrorAction SilentlyContinue }
    }

    $saved = [math]::Round([math]::Max(0, $sizeBefore - (Get-FolderSizeGB $Target.Path)), 2)
    return @{ Found = $true; SavedGB = $saved; Deleted = $r.Deleted; Locked = $r.Locked }
}

# อ่านรายการไดรเวอร์จาก pnputil แล้วจัดกลุ่มไดรเวอร์ที่ซ้ำกัน
# ซ้ำ = Original Name + Provider + Class เดียวกัน, เก็บตัวใหม่สุด (Version ก่อน แล้วค่อย Date)
function Get-DuplicateDrivers {
    $raw    = pnputil.exe /enum-drivers 2>&1
    $blocks = ($raw -join "`n") -split "(?=Published Name\s*:)" | Where-Object { $_ -match "Published Name" }
    $drivers = foreach ($b in $blocks) {
        $f = @{}
        foreach ($line in $b -split "`n") {
            if ($line -match '^\s*([^:]+?)\s*:\s*(.*?)\s*$') { $f[$Matches[1]] = $Matches[2] }
        }
        if (-not ($f['Published Name'] -and $f['Original Name'])) { continue }

        $date = [datetime]::MinValue; $ver = [version]'0.0'
        if ($f['Driver Version'] -match '^(\d{2}/\d{2}/\d{4})\s+(\S+)') {
            try { $date = [datetime]::ParseExact($Matches[1], "MM/dd/yyyy", $null) } catch {}
            try { $ver  = [version]$Matches[2] } catch {}
        }
        [PSCustomObject]@{
            Published = $f['Published Name']
            Original  = $f['Original Name']
            Provider  = $f['Provider Name']
            Class     = $f['Class Name']
            Version   = $ver
            Date      = $date
        }
    }
    $drivers = @($drivers)

    $groups = foreach ($g in ($drivers | Group-Object Original, Provider, Class | Where-Object { $_.Count -gt 1 })) {
        $sorted = @($g.Group | Sort-Object Version, Date -Descending)
        [PSCustomObject]@{
            Original = $sorted[0].Original
            Keep     = $sorted[0]
            Remove   = @($sorted | Select-Object -Skip 1)
        }
    }
    return [PSCustomObject]@{
        Parsed = $drivers.Count
        Raw    = @($raw).Count
        Groups = @($groups)
    }
}

function Get-DriveInfo {
    $drive = Get-PSDrive -Name C -ErrorAction SilentlyContinue
    if ($null -eq $drive) { return @{ TotalGB = 0; UsedGB = 0; FreeGB = 0; UsedPct = 0 } }
    $totalGB = [math]::Round(($drive.Used + $drive.Free) / 1GB, 1)
    $freeGB  = [math]::Round($drive.Free / 1GB, 1)
    $usedGB  = [math]::Round($drive.Used / 1GB, 1)
    $usedPct = if ($totalGB -gt 0) { [math]::Round(($usedGB / $totalGB) * 100, 0) } else { 0 }
    return @{ TotalGB = $totalGB; UsedGB = $usedGB; FreeGB = $freeGB; UsedPct = $usedPct }
}

# ============================================================
# XAML UI DEFINITION
# ============================================================
$xamlString = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="&#x1F4BF; Disk Cleanup Toolkit"
    Width="820" Height="700"
    MinWidth="720" MinHeight="600"
    WindowStartupLocation="CenterScreen"
    Background="#12121A"
    FontFamily="Segoe UI">

    <Window.Resources>
        <!-- Colors -->
        <SolidColorBrush x:Key="BgDark"       Color="#12121A"/>
        <SolidColorBrush x:Key="BgCard"       Color="#1E1E2E"/>
        <SolidColorBrush x:Key="BgCardHover"  Color="#252538"/>
        <SolidColorBrush x:Key="AccentBlue"   Color="#4CC9F0"/>
        <SolidColorBrush x:Key="AccentPurple" Color="#7C3AED"/>
        <SolidColorBrush x:Key="AccentGreen"  Color="#22C55E"/>
        <SolidColorBrush x:Key="AccentOrange" Color="#F59E0B"/>
        <SolidColorBrush x:Key="AccentRed"    Color="#EF4444"/>
        <SolidColorBrush x:Key="TextPrimary"  Color="#E2E8F0"/>
        <SolidColorBrush x:Key="TextMuted"    Color="#64748B"/>
        <SolidColorBrush x:Key="Border1"      Color="#2D2D44"/>

        <!-- Button Style: Primary -->
        <Style x:Key="BtnPrimary" TargetType="Button">
            <Setter Property="Background" Value="#4CC9F0"/>
            <Setter Property="Foreground" Value="#0F0F1A"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="FontSize"   Value="13"/>
            <Setter Property="Padding"    Value="18,10"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Cursor"     Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border"
                                Background="{TemplateBinding Background}"
                                CornerRadius="8"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#38BDF8"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#0284C7"/>
                                <Setter TargetName="border" Property="RenderTransform">
                                    <Setter.Value><ScaleTransform ScaleX="0.98" ScaleY="0.98"/></Setter.Value>
                                </Setter>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="border" Property="Background" Value="#334155"/>
                                <Setter Property="Foreground" Value="#475569"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Button Style: Danger -->
        <Style x:Key="BtnDanger" TargetType="Button" BasedOn="{StaticResource BtnPrimary}">
            <Setter Property="Background" Value="#EF4444"/>
            <Setter Property="Foreground" Value="White"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#F87171"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <!-- Button Style: Secondary -->
        <Style x:Key="BtnSecondary" TargetType="Button" BasedOn="{StaticResource BtnPrimary}">
            <Setter Property="Background" Value="#2D2D44"/>
            <Setter Property="Foreground" Value="#E2E8F0"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#3D3D5C"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <!-- Button Style: Success -->
        <Style x:Key="BtnSuccess" TargetType="Button" BasedOn="{StaticResource BtnPrimary}">
            <Setter Property="Background" Value="#16A34A"/>
            <Setter Property="Foreground" Value="White"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#22C55E"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <!-- CheckBox Style -->
        <Style TargetType="CheckBox">
            <Setter Property="Foreground"  Value="#CBD5E1"/>
            <Setter Property="FontSize"    Value="12"/>
            <Setter Property="Margin"      Value="0,4"/>
            <Setter Property="Cursor"      Value="Hand"/>
        </Style>

        <!-- Scrollbar Style (minimal) -->
        <Style TargetType="ScrollBar">
            <Setter Property="Width"      Value="6"/>
            <Setter Property="Background" Value="Transparent"/>
        </Style>
    </Window.Resources>

    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>  <!-- Header / Drive Info -->
            <RowDefinition Height="*"/>     <!-- Main content -->
            <RowDefinition Height="Auto"/>  <!-- Status bar -->
        </Grid.RowDefinitions>

        <!-- ===== ROW 0: HEADER ===== -->
        <Border Grid.Row="0" Background="#1E1E2E" BorderBrush="#2D2D44" BorderThickness="0,0,0,1" Padding="20,16">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>

                <!-- App Title -->
                <StackPanel Grid.Column="0" VerticalAlignment="Center">
                    <TextBlock Text="💿 Disk Cleanup Toolkit"
                               FontSize="18" FontWeight="Bold"
                               Foreground="#4CC9F0"/>
                    <TextBlock Text="Windows System Maintenance Tool"
                               FontSize="11" Foreground="#475569" Margin="0,2,0,0"/>
                </StackPanel>

                <!-- Drive C: Info -->
                <StackPanel Grid.Column="2" HorizontalAlignment="Right" MinWidth="260">
                    <Grid Margin="0,0,0,6">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock x:Name="txtDriveLabel" Grid.Column="0"
                                   FontSize="12" FontWeight="SemiBold" Foreground="#94A3B8"
                                   Text="ไดรฟ์ C: กำลังโหลด..."/>
                        <TextBlock x:Name="txtDrivePct" Grid.Column="1"
                                   FontSize="12" FontWeight="Bold" Foreground="#F59E0B" HorizontalAlignment="Right"
                                   Text="—%"/>
                    </Grid>
                    <Border CornerRadius="4" Background="#0F172A" Height="12">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition x:Name="driveUsedCol" Width="0*"/>
                                <ColumnDefinition x:Name="driveFreeCol" Width="100*"/>
                            </Grid.ColumnDefinitions>
                            <Border x:Name="driveProgressBar" Grid.Column="0"
                                    CornerRadius="4" Height="12" MinWidth="6">
                                <Border.Background>
                                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                                        <GradientStop Color="#4CC9F0" Offset="0"/>
                                        <GradientStop Color="#7C3AED" Offset="1"/>
                                    </LinearGradientBrush>
                                </Border.Background>
                            </Border>
                        </Grid>
                    </Border>
                    <Grid Margin="0,4,0,0">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock x:Name="txtDriveUsed" Grid.Column="0"
                                   FontSize="11" Foreground="#64748B" Text="ใช้: — GB"/>
                        <TextBlock x:Name="txtDriveFree" Grid.Column="1"
                                   FontSize="11" Foreground="#22C55E" HorizontalAlignment="Right"
                                   Text="ว่าง: — GB"/>
                    </Grid>
                </StackPanel>
            </Grid>
        </Border>

        <!-- ===== ROW 1: MAIN CONTENT ===== -->
        <Grid Grid.Row="1" Margin="0">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="300"/>    <!-- Left Panel: Controls -->
                <ColumnDefinition Width="*"/>       <!-- Right Panel: Output -->
            </Grid.ColumnDefinitions>

            <!-- LEFT PANEL -->
            <Border Grid.Column="0" Background="#1A1A28" BorderBrush="#2D2D44" BorderThickness="0,0,1,0">
                <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="16,16,10,16">
                    <StackPanel>

                        <!-- SECTION: Quick Clean -->
                        <Border Background="#1E1E2E" CornerRadius="10" Padding="16" Margin="0,0,0,12">
                            <StackPanel>
                                <StackPanel Orientation="Horizontal" Margin="0,0,0,10">
                                    <TextBlock Text="⚡" FontSize="16" VerticalAlignment="Center" Margin="0,0,8,0"/>
                                    <StackPanel>
                                        <TextBlock Text="Quick Clean" FontSize="14" FontWeight="Bold"
                                                   Foreground="#4CC9F0"/>
                                        <TextBlock Text="ล้างสิ่งที่ปลอดภัยในคลิกเดียว"
                                                   FontSize="11" Foreground="#64748B"/>
                                    </StackPanel>
                                </StackPanel>
                                <Button x:Name="btnQuickClean" Content="🚀  One-Click Quick Clean"
                                        Style="{StaticResource BtnPrimary}"
                                        HorizontalAlignment="Stretch" Margin="0,0,0,8"/>
                                <Button x:Name="btnScanAll" Content="🔍  สแกนดูพื้นที่ Cache"
                                        Style="{StaticResource BtnSecondary}"
                                        HorizontalAlignment="Stretch"/>
                            </StackPanel>
                        </Border>

                        <!-- SECTION: Cache & Temp Manager -->
                        <Border Background="#1E1E2E" CornerRadius="10" Padding="16" Margin="0,0,0,12">
                            <StackPanel>
                                <StackPanel Orientation="Horizontal" Margin="0,0,0,10">
                                    <TextBlock Text="🧹" FontSize="16" VerticalAlignment="Center" Margin="0,0,8,0"/>
                                    <StackPanel>
                                        <TextBlock Text="Cache &amp; Temp" FontSize="14" FontWeight="Bold"
                                                   Foreground="#F59E0B"/>
                                        <TextBlock Text="เลือกสิ่งที่ต้องการล้าง"
                                                   FontSize="11" Foreground="#64748B"/>
                                    </StackPanel>
                                </StackPanel>
                                <CheckBox x:Name="chkWindowsTemp"  Content="🗂  Windows Temp (%WINDIR%\Temp)" IsChecked="True"/>
                                <CheckBox x:Name="chkUserTemp"     Content="📁  User Temp (%TEMP%)" IsChecked="True"/>
                                <CheckBox x:Name="chkWinUpdate"    Content="🔄  Windows Update Download Cache" IsChecked="True"/>
                                <CheckBox x:Name="chkSteamShader"  Content="🎮  Steam Shader Cache" IsChecked="False"/>
                                <CheckBox x:Name="chkSteamDl"      Content="⬇  Steam Downloading Cache" IsChecked="False"/>
                                <CheckBox x:Name="chkSteamHtml"    Content="🌐  Steam HTML Cache" IsChecked="False"/>
                                <CheckBox x:Name="chkNvidiaCache"  Content="🟢  NVIDIA Shader Cache" IsChecked="False"/>
                                <CheckBox x:Name="chkAmdCache"     Content="🔴  AMD DirectX Cache" IsChecked="False"/>
                                <Separator Background="#2D2D44" Margin="0,10"/>
                                <Button x:Name="btnCleanSelected" Content="🧹  ล้างที่เลือก"
                                        Style="{StaticResource BtnSuccess}"
                                        HorizontalAlignment="Stretch"/>
                            </StackPanel>
                        </Border>

                        <!-- SECTION: Deep System Clean -->
                        <Border Background="#1E1E2E" CornerRadius="10" Padding="16" Margin="0,0,0,12">
                            <StackPanel>
                                <StackPanel Orientation="Horizontal" Margin="0,0,0,10">
                                    <TextBlock Text="⚙️" FontSize="16" VerticalAlignment="Center" Margin="0,0,8,0"/>
                                    <StackPanel>
                                        <TextBlock Text="Deep System Clean" FontSize="14" FontWeight="Bold"
                                                   Foreground="#A78BFA"/>
                                        <TextBlock Text="เครื่องมือขั้นสูง"
                                                   FontSize="11" Foreground="#64748B"/>
                                    </StackPanel>
                                </StackPanel>
                                <Button x:Name="btnCheckWinsxs" Content="📊  เช็ค WinSxS / Restore"
                                        Style="{StaticResource BtnSecondary}"
                                        HorizontalAlignment="Stretch" Margin="0,0,0,8"/>
                                <Button x:Name="btnCleanWinsxs" Content="🗑  ล้าง WinSxS (DISM)"
                                        Style="{StaticResource BtnSecondary}"
                                        HorizontalAlignment="Stretch" Margin="0,0,0,8"/>
                                <Button x:Name="btnCheckDriver" Content="🔌  เช็ค DriverStore"
                                        Style="{StaticResource BtnSecondary}"
                                        HorizontalAlignment="Stretch" Margin="0,0,0,8"/>
                                <Button x:Name="btnCleanDriver" Content="🗑  ลบไดรเวอร์ซ้ำ"
                                        Style="{StaticResource BtnDanger}"
                                        HorizontalAlignment="Stretch"/>
                            </StackPanel>
                        </Border>

                        <!-- SECTION: Windows.old -->
                        <Border Background="#1E1E2E" CornerRadius="10" Padding="16">
                            <StackPanel>
                                <StackPanel Orientation="Horizontal" Margin="0,0,0,10">
                                    <TextBlock Text="🗃" FontSize="16" VerticalAlignment="Center" Margin="0,0,8,0"/>
                                    <StackPanel>
                                        <TextBlock Text="Windows.old" FontSize="14" FontWeight="Bold"
                                                   Foreground="#EF4444"/>
                                        <TextBlock Text="โฟลเดอร์ Windows เวอร์ชันเก่า"
                                                   FontSize="11" Foreground="#64748B"/>
                                    </StackPanel>
                                </StackPanel>
                                <Button x:Name="btnCheckWindowsOld" Content="📊  เช็คขนาด Windows.old"
                                        Style="{StaticResource BtnSecondary}"
                                        HorizontalAlignment="Stretch" Margin="0,0,0,8"/>
                                <Button x:Name="btnCleanWindowsOld" Content="🗑  ลบ Windows.old"
                                        Style="{StaticResource BtnDanger}"
                                        HorizontalAlignment="Stretch"/>
                            </StackPanel>
                        </Border>

                    </StackPanel>
                </ScrollViewer>
            </Border>

            <!-- RIGHT PANEL: Output Terminal -->
            <Grid Grid.Column="1">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                </Grid.RowDefinitions>

                <!-- Terminal Toolbar -->
                <Border Grid.Row="0" Background="#161622" Padding="12,8" BorderBrush="#2D2D44" BorderThickness="0,0,0,1">
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                            <Ellipse Width="10" Height="10" Fill="#EF4444" Margin="0,0,6,0"/>
                            <Ellipse Width="10" Height="10" Fill="#F59E0B" Margin="0,0,6,0"/>
                            <Ellipse Width="10" Height="10" Fill="#22C55E" Margin="0,0,12,0"/>
                            <TextBlock Text="Output Console" FontSize="12" FontWeight="SemiBold"
                                       Foreground="#64748B" VerticalAlignment="Center"/>
                        </StackPanel>
                        <StackPanel Grid.Column="1" Orientation="Horizontal">
                            <Button x:Name="btnCopyLog" Content="📋 Copy"
                                    Style="{StaticResource BtnSecondary}"
                                    Padding="10,6" Margin="0,0,6,0"/>
                            <Button x:Name="btnClearLog" Content="✕ Clear"
                                    Style="{StaticResource BtnSecondary}"
                                    Padding="10,6"/>
                        </StackPanel>
                    </Grid>
                </Border>

                <!-- Terminal Output Box -->
                <Border Grid.Row="1" Background="#0D0D17">
                    <RichTextBox x:Name="outputBox"
                                 Background="Transparent"
                                 Foreground="#94A3B8"
                                 BorderThickness="0"
                                 Padding="16,12"
                                 IsReadOnly="True"
                                 VerticalScrollBarVisibility="Auto"
                                 FontFamily="Cascadia Code, Consolas, Courier New"
                                 FontSize="12.5"/>
                </Border>
            </Grid>
        </Grid>

        <!-- ===== ROW 2: STATUS BAR ===== -->
        <Border Grid.Row="2" Background="#1E1E2E" BorderBrush="#2D2D44" BorderThickness="0,1,0,0" Padding="20,8">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>

                <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
                    <Ellipse x:Name="statusDot" Width="8" Height="8" Fill="#22C55E" Margin="0,0,8,0"/>
                    <TextBlock x:Name="txtStatus" Text="พร้อมใช้งาน"
                               FontSize="12" Foreground="#94A3B8" VerticalAlignment="Center"/>
                </StackPanel>

                <ProgressBar x:Name="progressBar" Grid.Column="1"
                             Margin="20,0" Height="4" Minimum="0" Maximum="100" Value="0"
                             Visibility="Collapsed"
                             Foreground="#4CC9F0"/>

                <Button x:Name="btnClose" Grid.Column="2"
                        Content="  ปิดโปรแกรม"
                        Style="{StaticResource BtnSecondary}"
                        Padding="14,6"/>
            </Grid>
        </Border>
    </Grid>
</Window>
'@

# ============================================================
# LOAD WINDOW
# ============================================================
try {
    $window = [System.Windows.Markup.XamlReader]::Parse($xamlString)
} catch {
    [System.Windows.Forms.MessageBox]::Show("ไม่สามารถโหลด UI ได้:`n$_", "Error", "OK", "Error") | Out-Null
    exit 1
}

# ============================================================
# FIND CONTROLS
# ============================================================
$outputBox          = $window.FindName("outputBox")
$txtStatus          = $window.FindName("txtStatus")
$statusDot          = $window.FindName("statusDot")
$progressBar        = $window.FindName("progressBar")
$driveUsedCol       = $window.FindName("driveUsedCol")
$driveFreeCol       = $window.FindName("driveFreeCol")
$txtDriveLabel      = $window.FindName("txtDriveLabel")
$txtDrivePct        = $window.FindName("txtDrivePct")
$txtDriveUsed       = $window.FindName("txtDriveUsed")
$txtDriveFree       = $window.FindName("txtDriveFree")

# Buttons
$btnQuickClean      = $window.FindName("btnQuickClean")
$btnScanAll         = $window.FindName("btnScanAll")
$btnCleanSelected   = $window.FindName("btnCleanSelected")
$btnCheckWinsxs     = $window.FindName("btnCheckWinsxs")
$btnCleanWinsxs     = $window.FindName("btnCleanWinsxs")
$btnCheckDriver     = $window.FindName("btnCheckDriver")
$btnCleanDriver     = $window.FindName("btnCleanDriver")
$btnCheckWindowsOld = $window.FindName("btnCheckWindowsOld")
$btnCleanWindowsOld = $window.FindName("btnCleanWindowsOld")
$btnCopyLog         = $window.FindName("btnCopyLog")
$btnClearLog        = $window.FindName("btnClearLog")
$btnClose           = $window.FindName("btnClose")

# Checkboxes
$chkWindowsTemp     = $window.FindName("chkWindowsTemp")
$chkUserTemp        = $window.FindName("chkUserTemp")
$chkWinUpdate       = $window.FindName("chkWinUpdate")
$chkSteamShader     = $window.FindName("chkSteamShader")
$chkSteamDl         = $window.FindName("chkSteamDl")
$chkSteamHtml       = $window.FindName("chkSteamHtml")
$chkNvidiaCache     = $window.FindName("chkNvidiaCache")
$chkAmdCache        = $window.FindName("chkAmdCache")

# ============================================================
# UI HELPER FUNCTIONS
# ============================================================
function Set-Status {
    param([string]$Text, [string]$Color = "Green", [bool]$Working = $false)
    $window.Dispatcher.Invoke({
        $txtStatus.Text = $Text
        $statusDot.Fill = [System.Windows.Media.Brushes]::$Color
        $progressBar.Visibility = if ($Working) { "Visible" } else { "Collapsed" }
        $progressBar.IsIndeterminate = $Working
    })
}

function Write-Log {
    param([string]$Text, [string]$Color = "#94A3B8")
    $window.Dispatcher.Invoke({
        $para = New-Object System.Windows.Documents.Paragraph
        $para.Margin = New-Object System.Windows.Thickness(0)
        $run = New-Object System.Windows.Documents.Run($Text)
        try { $run.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($Color) } catch {}
        $para.Inlines.Add($run)
        $outputBox.Document.Blocks.Add($para)
        $outputBox.ScrollToEnd()
    })
    [System.Windows.Forms.Application]::DoEvents()
}

function Set-ProgressPercent {
    param([double]$Percent)
    $window.Dispatcher.Invoke({
        $progressBar.IsIndeterminate = $false
        $progressBar.Value = $Percent
    })
}

# รันโปรแกรมภายนอก (เช่น DISM) แบบไม่ทำให้หน้าต่างค้าง
# - แสดง output ทีละบรรทัดทันทีที่ได้รับ
# - บรรทัด progress ของ DISM "[=== 42.0% ===]" จะแสดงที่ progress bar แทนการพิมพ์ซ้ำ ๆ ใน Log
function Invoke-LiveCommand {
    param(
        [string]$FilePath,
        [string]$Arguments,
        [scriptblock]$ColorOf = { "#94A3B8" }
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $FilePath
    $psi.Arguments              = $Arguments
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.StandardOutputEncoding = [Console]::OutputEncoding
    $psi.StandardErrorEncoding  = [Console]::OutputEncoding

    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        Write-Log "❌ เริ่ม $FilePath ไม่สำเร็จ: $_" "#EF4444"
        return -1
    }

    $errTask  = $proc.StandardError.ReadToEndAsync()
    $lineTask = $proc.StandardOutput.ReadLineAsync()
    while ($true) {
        if (-not $lineTask.Wait(50)) {
            [System.Windows.Forms.Application]::DoEvents()
            continue
        }
        $line = $lineTask.Result
        if ($null -eq $line) { break }
        $lineTask = $proc.StandardOutput.ReadLineAsync()

        if ($line -match '^\s*\[[=\s]*(\d+(?:\.\d+)?)%[=\s]*\]\s*$') {
            Set-ProgressPercent ([double]$Matches[1])
            [System.Windows.Forms.Application]::DoEvents()
        } elseif ($line.Trim()) {
            Write-Log $line (& $ColorOf $line)
        }
    }
    $proc.WaitForExit()
    foreach ($line in ($errTask.Result -split "`r?`n" | Where-Object { $_.Trim() })) {
        Write-Log $line "#EF4444"
    }
    $code = $proc.ExitCode
    $proc.Dispose()
    return $code
}

function Write-LogSection {
    param([string]$Title)
    Write-Log ""
    Write-Log "━━━  $Title  ━━━" "#4CC9F0"
}

function Clear-Log {
    $window.Dispatcher.Invoke({
        $outputBox.Document.Blocks.Clear()
    })
}

function Set-AllButtons {
    param([bool]$Enabled)
    $script:isBusy = -not $Enabled
    $window.Dispatcher.Invoke({
        foreach ($btn in @($btnQuickClean,$btnScanAll,$btnCleanSelected,$btnCheckWinsxs,
                           $btnCleanWinsxs,$btnCheckDriver,$btnCleanDriver,
                           $btnCheckWindowsOld,$btnCleanWindowsOld)) {
            $btn.IsEnabled = $Enabled
        }
    })
}

# ============================================================
# DRIVE INFO UPDATE
# ============================================================
function Update-DriveInfo {
    $info = Get-DriveInfo
    $window.Dispatcher.Invoke({
        $txtDriveLabel.Text = "ไดรฟ์ C:  ($($info.TotalGB) GB รวม)"
        $txtDrivePct.Text   = "$($info.UsedPct)%"
        $txtDriveUsed.Text  = "ใช้: $($info.UsedGB) GB"
        $txtDriveFree.Text  = "ว่าง: $($info.FreeGB) GB"

        # Set progress bar color: red if >85%
        if ($info.UsedPct -gt 85) {
            $txtDrivePct.Foreground = [System.Windows.Media.Brushes]::OrangeRed
        } elseif ($info.UsedPct -gt 70) {
            $txtDrivePct.Foreground = [System.Windows.Media.Brushes]::Orange
        } else {
            $txtDrivePct.Foreground = [System.Windows.Media.Brushes]::Gold
        }

        # แบ่งสัดส่วนคอลัมน์ used/free แบบ star — ปรับตามความกว้างจริงของแถบอัตโนมัติ
        $driveUsedCol.Width = New-Object System.Windows.GridLength($info.UsedPct, 'Star')
        $driveFreeCol.Width = New-Object System.Windows.GridLength((100 - $info.UsedPct), 'Star')
    })
}

# ============================================================
# CLEAN TARGETS MAP
# ============================================================
$allCacheTargets = @(
    @{ Name = "Steam Shader Cache";   Path = "C:\Program Files (x86)\Steam\steamapps\shadercache"; Chk = $chkSteamShader }
    @{ Name = "Steam Download Cache"; Path = "C:\Program Files (x86)\Steam\steamapps\downloading"; Chk = $chkSteamDl }
    @{ Name = "Steam HTML Cache";     Path = "$env:LOCALAPPDATA\Steam\htmlcache";                  Chk = $chkSteamHtml }
    @{ Name = "NVIDIA Shader Cache";  Path = "C:\ProgramData\NVIDIA Corporation\NV_Cache";         Chk = $chkNvidiaCache }
    @{ Name = "AMD DirectX Cache";    Path = "C:\ProgramData\AMD\DxCache";                         Chk = $chkAmdCache }
    @{ Name = "Windows Temp";         Path = "$env:WINDIR\Temp";                                   Chk = $chkWindowsTemp }
    @{ Name = "User Temp";            Path = "$env:TEMP";                                          Chk = $chkUserTemp }
    @{ Name = "Windows Update Cache"; Path = "$env:WINDIR\SoftwareDistribution\Download";          Chk = $chkWinUpdate; Services = @("wuauserv", "bits") }
)

function Write-CleanupResult {
    param([string]$Name, [hashtable]$Result)
    if (-not $Result.Found) {
        Write-Log "⏭  ข้ามไป (ไม่พบโฟลเดอร์): $Name" "#334155"
    } elseif ($Result.Locked -gt 0) {
        Write-Log "⚠️  $Name — ประหยัดได้ $($Result.SavedGB) GB (ข้ามไฟล์ที่ถูกใช้งานอยู่ $($Result.Locked) ไฟล์)" "#F59E0B"
    } else {
        Write-Log "✅ $Name — ประหยัดได้ $($Result.SavedGB) GB" "#22C55E"
    }
}

$scanOnlyTargets = @(
    @{ Name = "Steam Shader Cache";   Path = "C:\Program Files (x86)\Steam\steamapps\shadercache" }
    @{ Name = "Steam Download Cache"; Path = "C:\Program Files (x86)\Steam\steamapps\downloading" }
    @{ Name = "Steam HTML Cache";     Path = "$env:LOCALAPPDATA\Steam\htmlcache" }
    @{ Name = "NVIDIA Shader Cache";  Path = "C:\ProgramData\NVIDIA Corporation\NV_Cache" }
    @{ Name = "AMD DirectX Cache";    Path = "C:\ProgramData\AMD\DxCache" }
    @{ Name = "Windows Temp";         Path = "$env:WINDIR\Temp" }
    @{ Name = "User Temp";            Path = "$env:TEMP" }
    @{ Name = "Windows Update Cache"; Path = "$env:WINDIR\SoftwareDistribution\Download" }
    @{ Name = "Windows.old";          Path = "C:\Windows.old" }
)

# ============================================================
# ACTION: Scan All
# ============================================================
$btnScanAll.Add_Click({
    Set-AllButtons $false
    Set-Status "กำลังสแกน..." "Orange" $true
    Clear-Log
    Write-LogSection "สแกนพื้นที่ Cache ทั้งหมด"
    Write-Log ("{0,-30} {1,8}" -f "ชื่อ Cache", "ขนาด (GB)") "#64748B"
    Write-Log ("{0}" -f ("─" * 42)) "#334155"

    $total = 0
    foreach ($t in $scanOnlyTargets) {
        $size = Get-FolderSizeGB -Path $t.Path
        $total += $size
        if ($size -gt 1)       { $col = "#EF4444" }
        elseif ($size -gt 0.1) { $col = "#F59E0B" }
        elseif ($size -gt 0)   { $col = "#22C55E" }
        else                    { $col = "#334155" }
        Write-Log ("{0,-30} {1,8} GB" -f $t.Name, $size) $col
    }
    Write-Log ("{0}" -f ("─" * 42)) "#334155"
    Write-Log ("{0,-30} {1,8} GB" -f "รวมทั้งหมด", ([math]::Round($total, 2))) "#4CC9F0"
    Write-Log ""
    Write-Log "✅ สแกนเสร็จแล้ว — กดปุ่ม 'ล้างที่เลือก' เพื่อล้าง Cache ที่ต้องการ" "#22C55E"

    Set-AllButtons $true
    Set-Status "สแกนเสร็จแล้ว" "Green" $false
    Update-DriveInfo
})

# ============================================================
# ACTION: Clean Selected
# ============================================================
$btnCleanSelected.Add_Click({
    $selected = @($allCacheTargets | Where-Object { $_.Chk.IsChecked -eq $true })
    if ($selected.Count -eq 0) {
        [System.Windows.MessageBox]::Show("กรุณาเลือกอย่างน้อย 1 รายการก่อนครับ", "แจ้งเตือน",
            [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
        return
    }
    $names = ($selected | ForEach-Object { "• $($_.Name)" }) -join "`n"
    $confirm = [System.Windows.MessageBox]::Show(
        "จะลบรายการต่อไปนี้:`n$names`n`nต้องการดำเนินการต่อไหม?",
        "ยืนยันการล้าง",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question)
    if ($confirm -ne "Yes") { return }

    Set-AllButtons $false
    Set-Status "กำลังล้าง Cache..." "Orange" $true
    Clear-Log
    Write-LogSection "ล้าง Cache ที่เลือก"

    $totalSaved = 0.0; $totalLocked = 0
    foreach ($t in $selected) {
        Set-Status "กำลังล้าง $($t.Name)..." "Orange" $true
        $r = Invoke-CacheCleanup -Target $t
        Write-CleanupResult -Name $t.Name -Result $r
        $totalSaved  += $r.SavedGB
        $totalLocked += $r.Locked
    }
    Write-Log ""
    Write-Log "📋 สรุป: ประหยัดพื้นที่รวม ~$([math]::Round($totalSaved, 2)) GB" "#4CC9F0"
    if ($totalLocked -gt 0) {
        Write-Log "💡 มี $totalLocked ไฟล์ที่ถูกโปรแกรมอื่นใช้งานอยู่ — ปิดโปรแกรมหรือรีสตาร์ทแล้วลองใหม่" "#94A3B8"
    }

    Set-AllButtons $true
    Set-Status "ล้าง Cache เสร็จแล้ว" "Green" $false
    Update-DriveInfo
})

# ============================================================
# ACTION: Quick Clean (ปลอดภัย 100%)
# ============================================================
$btnQuickClean.Add_Click({
    $confirm = [System.Windows.MessageBox]::Show(
        "จะล้าง Windows Temp, User Temp และ Windows Update Download Cache ทันที`n`nต้องการดำเนินการต่อไหม?",
        "Quick Clean",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question)
    if ($confirm -ne "Yes") { return }

    Set-AllButtons $false
    Set-Status "Quick Clean กำลังทำงาน..." "Orange" $true
    Clear-Log
    Write-LogSection "⚡ Quick Clean"
    Write-Log "ล้างไฟล์ Temp และ Cache ที่ปลอดภัยทั้งหมด..." "#94A3B8"

    $quickPaths = @(
        @{ Name = "Windows Temp"; Path = "$env:WINDIR\Temp" }
        @{ Name = "User Temp";    Path = "$env:TEMP" }
        @{ Name = "Update Cache"; Path = "$env:WINDIR\SoftwareDistribution\Download"; Services = @("wuauserv", "bits") }
    )
    $totalSaved = 0.0
    foreach ($t in $quickPaths) {
        $r = Invoke-CacheCleanup -Target $t
        Write-CleanupResult -Name $t.Name -Result $r
        $totalSaved += $r.SavedGB
    }
    Write-Log ""
    Write-Log "🎉 Quick Clean เสร็จสิ้น! ประหยัดพื้นที่รวม ~$([math]::Round($totalSaved,2)) GB" "#4CC9F0"

    Set-AllButtons $true
    Set-Status "Quick Clean เสร็จแล้ว" "Green" $false
    Update-DriveInfo
})

# ============================================================
# ACTION: Check WinSxS / Restore
# ============================================================
$btnCheckWinsxs.Add_Click({
    Set-AllButtons $false
    Set-Status "กำลังวิเคราะห์ WinSxS... (อาจใช้เวลาสักครู่)" "Orange" $true
    Clear-Log
    Write-LogSection "WinSxS Component Store Analysis"
    Write-Log "กำลังรัน DISM /AnalyzeComponentStore..." "#64748B"

    [void](Invoke-LiveCommand "dism.exe" "/online /Cleanup-Image /AnalyzeComponentStore" -ColorOf {
        param($line)
        if ($line -match "ข้อผิดพลาด|Error") { "#EF4444" }
        elseif ($line -match "Recommended\s*:\s*Yes|แนะนำ.*:\s*ใช่") { "#F59E0B" }
        else { "#94A3B8" }
    })

    Write-LogSection "System Restore (Shadow Copy)"
    Set-Status "กำลังเช็ค Shadow Copy..." "Orange" $true
    [void](Invoke-LiveCommand "vssadmin.exe" "list shadowstorage")

    Write-LogSection "Windows Installer Cache"
    $installerGB = Get-FolderSizeGB "C:\Windows\Installer"
    Write-Log "C:\Windows\Installer: $installerGB GB" "#F59E0B"

    Set-AllButtons $true
    Set-Status "วิเคราะห์เสร็จแล้ว" "Green" $false
})

# ============================================================
# ACTION: Clean WinSxS (DISM)
# ============================================================
$btnCleanWinsxs.Add_Click({
    $confirm = [System.Windows.MessageBox]::Show(
        "จะรัน DISM StartComponentCleanup เพื่อลด WinSxS`nอาจใช้เวลา 5-15 นาที`n`nต้องการดำเนินการต่อไหม?",
        "ยืนยัน DISM Cleanup",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning)
    if ($confirm -ne "Yes") { return }

    Set-AllButtons $false
    Set-Status "กำลังล้าง WinSxS... (กรุณารอสักครู่)" "Orange" $true
    Clear-Log
    Write-LogSection "DISM StartComponentCleanup"
    Write-Log "กำลังรัน DISM... กรุณารอ ห้ามปิดโปรแกรม" "#F59E0B"

    $exitCode = Invoke-LiveCommand "dism.exe" "/online /Cleanup-Image /StartComponentCleanup" -ColorOf {
        param($line)
        if ($line -match "ข้อผิดพลาด|Error") { "#EF4444" }
        elseif ($line -match "สำเร็จ|success") { "#22C55E" }
        else { "#94A3B8" }
    }
    Write-Log ""
    if ($exitCode -eq 0) {
        Write-Log "✅ DISM Cleanup เสร็จสิ้น" "#22C55E"
        Set-Status "ล้าง WinSxS เสร็จแล้ว" "Green" $false
    } else {
        Write-Log "❌ DISM จบการทำงานด้วยรหัส $exitCode — ดูรายละเอียดใน C:\Windows\Logs\DISM\dism.log" "#EF4444"
        Set-Status "DISM ล้มเหลว (รหัส $exitCode)" "Red" $false
    }

    Set-AllButtons $true
    Update-DriveInfo
})

# ============================================================
# ACTION: Check DriverStore
# ============================================================
$btnCheckDriver.Add_Click({
    Set-AllButtons $false
    Set-Status "กำลังเช็ค DriverStore..." "Orange" $true
    Clear-Log
    Write-LogSection "DriverStore Analysis"

    $storeGB = Get-FolderSizeGB "C:\Windows\System32\DriverStore\FileRepository"
    Write-Log "ขนาด DriverStore รวม: $storeGB GB" "#F59E0B"

    Write-Log "" 
    Write-Log "กำลังวิเคราะห์ไดรเวอร์ซ้ำ..." "#64748B"
    $dup = Get-DuplicateDrivers
    if ($dup.Parsed -eq 0 -and $dup.Raw -gt 5) {
        Write-Log "⚠️  อ่าน output ของ pnputil ไม่ได้ (Windows ภาษานี้อาจยังไม่รองรับ)" "#F59E0B"
    } elseif ($dup.Groups.Count -eq 0) {
        Write-Log "✅ ไม่พบไดรเวอร์ซ้ำ" "#22C55E"
    } else {
        Write-Log "⚠️  พบไดรเวอร์ซ้ำ $($dup.Groups.Count) กลุ่ม สามารถกด 'ลบไดรเวอร์ซ้ำ' เพื่อล้าง" "#F59E0B"
        foreach ($g in $dup.Groups) {
            Write-Log "  • $($g.Original): เก็บ v$($g.Keep.Version) ($($g.Keep.Published)), ลบได้ $($g.Remove.Count) เวอร์ชันเก่า" "#94A3B8"
        }
    }

    Set-AllButtons $true
    Set-Status "เช็ค DriverStore เสร็จแล้ว" "Green" $false
})

# ============================================================
# ACTION: Clean Duplicate Drivers
# ============================================================
$btnCleanDriver.Add_Click({
    Set-AllButtons $false
    Set-Status "กำลังวิเคราะห์ไดรเวอร์..." "Orange" $true
    Clear-Log
    Write-LogSection "ลบไดรเวอร์เก่าที่ซ้ำกัน"

    $dup = Get-DuplicateDrivers
    if ($dup.Groups.Count -eq 0) {
        Write-Log "✅ ไม่พบไดรเวอร์ซ้ำ ไม่มีอะไรให้ลบ" "#22C55E"
        Set-AllButtons $true
        Set-Status "ไม่มีไดรเวอร์ซ้ำ" "Green" $false
        return
    }

    $toDelete = @($dup.Groups | ForEach-Object { $_.Remove })
    Write-Log "พบไดรเวอร์เก่าซ้ำ $($toDelete.Count) ตัวที่สามารถลบได้" "#F59E0B"
    foreach ($d in $toDelete) {
        Write-Log "  • $($d.Published)  $($d.Original)  v$($d.Version)" "#94A3B8"
    }

    $confirm = [System.Windows.MessageBox]::Show(
        "พบไดรเวอร์เก่าซ้ำ $($toDelete.Count) ตัว`nต้องการลบเลยไหม?`n`nไดรเวอร์ที่อุปกรณ์ยังใช้งานอยู่จะถูกข้ามโดยอัตโนมัติ`n⚠️  แนะนำให้สร้าง Restore Point ก่อนหากไม่แน่ใจ",
        "ยืนยันการลบไดรเวอร์",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning)
    if ($confirm -ne "Yes") {
        Set-AllButtons $true
        Set-Status "ยกเลิกแล้ว" "Green" $false
        return
    }

    # ไม่ใช้ /uninstall /force — pnputil จะปฏิเสธการลบไดรเวอร์ที่อุปกรณ์ยังใช้อยู่เอง
    $ok = 0; $skipped = 0
    foreach ($d in $toDelete) {
        $out = pnputil.exe /delete-driver $d.Published 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Log "✅ ลบแล้ว: $($d.Published) ($($d.Original) v$($d.Version))" "#22C55E"
            $ok++
        } else {
            $reason = ($out | Where-Object { "$_".Trim() } | Select-Object -Last 1)
            Write-Log "⏭  เก็บไว้: $($d.Published) — $reason" "#64748B"
            $skipped++
        }
    }
    Write-Log ""
    Write-Log "📋 สรุป: ลบแล้ว $ok  |  ข้าม (ยังใช้งานอยู่) $skipped" "#4CC9F0"
    Write-Log "💡 แนะนำให้รีสตาร์ทเครื่องหลังจากลบไดรเวอร์" "#F59E0B"

    Set-AllButtons $true
    Set-Status "ลบไดรเวอร์เสร็จแล้ว — กรุณา Restart เครื่อง" "Green" $false
    Update-DriveInfo
})

# ============================================================
# ACTION: Check Windows.old
# ============================================================
$btnCheckWindowsOld.Add_Click({
    Clear-Log
    Write-LogSection "เช็ค Windows.old"
    $path = "C:\Windows.old"
    if (Test-Path $path) {
        $size = Get-FolderSizeGB $path
        $col  = if ($size -gt 5) { "#EF4444" } elseif ($size -gt 1) { "#F59E0B" } else { "#22C55E" }
        Write-Log "พบ Windows.old: $size GB" $col
        Write-Log "📌 สามารถลบได้หากไม่ต้องการ Roll Back ไป Windows เวอร์ชันเก่า" "#94A3B8"
    } else {
        Write-Log "✅ ไม่พบ Windows.old — ไม่มีอะไรต้องทำ" "#22C55E"
    }
    Set-Status "เช็คเสร็จแล้ว" "Green" $false
})

# ============================================================
# ACTION: Delete Windows.old
# ============================================================
$btnCleanWindowsOld.Add_Click({
    $path = "C:\Windows.old"
    if (-not (Test-Path $path)) {
        [System.Windows.MessageBox]::Show("ไม่พบโฟลเดอร์ Windows.old บนเครื่องนี้", "แจ้งเตือน",
            [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
        return
    }
    $size = Get-FolderSizeGB $path
    $confirm = [System.Windows.MessageBox]::Show(
        "⚠️  จะลบ Windows.old ($size GB) ถาวร`n`nหลังลบแล้วจะไม่สามารถ Rollback ไปเวอร์ชัน Windows เก่าได้`n`nต้องการลบไหม?",
        "⚠️  ยืนยันการลบ Windows.old",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning)
    if ($confirm -ne "Yes") { return }

    Set-AllButtons $false
    Set-Status "กำลังลบ Windows.old..." "Orange" $true
    Clear-Log
    Write-LogSection "ลบ Windows.old"

    # ใช้ takeown + icacls เพื่อ grant permission ก่อนลบ
    Write-Log "กำลัง takeown + grant permission..." "#64748B"
    takeown /F $path /R /D Y 2>&1 | Out-Null
    icacls $path /grant Administrators:F /T /C 2>&1 | Out-Null

    Write-Log "กำลังลบไฟล์... (อาจใช้เวลาหลายนาที)" "#64748B"
    Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue

    if (-not (Test-Path -LiteralPath $path)) {
        Write-Log "✅ ลบ Windows.old เสร็จสิ้น — ประหยัดได้ ~$size GB" "#22C55E"
    } else {
        $left = Get-FolderSizeGB $path
        Write-Log "⚠️  ลบได้บางส่วน — ยังเหลืออยู่ $left GB (ประหยัดได้ ~$([math]::Round($size - $left, 2)) GB)" "#F59E0B"
        Write-Log "💡 ลองใช้ Disk Cleanup (cleanmgr) เพื่อลบ Previous Windows Installation แทน" "#94A3B8"
    }

    Set-AllButtons $true
    Set-Status "ลบ Windows.old เสร็จแล้ว" "Green" $false
    Update-DriveInfo
})

# ============================================================
# ACTION: Copy Log
# ============================================================
$btnCopyLog.Add_Click({
    $text = New-Object System.Windows.Documents.TextRange(
        $outputBox.Document.ContentStart,
        $outputBox.Document.ContentEnd)
    if ($text.Text.Trim() -ne "") {
        [System.Windows.Clipboard]::SetText($text.Text)
        Set-Status "คัดลอก Log แล้ว" "Green" $false
    }
})

# ============================================================
# ACTION: Clear Log
# ============================================================
$btnClearLog.Add_Click({ Clear-Log })

# ============================================================
# ACTION: Close
# ============================================================
$btnClose.Add_Click({ $window.Close() })

# กันการปิดหน้าต่างระหว่างที่ DISM / การลบไฟล์กำลังทำงาน
$script:isBusy = $false
$window.Add_Closing({
    param($s, $e)
    if ($script:isBusy) {
        $e.Cancel = $true
        [System.Windows.MessageBox]::Show(
            "กำลังทำงานอยู่ กรุณารอให้เสร็จก่อนปิดโปรแกรม",
            "กรุณารอสักครู่",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information) | Out-Null
    }
})

# ============================================================
# WELCOME MESSAGE
# ============================================================
Write-Log "╔══════════════════════════════════════════════════╗" "#2D2D44"
Write-Log "║   💿  Disk Cleanup Toolkit  — ยินดีต้อนรับ!      ║" "#4CC9F0"
Write-Log "╠══════════════════════════════════════════════════╣" "#2D2D44"
Write-Log "║  วิธีใช้งาน:                                     ║" "#64748B"
Write-Log "║  ⚡ Quick Clean → ล้างแบบเร็ว ปลอดภัย 1 คลิก    ║" "#94A3B8"
Write-Log "║  🧹 Cache & Temp → เลือก Checkbox แล้วกดล้าง    ║" "#94A3B8"
Write-Log "║  ⚙️  Deep Clean → สำหรับผู้ใช้ขั้นสูง            ║" "#94A3B8"
Write-Log "╚══════════════════════════════════════════════════╝" "#2D2D44"
Write-Log ""
Write-Log "💡 แนะนำ: กด 'สแกนดูพื้นที่ Cache' ก่อนเพื่อดูขนาดแต่ละรายการ" "#F59E0B"

# ============================================================
# SHOW WINDOW
# ============================================================
Update-DriveInfo
[void]$window.ShowDialog()
