# =====================================================================
#  U 盘热插拔自动备份   —— 插上 U 盘就把工作区里的宠物同步过去
#  --------------------------------------------------------------------
#  纯 PowerShell 实现, 不需要 Python / 任何第三方工具。
#  用法:  powershell -NoProfile -ExecutionPolicy Bypass -File usb_backup.ps1
#         powershell ... -File usb_backup.ps1 -Once       # 只备份一次就退出
#         powershell ... -File usb_backup.ps1 -IntervalSec 3
#  说明:  每 5 秒看一眼有没有可移动磁盘; 一旦发现"新插入"的 U 盘, 就把本脚本所在
#         工作区里的所有宠物目录复制到 <U盘>\桌面小组件\ 下(用 robocopy /E, 不删除
#         U 盘上的其它文件)。日志写在 %TEMP%\USB备份.log。
#         想开机就监控: 把同目录的「启动U盘备份.vbs」快捷方式放进 shell:startup。
# =====================================================================
param(
    [int]$IntervalSec = 5,
    [switch]$Once
)

$ErrorActionPreference = 'Continue'
$logPath = Join-Path $env:TEMP 'USB备份.log'
function Write-UsbLog([string]$msg) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    try { Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8 } catch { }
    Write-Host $line
}

# 工作区 = tools\ 的上上级目录
$workRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

function Get-PetDirs {
    if (-not (Test-Path -LiteralPath $workRoot)) { return @() }
    return @(Get-ChildItem -LiteralPath $workRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'social.ps1') } |
        ForEach-Object { $_.FullName })
}

function Get-RemovableDrives {
    return @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=2' -ErrorAction SilentlyContinue |
        Where-Object { $_.Size -gt 0 } | ForEach-Object { $_.DeviceID })
}

function Invoke-UsbBackup([string]$drive) {
    $pets = Get-PetDirs
    if ($pets.Count -eq 0) { Write-UsbLog "工作区里没找到宠物目录: $workRoot"; return }
    $target = Join-Path ($drive + '\') '桌面小组件'
    Write-UsbLog "检测到 U 盘 $drive, 开始备份 $($pets.Count) 个宠物目录 -> $target"
    $total = 0
    foreach ($p in $pets) {
        $name = Split-Path $p -Leaf
        $dst = Join-Path $target $name
        # robocopy /E 复制(不删除 U 盘上已有的其它文件); 返回码 < 8 都算成功
        $null = robocopy $p $dst /E /NFL /NDL /NJH /NJS /NP /R:1 /W:1 2>&1
        if ($LASTEXITCODE -lt 8) {
            $n = (Get-ChildItem -LiteralPath $dst -Recurse -File -Force -ErrorAction SilentlyContinue).Count
            $total += $n
            Write-UsbLog ("  {0}: {1} 个文件 ✓" -f $name, $n)
        } else {
            Write-UsbLog ("  {0}: 复制失败(robocopy 返回 {1})" -f $name, $LASTEXITCODE)
        }
    }
    $info = @(
        "自动备份时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        "来源: $workRoot"
        "目标: $target"
        "宠物目录: $($pets.Count) 个, 共 $total 个文件"
        ""
        "玩法见同目录 使用说明.txt; 每个宠物目录都是一个完整的 git 仓库。"
    )
    try { [System.IO.File]::WriteAllLines((Join-Path $target '备份信息.txt'), $info, (New-Object System.Text.UTF8Encoding($true))) } catch { }
    Write-UsbLog "备份完成: $total 个文件"
}

$seen = @{}
Write-UsbLog "U 盘备份监控已启动 (工作区: $workRoot, 轮询 ${IntervalSec}s)"
while ($true) {
    $drives = Get-RemovableDrives
    foreach ($d in $drives) {
        if (-not $seen.ContainsKey($d)) {
            $seen[$d] = $true
            Invoke-UsbBackup $d
        }
    }
    foreach ($k in @($seen.Keys)) {
        if ($drives -notcontains $k) {
            $seen.Remove($k)
            Write-UsbLog "U 盘 $k 已拔出(下次插入会重新备份)"
        }
    }
    if ($Once) { break }
    Start-Sleep -Seconds $IntervalSec
}
