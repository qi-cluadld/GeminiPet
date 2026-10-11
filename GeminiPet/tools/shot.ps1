# 测试用小工具:截屏 / 模拟右键 / 左键点一下 / 拖动宠物窗口(仅用于验证)
param(
    [string]$Out = "$env:TEMP\shot.png",
    [int]$PetPid = 0,
    [string]$Title = 'Gemini Pet',
    [ValidateSet('shot', 'right', 'left', 'drag', 'menuquit')][string]$Mode = 'shot',
    [int]$DragDx = -200,
    [string]$Crop = ''
)
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -Namespace Sh -Name U -MemberDefinition @'
public delegate bool EnumProc(IntPtr h, IntPtr l);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern bool GetCursorPos(out RECT r);
[DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, IntPtr e);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int L; public int T; public int R; public int B; }
'@
[void][Sh.U]::SetProcessDPIAware()

function Find-PetWindow([int]$procId) {
    $script:found = [IntPtr]::Zero
    $cb = [Sh.U+EnumProc]{
        param($h, $l)
        $p = 0
        [void][Sh.U]::GetWindowThreadProcessId($h, [ref]$p)
        if ($p -eq $procId -and [Sh.U]::IsWindowVisible($h)) {
            $sb = New-Object System.Text.StringBuilder 256
            [void][Sh.U]::GetWindowTextW($h, $sb, 256)
            if ($sb.ToString() -eq $Title) { $script:found = $h }
        }
        return $true
    }
    [void][Sh.U]::EnumWindows($cb, [IntPtr]::Zero)
    return $script:found
}
function Get-Rect([IntPtr]$h) {
    $r = New-Object Sh.U+RECT
    [void][Sh.U]::GetWindowRect($h, [ref]$r)
    return $r
}
function Save-Crop([string]$srcPath, [string]$spec, [string]$dstPath) {
    if (-not $spec) { return }
    $img = [System.Drawing.Image]::FromFile($srcPath)
    $parts = $spec.Split(',')
    $rc = New-Object System.Drawing.Rectangle([int]$parts[0], [int]$parts[1], [int]$parts[2], [int]$parts[3])
    $bmp = New-Object System.Drawing.Bitmap($rc.Width, $rc.Height)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.DrawImage($img, (New-Object System.Drawing.Rectangle(0, 0, $rc.Width, $rc.Height)), $rc, [System.Drawing.GraphicsUnit]::Pixel)
    $g.Dispose(); $bmp.Save($dstPath, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose(); $img.Dispose()
    Write-Host "crop saved $dstPath"
}

$h = Find-PetWindow $PetPid
if ($h -eq [IntPtr]::Zero) { Write-Host 'NOT_FOUND'; exit 2 }
$r0 = Get-Rect $h
$cx = [int](($r0.L + $r0.R) / 2); $cy = [int](($r0.T + $r0.B) / 2)
Write-Host ("窗口0: L={0} T={1} R={2} B={3} 中心=({4},{5})" -f $r0.L, $r0.T, $r0.R, $r0.B, $cx, $cy)

$before = New-Object Sh.U+RECT
[void][Sh.U]::GetCursorPos([ref]$before)

switch ($Mode) {
    'right' {
        [void][Sh.U]::SetCursorPos($cx, $cy); Start-Sleep -Milliseconds 250
        [Sh.U]::mouse_event(0x0008, 0, 0, 0, [IntPtr]::Zero); Start-Sleep -Milliseconds 60
        [Sh.U]::mouse_event(0x0010, 0, 0, 0, [IntPtr]::Zero); Start-Sleep -Milliseconds 800
        $script:popup = [IntPtr]::Zero
        $cb2 = [Sh.U+EnumProc]{
            param($hh, $l)
            $p = 0
            [void][Sh.U]::GetWindowThreadProcessId($hh, [ref]$p)
            if ($p -eq $PetPid -and [Sh.U]::IsWindowVisible($hh) -and $hh -ne $h) {
                $sb = New-Object System.Text.StringBuilder 256
                [void][Sh.U]::GetWindowTextW($hh, $sb, 256)
                $r2 = New-Object Sh.U+RECT
                [void][Sh.U]::GetWindowRect($hh, [ref]$r2)
                Write-Host ("popup hwnd={0} title='{1}' L={2} T={3} R={4} B={5}" -f $hh, $sb.ToString(), $r2.L, $r2.T, $r2.R, $r2.B)
                if (($r2.R - $r2.L) -gt 60) { $script:popup = $hh }
            }
            return $true
        }
        [void][Sh.U]::EnumWindows($cb2, [IntPtr]::Zero)
    }
    'left' {
        [void][Sh.U]::SetCursorPos($cx, $cy); Start-Sleep -Milliseconds 250
        [Sh.U]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero); Start-Sleep -Milliseconds 80
        [Sh.U]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero); Start-Sleep -Milliseconds 200
    }
    'menuquit' {
        [void][Sh.U]::SetCursorPos($cx, $cy); Start-Sleep -Milliseconds 250
        [Sh.U]::mouse_event(0x0008, 0, 0, 0, [IntPtr]::Zero); Start-Sleep -Milliseconds 60
        [Sh.U]::mouse_event(0x0010, 0, 0, 0, [IntPtr]::Zero); Start-Sleep -Milliseconds 900
        # 找到右键菜单弹出的窗口(同一进程里除宠物窗之外可见的窗口)
        $script:popup = [IntPtr]::Zero
        $cb2 = [Sh.U+EnumProc]{
            param($hh, $l)
            $p = 0
            [void][Sh.U]::GetWindowThreadProcessId($hh, [ref]$p)
            if ($p -eq $PetPid -and [Sh.U]::IsWindowVisible($hh) -and $hh -ne $h) {
                $sb = New-Object System.Text.StringBuilder 256
                [void][Sh.U]::GetWindowTextW($hh, $sb, 256)
                $r2 = New-Object Sh.U+RECT
                [void][Sh.U]::GetWindowRect($hh, [ref]$r2)
                Write-Host ("popup hwnd={0} title='{1}' L={2} T={3} R={4} B={5}" -f $hh, $sb.ToString(), $r2.L, $r2.T, $r2.R, $r2.B)
                if (($r2.R - $r2.L) -gt 60) { $script:popup = $hh }
            }
            return $true
        }
        [void][Sh.U]::EnumWindows($cb2, [IntPtr]::Zero)
        if ($script:popup -ne [IntPtr]::Zero) {
            $rp = Get-Rect $script:popup
            $tx = $rp.L + 30
            $ty = $rp.B - 16
            Write-Host ("click menu item at ({0},{1})" -f $tx, $ty)
            [void][Sh.U]::SetCursorPos($tx, $ty); Start-Sleep -Milliseconds 300
            [Sh.U]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero); Start-Sleep -Milliseconds 80
            [Sh.U]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero); Start-Sleep -Milliseconds 1200
            $still = Find-PetWindow $PetPid
            if ($still -eq [IntPtr]::Zero) { Write-Host 'RESULT: 宠物窗口已关闭 (菜单项执行成功)' } else { Write-Host 'RESULT: 宠物仍在运行' }
        } else { Write-Host 'RESULT: 没找到菜单窗口' }
    }
    'drag' {
        [void][Sh.U]::SetCursorPos($cx, $cy); Start-Sleep -Milliseconds 250
        [Sh.U]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero); Start-Sleep -Milliseconds 120
        for ($i = 1; $i -le 10; $i++) {
            [void][Sh.U]::SetCursorPos($cx + [int]($DragDx * $i / 10), $cy)
            Start-Sleep -Milliseconds 60
        }
        [Sh.U]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero); Start-Sleep -Milliseconds 400
        $r1 = Get-Rect $h
        Write-Host ("窗口1: L={0} T={1} R={2} B={3}  => 实际位移 dx={4} (期望 {5})" -f $r1.L, $r1.T, $r1.R, $r1.B, ($r1.L - $r0.L), $DragDx)
    }
}

$b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$bmp = New-Object System.Drawing.Bitmap($b.Width, $b.Height)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($b.X, $b.Y, 0, 0, $bmp.Size)
$g.Dispose()
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Host "saved $Out ($($b.Width)x$($b.Height))"
Save-Crop $Out $Crop ($Out -replace '\.png$', '_crop.png')

[void][Sh.U]::SetCursorPos($before.L, $before.T)
