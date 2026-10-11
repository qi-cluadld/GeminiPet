#Requires -Version 5.1
<#
  Gemini 桌面小宠物 / Gemini Desktop Pet
  ---------------------------------------------------------------
  * 纯 Windows 自带组件实现(WPF + PowerShell 5.1),无需安装任何依赖
  * 四角星造型的 Gemini 小精灵:待机漂浮 / 眨眼 / 随机小动作 / 戳一戳有反应
  * 左键拖动移动,右键菜单(打招呼、摸摸头、缩小放大、换位置、退出)
  * 不抢焦点(可在你打字时安静地待在角落)

  用法:
    powershell -NoProfile -ExecutionPolicy Bypass -File GeminiPet.ps1
    powershell ... -File GeminiPet.ps1 -Size 1.3          # 放大
    powershell ... -File GeminiPet.ps1 -Preview out        # 渲染静态预览图(用于检查外观)
    powershell ... -File GeminiPet.ps1 -SelfTest 20        # 自检 20 秒(自动化跑一遍所有动作)
#>
[CmdletBinding()]
param(
    [string]$Preview,                 # 渲染预览图的输出目录
    [int]$SelfTest = 0,               # 自检运行秒数
    [switch]$PreviewAlpha,           # 预览图带透明通道(用于做图标)
    [double]$Size = 1.0,              # 宠物大小倍率
    [switch]$ActivateOnClick,         # 点击时允许抢焦点(默认不抢)
    [switch]$AllowMultiple            # 允许开多只
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- 程序集
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
try { Add-Type -AssemblyName System.Xaml } catch { }

$script:LogPath = Join-Path $env:TEMP 'GeminiPet.log'
$socialPath = Join-Path $PSScriptRoot 'social.ps1'
if (Test-Path -LiteralPath $socialPath) { . $socialPath }
function Write-PetLog([string]$msg) {
    try { Add-Content -LiteralPath $script:LogPath -Value ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $msg) -Encoding UTF8 } catch { }
}

# ---------------------------------------------------------------- 原生调用
try {
    Add-Type -Namespace 'GeminiPetNative' -Name 'Win32' -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
[DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
[DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
[StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
'@
} catch { Write-PetLog "Add-Type Win32 失败: $_" }

function Initialize-Dpi {
    try {
        if (-not [GeminiPetNative.Win32]::SetProcessDpiAwarenessContext([IntPtr](-4))) {
            [void][GeminiPetNative.Win32]::SetProcessDPIAware()
        }
    } catch {
        try { [void][GeminiPetNative.Win32]::SetProcessDPIAware() } catch { }
    }
}
function Get-CursorPoint {
    $p = New-Object GeminiPetNative.Win32+POINT
    if ([GeminiPetNative.Win32]::GetCursorPos([ref]$p)) { return @($p.X, $p.Y) }
    return @(0, 0)
}

# ---------------------------------------------------------------- 小工具
$script:Inv = [System.Globalization.CultureInfo]::InvariantCulture
function F([double]$v) { $v.ToString('0.###', $script:Inv) }
function Clamp01([double]$v) { if ($v -lt 0) { 0.0 } elseif ($v -gt 1) { 1.0 } else { $v } }
function Ease-InOut([double]$p) { $p = Clamp01 $p; $p * $p * (3 - 2 * $p) }

$script:Rng = New-Object System.Random
function Rand([double]$min, [double]$max) { $min + $script:Rng.NextDouble() * ($max - $min) }

function New-Gs([string]$color, [double]$offset) {
    $g = New-Object System.Windows.Media.GradientStop
    $g.Color = [System.Windows.Media.Color][System.Windows.Media.ColorConverter]::ConvertFromString($color)
    $g.Offset = $offset
    return $g
}
function New-LinBrush([string[]]$colors, [double[]]$offsets, [double]$x1 = 0, [double]$y1 = 0, [double]$x2 = 1, [double]$y2 = 1) {
    $b = New-Object System.Windows.Media.LinearGradientBrush
    $b.StartPoint = New-Object System.Windows.Point($x1, $y1)
    $b.EndPoint = New-Object System.Windows.Point($x2, $y2)
    for ($i = 0; $i -lt $colors.Count; $i++) { [void]$b.GradientStops.Add((New-Gs $colors[$i] $offsets[$i])) }
    return $b
}
function New-RadBrush([string]$inner, [string]$outer, [double]$gx = 0.5, [double]$gy = 0.5, [double]$rx = 0.5, [double]$ry = 0.5) {
    $b = New-Object System.Windows.Media.RadialGradientBrush
    $b.GradientOrigin = New-Object System.Windows.Point($gx, $gy)
    $b.Center = New-Object System.Windows.Point($gx, $gy)
    $b.RadiusX = $rx
    $b.RadiusY = $ry
    [void]$b.GradientStops.Add((New-Gs $inner 0))
    [void]$b.GradientStops.Add((New-Gs $outer 1))
    return $b
}

# 四角星(双子星火花)几何:M 顶点 C 控制点... 每段控制点取顶点 * Waist
# Waist 越小腰身越细, 越大越饱满(Gemini 的星星比较饱满, 约 0.68)
function New-SparkleData([double]$R, [double]$Waist = 0.68) {
    $pts = @(
        @(0.0, -$R), @($R, 0.0), @(0.0, $R), @(-$R, 0.0)
    )
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('M ' + (F $pts[0][0]) + ',' + (F $pts[0][1]))
    for ($i = 0; $i -lt 4; $i++) {
        $p = $pts[$i]
        $q = $pts[($i + 1) % 4]
        $c1x = $p[0] * $Waist; $c1y = $p[1] * $Waist
        $c2x = $q[0] * $Waist; $c2y = $q[1] * $Waist
        [void]$sb.Append(' C ' + (F $c1x) + ',' + (F $c1y) + ' ' + (F $c2x) + ',' + (F $c2y) + ' ' + (F $q[0]) + ',' + (F $q[1]))
    }
    [void]$sb.Append(' Z')
    return $sb.ToString()
}

$script:BodyR = 78.0
$script:BodyData = New-SparkleData -R $script:BodyR -Waist 0.78
$script:MiniData = New-SparkleData -R 11 -Waist 0.52
$script:OrbitData = New-SparkleData -R 9 -Waist 0.5
$script:HeartData = 'M 0,9 C -11,2 -10,-7 -4.5,-9 C -1.5,-10 0,-8 0,-6 C 0,-8 1.5,-10 4.5,-9 C 10,-7 11,2 0,9 Z'

# ---------------------------------------------------------------- 界面(XAML)
$xaml = @'
<Canvas xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        x:Name="Root" Width="240" Height="240" ClipToBounds="False">

  <Canvas x:Name="PetWrap" Width="240" Height="240" Canvas.Left="0" Canvas.Top="0"
          RenderTransformOrigin="0.5,0.5" Cursor="Hand" ClipToBounds="False">
    <Canvas.RenderTransform>
      <TransformGroup>
        <ScaleTransform x:Name="TScale" ScaleX="1" ScaleY="1"/>
        <RotateTransform x:Name="TRot" Angle="0"/>
        <TranslateTransform x:Name="TTrans" X="0" Y="0"/>
      </TransformGroup>
    </Canvas.RenderTransform>
    <Canvas x:Name="Pet" Width="240" Height="240">

    <!-- 光晕 -->
    <Ellipse Width="230" Height="230" Canvas.Left="5" Canvas.Top="5" Opacity="0.5" IsHitTestVisible="False">
      <Ellipse.Fill>
        <RadialGradientBrush>
          <GradientStop Color="#66BCD6FF" Offset="0.30"/>
          <GradientStop Color="#339B72CB" Offset="0.66"/>
          <GradientStop Color="#00D96570" Offset="1"/>
        </RadialGradientBrush>
      </Ellipse.Fill>
    </Ellipse>

    <!-- 身体(四角星) -->
    <Path x:Name="Body" Data="{BODY}" StrokeThickness="0" IsHitTestVisible="True">
      <Path.Fill>
        <LinearGradientBrush StartPoint="0.10,0" EndPoint="0.90,1">
          <GradientStop Color="#FF4A88F8" Offset="0"/>
          <GradientStop Color="#FF8B78E2" Offset="0.34"/>
          <GradientStop Color="#FF9B72CB" Offset="0.58"/>
          <GradientStop Color="#FFE2688C" Offset="1"/>
        </LinearGradientBrush>
      </Path.Fill>
      <Path.RenderTransform>
        <TranslateTransform X="120" Y="120"/>
      </Path.RenderTransform>
      <Path.Effect>
        <DropShadowEffect Color="#7A2B57B0" BlurRadius="16" ShadowDepth="5" Direction="270" Opacity="0.5"/>
      </Path.Effect>
    </Path>

    <!-- 高光 -->
    <Path Data="{BODY}" IsHitTestVisible="False">
      <Path.Fill>
        <RadialGradientBrush GradientOrigin="0.30,0.20" Center="0.30,0.20" RadiusX="0.68" RadiusY="0.60">
          <GradientStop Color="#59FFFFFF" Offset="0"/>
          <GradientStop Color="#00FFFFFF" Offset="1"/>
        </RadialGradientBrush>
      </Path.Fill>
      <Path.RenderTransform>
        <TranslateTransform X="120" Y="120"/>
      </Path.RenderTransform>
    </Path>

    <!-- 星星上的小亮点 -->
    <Path Data="{MINI}" Fill="#CCFFFFFF" Opacity="0.85" IsHitTestVisible="False">
      <Path.RenderTransform>
        <TranslateTransform X="84" Y="72"/>
      </Path.RenderTransform>
    </Path>

    <!-- 小手 -->
    <Rectangle x:Name="ArmL" Width="24" Height="14" RadiusX="7" RadiusY="7" Canvas.Left="30" Canvas.Top="133"
               RenderTransformOrigin="1,0.5" IsHitTestVisible="False">
      <Rectangle.Fill>
        <LinearGradientBrush StartPoint="0,0" EndPoint="1,0.6">
          <GradientStop Color="#FF7E76D6" Offset="0"/>
          <GradientStop Color="#FF5C8DF0" Offset="1"/>
        </LinearGradientBrush>
      </Rectangle.Fill>
      <Rectangle.RenderTransform>
        <RotateTransform x:Name="ArmLRot" Angle="8"/>
      </Rectangle.RenderTransform>
    </Rectangle>
    <Rectangle x:Name="ArmR" Width="24" Height="14" RadiusX="7" RadiusY="7" Canvas.Left="186" Canvas.Top="133"
               RenderTransformOrigin="0,0.5" IsHitTestVisible="False">
      <Rectangle.Fill>
        <LinearGradientBrush StartPoint="1,0" EndPoint="0,0.6">
          <GradientStop Color="#FFE2688C" Offset="0"/>
          <GradientStop Color="#FF9B72CB" Offset="1"/>
        </LinearGradientBrush>
      </Rectangle.Fill>
      <Rectangle.RenderTransform>
        <RotateTransform x:Name="ArmRRot" Angle="-8"/>
      </Rectangle.RenderTransform>
    </Rectangle>

    <!-- 眼睛(睁) -->
    <Canvas x:Name="EyeOpen" Width="240" Height="240" RenderTransformOrigin="0.5,0.5" IsHitTestVisible="False">
      <Canvas.RenderTransform>
        <TransformGroup>
          <ScaleTransform x:Name="EyeScale" ScaleX="1" ScaleY="1"/>
          <TranslateTransform x:Name="EyeLook" X="0" Y="0"/>
        </TransformGroup>
      </Canvas.RenderTransform>
      <Ellipse Width="27" Height="30" Canvas.Left="80.5" Canvas.Top="103">
        <Ellipse.Fill>
          <LinearGradientBrush StartPoint="0.2,0" EndPoint="0.8,1">
            <GradientStop Color="#FF33436E" Offset="0"/>
            <GradientStop Color="#FF141B32" Offset="1"/>
          </LinearGradientBrush>
        </Ellipse.Fill>
      </Ellipse>
      <Ellipse Width="27" Height="30" Canvas.Left="132.5" Canvas.Top="103">
        <Ellipse.Fill>
          <LinearGradientBrush StartPoint="0.2,0" EndPoint="0.8,1">
            <GradientStop Color="#FF33436E" Offset="0"/>
            <GradientStop Color="#FF141B32" Offset="1"/>
          </LinearGradientBrush>
        </Ellipse.Fill>
      </Ellipse>
      <Ellipse Width="10" Height="10" Canvas.Left="85" Canvas.Top="107" Fill="#FFFFFFFF" Opacity="0.95"/>
      <Ellipse Width="10" Height="10" Canvas.Left="137" Canvas.Top="107" Fill="#FFFFFFFF" Opacity="0.95"/>
      <Ellipse Width="4.5" Height="4.5" Canvas.Left="100" Canvas.Top="121" Fill="#FFFFFFFF" Opacity="0.6"/>
      <Ellipse Width="4.5" Height="4.5" Canvas.Left="152" Canvas.Top="121" Fill="#FFFFFFFF" Opacity="0.6"/>
    </Canvas>

    <!-- 眼睛(笑成弯月) -->
    <Canvas x:Name="EyeHappy" Width="240" Height="240" Visibility="Collapsed" IsHitTestVisible="False">
      <Path Data="M -12,3 Q 0,-10 12,3" Stroke="#FF1B2745" StrokeThickness="4.2"
            StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round">
        <Path.RenderTransform>
          <TranslateTransform X="94" Y="119"/>
        </Path.RenderTransform>
      </Path>
      <Path Data="M -12,3 Q 0,-10 12,3" Stroke="#FF1B2745" StrokeThickness="4.2"
            StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round">
        <Path.RenderTransform>
          <TranslateTransform X="146" Y="119"/>
        </Path.RenderTransform>
      </Path>
    </Canvas>

    <!-- 嘴 -->
    <Canvas x:Name="Mouth" Width="240" Height="240" IsHitTestVisible="False">
      <Path x:Name="MouthSmile" Data="M -10,0 Q 0,10 10,0" Stroke="#FF1B2745" StrokeThickness="3.4"
            StrokeStartLineCap="Round" StrokeEndLineCap="Round">
        <Path.RenderTransform>
          <TranslateTransform X="120" Y="150"/>
        </Path.RenderTransform>
      </Path>
      <Path x:Name="MouthFlat" Data="M -8,0 L 8,0" Stroke="#FF1B2745" StrokeThickness="3.4"
            StrokeStartLineCap="Round" StrokeEndLineCap="Round" Visibility="Collapsed">
        <Path.RenderTransform>
          <TranslateTransform X="120" Y="151"/>
        </Path.RenderTransform>
      </Path>
      <Ellipse x:Name="MouthOpen" Width="13" Height="15" Canvas.Left="113.5" Canvas.Top="143" Fill="#FF1B2745" Visibility="Collapsed"/>
    </Canvas>

    <!-- 腮红 -->
    <Canvas x:Name="Blush" Width="240" Height="240" Opacity="0" IsHitTestVisible="False">
      <Ellipse Width="26" Height="13" Canvas.Left="67" Canvas.Top="130">
        <Ellipse.Fill>
          <RadialGradientBrush>
            <GradientStop Color="#FFFF8FB4" Offset="0"/>
            <GradientStop Color="#00FF8FB4" Offset="1"/>
          </RadialGradientBrush>
        </Ellipse.Fill>
      </Ellipse>
      <Ellipse Width="26" Height="13" Canvas.Left="147" Canvas.Top="130">
        <Ellipse.Fill>
          <RadialGradientBrush>
            <GradientStop Color="#FFFF8FB4" Offset="0"/>
            <GradientStop Color="#00FF8FB4" Offset="1"/>
          </RadialGradientBrush>
        </Ellipse.Fill>
      </Ellipse>
    </Canvas>
    </Canvas>
  </Canvas>

  <Canvas x:Name="OrbitLayer" Width="240" Height="240" IsHitTestVisible="False"/>
  <Canvas x:Name="ParticleLayer" Width="240" Height="240" IsHitTestVisible="False"/>
</Canvas>
'@

$xaml = $xaml.Replace('{BODY}', $script:BodyData).Replace('{MINI}', $script:MiniData)
$root = [System.Windows.Markup.XamlReader]::Parse($xaml)

function N([string]$name) {
    $el = $root.FindName($name)
    if (-not $el) { throw "找不到界面元素: $name" }
    return $el
}
$PetWrap = N 'PetWrap'
$Pet = N 'Pet'
$Pet.CacheMode = New-Object System.Windows.Media.BitmapCache
$Pet.CacheMode.RenderAtScale = 1.0
$Pet.CacheMode.EnableClearType = $false
$TScale = N 'TScale'; $TRot = N 'TRot'; $TTrans = N 'TTrans'
$Body = N 'Body'
$ArmL = N 'ArmL'; $ArmR = N 'ArmR'; $ArmLRot = N 'ArmLRot'; $ArmRRot = N 'ArmRRot'
$EyeOpen = N 'EyeOpen'; $EyeHappy = N 'EyeHappy'; $EyeScale = N 'EyeScale'; $EyeLook = N 'EyeLook'
$Mouth = N 'Mouth'; $MouthSmile = N 'MouthSmile'; $MouthFlat = N 'MouthFlat'; $MouthOpen = N 'MouthOpen'
$Blush = N 'Blush'
$OrbitLayer = N 'OrbitLayer'; $ParticleLayer = N 'ParticleLayer'

# ---------------------------------------------------------------- 计时元素
$script:Orbit = New-Object System.Collections.ArrayList
function Initialize-Orbit {
    $i = 0
    foreach ($phase in @(0.4, 2.5, 4.6)) {
        $p = New-Object System.Windows.Shapes.Path
        $p.Data = [System.Windows.Media.Geometry]::Parse($script:OrbitData)
        $p.Fill = New-LinBrush -colors @('#FF9FC4FF', '#FFD96570') -offsets @(0, 1)
        $p.RenderTransformOrigin = New-Object System.Windows.Point(0, 0)
        $rt = New-Object System.Windows.Media.RotateTransform(0)
        $p.RenderTransform = $rt
        $p.IsHitTestVisible = $false
        [void]$OrbitLayer.Children.Add($p)
        [void]$script:Orbit.Add(@{
                El = $p; Rot = $rt; Phase = $phase
                Speed = 0.30 + 0.06 * $i
                Radius = 84.0 + 7.0 * $i
                Size = 0.75 + 0.22 * $i
            })
        $i++
    }
}
Initialize-Orbit

# ---------------------------------------------------------------- 粒子
$script:Particles = New-Object System.Collections.ArrayList

function New-Particle {
    param(
        [ValidateSet('star', 'heart', 'z')][string]$Kind,
        [double]$X, [double]$Y, [double]$VX, [double]$VY, [double]$G,
        [double]$Life, [double]$S0, [double]$S1, [double]$Spin
    )
    $el = $null
    switch ($Kind) {
        'star' {
            $el = New-Object System.Windows.Shapes.Path
            $el.Data = [System.Windows.Media.Geometry]::Parse($script:OrbitData)
            $el.Fill = New-LinBrush -colors @('#FFFFE9A8', '#FFD96570') -offsets @(0, 1)
        }
        'heart' {
            $el = New-Object System.Windows.Shapes.Path
            $el.Data = [System.Windows.Media.Geometry]::Parse($script:HeartData)
            $el.Fill = New-LinBrush -colors @('#FFFF9EC2', '#FFE0658C') -offsets @(0, 1)
        }
        'z' {
            $el = New-Object System.Windows.Controls.TextBlock
            $el.Text = 'Z'
            $el.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe UI')
            $el.FontWeight = [System.Windows.FontWeights]::Bold
            $el.FontSize = 17
            $el.Foreground = New-LinBrush -colors @('#FFE6EEFF', '#FFB08CE0') -offsets @(0, 1)
        }
    }
    $el.IsHitTestVisible = $false
    $sc = New-Object System.Windows.Media.ScaleTransform($S0, $S0)
    $rt = New-Object System.Windows.Media.RotateTransform(0)
    $tg = New-Object System.Windows.Media.TransformGroup
    [void]$tg.Children.Add($sc)
    [void]$tg.Children.Add($rt)
    $el.RenderTransformOrigin = New-Object System.Windows.Point(0, 0)
    $el.RenderTransform = $tg
    $el.Opacity = 1.0
    [System.Windows.Controls.Canvas]::SetLeft($el, $X)
    [System.Windows.Controls.Canvas]::SetTop($el, $Y)
    [void]$ParticleLayer.Children.Add($el)
    [void]$script:Particles.Add(@{
            El = $el; X = $X; Y = $Y; VX = $VX; VY = $VY; G = $G
            Life = 0.0; MaxLife = $Life; S0 = $S0; S1 = $S1; Spin = $Spin
            Sc = $sc; Rot = $rt
        })
}

function Clear-Particles {
    foreach ($p in @($script:Particles)) { [void]$ParticleLayer.Children.Remove($p.El) }
    $script:Particles.Clear()
}

function Spawn-Burst([int]$n) {
    for ($i = 0; $i -lt $n; $i++) {
        $a = $script:Rng.NextDouble() * 2 * [Math]::PI
        $sp = Rand 45 120
        New-Particle -Kind 'star' -X (120 + [Math]::Cos($a) * 12) -Y (120 + [Math]::Sin($a) * 12) `
            -VX ([Math]::Cos($a) * $sp) -VY ([Math]::Sin($a) * $sp - 30) -G 60 `
            -Life (Rand 0.7 1.2) -S0 (Rand 0.5 0.95) -S1 (Rand 0.1 0.4) -Spin (Rand -200 200)
    }
}
function Spawn-Hearts([int]$n) {
    for ($i = 0; $i -lt $n; $i++) {
        New-Particle -Kind 'heart' -X (120 + (Rand -48 48)) -Y (116 + (Rand -12 12)) `
            -VX (Rand -24 24) -VY (Rand -66 -36) -G -8 `
            -Life (Rand 0.9 1.4) -S0 (Rand 0.3 0.5) -S1 (Rand 0.9 1.25) -Spin (Rand -70 70)
    }
}
function Spawn-Z {
    New-Particle -Kind 'z' -X (Rand 146 160) -Y (Rand 86 100) `
        -VX (Rand 9 20) -VY (Rand -24 -14) -G -2 `
        -Life (Rand 1.6 2.1) -S0 (Rand 0.6 0.8) -S1 (Rand 1.3 1.7) -Spin 0
}

# ---------------------------------------------------------------- 表情
$script:CurExpr = ''
$script:EyeBase = 1.0
function Show-Mouth([string]$which) {
    $MouthSmile.Visibility = if ($which -eq 'smile') { 'Visible' } else { 'Collapsed' }
    $MouthFlat.Visibility = if ($which -eq 'flat') { 'Visible' } else { 'Collapsed' }
    $MouthOpen.Visibility = if ($which -eq 'open') { 'Visible' } else { 'Collapsed' }
}
function Set-Expression([string]$name) {
    if ($script:CurExpr -eq $name) { return }
    $script:CurExpr = $name
    switch ($name) {
        'happy' {
            $EyeOpen.Visibility = 'Collapsed'; $EyeHappy.Visibility = 'Visible'
            Show-Mouth 'smile'; $script:EyeBase = 1.0
        }
        'sleepy' {
            $EyeOpen.Visibility = 'Visible'; $EyeHappy.Visibility = 'Collapsed'
            Show-Mouth 'flat'; $script:EyeBase = 0.07
        }
        'surprised' {
            $EyeOpen.Visibility = 'Visible'; $EyeHappy.Visibility = 'Collapsed'
            Show-Mouth 'open'; $script:EyeBase = 1.2
        }
        default {
            $EyeOpen.Visibility = 'Visible'; $EyeHappy.Visibility = 'Collapsed'
            Show-Mouth 'smile'; $script:EyeBase = 1.0
        }
    }
}

# ---------------------------------------------------------------- 状态
$script:Win = $null
$script:T = 0.0
$script:State = 'idle'
$script:StateT = 0.0
$script:StateDur = 0.0
$script:LastAction = ''
$script:NextAction = 5.0
$script:BlinkT = -1.0
$script:NextBlink = 3.0
$script:PatT = -1.0
$script:ZTimer = 0.0
$script:Sleepy = $false
$script:IdleSince = 0.0
$script:ExprForce = ''
$script:ExprUntil = 0.0
$script:WanderFrom = 0.0
$script:WanderTo = 0.0
$script:WanderDir = 1.0
$script:PatCount = 0
$script:ErrorCount = 0

function Reset-PetState {
    Clear-Particles
    $script:State = 'idle'; $script:StateT = 0.0; $script:StateDur = 0.0
    $script:Sleepy = $false; $script:BlinkT = -1.0; $script:PatT = -1.0
    $script:ExprForce = ''; $script:ExprUntil = 0.0; $script:CurExpr = ''
    $script:EyeBase = 1.0
    $script:IdleSince = $script:T
    $script:NextAction = $script:T + 6.0
}

function End-State {
    $script:State = 'idle'; $script:StateT = 0.0; $script:StateDur = 0.0
    $script:NextAction = $script:T + (Rand 3.5 9.5)
}

function Start-Action([string]$name) {
    $script:State = $name
    $script:StateT = 0.0
    switch ($name) {
        'hop' { $script:StateDur = 0.80 }
        'spin' { $script:StateDur = 0.95 }
        'look' { $script:StateDur = 1.50 }
        'wave' { $script:StateDur = 1.70 }
        'burst' { $script:StateDur = 1.20; Spawn-Burst 11 }
        'stretch' { $script:StateDur = 1.10 }
        'pop' { $script:StateDur = 0.62 }
        'wander' {
            $script:StateDur = 2.30
            $script:WanderFrom = 0.0; $script:WanderTo = 0.0; $script:WanderDir = 1.0
            if ($script:Win) {
                $wa = [System.Windows.SystemParameters]::WorkArea
                $w = $script:Win.Width
                $minX = $wa.Left + 8
                $maxX = $wa.Right - $w - 8
                $cur = $script:Win.Left
                $tgt = $cur
                if ($maxX -gt $minX) {
                    for ($i = 0; $i -lt 12; $i++) {
                        $tgt = Rand $minX $maxX
                        if ([Math]::Abs($tgt - $cur) -gt 150) { break }
                    }
                    if ([Math]::Abs($tgt - $cur) -lt 60) { $tgt = if ($cur -lt ($minX + $maxX) / 2) { $maxX } else { $minX } }
                }
                $script:WanderFrom = $cur
                $script:WanderTo = $tgt
                $script:WanderDir = [Math]::Sign($tgt - $cur)
            }
        }
    }
    Write-PetLog "动作: $name"
}

function Start-RandomAction {
    $pool = @(
        @{ n = 'hop'; w = 17 }, @{ n = 'look'; w = 19 }, @{ n = 'wave'; w = 13 },
        @{ n = 'spin'; w = 10 }, @{ n = 'burst'; w = 15 }, @{ n = 'stretch'; w = 12 },
        @{ n = 'wander'; w = 14 }
    )
    $pool = @($pool | Where-Object { $_.n -ne $script:LastAction })
    $total = 0.0
    foreach ($it in $pool) { $total += $it.w }
    $r = $script:Rng.NextDouble() * $total
    $acc = 0.0
    foreach ($it in $pool) {
        $acc += $it.w
        if ($r -le $acc) { $script:LastAction = $it.n; Start-Action $it.n; return }
    }
    Start-Action 'hop'
}

function Enter-Sleep {
    $script:Sleepy = $true
    $script:State = 'idle'; $script:StateT = 0.0; $script:StateDur = 0.0
    $script:ZTimer = 0.0
    Write-PetLog '睡着了'
}
function Wake-Pet {
    if ($script:Sleepy) {
        $script:Sleepy = $false
        $script:ExprForce = 'surprised'; $script:ExprUntil = $script:T + 0.7
        Write-PetLog '醒了'
    }
}

function Invoke-Pat {
    $script:IdleSince = $script:T
    Wake-Pet
    $script:PatCount++
    $script:PatT = 0.0
    $script:ExprForce = 'happy'; $script:ExprUntil = $script:T + 1.1
    Spawn-Hearts 5
    $roll = $script:Rng.NextDouble()
    if ($roll -lt 0.30) { Start-Action 'hop' }
    elseif ($roll -lt 0.50) { Start-Action 'spin' }
    elseif ($roll -lt 0.62) { Start-Action 'burst' }
    else { Start-Action 'pop' }
}

# ---------------------------------------------------------------- 每帧更新
# ---------------------------------------------------------------- 三只桌宠联动
function Initialize-PetSocial {
    if ($script:SocialReady) { return $true }
    if (-not (Get-Command Connect-PetSocial -ErrorAction SilentlyContinue)) { $script:SocialReady = $true; return $false }
    $script:SocialLookX = 0.0; $script:SocialLookY = 0.0; $script:SocialTilt = 0.0
    $hooks = @{
        Greet = {
            param($n)
            $script:IdleSince = $script:T
            Wake-Pet
            Start-Action 'wave'
            $script:ExprForce = 'happy'; $script:ExprUntil = $script:T + 1.7
            Spawn-Hearts 4
            Spawn-Burst 5
        }
        Play = {
            param($n)
            $script:IdleSince = $script:T
            Wake-Pet
            Start-Action 'spin'
            $script:ExprForce = 'happy'; $script:ExprUntil = $script:T + 1.4
            Spawn-Burst 8
        }
        LookAt = {
            param($x, $y)
            $script:SocialLookX = $x
            $script:SocialLookY = $y
            $script:SocialTilt = [Math]::Max(-4.0, [Math]::Min(4.0, $x * 0.5))
        }
        MoveTo = {
            param($x)
            $script:IdleSince = $script:T
            Start-Action 'wander'
            $script:WanderFrom = $script:Win.Left
            $script:WanderTo = $x
            $script:WanderDir = [Math]::Sign($x - $script:Win.Left)
        }
        Busy = { $script:State -ne 'idle' }
        Sleepy = { [bool]$script:Sleepy }
    }
    if (-not (Connect-PetSocial -SelfId 'gemini' -Hooks $hooks)) { $script:SocialReady = $true; return $false }
    $script:SocialReady = $true
    return $true
}
function Update-PetSocialTick([double]$dt) {
    if (-not $script:SocialReady) { if (-not (Initialize-PetSocial)) { return } }
    try { Invoke-PetSocial -Dt $dt -Win $script:Win -Hooks $script:PetSocialHooks } catch { Write-PetLog "联动异常: $_" }
}
function Update-Pet([double]$dt) {
    $script:T += $dt
    $script:StateT += $dt
    if ($script:PatT -ge 0) { $script:PatT += $dt }

    # 太久没人理 -> 睡觉
    if (-not $script:Sleepy -and $script:State -eq 'idle' -and ($script:T - $script:IdleSince) -gt 75) { Enter-Sleep }

    # 眨眼
    $blink = 1.0
    if (-not $script:Sleepy -and $script:EyeBase -gt 0.5) {
        if ($script:BlinkT -lt 0 -and $script:T -ge $script:NextBlink) { $script:BlinkT = 0.0 }
        if ($script:BlinkT -ge 0) {
            $script:BlinkT += $dt
            $k = $script:BlinkT / 0.16
            if ($k -ge 1) {
                $script:BlinkT = -1.0
                $script:NextBlink = $script:T + (Rand 2.2 6.5)
            } else {
                $blink = 1.0 - 0.93 * [Math]::Sin([Math]::PI * $k)
            }
        }
    }

    # 随机小动作
    if ($script:State -eq 'idle' -and -not $script:Sleepy -and $script:T -ge $script:NextAction) { Start-RandomAction }

    # ---- 待机基础动画 ----
    $bobP = if ($script:Sleepy) { 5.0 } else { 3.4 }
    $bobA = if ($script:Sleepy) { 4.0 } else { 7.5 }
    $oy = [Math]::Sin($script:T * 2 * [Math]::PI / $bobP) * $bobA
    $rot = [Math]::Sin($script:T * 2 * [Math]::PI / 5.9) * 3.5
    $br = 0.016 * [Math]::Sin($script:T * 2 * [Math]::PI / 2.7)
    $sx = 1.0 + $br
    $sy = 1.0 - $br
    $ox = 0.0
    $lookX = 0.0; $lookY = 0.0
    $armLA = 8.0; $armRA = -8.0
    $blushAmt = 0.0
    if ($script:Sleepy) { $rot = 0.0; $armLA = 0.0; $armRA = 0.0 }

    # ---- 当前动作 ----
    $st = $script:State
    switch ($st) {
        'hop' {
            $p = Clamp01 ($script:StateT / $script:StateDur)
            $oy -= 46 * 4 * $p * (1 - $p)
            $s = [Math]::Sin([Math]::PI * $p)
            $sy = 1 + 0.14 * $s
            $sx = 1 - 0.08 * $s
            if ($p -gt 0.80) {
                $q = ($p - 0.80) / 0.20
                $sy *= 1 - 0.14 * [Math]::Sin([Math]::PI * $q)
                $sx *= 1 + 0.11 * [Math]::Sin([Math]::PI * $q)
            }
            if ($p -ge 1) { End-State }
        }
        'spin' {
            $p = Clamp01 ($script:StateT / $script:StateDur)
            $rot += 360 * (Ease-InOut $p)
            $s = 1 - 0.13 * [Math]::Sin([Math]::PI * $p)
            $sx *= $s; $sy *= $s
            if ($p -ge 1) { End-State }
        }
        'look' {
            $p = Clamp01 ($script:StateT / $script:StateDur)
            $sw = [Math]::Sin(2 * [Math]::PI * $p)
            $rot += 7 * $sw
            $lookX = 7 * $sw
            $lookY = 2 * [Math]::Sin(4 * [Math]::PI * $p)
            if ($p -ge 1) { End-State }
        }
        'wave' {
            $p = Clamp01 ($script:StateT / $script:StateDur)
            $armRA = -22 - 38 * [Math]::Sin(2 * [Math]::PI * $p * 2)
            $armLA = 8 + 8 * [Math]::Sin(2 * [Math]::PI * $p * 2 + 1)
            $rot += 4 * [Math]::Sin(2 * [Math]::PI * $p * 2)
            $blushAmt = 0.5 * [Math]::Sin([Math]::PI * $p)
            if ($p -ge 1) { End-State }
        }
        'burst' {
            $p = Clamp01 ($script:StateT / $script:StateDur)
            $s = 1 + 0.13 * [Math]::Sin([Math]::PI * $p)
            $sx *= $s; $sy *= $s
            $blushAmt = 0.45 * [Math]::Sin([Math]::PI * $p)
            if ($p -ge 1) { End-State }
        }
        'stretch' {
            $p = Clamp01 ($script:StateT / $script:StateDur)
            $k = [Math]::Sin([Math]::PI * $p)
            $sx *= 1 + 0.13 * $k
            $sy *= 1 - 0.12 * $k
            $armLA = 8 - 30 * $k
            $armRA = -8 + 30 * $k
            if ($p -ge 1) { End-State }
        }
        'pop' {
            $p = Clamp01 ($script:StateT / $script:StateDur)
            $blushAmt = 0.45 * [Math]::Sin([Math]::PI * $p)
            if ($p -ge 1) { End-State }
        }
        'wander' {
            $p = Clamp01 ($script:StateT / $script:StateDur)
            $e = Ease-InOut $p
            if ($script:Win) { $script:Win.Left = $script:WanderFrom + ($script:WanderTo - $script:WanderFrom) * $e }
            $rot += 6 * $script:WanderDir * [Math]::Sin([Math]::PI * $p)
            $oy -= 15 * [Math]::Abs([Math]::Sin(2 * [Math]::PI * $p))
            if ($p -ge 1) { End-State }
        }
    }

    # 被戳时的一下弹跳
    if ($script:PatT -ge 0) {
        if ($script:PatT -lt 0.40) {
            $pop = 1 + 0.17 * [Math]::Sin([Math]::PI * ($script:PatT / 0.40))
            $sx *= $pop; $sy *= $pop
        } else { $script:PatT = -1.0 }
    }

    # 睡觉时冒 Z
    if ($script:Sleepy) {
        $script:ZTimer += $dt
        if ($script:ZTimer -gt 0.95) { $script:ZTimer = 0.0; Spawn-Z }
    }

    # ---- 表情 ----
    $expr = 'normal'
    if ($script:Sleepy) { $expr = 'sleepy' }
    elseif ($st -eq 'wave' -or $st -eq 'burst' -or $st -eq 'pop') { $expr = 'happy' }
    if ($script:T -lt $script:ExprUntil) { $expr = $script:ExprForce }
    if ($script:T -ge $script:ExprUntil -and $script:ExprForce -ne '') { $script:ExprForce = '' }
    Set-Expression $expr

    # ---- 三只桌宠联动(感知同伴, 打招呼/对视/一起玩/串门) ----
    Update-PetSocialTick $dt

    # 兜底: NaN / Infinity 一旦写进变换, 元素就直接不渲染了
    if ([double]::IsNaN($rot) -or [double]::IsInfinity($rot)) { $rot = 0.0 }
    if ([double]::IsNaN($sx) -or [double]::IsInfinity($sx) -or $sx -le 0.01) { $sx = 1.0 }
    if ([double]::IsNaN($sy) -or [double]::IsInfinity($sy) -or $sy -le 0.01) { $sy = 1.0 }
    if ([double]::IsNaN($oy) -or [double]::IsInfinity($oy)) { $oy = 0.0 }
    if ([double]::IsNaN($lookX) -or [double]::IsInfinity($lookX)) { $lookX = 0.0 }
    if ([double]::IsNaN($lookY) -or [double]::IsInfinity($lookY)) { $lookY = 0.0 }

    # ---- 应用到界面 ----
    $TRot.Angle = $rot + $script:SocialTilt
    $TScale.ScaleX = $sx
    $TScale.ScaleY = $sy
    $TTrans.X = $ox
    $TTrans.Y = $oy
    $EyeScale.ScaleY = $script:EyeBase * $blink
    $EyeLook.X = $lookX + $script:SocialLookX
    $EyeLook.Y = $lookY + $script:SocialLookY
    $ArmLRot.Angle = $armLA
    $ArmRRot.Angle = $armRA
    $Blush.Opacity = [Math]::Max(0.0, [Math]::Min(1.0, $blushAmt))

    # ---- 环绕的小星星 ----
    foreach ($o in $script:Orbit) {
        $ang = $script:T * $o.Speed + $o.Phase
        [System.Windows.Controls.Canvas]::SetLeft($o.El, 120 + [Math]::Cos($ang) * $o.Radius - 9)
        [System.Windows.Controls.Canvas]::SetTop($o.El, 120 + [Math]::Sin($ang) * $o.Radius * 0.72 - 9)
        $o.El.Opacity = 0.18 + 0.5 * (0.5 + 0.5 * [Math]::Sin($script:T * 1.5 + $o.Phase))
        $o.Rot.Angle = $ang * 57.2958
    }

    # ---- 粒子 ----
    if ($script:Particles.Count -gt 0) {
        for ($i = $script:Particles.Count - 1; $i -ge 0; $i--) {
            $pt = $script:Particles[$i]
            $pt.Life += $dt
            $tt = $pt.Life / $pt.MaxLife
            if ($tt -ge 1) {
                [void]$ParticleLayer.Children.Remove($pt.El)
                $script:Particles.RemoveAt($i)
                continue
            }
            $pt.X += $pt.VX * $dt
            $pt.Y += $pt.VY * $dt
            $pt.VY += $pt.G * $dt
            $pt.VX *= 0.985
            [System.Windows.Controls.Canvas]::SetLeft($pt.El, $pt.X)
            [System.Windows.Controls.Canvas]::SetTop($pt.El, $pt.Y)
            $pt.El.Opacity = [Math]::Max(0.0, 1.0 - $tt * $tt)
            $s = $pt.S0 + ($pt.S1 - $pt.S0) * $tt
            $pt.Sc.ScaleX = $s
            $pt.Sc.ScaleY = $s
            $pt.Rot.Angle += $pt.Spin * $dt
        }
    }
}

function Step-Pet([double]$dt) {
    try { Update-Pet $dt }
    catch {
        $script:ErrorCount++
        Write-PetLog "Update 异常: $_ @ $($_.InvocationInfo.PositionMessage -replace '\s+', ' ')"
        if ($env:GEMINIPET_VERBOSE) { Write-Host "Update 异常: $_ @ $($_.InvocationInfo.PositionMessage)" }
        if ($script:ErrorCount -gt 40) { if ($script:Win) { $script:Win.Close() } }
    }
}

# ---------------------------------------------------------------- 预览模式
function Render-Preview([string]$path) {
    $holder = New-Object System.Windows.Controls.Border
    $holder.Width = 240; $holder.Height = 240
    if (-not $script:PreviewAlpha) {
        $holder.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color][System.Windows.Media.ColorConverter]::ConvertFromString('#FFF1F2F8'))
    }
    $holder.Child = $root
    $holder.Measure((New-Object System.Windows.Size(240, 240)))
    $holder.Arrange((New-Object System.Windows.Rect(0, 0, 240, 240)))
    $holder.UpdateLayout()
    $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(240, 240, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($holder)
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    [void]$enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $fs = [System.IO.File]::Create($path)
    try { $enc.Save($fs) } finally { $fs.Close() }
    $holder.Child = $null
}

if ($Preview) {
    Initialize-Dpi
    $script:Rng = New-Object System.Random 20240607
    $script:PreviewAlpha = $PreviewAlpha
    $dir = $Preview
    if (-not [System.IO.Path]::IsPathRooted($dir)) { $dir = Join-Path (Get-Location).Path $dir }
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    Write-Host "预览输出目录: $dir"

    $poses = @(
        @{ n = '01_idle'; step = 0.033; times = 4; act = {} },
        @{ n = '02_blink'; step = 0.033; times = 3; act = { $script:BlinkT = 0.07 } },
        @{ n = '03_wave'; step = 0.033; times = 22; act = { Start-Action 'wave' } },
        @{ n = '04_hop'; step = 0.033; times = 12; act = { Start-Action 'hop' } },
        @{ n = '05_spin'; step = 0.033; times = 14; act = { Start-Action 'spin' } },
        @{ n = '06_burst'; step = 0.033; times = 9; act = { Start-Action 'burst' } },
        @{ n = '07_pat'; step = 0.033; times = 5; act = { Invoke-Pat } },
        @{ n = '08_surprised'; step = 0.033; times = 3; act = { $script:ExprForce = 'surprised'; $script:ExprUntil = $script:T + 5 } },
        @{ n = '09_sleep'; step = 0.05; times = 42; act = { Enter-Sleep } },
        @{ n = '10_stretch'; step = 0.033; times = 17; act = { Start-Action 'stretch' } },
        @{ n = '11_look'; step = 0.033; times = 22; act = { Start-Action 'look' } },
        @{ n = '12_wander'; step = 0.033; times = 26; act = { Start-Action 'wander' } }
    )
    foreach ($pose in $poses) {
        Reset-PetState
        $script:T = 12.0
        $script:NextBlink = 999
        & $pose.act
        for ($i = 0; $i -lt $pose.times; $i++) { Step-Pet $pose.step }
        $out = Join-Path $dir ($pose.n + '.png')
        Render-Preview $out
        Write-Host ("  已渲染 {0}" -f $pose.n)
    }
    Write-Host '预览完成。'
    exit 0
}

# ---------------------------------------------------------------- 单实例
if (-not $AllowMultiple -and -not $SelfTest) {
    $created = $false
    $script:Mutex = New-Object System.Threading.Mutex($true, 'GeminiDesktopPet.SingleInstance', [ref]$created)
    if (-not $created) {
        Write-PetLog '已经有一只小宠物在运行了,本次启动退出。'
        exit 0
    }
}

# ---------------------------------------------------------------- 主窗口
Initialize-Dpi

$win = New-Object System.Windows.Window
$win.Title = 'Gemini Pet'
$win.WindowStyle = 'None'
$win.AllowsTransparency = $true
$win.Background = [System.Windows.Media.Brushes]::Transparent
$win.ShowInTaskbar = $false
$win.Topmost = $true
$win.ResizeMode = 'NoResize'
$win.SizeToContent = 'Manual'
$win.WindowStartupLocation = 'Manual'
$win.ShowActivated = $false
$win.UseLayoutRounding = $true
$win.SnapsToDevicePixels = $true
$win.Content = $root
$script:Win = $win

function Set-PetSize([double]$s) {
    $script:SizeFactor = $s
    $root.LayoutTransform = New-Object System.Windows.Media.ScaleTransform($s, $s)
    if ($Pet.CacheMode) { $Pet.CacheMode.RenderAtScale = [Math]::Max(1.0, $s) }
    $win.Width = 240 * $s
    $win.Height = 240 * $s
    $wa = [System.Windows.SystemParameters]::WorkArea
    if ($win.Left -lt $wa.Left - 40 -or $win.Left -gt $wa.Right) { $win.Left = $wa.Right - $win.Width - 36 }
    if ($win.Top -lt $wa.Top - 40 -or $win.Top -gt $wa.Bottom) { $win.Top = $wa.Bottom - $win.Height - 8 }
}
$script:SizeFactor = $Size

# 初始位置:右下角
$wa = [System.Windows.SystemParameters]::WorkArea
$win.Width = 240 * $Size
$win.Height = 240 * $Size
$win.Left = $wa.Right - $win.Width - 36
$win.Top = $wa.Bottom - $win.Height - 8
Set-PetSize $Size

# 不抢焦点
if (-not $ActivateOnClick) {
    $win.Add_SourceInitialized({
            try {
                $helper = New-Object System.Windows.Interop.WindowInteropHelper($win)
                $h = $helper.Handle
                $GWLEX = -20
                $ex = [GeminiPetNative.Win32]::GetWindowLong($h, $GWLEX)
                $ex = $ex -bor 0x08000000 -bor 0x00000080   # WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW
                [void][GeminiPetNative.Win32]::SetWindowLong($h, $GWLEX, $ex)
                Write-PetLog '已设置不抢焦点 (WS_EX_NOACTIVATE)'
            } catch { Write-PetLog "设置 NOACTIVATE 失败: $_" }
        })
}

# ---------------------------------------------------------------- 右键菜单
function New-MenuItem([string]$header, [scriptblock]$action) {
    $mi = New-Object System.Windows.Controls.MenuItem
    $mi.Header = $header
    $mi.Add_Click($action)
    return $mi
}
$menu = New-Object System.Windows.Controls.ContextMenu
$menu.FontFamily = New-Object System.Windows.Media.FontFamily('Microsoft YaHei UI')
$menu.FontSize = 13
[void]$menu.Items.Add((New-MenuItem '👋  打个招呼' { $script:IdleSince = $script:T; Wake-Pet; Start-Action 'wave'; $script:ExprForce = 'happy'; $script:ExprUntil = $script:T + 1.6 }))
[void]$menu.Items.Add((New-MenuItem '💗  摸摸头' { Invoke-Pat }))
[void]$menu.Items.Add((New-MenuItem '✨  放个烟花' { $script:IdleSince = $script:T; Wake-Pet; Start-Action 'burst' }))
[void]$menu.Items.Add((New-MenuItem '😴  去睡觉' { Enter-Sleep }))
[void]$menu.Items.Add((New-Object System.Windows.Controls.Separator))
$miSize = New-Object System.Windows.Controls.MenuItem
$miSize.Header = '大小'
foreach ($opt in @(@('小', 0.7), @('中', 1.0), @('大', 1.4))) {
    $sub = New-MenuItem $opt[0] ([scriptblock]::Create("Set-PetSize $($opt[1])"))
    [void]$miSize.Items.Add($sub)
}
[void]$menu.Items.Add($miSize)
[void]$menu.Items.Add((New-MenuItem '🎈  换个位置' { $script:IdleSince = $script:T; Start-Action 'wander' }))
[void]$menu.Items.Add((New-Object System.Windows.Controls.Separator))
[void]$menu.Items.Add((New-MenuItem '❌  退出' { $win.Close() }))
$root.ContextMenu = $menu

# ---------------------------------------------------------------- 鼠标交互
$script:Pressed = $false
$script:DragMoved = $false
$script:PressPos = @(0, 0)
$script:WinStart = @(0.0, 0.0)

$root.Add_MouseLeftButtonDown({
        $script:Pressed = $true
        $script:DragMoved = $false
        $script:PressPos = Get-CursorPoint
        $script:WinStart = @($win.Left, $win.Top)
        [void]$root.CaptureMouse()
        $script:IdleSince = $script:T
    })
$root.Add_MouseMove({
        if (-not $script:Pressed) { return }
        $p = Get-CursorPoint
        $dx = $p[0] - $script:PressPos[0]
        $dy = $p[1] - $script:PressPos[1]
        if (-not $script:DragMoved -and ([Math]::Abs($dx) + [Math]::Abs($dy)) -gt 5) {
            $script:DragMoved = $true
            if ($script:State -eq 'wander') { End-State }
        }
        if ($script:DragMoved) {
            # 鼠标坐标是物理像素,窗口坐标是 DIP,需要按 DPI 缩放换算
            $sc = 1.0
            try { $sc = [System.Windows.Media.VisualTreeHelper]::GetDpi($root).DpiScaleX } catch { }
            if ($sc -le 0) { $sc = 1.0 }
            $win.Left = $script:WinStart[0] + $dx / $sc
            $win.Top = $script:WinStart[1] + $dy / $sc
        }
    })
$root.Add_MouseLeftButtonUp({
        [void]$root.ReleaseMouseCapture()
        if ($script:Pressed -and -not $script:DragMoved) { Invoke-Pat }
        $script:Pressed = $false
        $script:IdleSince = $script:T
    })

# ---------------------------------------------------------------- 心跳
$script:Clock = [System.Diagnostics.Stopwatch]::StartNew()
$script:LastTick = 0.0
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(33)
$timer.Add_Tick({
        $now = $script:Clock.Elapsed.TotalSeconds
        $dt = $now - $script:LastTick
        $script:LastTick = $now
        if ($dt -le 0) { $dt = 0.033 }
        if ($dt -gt 0.25) { $dt = 0.25 }
        Step-Pet $dt
    })

# ---------------------------------------------------------------- 启动
$app = New-Object System.Windows.Application
$app.ShutdownMode = 'OnMainWindowClose'
$app.MainWindow = $win

$win.Add_Loaded({
        $script:Clock.Restart()
        $script:LastTick = 0.0
        $timer.Start()
        Write-PetLog '宠物已启动'
    })
$win.Add_Closed({
        $timer.Stop()
        Write-PetLog '宠物已退出'
    })

# 自检:按脚本跑一遍所有动作,便于验证不会出错
if ($SelfTest -gt 0) {
    $script:SelfTestLeft = [double]$SelfTest
    $script:SelfTestTick = 0.0
    $script:SelfTestStep = 0
    $script:SelfTestList = @('wave', 'hop', 'spin', 'look', 'burst', 'stretch', 'wander', 'pop')
    $stTimer = New-Object System.Windows.Threading.DispatcherTimer
    $stTimer.Interval = [TimeSpan]::FromMilliseconds(100)
    $stTimer.Add_Tick({
            $script:SelfTestLeft -= 0.1
            $script:SelfTestTick += 0.1
            if ($script:SelfTestTick -ge 1.6) {
                $script:SelfTestTick = 0.0
                $act = $script:SelfTestList[$script:SelfTestStep % $script:SelfTestList.Count]
                $script:SelfTestStep++
                if ($act -eq 'pop') { Invoke-Pat } else { Start-Action $act }
                if ($script:SelfTestStep -eq 3) { Invoke-Pat }
                if ($script:SelfTestStep -eq 6) { Enter-Sleep }
                if ($script:SelfTestStep -eq 7) { Wake-Pet }
                Write-PetLog "自检步骤 $($script:SelfTestStep): $act"
            }
            if ($script:SelfTestLeft -le 0) {
                $stTimer.Stop()
                Write-PetLog "自检结束, 异常次数=$($script:ErrorCount), 粒子残留=$($script:Particles.Count)"
                Write-Host "自检结束: 异常次数=$($script:ErrorCount)"
                $win.Close()
            }
        })
    $win.Add_Loaded({ $stTimer.Start() })
}

$win.Show()
[void]$app.Run()
Write-PetLog '进程结束'
