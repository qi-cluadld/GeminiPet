# =====================================================================
#  三只桌宠联动模块  v2  (Desktop Pets Interop / Social)
#  --------------------------------------------------------------------
#  通信:命名共享内存 'DesktopPets.Interop.v2', 3 个槽位(各 48 字节)。
#        每只宠物只写自己的槽、读别人的槽, 用 TickCount 判断对方是否还活着。
#        不需要服务进程; 谁在跑就跟谁联动, 一只在跑时完全不触发。
#
#  能力:
#    * 见面打招呼(爱心/开心脸) + 真·对话(一句一句轮流说, 有来有回)
#    * 一直对视; 待在一起会自动排排站(对齐高度)
#    * 一起玩(动作同步) / 传爱心(一方送、一方接) / 追逐(跑了就追, 追到一起玩)
#    * 远处偶尔串门; 挤成一坨主动让位; 跑出屏幕自动拉回
#
#  台词表:同目录 lines.json(不存在就用脚本内默认值)。{me}/{you} 会替换成名字。
#
#  用法(每只宠物):
#     1) 脚本开头 dot-source:  . "$PSScriptRoot\social.ps1"
#     2) Connect-PetSocial -SelfId 'gemini'|'deepseek'|'chatgpt' -Hooks <hashtable> -LinesPath <lines.json>
#     3) 每帧 Invoke-PetSocial -Dt $dt -Win $win
#     Hooks: Greet Play LookAt MoveTo Gift Busy Sleepy StopMove Say HideSay Lines
#  注意:三个仓库各有一份同样的本文件, 改动请同步三处。
# =====================================================================

try { Add-Type -AssemblyName System.IO.MemoryMappedFiles -ErrorAction Stop } catch { }

$script:PetSocialMmfName = 'DesktopPets.Interop.v2'
$script:PetSocialCapacity = 256
$script:PetSocialSlotSize = 48
$script:PetSocialIds = @{ 'gemini' = 0; 'deepseek' = 1; 'chatgpt' = 2 }
$script:PetSocialNames = @{ 'gemini' = '小星星'; 'deepseek' = '小鲸鱼'; 'chatgpt' = '小花' }
$script:PetSocialBitAlive = 1
$script:PetSocialBitPlay = 2
$script:PetSocialBitSleep = 4
$script:PetSocialBitBusy = 8
$script:PetSocialBitChase = 16
$script:PetSocialMaxAgeMs = 2500
# 对话台词类型
$script:PetSocialTalkNone = 0
$script:PetSocialTalkHello = 1
$script:PetSocialTalkHelloReply = 2
$script:PetSocialTalkFollow = 3
$script:PetSocialTalkFollowReply = 4
$script:PetSocialTalkBye = 5
$script:PetSocialTalkGift = 6
$script:PetSocialTalkGiftReply = 7
$script:PetSocialTalkChase = 8
$script:PetSocialTalkCatch = 9

# ---------------------------------------------------------------- 台词表(外置 lines.json)
function Import-PetSocialLines {
    param([hashtable]$Defaults, [string]$JsonPath)
    $lines = @{}
    if ($Defaults) { foreach ($k in $Defaults.Keys) { $lines[$k] = @($Defaults[$k]) } }
    $customName = $null
    if ($JsonPath -and (Test-Path -LiteralPath $JsonPath)) {
        try {
            $obj = (Get-Content -LiteralPath $JsonPath -Raw -Encoding UTF8) | ConvertFrom-Json
            if ($obj.name) { $customName = [string]$obj.name }
            if ($obj.lines) {
                foreach ($p in $obj.lines.PSObject.Properties) {
                    $arr = @($p.Value | ForEach-Object { [string]$_ } | Where-Object { $_ -ne '' })
                    if ($arr.Count -gt 0) { $lines[$p.Name] = $arr }
                }
            }
            Write-PetLog "联动: 已载入外置台词表 $(Split-Path -Leaf $JsonPath)"
        } catch { Write-PetLog "联动: 台词表读取失败($_)，改用内置台词" }
    }
    $script:PetSocialLines = $lines
    if ($customName) { $script:PetSocialNames[$script:PetSocialSelfId] = $customName }
    return $lines
}

function Get-PetSocialLine {
    param([string]$Kind, [string]$ToId)
    if (-not $script:PetSocialLines -or -not $script:PetSocialLines.ContainsKey($Kind)) { return $null }
    $arr = @($script:PetSocialLines[$Kind])
    if ($arr.Count -eq 0) { return $null }
    $txt = [string]$arr[$script:Rng.Next(0, $arr.Count)]
    $meName = $script:PetSocialNames[$script:PetSocialSelfId]
    $youName = if ($ToId -and $script:PetSocialNames.ContainsKey($ToId)) { $script:PetSocialNames[$ToId] } else { '你' }
    return $txt.Replace('{me}', $meName).Replace('{you}', $youName)
}

# ---------------------------------------------------------------- 连接
function Connect-PetSocial {
    param([string]$SelfId, [hashtable]$Hooks, [string]$LinesPath)
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
    $script:PetSocialLastGift = -99.0
    $script:PetSocialLastChase = -99.0
    $script:PetSocialPlaying = $false
    $script:PetSocialPlayUntil = -99.0
    $script:PetSocialChasing = $false
    $script:PetSocialChaseUntil = -99.0
    $script:PetSocialGiftUntil = -99.0
    $script:PetSocialLookX = 0.0
    $script:PetSocialLookY = 0.0
    $script:PetSocialTilt = 0.0
    $script:PetSocialSayUntil = -1.0
    $script:PetSocialNextChatter = 45.0
    $script:PetSocialTalkSeq = 0
    $script:PetSocialTalkKind = $script:PetSocialTalkNone
    $script:PetSocialTalkTo = -1
    $script:PetSocialTalkStamp = 0
    $script:PetSocialSeenSeq = @{ 0 = 0; 1 = 0; 2 = 0 }
    $script:PetSocialConvo = $null
    $script:PetSocialConvoUntil = -99.0
    $script:PetSocialPending = $null
    $script:PetSocialLastConvo = -99.0
    Import-PetSocialLines -Defaults $Hooks.Lines -JsonPath $LinesPath | Out-Null
    Write-PetLog "联动: 已连接 v2(槽位 $($script:PetSocialSelfIdx), 名字 $($script:PetSocialNames[$SelfId]))"
    return $true
}

# ---------------------------------------------------------------- 收发状态
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
        $script:PetSocialAcc.Write($b + 24, $script:PetSocialTalkKind)
        $script:PetSocialAcc.Write($b + 28, $script:PetSocialTalkSeq)
        $script:PetSocialAcc.Write($b + 32, $script:PetSocialTalkTo)
        $script:PetSocialAcc.Write($b + 36, $script:PetSocialTalkStamp)
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
            $tk = $script:PetSocialAcc.ReadInt32($b + 24)
            $tq = $script:PetSocialAcc.ReadInt32($b + 28)
            $tt = $script:PetSocialAcc.ReadInt32($b + 32)
            $tst = $script:PetSocialAcc.ReadInt32($b + 36)
        } catch { continue }
        if ([Math]::Abs($now - $ts) -gt $script:PetSocialMaxAgeMs -or $w -le 0 -or $h -le 0) { continue }
        $list += @{
            Id = $kv.Key; Index = $kv.Value; X = $x; Y = $y; W = $w; H = $h; Flags = $fl
            Age = [Math]::Abs($now - $ts); TalkKind = $tk; TalkSeq = $tq; TalkTo = $tt
            TalkStamp = $tst; TalkAge = [Math]::Abs($now - $tst)
        }
    }
    return $list
}

# ---------------------------------------------------------------- 说话 / 气泡
function Say-PetThing {
    param([string]$Text, [double]$Seconds = 2.6)
    if (-not $script:PetSocialReady -or -not $Text) { return }
    if ($script:T -lt $script:PetSocialSayUntil) { return }
    $script:PetSocialSayUntil = $script:T + $Seconds
    try { & $script:PetSocialHooks.Say $Text } catch { }
}
function Update-PetSayState {
    if (-not $script:PetSocialReady) { return }
    if ($script:PetSocialSayUntil -gt 0 -and $script:T -gt $script:PetSocialSayUntil) {
        $script:PetSocialSayUntil = -1.0
        try { & $script:PetSocialHooks.HideSay } catch { }
    }
}
# 说一句"对话台词"并写进共享内存, 让同伴知道我说了哪一类
function Say-PetSocialTalk {
    param([string]$Kind, [string]$ToId, [int]$KindCode, [double]$Seconds = 2.6)
    $txt = Get-PetSocialLine -Kind $Kind -ToId $ToId
    if (-not $txt) { return $false }
    $script:PetSocialTalkSeq++
    $script:PetSocialTalkKind = $KindCode
    $script:PetSocialTalkTo = if ($ToId -and $script:PetSocialIds.ContainsKey($ToId)) { $script:PetSocialIds[$ToId] } else { -1 }
    $script:PetSocialTalkStamp = [int][Environment]::TickCount
    Say-PetThing $txt $Seconds
    return $true
}

# ---------------------------------------------------------------- 对话协议
function Start-PetSocialConvo {
    param($N, [double]$Now)
    $script:PetSocialLastConvo = $Now
    $script:PetSocialConvo = @{ With = $N.Id; Stage = 'hello'; At = $Now + 1.6 }
    $script:PetSocialConvoUntil = $Now + 9.0
    Say-PetSocialTalk -Kind 'Hello' -ToId $N.Id -KindCode $script:PetSocialTalkHello 2.8 | Out-Null
    Write-PetLog "对话: 我先跟 $($N.Id) 开口"
}
function Update-PetSocialTalk {
    param($N, [double]$Now)
    # 1) 我欠人家一句回复
    if ($script:PetSocialPending -and $Now -ge $script:PetSocialPending.At) {
        $p = $script:PetSocialPending
        $script:PetSocialPending = $null
        Say-PetSocialTalk -Kind $p.KindName -ToId $p.To -KindCode $p.KindCode 2.6 | Out-Null
        Write-PetLog "对话: 回了 $($p.KindName) 给 $($p.To)"
        if ($p.KindName -eq 'HelloReply' -and -not $script:PetSocialConvo) {
            $script:PetSocialConvo = @{ With = $p.To; Stage = 'replied'; At = $Now + 3.5 }
            $script:PetSocialConvoUntil = $Now + 9.0
        }
        return $true
    }
    # 2) 同伴刚对我说话
    if ($N -and $N.TalkTo -eq $script:PetSocialSelfIdx -and $N.TalkSeq -gt 0 -and $N.TalkAge -lt 2200) {
        $seen = 0
        if ($script:PetSocialSeenSeq.ContainsKey($N.Index)) { $seen = $script:PetSocialSeenSeq[$N.Index] }
        if ($N.TalkSeq -gt $seen) {
            $script:PetSocialSeenSeq[$N.Index] = $N.TalkSeq
            switch ($N.TalkKind) {
                $script:PetSocialTalkHello {
                    $script:PetSocialPending = @{ To = $N.Id; Kind = $script:PetSocialTalkHelloReply; KindName = 'HelloReply'; At = $Now + (Rand 0.4 1.1) }
                }
                $script:PetSocialTalkFollow {
                    $script:PetSocialPending = @{ To = $N.Id; Kind = $script:PetSocialTalkFollowReply; KindName = 'FollowReply'; At = $Now + (Rand 0.4 1.1) }
                }
                $script:PetSocialTalkBye {
                    if ($script:Rng.NextDouble() -lt 0.6) {
                        $script:PetSocialPending = @{ To = $N.Id; Kind = $script:PetSocialTalkBye; KindName = 'Bye'; At = $Now + (Rand 0.3 0.9) }
                    }
                    $script:PetSocialConvo = $null
                }
                $script:PetSocialTalkGift {
                    if ($Now -gt $script:PetSocialGiftUntil) {
                        $script:PetSocialGiftUntil = $Now + 3.0
                        if ($script:PetSocialHooks.Gift) { try { & $script:PetSocialHooks.Gift $N } catch { } }
                        $script:PetSocialPending = @{ To = $N.Id; Kind = $script:PetSocialTalkGiftReply; KindName = 'GiftReply'; At = $Now + (Rand 0.5 1.3) }
                        Write-PetLog "对话: 收到 $($N.Id) 送的小心心"
                    }
                }
                $script:PetSocialTalkChase {
                    if ($script:Rng.NextDouble() -lt 0.45) {
                        $side = if ($script:PetSocialWin.Left -lt $N.X) { 1.0 } else { -1.0 }
                        $tgt = Get-PetSocialTargetX -Win $script:PetSocialWin -X ($script:PetSocialWin.Left + $side * $script:PetSocialWin.Width * 1.8)
                        if ($script:PetSocialHooks.MoveTo) { & $script:PetSocialHooks.MoveTo $tgt }
                        Write-PetLog "对话: $($N.Id) 来追我, 快跑!"
                    } else {
                        $script:PetSocialPending = @{ To = $N.Id; Kind = $script:PetSocialTalkCatch; KindName = 'Chase'; At = $Now + 0.7 }
                    }
                }
            }
            return $true
        }
    }
    # 3) 我发起的对话: 等对方回话, 再决定接一句还是道别
    if ($script:PetSocialConvo) {
        $c = $script:PetSocialConvo
        $partner = $null
        foreach ($x in (Get-PetSocialNeighbors)) { if ($x.Id -eq $c.With) { $partner = $x } }
        if (-not $partner) { $script:PetSocialConvo = $null; return $false }
        $pSeen = 0
        if ($script:PetSocialSeenSeq.ContainsKey($partner.Index)) { $pSeen = $script:PetSocialSeenSeq[$partner.Index] }
        if ($partner.TalkSeq -gt $pSeen -and $partner.TalkAge -lt 2500) {
            $script:PetSocialSeenSeq[$partner.Index] = $partner.TalkSeq
            if ($partner.TalkKind -eq $script:PetSocialTalkHelloReply -and $c.Stage -eq 'hello') {
                $script:PetSocialConvo = @{ With = $c.With; Stage = 'waitFollowReply'; At = $Now + (Rand 0.8 1.6) }
                return $true
            }
            if ($partner.TalkKind -eq $script:PetSocialTalkFollowReply -and $c.Stage -eq 'waitFollowReply') {
                $script:PetSocialConvo = @{ With = $c.With; Stage = 'bye'; At = $Now + (Rand 0.7 1.3) }
                return $true
            }
        }
        if ($Now -ge $c.At) {
            switch ($c.Stage) {
                'hello' { $script:PetSocialConvo = $null }        # 对方没回, 算了
                'waitFollowReply' {
                    if ($script:Rng.NextDouble() -lt 0.75) {
                        Say-PetSocialTalk -Kind 'Follow' -ToId $c.With -KindCode $script:PetSocialTalkFollow 2.6 | Out-Null
                        Write-PetLog "对话: 又跟 $($c.With) 聊了一句"
                        $script:PetSocialConvo = @{ With = $c.With; Stage = 'awaitFollowReply'; At = $Now + 2.2 }
                    } else {
                        Say-PetSocialTalk -Kind 'Bye' -ToId $c.With -KindCode $script:PetSocialTalkBye 2.2 | Out-Null
                        Write-PetLog "对话: 跟 $($c.With) 道别"
                        $script:PetSocialConvo = $null
                    }
                }
                'awaitFollowReply' {
                    Say-PetSocialTalk -Kind 'Bye' -ToId $c.With -KindCode $script:PetSocialTalkBye 2.2 | Out-Null
                    Write-PetLog "对话: 跟 $($c.With) 道别"
                    $script:PetSocialConvo = $null
                }
                default { $script:PetSocialConvo = $null }
            }
        }
    }
    return $false
}

# ---------------------------------------------------------------- 边界保护
function Get-PetSocialTargetX {
    param($Win, [double]$X)
    $wa = [System.Windows.SystemParameters]::WorkArea
    $minX = $wa.Left + 8.0
    $maxX = $wa.Right - $Win.Width - 8.0
    if ($maxX -lt $minX) { return $Win.Left }
    return [Math]::Max($minX, [Math]::Min($maxX, $X))
}
function Protect-PetOnScreen {
    param($Win, $Hooks)
    $wa = [System.Windows.SystemParameters]::WorkArea
    $cx = $Win.Left + $Win.Width / 2.0
    $cy = $Win.Top + $Win.Height / 2.0
    if ($cx -ge $wa.Left -and $cx -le $wa.Right -and $cy -ge $wa.Top -and $cy -le $wa.Bottom) { return $false }
    try { & $Hooks.StopMove } catch { }
    if ($cx -lt $wa.Left) { $Win.Left = $wa.Left + 6.0 }
    elseif ($cx -gt $wa.Right) { $Win.Left = $wa.Right - $Win.Width - 6.0 }
    if ($cy -lt $wa.Top) { $Win.Top = $wa.Top + 6.0 }
    elseif ($cy -gt $wa.Bottom) { $Win.Top = $wa.Bottom - $Win.Height - 6.0 }
    Write-PetLog "边界保护: 自己跑出桌面了, 已自动拉回"
    return $true
}

# ---------------------------------------------------------------- 主循环
function Invoke-PetSocial {
    param([double]$Dt, $Win, $Hooks)
    if (-not $script:PetSocialReady) { return }
    $now = $script:T
    $script:PetSocialWin = $Win
    Protect-PetOnScreen -Win $Win -Hooks $Hooks | Out-Null
    Update-PetSayState
    $busy = [bool](& $Hooks.Busy)
    $sleepy = [bool](& $Hooks.Sleepy)
    $fl = $script:PetSocialBitAlive
    if ($script:PetSocialPlaying) { $fl = $fl -bor $script:PetSocialBitPlay }
    if ($sleepy) { $fl = $fl -bor $script:PetSocialBitSleep }
    if ($busy) { $fl = $fl -bor $script:PetSocialBitBusy }
    if ($script:PetSocialChasing) { $fl = $fl -bor $script:PetSocialBitChase }
    Publish-PetSocialState -Win $Win -Flags $fl -Now $now

    $ns = Get-PetSocialNeighbors
    if ($ns.Count -eq 0) {
        if ($script:PetSocialLookX -ne 0 -or $script:PetSocialLookY -ne 0 -or $script:PetSocialTilt -ne 0) { & $Hooks.LookAt 0 0 }
        $script:PetSocialNear = $false
        return
    }
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
    if (-not $busy -and -not $sleepy) {
        & $Hooks.LookAt ([Math]::Max(-7.0, [Math]::Min(7.0, $dx / $len * 7.0))) ([Math]::Max(-5.0, [Math]::Min(5.0, $dy / $len * 5.0)))
    }
    $nearLimit = [Math]::Max($Win.Width, $Win.Height) * 1.25
    $near = $bestD -lt $nearLimit

    # 排排站: 挨着时慢慢对齐高度
    if ($near -and -not $busy -and -not $sleepy) {
        $dyTop = $n.Y - $Win.Top
        if ([Math]::Abs($dyTop) -gt 18) {
            $Win.Top = $Win.Top + [Math]::Sign($dyTop) * [Math]::Min([Math]::Abs($dyTop), 90.0 * $Dt)
        }
    }

    if (($now - $script:PetSocialDecT) -lt 0.22) { return }
    $script:PetSocialDecT = $now
    $theyPlay = ($n.Flags -band $script:PetSocialBitPlay) -ne 0

    if (Update-PetSocialTalk -N $n -Now $now) { return }

    if ($theyPlay -and -not $busy -and -not $sleepy -and ($now - $script:PetSocialLastPlay) -gt 6) {
        $script:PetSocialLastPlay = $now
        $script:PetSocialPlaying = $true
        $script:PetSocialPlayUntil = $now + 1.8
        & $Hooks.Play $n
        Say-PetSocialTalk -Kind 'Play' -ToId $n.Id -KindCode $script:PetSocialTalkNone 2.4 | Out-Null
        Write-PetLog "联动: 跟着 $($n.Id) 一起玩"
        return
    }
    if ($script:PetSocialPlaying -and $now -gt $script:PetSocialPlayUntil) { $script:PetSocialPlaying = $false }

    if ($near -and -not $script:PetSocialNear) {
        $script:PetSocialNear = $true
        if (($now - $script:PetSocialLastGreet) -gt 9) {
            $script:PetSocialLastGreet = $now
            $script:PetSocialLastPlay = $now - 26.0
            & $Hooks.Greet $n
            if ($now -gt ($script:PetSocialLastConvo + 45)) { Start-PetSocialConvo -N $n -Now $now }
            else { Say-PetSocialTalk -Kind 'Greet' -ToId $n.Id -KindCode $script:PetSocialTalkNone 2.8 | Out-Null }
            Write-PetLog "联动: 跟 $($n.Id) 打招呼(距离 $([int]$bestD)px)"
            return
        }
    } elseif (-not $near) {
        $script:PetSocialNear = $false
    }

    if ($busy -or $sleepy) { return }
    if ($script:PetSocialConvo) { return }

    if ($near) {
        if ($bestD -lt ([Math]::Max($Win.Width, $Win.Height) * 0.62) -and ($now - $script:PetSocialLastAside) -gt 22) {
            $script:PetSocialLastAside = $now
            $side = if ($meX -lt $ncx) { -1.0 } else { 1.0 }
            & $Hooks.MoveTo (Get-PetSocialTargetX -Win $Win -X ($Win.Left + $side * $Win.Width * 1.05))
            Write-PetLog "联动: 给 $($n.Id) 让个位置"
            return
        }
        if (($now - $script:PetSocialLastGift) -gt 40 -and $script:Rng.NextDouble() -lt 0.09) {
            $script:PetSocialLastGift = $now
            if ($Hooks.Gift) { try { & $Hooks.Gift $n } catch { } }
            Say-PetSocialTalk -Kind 'Gift' -ToId $n.Id -KindCode $script:PetSocialTalkGift 2.6 | Out-Null
            Write-PetLog "联动: 送了 $($n.Id) 一颗小心心"
            return
        }
        if (-not $script:PetSocialPlaying -and ($now - $script:PetSocialLastPlay) -gt 30 -and $script:Rng.NextDouble() -lt 0.10) {
            $script:PetSocialLastPlay = $now
            $script:PetSocialPlaying = $true
            $script:PetSocialPlayUntil = $now + 1.8
            & $Hooks.Play $n
            Say-PetSocialTalk -Kind 'Play' -ToId $n.Id -KindCode $script:PetSocialTalkNone 2.4 | Out-Null
            Write-PetLog "联动: 和 $($n.Id) 一起玩"
            return
        }
    } else {
        if ($bestD -lt ([Math]::Max($Win.Width, $Win.Height) * 2.6) -and ($now - $script:PetSocialLastChase) -gt 55 -and $script:Rng.NextDouble() -lt 0.07) {
            $script:PetSocialLastChase = $now
            $script:PetSocialChasing = $true
            $script:PetSocialChaseUntil = $now + 4.0
            & $Hooks.MoveTo (Get-PetSocialTargetX -Win $Win -X ($ncx - $Win.Width / 2.0))
            Say-PetSocialTalk -Kind 'Chase' -ToId $n.Id -KindCode $script:PetSocialTalkChase 2.2 | Out-Null
            Write-PetLog "联动: 去追 $($n.Id)"
            return
        }
        if (($now - $script:PetSocialLastVisit) -gt 70 -and $script:Rng.NextDouble() -lt 0.06) {
            $script:PetSocialLastVisit = $now
            $side = if ($meX -lt $ncx) { 1.0 } else { -1.0 }
            $tgt = $ncx - $Win.Width / 2.0 + $side * $Win.Width * 0.62
            & $Hooks.MoveTo (Get-PetSocialTargetX -Win $Win -X $tgt)
            Say-PetSocialTalk -Kind 'Visit' -ToId $n.Id -KindCode $script:PetSocialTalkNone 2.6 | Out-Null
            Write-PetLog "联动: 去 $($n.Id) 那边串门"
            return
        }
        if (-not $sleepy -and $now -gt $script:PetSocialNextChatter) {
            $script:PetSocialNextChatter = $now + (Rand 50 120)
            Say-PetSocialTalk -Kind 'Idle' -ToId $null -KindCode $script:PetSocialTalkNone 2.4 | Out-Null
        }
    }
    if ($script:PetSocialChasing) {
        if ($now -gt $script:PetSocialChaseUntil -or $bestD -lt ([Math]::Max($Win.Width, $Win.Height) * 0.75)) {
            $script:PetSocialChasing = $false
            if ($bestD -lt ([Math]::Max($Win.Width, $Win.Height) * 0.75)) {
                $script:PetSocialLastPlay = $now
                $script:PetSocialPlaying = $true
                $script:PetSocialPlayUntil = $now + 1.8
                & $Hooks.Play $n
                Say-PetSocialTalk -Kind 'Chase' -ToId $n.Id -KindCode $script:PetSocialTalkCatch 2.4 | Out-Null
                Write-PetLog "联动: 追到 $($n.Id) 啦, 一起玩"
            }
        }
    }
}
