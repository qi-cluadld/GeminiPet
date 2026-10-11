# =====================================================================
#  三只桌宠联动模块  (Desktop Pets Interop / Social)
#  --------------------------------------------------------------------
#  通信:命名共享内存 'DesktopPets.Interop.v1', 3 个槽位(各 32 字节),
#        每只宠物只写自己的槽, 读别人的槽; 用 TickCount 判断对方是否还活着。
#        不需要服务进程, 谁在跑就自动跟谁联动(只跑一只时完全不触发)。
#  行为:见面打招呼 / 一直对视 / 时不时一起玩 / 远处偶尔去串门 / 挤在一起主动让位置
#
#  用法(每只宠物):
#     1) 脚本开头 dot-source:  . "$PSScriptRoot\social.ps1"
#     2) 先 Connect-PetSocial -SelfId 'gemini'|'deepseek'|'chatgpt' -Hooks <hashtable>
#     3) 每帧调用     Invoke-PetSocial -Dt $dt -Win $win
#     Hooks 里各宠物提供自己的动作/粒子实现:
#        Greet  {param($n)}      见面打招呼
#        Play   {param($n)}      一起玩
#        LookAt {param($x,$y)}   眼睛看向对方(x/y 是像素偏移)
#        MoveTo {param($x)}      移动到指定窗口左边位置
#        Busy   {}               返回 $true 表示正在做动作
#        Sleepy {}               返回 $true 表示睡着了
#  注意:三个仓库各有一份同样的本文件, 改动请同步三处。
# =====================================================================

try { Add-Type -AssemblyName System.IO.MemoryMappedFiles -ErrorAction Stop } catch { }

$script:PetSocialMmfName = 'DesktopPets.Interop.v1'
$script:PetSocialCapacity = 256
$script:PetSocialSlotSize = 32
$script:PetSocialIds = @{ 'gemini' = 0; 'deepseek' = 1; 'chatgpt' = 2 }
$script:PetSocialBitAlive = 1
$script:PetSocialBitPlay = 2
$script:PetSocialBitSleep = 4
$script:PetSocialBitBusy = 8
$script:PetSocialMaxAgeMs = 2500

function Connect-PetSocial {
    param([string]$SelfId, [hashtable]$Hooks)
    if (-not $script:PetSocialIds.ContainsKey($SelfId)) { Write-PetLog "联动: 未知宠物 id '$SelfId'"; return $false }
    try {
        $script:PetSocialMmf = [System.IO.MemoryMappedFiles.MemoryMappedFile]::CreateOrOpen($script:PetSocialMmfName, $script:PetSocialCapacity)
        $script:PetSocialAcc = $script:PetSocialMmf.CreateViewAccessor(0, $script:PetSocialCapacity)
    } catch { Write-PetLog "联动: 共享内存不可用($_)，本次不联动"; return $false }
    $script:PetSocialSelfId = $SelfId
    $script:PetSocialSelfIdx = $script:PetSocialIds[$SelfId]
    $script:PetSocialHooks = $Hooks
    $script:PetSocialReady = $true
    $script:PetSocialLastPub = -99.0
    $script:PetSocialDecT = -99.0
    $script:PetSocialNear = $false
    $script:PetSocialLastGreet = -99.0
    $script:PetSocialLastPlay = -99.0
    $script:PetSocialLastVisit = -99.0
    $script:PetSocialLastAside = -99.0
    $script:PetSocialPlaying = $false
    $script:PetSocialPlayUntil = -99.0
    $script:PetSocialLookX = 0.0
    $script:PetSocialLookY = 0.0
    $script:PetSocialTilt = 0.0
    $script:PetSocialSeen = @{}
    Write-PetLog "联动: 已连接(槽位 $($script:PetSocialSelfIdx))"
    return $true
}

function Publish-PetSocialState {
    param($Win, [int]$Flags, [double]$Now)
    if (-not $script:PetSocialAcc) { return }
    if (($Now - $script:PetSocialLastPub) -lt 0.12) { return }
    $script:PetSocialLastPub = $Now
    $b = $script:PetSocialSelfIdx * $script:PetSocialSlotSize
    try {
        $script:PetSocialAcc.Write($b + 0, [int][Math]::Round($Win.Left))
        $script:PetSocialAcc.Write($b + 4, [int][Math]::Round($Win.Top))
        $script:PetSocialAcc.Write($b + 8, [int][Math]::Round($Win.Width))
        $script:PetSocialAcc.Write($b + 12, [int][Math]::Round($Win.Height))
        $script:PetSocialAcc.Write($b + 16, $Flags)
        $script:PetSocialAcc.Write($b + 20, [int][Environment]::TickCount)
    } catch { }
}

function Get-PetSocialNeighbors {
    $list = @()
    if (-not $script:PetSocialAcc) { return $list }
    $now = [int][Environment]::TickCount
    foreach ($kv in $script:PetSocialIds.GetEnumerator()) {
        if ($kv.Value -eq $script:PetSocialSelfIdx) { continue }
        $b = $kv.Value * $script:PetSocialSlotSize
        try {
            $x = $script:PetSocialAcc.ReadInt32($b + 0)
            $y = $script:PetSocialAcc.ReadInt32($b + 4)
            $w = $script:PetSocialAcc.ReadInt32($b + 8)
            $h = $script:PetSocialAcc.ReadInt32($b + 12)
            $fl = $script:PetSocialAcc.ReadInt32($b + 16)
            $ts = $script:PetSocialAcc.ReadInt32($b + 20)
        } catch { continue }
        $age = [Math]::Abs($now - $ts)
        if ($age -gt $script:PetSocialMaxAgeMs -or $w -le 0 -or $h -le 0) { continue }
        $list += @{ Id = $kv.Key; X = $x; Y = $y; W = $w; H = $h; Flags = $fl; Age = $age }
    }
    return $list
}

function Invoke-PetSocial {
    param([double]$Dt, $Win, $Hooks)
    if (-not $script:PetSocialReady) { return }
    $now = $script:T
    $busy = [bool](& $Hooks.Busy)
    $sleepy = [bool](& $Hooks.Sleepy)
    $fl = $script:PetSocialBitAlive
    if ($script:PetSocialPlaying) { $fl = $fl -bor $script:PetSocialBitPlay }
    if ($sleepy) { $fl = $fl -bor $script:PetSocialBitSleep }
    if ($busy) { $fl = $fl -bor $script:PetSocialBitBusy }
    Publish-PetSocialState -Win $Win -Flags $fl -Now $now

    $ns = Get-PetSocialNeighbors
    if ($ns.Count -eq 0) {
        if ($script:PetSocialLookX -ne 0 -or $script:PetSocialLookY -ne 0 -or $script:PetSocialTilt -ne 0) {
            & $Hooks.LookAt 0 0
        }
        $script:PetSocialNear = $false
        return
    }
    # 找最近的一只
    $meX = $Win.Left + $Win.Width / 2.0
    $meY = $Win.Top + $Win.Height / 2.0
    $n = $null; $bestD = 1e9
    foreach ($c in $ns) {
        $cx = $c.X + $c.W / 2.0; $cy = $c.Y + $c.H / 2.0
        $d = [Math]::Sqrt(($cx - $meX) * ($cx - $meX) + ($cy - $meY) * ($cy - $meY))
        if ($d -lt $bestD) { $bestD = $d; $n = $c }
    }
    $ncx = $n.X + $n.W / 2.0; $ncy = $n.Y + $n.H / 2.0
    $dx = $ncx - $meX; $dy = $ncy - $meY
    $len = [Math]::Max(1.0, [Math]::Sqrt($dx * $dx + $dy * $dy))
    # 一直对视(除非在忙)
    if (-not $busy -and -not $sleepy) {
        & $Hooks.LookAt ([Math]::Max(-7.0, [Math]::Min(7.0, $dx / $len * 7.0))) ([Math]::Max(-5.0, [Math]::Min(5.0, $dy / $len * 5.0)))
    }
    $nearLimit = [Math]::Max($Win.Width, $Win.Height) * 1.25
    $near = $bestD -lt $nearLimit

    # 决策节流
    if (($now - $script:PetSocialDecT) -lt 0.25) { return }
    $script:PetSocialDecT = $now
    $theyPlay = ($n.Flags -band $script:PetSocialBitPlay) -ne 0

    # 对方在玩 -> 我也跟着玩
    if ($theyPlay -and -not $busy -and -not $sleepy -and ($now - $script:PetSocialLastPlay) -gt 6) {
        $script:PetSocialLastPlay = $now
        $script:PetSocialPlaying = $true
        $script:PetSocialPlayUntil = $now + 1.8
        & $Hooks.Play $n
        Write-PetLog "联动: 跟着 $($n.Id) 一起玩"
        return
    }
    if ($script:PetSocialPlaying -and $now -gt $script:PetSocialPlayUntil) { $script:PetSocialPlaying = $false }

    # 由远变近 -> 打招呼
    if ($near -and -not $script:PetSocialNear) {
        $script:PetSocialNear = $true
        if (($now - $script:PetSocialLastGreet) -gt 9) {
            $script:PetSocialLastGreet = $now
            $script:PetSocialLastPlay = $now - 26.0     # 打完招呼很快就能一起玩
            & $Hooks.Greet $n
            Write-PetLog "联动: 跟 $($n.Id) 打招呼(距离 $([int]$bestD)px)"
            return
        }
    } elseif (-not $near) {
        $script:PetSocialNear = $false
    }

    if ($busy -or $sleepy) { return }

    if ($near) {
        # 挤成一坨 -> 主动让开一点
        if ($bestD -lt ([Math]::Max($Win.Width, $Win.Height) * 0.62) -and ($now - $script:PetSocialLastAside) -gt 22) {
            $script:PetSocialLastAside = $now
            $side = if ($meX -lt $ncx) { -1.0 } else { 1.0 }
            & $Hooks.MoveTo ($Win.Left + $side * $Win.Width * 1.05)
            Write-PetLog "联动: 给 $($n.Id) 让个位置"
            return
        }
        # 时不时一起玩
        if (-not $script:PetSocialPlaying -and ($now - $script:PetSocialLastPlay) -gt 30 -and $script:Rng.NextDouble() -lt 0.10) {
            $script:PetSocialLastPlay = $now
            $script:PetSocialPlaying = $true
            $script:PetSocialPlayUntil = $now + 1.8
            & $Hooks.Play $n
            Write-PetLog "联动: 和 $($n.Id) 一起玩"
            return
        }
    } else {
        # 离得远 -> 偶尔去串门
        if (($now - $script:PetSocialLastVisit) -gt 70 -and $script:Rng.NextDouble() -lt 0.06) {
            $script:PetSocialLastVisit = $now
            $side = if ($meX -lt $ncx) { 1.0 } else { -1.0 }
            $tgt = $ncx - $Win.Width / 2.0 + $side * $Win.Width * 0.62
            & $Hooks.MoveTo $tgt
            Write-PetLog "联动: 去 $($n.Id) 那边串门"
            return
        }
    }
}
