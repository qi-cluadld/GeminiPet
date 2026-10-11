# =====================================================================
#  由预览图生成图标(.ico) 与 动作合集图(预览合集.png)   —— 开发辅助脚本
#  --------------------------------------------------------------------
#  纯 PowerShell + .NET 实现, 不需要 Python / PIL。
#  用法:  powershell -NoProfile -ExecutionPolicy Bypass -File make_assets.ps1
#         powershell ... -File make_assets.ps1 -AlphaDir <带透明通道的预览目录>
#  说明:  不给 -AlphaDir 就只重新合成"预览合集.png"; 给了才会同时重做图标。
# =====================================================================
param([string]$AlphaDir)

Add-Type -AssemblyName System.Drawing

$root = Split-Path $PSScriptRoot -Parent          # tools\ 的上一级 = 宠物目录
$pet = Split-Path $root -Leaf

$configs = @{
    'ChatGPTPet' = @{
        Title = 'ChatGPT 桌面小宠物 · 动作与表情预览'
        Icon = 'chatgpt_pet'
        Box = @(30, 32, 210, 212)
        Poses = @(
            @('01_idle', '待机浮动'), @('02_blink', '眨眼'), @('03_think', '思考中…'),
            @('04_ping', '冒个泡'), @('05_bounce', '蹦一下'), @('06_spin', '花瓣转两圈'),
            @('07_wobble', '果冻一样晃'), @('08_pat', '被戳一下(爱心)'), @('09_sleep', '睡着了'),
            @('10_stretch', '伸懒腰'), @('11_look', '东张西望'), @('12_slide', '挪个地方')
        )
    }
    'DeepSeekPet' = @{
        Title = 'DeepSeek 桌面小宠物 · 动作与表情预览'
        Icon = 'deepseek_pet'
        Box = @(30, 22, 226, 218)
        Poses = @(
            @('01_idle', '待机漂浮'), @('02_blink', '眨眼'), @('03_flap', '拍拍胸鳍'),
            @('04_breach', '跃出水面'), @('05_roll', '翻滚一圈'), @('06_spout', '喷水柱'),
            @('07_pat', '被戳一下(爱心)'), @('08_bubbles', '吹泡泡'), @('09_sleep', '睡着了'),
            @('10_stretch', '伸懒腰'), @('11_look', '东张西望'), @('12_swim', '游到别处')
        )
    }
    'GeminiPet' = @{
        Title = 'Gemini 桌面小宠物 · 动作与表情预览'
        Icon = 'gemini_pet'
        Box = @(24, 18, 216, 210)
        Poses = @(
            @('01_idle', '待机漂浮'), @('02_blink', '眨眼'), @('03_wave', '挥手打招呼'),
            @('04_hop', '蹦一下'), @('05_spin', '转圈圈'), @('06_burst', '放烟花'),
            @('07_pat', '被戳一下(爱心)'), @('08_surprised', '惊讶'), @('09_sleep', '睡着了'),
            @('10_stretch', '伸懒腰'), @('11_look', '东张西望'), @('12_wander', '挪个窝')
        )
    }
}
$cfg = $configs[$pet]
if (-not $cfg) { Write-Host "未知宠物目录: $pet"; exit 1 }
$prev = Join-Path $root 'preview'

function New-Resized([System.Drawing.Image]$img, [int]$w, [int]$h) {
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.DrawImage($img, 0, 0, $w, $h)
    $g.Dispose()
    return $bmp
}

function New-Icon([string]$alphaDir) {
    $src = Join-Path $alphaDir '01_idle.png'
    if (-not (Test-Path -LiteralPath $src)) { Write-Host "  跳过图标: 找不到 $src"; return }
    $img = [System.Drawing.Image]::FromFile($src)
    $b = $cfg.Box
    $cropW = $b[2] - $b[0]; $cropH = $b[3] - $b[1]
    $crop = New-Object System.Drawing.Bitmap($cropW, $cropH)
    $g = [System.Drawing.Graphics]::FromImage($crop)
    $g.DrawImage($img, (New-Object System.Drawing.Rectangle(0, 0, $cropW, $cropH)),
        (New-Object System.Drawing.Rectangle($b[0], $b[1], $cropW, $cropH)), [System.Drawing.GraphicsUnit]::Pixel)
    $g.Dispose(); $img.Dispose()
    $side = [Math]::Max($cropW, $cropH)
    $square = New-Object System.Drawing.Bitmap($side, $side)
    $g = [System.Drawing.Graphics]::FromImage($square)
    $g.DrawImage($crop, [int](($side - $cropW) / 2), [int](($side - $cropH) / 2), $cropW, $cropH)
    $g.Dispose(); $crop.Dispose()
    $icon256 = New-Resized $square 256 256
    $square.Dispose()
    $png = Join-Path $root ($cfg.Icon + '.png')
    $icon256.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)

    # 手写 .ico 容器(每个尺寸内嵌一张 PNG, Vista 及以上都支持)
    $sizes = @(16, 24, 32, 48, 64, 128, 256)
    $payloads = @()
    foreach ($s in $sizes) {
        $bmp = New-Resized $icon256 $s $s
        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $payloads += , $ms.ToArray()
        $ms.Dispose(); $bmp.Dispose()
    }
    $icon256.Dispose()
    $out = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($out)
    $bw.Write([UInt16]0); $bw.Write([UInt16]1); $bw.Write([UInt16]$sizes.Count)
    $offset = 6 + 16 * $sizes.Count
    for ($i = 0; $i -lt $sizes.Count; $i++) {
        $s = $sizes[$i]
        $wh = if ($s -ge 256) { 0 } else { $s }
        $bw.Write([byte]$wh); $bw.Write([byte]$wh)
        $bw.Write([byte]0); $bw.Write([byte]0)
        $bw.Write([UInt16]1); $bw.Write([UInt16]32)
        $bw.Write([UInt32]$payloads[$i].Length); $bw.Write([UInt32]$offset)
        $offset += $payloads[$i].Length
    }
    foreach ($p in $payloads) { $bw.Write($p) }
    $bw.Flush()
    $ico = Join-Path $root ($cfg.Icon + '.ico')
    [System.IO.File]::WriteAllBytes($ico, $out.ToArray())
    $bw.Dispose(); $out.Dispose()
    $check = New-Object System.Drawing.Icon($ico)
    Write-Host ("  icon -> {0}  ({1} 字节, 最大 {2}x{3})" -f $ico, (Get-Item $ico).Length, $check.Width, $check.Height)
    $check.Dispose()
}

function New-Sheet {
    $cw = 240; $ch = 240; $pad = 14; $labelH = 52; $cols = 4; $rows = 3; $titleH = 58
    $W = $pad + $cols * ($cw + $pad)
    $H = $titleH + $pad + $rows * ($ch + $labelH + $pad)
    $bmp = New-Object System.Drawing.Bitmap($W, $H)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
    $g.Clear([System.Drawing.Color]::FromArgb(244, 245, 250))
    $titleFont = New-Object System.Drawing.Font('Microsoft YaHei', 18)
    $labelFont = New-Object System.Drawing.Font('Microsoft YaHei', 12.5)
    $titleBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(40, 44, 66))
    $labelBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(58, 63, 90))
    $cardBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
    $g.DrawString($cfg.Title, $titleFont, $titleBrush, ($pad + 6), 16)
    for ($i = 0; $i -lt $cfg.Poses.Count; $i++) {
        $stem = $cfg.Poses[$i][0]; $label = $cfg.Poses[$i][1]
        $r = [int]($i / $cols); $c = $i % $cols
        $x = $pad + $c * ($cw + $pad)
        $y = $titleH + $pad + $r * ($ch + $labelH + $pad)
        # 圆角白卡片
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $rad = 14; $rw = $cw + 8; $rh = $ch + $labelH - 2
        $path.AddArc($x - 4, $y - 4, $rad, $rad, 180, 90)
        $path.AddArc($x - 4 + $rw - $rad, $y - 4, $rad, $rad, 270, 90)
        $path.AddArc($x - 4 + $rw - $rad, $y - 4 + $rh - $rad, $rad, $rad, 0, 90)
        $path.AddArc($x - 4, $y - 4 + $rh - $rad, $rad, $rad, 90, 90)
        $path.CloseFigure()
        $g.FillPath($cardBrush, $path); $path.Dispose()
        $png = Join-Path $prev ($stem + '.png')
        if (Test-Path -LiteralPath $png) {
            $img = [System.Drawing.Image]::FromFile($png)
            $g.DrawImage($img, $x, $y, $cw, $ch); $img.Dispose()
        }
        $size = $g.MeasureString($label, $labelFont)
        $g.DrawString($label, $labelFont, $labelBrush, ($x + ($cw - $size.Width) / 2), ($y + $ch + 14))
    }
    $outPng = Join-Path $prev '预览合集.png'
    $bmp.Save($outPng, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    $titleFont.Dispose(); $labelFont.Dispose(); $titleBrush.Dispose(); $labelBrush.Dispose(); $cardBrush.Dispose()
    Write-Host ("  sheet -> {0}  ({1}x{2})" -f $outPng, $W, $H)
}

if ($AlphaDir) {
    if (-not [System.IO.Path]::IsPathRooted($AlphaDir)) { $AlphaDir = Join-Path (Get-Location).Path $AlphaDir }
    New-Icon $AlphaDir
}
New-Sheet
