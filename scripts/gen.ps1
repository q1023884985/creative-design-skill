# gen.ps1 — AI 生图（线上版）PowerShell 版
# 与 gen.py 行为对齐：同一套服务端接口、同一个 ~/.creative-design 目录。
# 目的：买家机器上零安装（PowerShell 是 Windows 自带），不需要装 Python。
#
# ⚠️ 本文件必须以 UTF-8 with BOM 保存：PowerShell 5.1 读无 BOM 的 UTF-8 会按 GBK 解码，
#    中文字符串会变乱码甚至语法报错。
#
#Requires -Version 5.1

$ErrorActionPreference = 'Continue'
$script:loadRetried = $false   # 负载类错误只自动重试一次（2026-10-20）
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# 输出统一 UTF-8：买家的 AI 助手按 UTF-8 读 stdout，而 PS 5.1 默认按 gb2312 输出 →
# 助手看到的全是乱码（本机实测）。设为 UTF-8 后控制台与管道都正确。
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# ── 常量（与 gen.py 保持一致）─────────────────────────────────────────────
$DEFAULT_MODEL = 'gpt-image-2.5'   # 静态兜底模型名（模型可传；正常值来自服务端 /auth/login 下发）
$WORKER = $env:CD_VERIFY_URL
if ([string]::IsNullOrWhiteSpace($WORKER)) { $WORKER = 'https://verify.evomindd.top' }
$WORKER = $WORKER.TrimEnd('/')
$GEN_URL = $WORKER + '/gen'
$PAY_URL = $WORKER + '/pay'
$GUIDE_URL = $WORKER + '/guide'   # 图文使用说明书（2026-10-27 上线，脚本直接把它打出来）
$CRED_DIR = Join-Path $env:USERPROFILE '.creative-design'
$CRED_PATH = Join-Path $CRED_DIR 'license.json'
$PENDING_PATH = Join-Path $CRED_DIR 'pending.json'
$VERSION_URL = $WORKER + '/skill/version'
# 技能根目录 = scripts 的上一级（不写死路径，买家装在哪儿都能自更新）
$SKILL_ROOT = Split-Path -Parent $PSScriptRoot
$SKILL_MD = Join-Path $SKILL_ROOT 'SKILL.md'
$UPDATE_CHECK_PATH = Join-Path $CRED_DIR 'update-check.json'

$GEN_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

$NET_TRIES = 5
$NET_BACKOFF = @(2, 4, 8, 15, 30)

$SIZE_HINTS = @{
  '1024x1536' = '画面宽 1024 像素、高 1536 像素，竖版构图，高大于宽'
  '1024x1024' = '画面宽 1024 像素、高 1024 像素，正方形构图'
  '1536x1024' = '画面宽 1536 像素、高 1024 像素，横版构图，宽大于高'
  '1024x2048' = '画面宽 1024 像素、高 2048 像素，长条竖版构图，高是宽的两倍'
  '2048x2048' = '画面宽 2048 像素、高 2048 像素，正方形构图'
}

# ── 输出 / 退出 ──────────────────────────────────────────────────────────
function Say([string]$m) { [Console]::Out.WriteLine($m) }

function Die([string]$msg, [int]$code = 1) {
  [Console]::Error.WriteLine("")
  [Console]::Error.WriteLine("[错误] $msg")
  [Console]::Error.WriteLine("")
  exit $code
}

function Die-Nolimit($r) {
  $pay = $r.pay
  if ([string]::IsNullOrWhiteSpace($pay)) { $pay = $PAY_URL + '?key=' + [string]$r.key }
  $free = 0
  if ($null -ne $r.free) { $free = [int]$r.free }
  $credits = 0
  if ($null -ne $r.credits) { $credits = [int]$r.credits }
  $have = $credits + $free
  $extra = ''
  if ($free -gt 0) { $extra = "（其中今日免费 $free）" }
  $trial = ''
  if ($r.trialUsedToday) { $trial = '，今日免费额度已用完' }
  $need = '?'
  if ($null -ne $r.need) { $need = [string]$r.need }
  [Console]::Error.WriteLine("")
  [Console]::Error.WriteLine("[提示] 这次要 $need 积分，你的账号还剩 $have 积分$extra$trial，先充值再跑。")
  [Console]::Error.WriteLine("       打开这个链接充值（key 已自动填好，填个金额付款就行）：")
  [Console]::Error.WriteLine("       $pay")
  [Console]::Error.WriteLine("       付完款回来重新跑一次刚才的命令。")
  [Console]::Error.WriteLine("")
  exit 2
}

# 说明书入口（2026-10-27 买家实测）：原来「注册后推使用说明」只写在 SKILL.md 里，
# 而走 --login / --save-key 的人根本不经过 --complete，于是整个会话拿不到任何入口。
# 现在由脚本在三个成功出口的**最后一行**打印，模型只要把这一行转述给用户。
function Show-Guide {
  Say ""
  Say "[使用说明] 第一次用可以先看这份图文说明（点开看，图多，手机上也能看）："
  Say "           $GUIDE_URL"
}

# 取服务端错误文案：优先 msg，没有就回显整个返回体（与 gen.py 的 r.get("msg", r) 对齐）
function Get-Msg($r) {
  if ($null -ne $r -and $null -ne $r.msg -and -not [string]::IsNullOrWhiteSpace([string]$r.msg)) { return [string]$r.msg }
  try { return (ConvertTo-Json -InputObject $r -Depth 6 -Compress) } catch { return '未知错误' }
}

# 注册重试专用：默认「验证码不对」（与 gen.py 对齐）
function Get-CodeMsg($r) {
  if ($null -ne $r -and $null -ne $r.msg -and -not [string]::IsNullOrWhiteSpace([string]$r.msg)) { return [string]$r.msg }
  return '验证码不对'
}

# 异常转可读串（带内层异常；买家报错排查要靠它）
function Format-Ex($e) {
  $ex = $e
  if ($null -ne $e -and $null -ne $e.PSObject.Properties['Exception']) { $ex = $e.Exception }
  if ($null -eq $ex) { return '未知错误' }
  $s = $ex.GetType().Name + ': ' + $ex.Message
  $inner = $ex.InnerException
  if ($null -ne $inner) { $s += ' >> ' + $inner.GetType().Name + ': ' + $inner.Message }
  return $s
}

# ── HTTP 层 ──────────────────────────────────────────────────────────────
# 关键：响应必须按「原始字节 → UTF-8」解码。PS 5.1 的 Invoke-WebRequest .Content
# 在 Content-Type 无 charset 时按 latin1 解，中文会变乱码（本机实测）。
function Invoke-Raw {
  param(
    [string]$Url,
    [byte[]]$Body = $null,
    [string]$ContentType = 'application/json',
    [int]$TimeoutSec = 30,
    [string]$Method = 'POST',
    [hashtable]$ExtraHeaders = $null
  )
  $req = [System.Net.HttpWebRequest]::Create($Url)
  $req.Method = $Method
  $req.Timeout = $TimeoutSec * 1000
  $req.ReadWriteTimeout = $TimeoutSec * 1000
  $req.UserAgent = $GEN_UA
  $req.AllowAutoRedirect = $true
  if ($ExtraHeaders) {
    foreach ($k in $ExtraHeaders.Keys) { $req.Headers[$k] = [string]$ExtraHeaders[$k] }
  }
  if ($null -ne $Body) {
    $req.ContentType = $ContentType
    $req.ContentLength = $Body.Length
    $st = $null
    try {
      $st = $req.GetRequestStream()
      $st.Write($Body, 0, $Body.Length)
      $st.Close()
    } catch {
      # 上传阶段失败（连接被断开 / 请求体过大）→ 单独归类，不与「等生成超时」混为一谈
      $em = ''
      try { $em = $_.Exception.Message } catch { }
      try { if ($null -ne $st) { $st.Close() } } catch { }
      return @{ http = 0; body = ''; stage = 'upload'; err = $em }
    }
  }
  try {
    $resp = $req.GetResponse()
  } catch [System.Net.WebException] {
    $wr = $_.Exception.Response
    if ($null -ne $wr) {
      $ms = New-Object System.IO.MemoryStream
      try { $wr.GetResponseStream().CopyTo($ms) } catch { }
      $wr.Close()
      return @{ http = [int]$wr.StatusCode; body = [System.Text.Encoding]::UTF8.GetString($ms.ToArray()) }
    }
    throw
  }
  $ms = New-Object System.IO.MemoryStream
  $resp.GetResponseStream().CopyTo($ms)
  $resp.Close()
  return @{ http = [int]$resp.StatusCode; body = [System.Text.Encoding]::UTF8.GetString($ms.ToArray()) }
}

function ConvertFrom-JsonSafe([string]$s) {
  try { return ($s | ConvertFrom-Json) } catch { return $null }
}
# ── 版本检测 / 自更新（2026-10-20）────────────────────────────────────────
# 本地版本号来自技能自身的 SKILL.md（不写死），远端来自 /skill/version
function Get-LocalVersion {
  if (-not (Test-Path -LiteralPath $SKILL_MD -PathType Leaf)) { return '' }
  try {
    $txt = [System.IO.File]::ReadAllText($SKILL_MD, [System.Text.Encoding]::UTF8)
    $m = [regex]::Match($txt, '(?m)^version:\s*"?([0-9]+\.[0-9]+)"?\s*$')
    if ($m.Success) { return $m.Groups[1].Value }
  } catch { }
  return ''
}

# 两段式数值比较：3.10 必须大于 3.9（直接字符串比是错的）
function Compare-Ver([string]$a, [string]$b) {
  if ($a -notmatch '^[0-9]+\.[0-9]+$' -or $b -notmatch '^[0-9]+\.[0-9]+$') { return 0 }
  $pa = $a.Split('.'); $pb = $b.Split('.')
  if ([int]$pa[0] -ne [int]$pb[0]) {
    if ([int]$pa[0] -gt [int]$pb[0]) { return 1 } else { return -1 }
  }
  if ([int]$pa[1] -gt [int]$pb[1]) { return 1 }
  if ([int]$pa[1] -lt [int]$pb[1]) { return -1 }
  return 0
}

function Get-RemoteVersion([int]$TimeoutSec = 2) {
  if ($env:CD_NO_UPDATE_CHECK -eq '1') { return $null }
  try {
    $u = $VERSION_URL + '?t=' + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $req = [System.Net.HttpWebRequest]::Create($u)
    $req.Method = 'GET'
    $req.Timeout = $TimeoutSec * 1000
    $req.ReadWriteTimeout = $TimeoutSec * 1000
    $req.UserAgent = $GEN_UA
    $resp = $req.GetResponse()
    $ms = New-Object System.IO.MemoryStream
    try { $resp.GetResponseStream().CopyTo($ms) } catch { }
    $resp.Close()
    return (ConvertFrom-JsonSafe ([System.Text.Encoding]::UTF8.GetString($ms.ToArray())))
  } catch { return $null }
}

# 出图前调用：失败/超时一律静默，绝不阻断出图
function Show-UpdateHint {
  if ($env:CD_NO_UPDATE_CHECK -eq '1') { return }
  $rv = Get-RemoteVersion 2
  if ($null -eq $rv -or $rv.ok -ne $true) { return }
  $latest = [string]$rv.latest
  $local = Get-LocalVersion
  if ([string]::IsNullOrWhiteSpace($local) -or [string]::IsNullOrWhiteSpace($latest)) { return }
  if ((Compare-Ver $latest $local) -le 0) { return }
  $lastVer = ''
  $lastAt = 0
  if (Test-Path -LiteralPath $UPDATE_CHECK_PATH) {
    try {
      $j = ConvertFrom-Json ([System.IO.File]::ReadAllText($UPDATE_CHECK_PATH, [System.Text.Encoding]::UTF8))
      $lastVer = [string]$j.version
      $lastAt = [long]$j.at
    } catch { }
  }
  $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  if ($lastVer -eq $latest -and ($now - $lastAt) -lt 86400) { return }
  Say ""
  Say "[版本] 技能有新版本：本地 v$local -> 最新 v$latest"
  Say "       更新命令：scripts\gen.cmd update   （约 10 秒）"
  Say "       更新后请重启 opencode 或新开会话，技能才会重新加载。"
  Say ""
  try {
    if (-not (Test-Path -LiteralPath $CRED_DIR)) { New-Item -ItemType Directory -Path $CRED_DIR -Force | Out-Null }
    $o = [ordered]@{ version = $latest; at = $now }
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($UPDATE_CHECK_PATH, (ConvertTo-Json -InputObject $o -Compress), $enc)
  } catch { }
}


# POST JSON，网络类失败自动重试；服务器明确响应（含业务失败）直接返回。
# 返回 @{ data = <对象或 $null>; neterr = <字符串或 $null> }
function Post-Json {
  param([string]$Url, $Payload, [int]$TimeoutSec = 30, [int]$Tries = 3)
  $json = ConvertTo-Json -InputObject $Payload -Depth 10 -Compress
  $body = [System.Text.Encoding]::UTF8.GetBytes($json)
  $last = $null
  for ($i = 0; $i -lt $Tries; $i++) {
    try {
      $r = Invoke-Raw -Url $Url -Body $body -ContentType 'application/json' -TimeoutSec $TimeoutSec
      return @{ data = (ConvertFrom-JsonSafe $r.body); neterr = $null }
    } catch {
      $last = $_
      if ($i -lt $Tries - 1) { Start-Sleep -Seconds (1 + $i * 1.5) }
    }
  }
  return @{ data = $null; neterr = $last.Exception.Message }
}

# ── 本地凭证（UTF-8 无 BOM；带 BOM 会让 gen.py 的 json.loads 失败）───────
function Read-JsonFile([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  try {
    $txt = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($txt)) { return $null }
    return ($txt | ConvertFrom-Json)
  } catch { return $null }
}

function Write-JsonFile([string]$path, $obj) {
  $dir = Split-Path -Parent $path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Force -Path $dir) }
  $json = ConvertTo-Json -InputObject $obj -Depth 10 -Compress
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($path, $json, $enc)
}

function Get-Cred {
  $c = Read-JsonFile $CRED_PATH
  if ($null -eq $c) { return $null }
  if ($c.ok -ne $true) { return $null }
  $k = [string]$c.key
  if (-not $k.StartsWith('sk-')) { return $null }
  # 2026-10-19 起不绑机、不采集机器指纹：凭证可在任意机器直接用
  return $c
}

function Save-Cred([string]$key, [string]$email = '') {
  $obj = [ordered]@{
    ok      = $true
    key     = $key
    email   = $email
    time    = (Get-Date -Format 'yyyy-MM-dd')
  }
  Write-JsonFile -path $CRED_PATH -obj $obj
}

# ── 出图任务持久化（与 gen.py 的 pending 同格式，可互换）─────────────────
function Get-Slot([string]$key) {
  if ($key.Length -le 8) { return $key }
  return $key.Substring($key.Length - 8)
}

function ConvertTo-Hashtable($obj) {
  $h = @{}
  if ($null -eq $obj) { return $h }
  foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = $p.Value }
  return $h
}

function Save-Pending([string]$key, [string]$rid, $params) {
  $dd = @{}
  $raw = Read-JsonFile $PENDING_PATH
  if ($null -ne $raw) { $dd = ConvertTo-Hashtable $raw }
  $ts = [int64][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $dd[(Get-Slot $key)] = @{ key = $key; rid = $rid; params = $params; ts = $ts }
  Write-JsonFile -path $PENDING_PATH -obj $dd
}

function Clear-Pending([string]$key) {
  $raw = Read-JsonFile $PENDING_PATH
  if ($null -eq $raw) { return }
  $dd = ConvertTo-Hashtable $raw
  $dd.Remove((Get-Slot $key)) | Out-Null
  Write-JsonFile -path $PENDING_PATH -obj $dd
}

function Find-Pending([string]$key) {
  $raw = Read-JsonFile $PENDING_PATH
  if ($null -eq $raw) { return $null }
  $dd = ConvertTo-Hashtable $raw
  $pp = $dd[(Get-Slot $key)]
  if ($null -eq $pp) { return $null }
  if ([string]$pp.key -ne $key) { return $null }
  $now = [int64][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  if (($now - [int64]$pp.ts) -gt (48 * 3600)) { return $null }
  return $pp
}

# ── 注册 / 登录 / 换 key ─────────────────────────────────────────────────
$EMAIL_RE = '^[^\s@]+@[^\s@]+\.[^\s@]+$'

function Assert-Email([string]$email) {
  if ($email -notmatch $EMAIL_RE) { Die "邮箱格式不对：$email" }
}

function Register-Flow {
  Say "首次使用，先用邮箱注册一个账号（不收任何费用，只是用来管你的积分）。"
  Say ""
  Say "你的邮箱（QQ 邮箱、163、Outlook 都行）："
  $email = ([Console]::In.ReadLine())
  if ($null -eq $email) { $email = '' }
  $email = $email.Trim()
  if ([string]::IsNullOrWhiteSpace($email)) { Die "没有输入邮箱。" }
  Assert-Email $email
  Say "正在发送验证码，请稍候…"
  $r = Post-Json -Url ($WORKER + '/reg/send') -Payload @{ email = $email } -TimeoutSec 30
  if ($null -eq $r.data) { Die "连不上服务器（$($r.neterr)）。检查网络后重新运行本命令。" }
  if ($r.data.ok -ne $true) { Die "验证码发送失败：$(Get-Msg $r.data)" }
  Say "[OK] 验证码已发到 $email，请查收邮箱（可能要等 1-2 分钟，30 分钟内有效）。"
  Say ""
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    Say "填入邮箱里的 6 位验证码（第 $attempt 次机会）："
    $code = ([Console]::In.ReadLine())
    if ($null -eq $code) { $code = '' }
    $code = $code.Trim()
    if ([string]::IsNullOrWhiteSpace($code)) { Die "没有输入验证码。" }
    $r2 = Post-Json -Url ($WORKER + '/reg/complete') -Payload @{ email = $email; code = $code } -TimeoutSec 30
    if ($null -eq $r2.data) { Die "连不上服务器（$($r2.neterr)）。检查网络后重新运行本命令。" }
    if ($r2.data.ok -eq $true -and ([string]$r2.data.key).StartsWith('sk-')) {
      Save-Cred -key ([string]$r2.data.key) -email $email
      Say ""
      Say "[OK] 注册成功！你的 key 已自动保存在本机，以后不用再管。"
      Say "     请把这串 key 备份到记事本里（换电脑时要用）："
      Say ""
      Say "     $($r2.data.key)"
      Say ""
      return [string]$r2.data.key
    }
    Say "       $(Get-CodeMsg $r2.data)，请重试。"
  }
  Die "连续 3 次没通过。重新运行本命令可以再收一封验证码。"
}

# 登录 / 验活：badkey 是服务端 KV 偶发读失败时的误报（2026-10-27 买家实测：
# 同一把 key 11:2x 连续三次回 badkey，11:4x 同一把 key 直接 ok）。
# 服务端已改成 4 次退避重试并新增 reason=temp；客户端再补两次 300ms / 900ms，
# 不能一句话就把用户的 key 判死。
function Invoke-Login {
  param([string]$Key, [int]$TimeoutSec = 20)
  $pr = Post-Json -Url ($WORKER + '/auth/login') -Payload @{ key = $Key; n = 1 } -TimeoutSec $TimeoutSec
  for ($t = 0; $t -lt 2; $t++) {
    if ($null -eq $pr.data) { break }
    $why = [string]$pr.data.reason
    if ($why -ne 'badkey' -and $why -ne 'temp') { break }
    Start-Sleep -Milliseconds (300 * [Math]::Pow(3, $t))   # 300ms / 900ms
    $pr = Post-Json -Url ($WORKER + '/auth/login') -Payload @{ key = $Key; n = 1 } -TimeoutSec $TimeoutSec
  }
  return $pr
}

function Login-Gate([string]$key) {
  $r = Invoke-Login $key
  if ($null -eq $r.data) {
    Say "[提醒] 连不上验证服务器（已重试），先照常用。"
    return
  }
  $d = $r.data
  if ($d.reason -eq 'temp') {
    Say "[提醒] 服务器这会儿读不到你的 key 记录（不是 key 坏了），先照常出图；"
    Say "       如果出图也报同样的错，等 1-2 分钟重跑一次就行。"
    return
  }
  if ($d.ok -eq $true) {
    $bal = 0
    if ($null -ne $d.credits) { $bal = [int]$d.credits }
    $free = 0
    if ($null -ne $d.free) { $free = [int]$d.free }
    $per = 0
    if ($null -ne $d.perImage) { $per = [int]$d.perImage }
    $script:PerImage = $per
    $script:AccountBalance = $bal
    if ($null -ne $d.defaultModel) { $script:DefaultModel = [string]$d.defaultModel }
    # 免费额度每次都显示：free=0 时说「已用完」，不能静默（买家分不清「没有」和「没显示」）
    $freeTxt = '已用完'
    if ($free -gt 0) { $freeTxt = "还剩 $free 积分" }
    $line = ">> 账号就绪，余额 $bal 积分，今日免费额度$freeTxt"
    if ($per -gt 0) { $line = $line + "，每张 $per 积分" }
    Say $line
    return
  }
  if ($d.reason -eq 'nolimit') {
    $freeLeft = 0
    if ($null -ne $d.free) { $freeLeft = [int]$d.free }
    $balLeft = 0
    if ($null -ne $d.credits) { $balLeft = [int]$d.credits }
    $state = '已用完'
    if ($freeLeft -gt 0) { $state = "还剩 $freeLeft 积分" }
    $perImg = ''
    if ($null -ne $d.perImage) { $perImg = "，每张 $([int]$d.perImage) 积分" }
    Say "[提示] 这次的积分不够：余额 $balLeft 积分，今日免费额度$state$perImg。"
    $pay = $d.pay
    if ([string]::IsNullOrWhiteSpace($pay)) { $pay = $PAY_URL + '?key=' + $key }
    Say "       如需继续出图，打开充值链接（key 已填好，填个金额付款就行）："
    Say "       $pay"
    return
  }
  if ($d.reason -eq 'used') {
    Say "[提示] key 状态异常，请重新运行出图命令；若持续出现请联系卖家。"
    return
  }
  Die "key 无效或已失效：$(Get-Msg $d)`n       核对一下 key 有没有复制错（sk- 开头一整串）；实在不行重新注册一个，或联系卖家。"
}

function Rekey-Flow([string]$key) {
  Say "正在换 key（余额会保留，旧 key 立即作废）…"
  $r = Post-Json -Url ($WORKER + '/auth/rekey') -Payload @{ key = $key } -TimeoutSec 30
  if ($null -eq $r.data) { Die "连不上服务器（$($r.neterr)）。检查网络后重新运行。" }
  if ($r.data.ok -ne $true -or -not ([string]$r.data.key).StartsWith('sk-')) {
    Die "换 key 失败：$(Get-Msg $r.data)"
  }
  $email = ''
  $c = Get-Cred
  if ($null -ne $c) { $email = [string]$c.email }
  Save-Cred -key ([string]$r.data.key) -email $email
  Say ""
  Say "[OK] 换好了。新 key 已保存在本机，请备份："
  Say ""
  Say "     $($r.data.key)"
  Say ""
  return [string]$r.data.key
}

# ── 出图 ─────────────────────────────────────────────────────────────────
function Anchor-Size([string]$prompt, [string]$size) {
  if (-not $SIZE_HINTS.ContainsKey($size)) { return $prompt }
  if ($prompt.Length -ge 4000) { return $prompt }
  foreach ($k in @('像素', '构图', '比例', '画幅')) {
    if ($prompt.Contains($k)) { return $prompt }
  }
  return ($prompt.TrimEnd() + '。' + $SIZE_HINTS[$size])
}

function Check-Refs($paths) {
  $ok = @()
  foreach ($f in $paths) {
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { Die "参考图不存在：$f" }
    $len = (Get-Item -LiteralPath $f).Length
    if ($len -gt (5 * 1024 * 1024)) {
      Die "参考图过大（$([int]($len / 1024 / 1024))MB）：$f`n       请压缩到 5MB 以内再传。"
    }
    $ok += (Resolve-Path -LiteralPath $f).Path
  }
  return $ok
}

# 参考图上传前自动压缩：长边 >1280 或体积 >600KB 时重编码为 JPEG(q85)
# 买家侧实测：大图直接传会在「建连阶段被断开（Write 失败）」，根因就是请求体过大
function Compress-Ref([string]$path) {
  try {
    $src = [System.IO.File]::ReadAllBytes($path)
    if ($src.Length -le 600KB) {
      Add-Type -AssemblyName System.Drawing
      $im0 = [System.Drawing.Image]::FromFile($path)
      try { $w0 = $im0.Width; $h0 = $im0.Height } finally { $im0.Dispose() }
      if ($w0 -le 1280 -and $h0 -le 1280) { return $path }
    }
    Add-Type -AssemblyName System.Drawing
    $img = [System.Drawing.Image]::FromFile($path)
    try {
      $w = $img.Width
      $h = $img.Height
      $scale = [Math]::Min(1.0, [Math]::Min(1280.0 / $w, 1280.0 / $h))
      $nw = [int]([Math]::Round($w * $scale))
      $nh = [int]([Math]::Round($h * $scale))
      $bmp = New-Object System.Drawing.Bitmap($nw, $nh)
      try {
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try {
          $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
          $g.Clear([System.Drawing.Color]::White)   # 透明区域铺白底，避免转 JPEG 变黑
          $g.DrawImage($img, 0, 0, $nw, $nh)
        } finally { $g.Dispose() }
        $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
        $ep = New-Object System.Drawing.Imaging.EncoderParameters(1)
        $ep.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, [long]85)
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('cd_ref_' + [guid]::NewGuid().ToString('N') + '.jpg')
        $bmp.Save($tmp, $codec, $ep)
        $newLen = (Get-Item -LiteralPath $tmp).Length
        if ($newLen -ge $src.Length) {
          Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
          return $path
        }
        Say "   参考图已自动压缩：$([System.IO.Path]::GetFileName($path))  $([int]($src.Length / 1024))KB -> $([int]($newLen / 1024))KB"
        return $tmp
      } finally { $bmp.Dispose() }
    } finally { $img.Dispose() }
  } catch {
    return $path
  }
}

function Build-Multipart($fields, $files) {
  # files = @( @{ name=..; path=..; filename=..; mime=.. }, ... )
  # 同名 image 字段重复出现 = 多图；不能用哈希表（同键会覆盖，静默丢图）。
  $boundary = '----opencodeimg' + [guid]::NewGuid().ToString('N')
  $ms = New-Object System.IO.MemoryStream
  $nl = "`r`n"
  foreach ($k in $fields.Keys) {
    if ($null -eq $fields[$k]) { continue }
    $head = "--$boundary$nl" + "Content-Disposition: form-data; name=`"$k`"$nl$nl"
    $b = [System.Text.Encoding]::UTF8.GetBytes($head + [string]$fields[$k] + $nl)
    $ms.Write($b, 0, $b.Length)
  }
  foreach ($f in $files) {
    $head = "--$boundary$nl" + "Content-Disposition: form-data; name=`"$($f.name)`"; filename=`"$($f.filename)`"$nl" + "Content-Type: $($f.mime)$nl$nl"
    $b = [System.Text.Encoding]::UTF8.GetBytes($head)
    $ms.Write($b, 0, $b.Length)
    $bytes = [System.IO.File]::ReadAllBytes($f.path)
    $ms.Write($bytes, 0, $bytes.Length)
    $crlf = [System.Text.Encoding]::ASCII.GetBytes($nl)
    $ms.Write($crlf, 0, $crlf.Length)
  }
  $tail = [System.Text.Encoding]::ASCII.GetBytes("--$boundary--$nl")
  $ms.Write($tail, 0, $tail.Length)
  return @{ body = $ms.ToArray(); ctype = "multipart/form-data; boundary=$boundary" }
}

# 读 PNG 实际像素：--size 只决定比例，真实像素由服务端定（1:1 → 1254×1254，竖版 → 941×1672）。
# 打到完成行里，免得买家以为「参数没生效」。
function Get-PngSize([string]$path) {
  try {
    $fs = [System.IO.File]::OpenRead($path)
    try {
      $b = New-Object byte[] 24
      if ($fs.Read($b, 0, 24) -lt 24) { return '' }
      if ($b[0] -ne 0x89 -or $b[1] -ne 0x50) { return '' }
      $w = ([long]$b[16] * 16777216) + ([long]$b[17] * 65536) + ([long]$b[18] * 256) + [long]$b[19]
      $h = ([long]$b[20] * 16777216) + ([long]$b[21] * 65536) + ([long]$b[22] * 256) + [long]$b[23]
      if ($w -le 0 -or $h -le 0) { return '' }
      return "$w×$h"
    } finally { $fs.Close() }
  } catch { return '' }
}

function Save-Url([string]$url, [string]$outPath) {
  $req = [System.Net.HttpWebRequest]::Create($url)
  $req.UserAgent = 'Mozilla/5.0'
  $req.Accept = 'image/*,*/*;q=0.8'
  $req.Referer = (($url -split '/')[0..2] -join '/') + '/'
  $req.Timeout = 120000
  $resp = $req.GetResponse()
  $ms = New-Object System.IO.MemoryStream
  $resp.GetResponseStream().CopyTo($ms)
  $resp.Close()
  $bytes = $ms.ToArray()
  $dir = Split-Path -Parent $outPath
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Force -Path $dir) }
  [System.IO.File]::WriteAllBytes($outPath, $bytes)
  return $bytes.Length
}

function Save-B64([string]$b64, [string]$outPath) {
  $bytes = [System.Convert]::FromBase64String($b64)
  $dir = Split-Path -Parent $outPath
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Force -Path $dir) }
  [System.IO.File]::WriteAllBytes($outPath, $bytes)
  return $bytes.Length
}

function Invoke-Gen($cred, [byte[]]$body, [string]$ctype, [int]$n, [int]$timeout) {
  $pending = Find-Pending $cred.key
  if ($null -ne $pending) {
    Say ">> 发现上次出图任务未确认完成，自动用同一任务号重放（服务端幂等，不会重复扣费）…"
    $rid = [string]$pending.rid
  } else {
    $rid = [guid]::NewGuid().ToString('N')
  }
  $url = $GEN_URL + '?key=' + [System.Uri]::EscapeDataString($cred.key) +
         '&rid=' + $rid + '&n=' + $n
  if ($null -eq $pending) { Save-Pending -key $cred.key -rid $rid -params @{ n = $n } }
  $last = $null
  for ($i = 0; $i -lt $NET_TRIES; $i++) {
    try {
      $r = Invoke-Raw -Url $url -Body $body -ContentType $ctype -TimeoutSec $timeout `
                      -ExtraHeaders @{ Authorization = 'Bearer ' + $cred.key }
    } catch {
      $last = $_
      $label = '网络没连上'
      if ($_.Exception -is [System.Net.WebException] -and $_.Exception.Status -eq 'Timeout') {
        $label = '等待服务端生成超时（服务端还在排队生成，不是你的网络问题）'
      }
      if ($i -lt $NET_TRIES - 1) {
        $wait = 15
        if ($i -lt $NET_BACKOFF.Count) { $wait = $NET_BACKOFF[$i] }
        Say ">> $label（$(Format-Ex $_)），$wait 秒后重试（第 $($i + 2)/$NET_TRIES 次）…"
        Start-Sleep -Seconds $wait
      }
      continue
    }
    if ($r.http -eq 0 -and $r.stage -eq 'upload') {
      $last = "上传阶段失败：$($r.err)"
      if ($i -lt $NET_TRIES - 1) {
        $wait = 15
        if ($i -lt $NET_BACKOFF.Count) { $wait = $NET_BACKOFF[$i] }
        Say ">> 上传参考图时连接被断开（$($r.err)）。通常是请求体太大或网络抖动；已自动重试（第 $($i + 2)/$NET_TRIES 次）…"
        Say "   若连续失败：减少参考图张数（先只传 1 张）再试，或把图先压缩到 1MB 以内。"
        Start-Sleep -Seconds $wait
      }
      continue
    }
    if ($r.http -ge 400) {
      $detail = $r.body
      if ($detail.Length -gt 400) { $detail = $detail.Substring(0, 400) }
      Die "服务器返回 HTTP $($r.http)：$detail`n       这是服务器侧的问题，稍等几分钟再试；持续出现请联系卖家。"
    }
    $d = ConvertFrom-JsonSafe $r.body
    if ($null -eq $d) {
      $snip = $r.body
      if ($snip.Length -gt 400) { $snip = $snip.Substring(0, 400) }
      Die "服务器返回无法解析的内容：$snip"
    }
    if ($d.ok -eq $true) {
      Clear-Pending $cred.key
      if ($d.dup) { Say ">> 服务器确认上次已受理，返回原结果（未重复扣费）" }
      return $d
    }
    if ($d.reason -eq 'nolimit') { Clear-Pending $cred.key; Die-Nolimit $d }
    if ($d.reason -eq 'used') {
      Clear-Pending $cred.key
      Die "这把 key 状态异常（服务器拒绝出图）。重新运行一次命令试试；持续出现请联系卖家。"
    }
    $msg = [string]$d.msg
    if ([string]::IsNullOrWhiteSpace($msg)) {
      $j = ($r.body -replace '\s+', ' ')
      if ($j.Length -gt 200) { $j = $j.Substring(0, 200) }
      $msg = $j
    }
    if ($d.refunded) {
      # 主通道负载类错误（excessive system load 等）是间歇性的：等 25 秒自动重试一次
      # （失败任务不扣积分，重试对买家零成本；同 rid 会被服务端幂等返回，故先清 pending 换新 rid）
      $upErr = ''
      if ($null -ne $d.upstream_error) { $upErr = [string]$d.upstream_error }
      $isLoad = ($upErr -match '(?i)excessive|overload|busy|system load|rate.?limit') -or ($msg -match '出图服务当前负载过高')
      if ($isLoad -and $script:loadRetried -ne $true) {
        $script:loadRetried = $true
        Clear-Pending $cred.key
        Say ">> 出图服务当前负载过高（间歇性问题），25 秒后自动重试一次…"
        Start-Sleep -Seconds 25
        return (Invoke-Gen $cred $body $ctype $n $timeout)
      }
      Clear-Pending $cred.key
      $free = 0
      if ($null -ne $d.free) { $free = [int]$d.free }
      $note = ''
      if ($free -gt 0) { $note = " + 今日免费 $free" }
      $bal = '?'
      if ($null -ne $d.credits) { $bal = [string]$d.credits }
      Die "这次没出成图，积分已退回（余额 $bal$note）。`n       原因：$msg`n       稍等片刻重新运行刚才的命令即可。"
    }
    Die "出图失败：$msg"
  }
  Say ""
  Say ">> 注意：这次网络中断，任务本身可能已经在服务器上跑起来了（服务端幂等，重跑不会重复扣费）。"
  Say ">> 等网络恢复后重新运行刚才那条命令即可找回结果。"
  $ln = ''
  if ($null -ne $last) { $ln = Format-Ex $last }
  Die "连试 $NET_TRIES 次都没连上服务器（$ln）。检查网络后重新运行；积分不会多扣。"
}

# ── 参数解析（手写；PS 原生不认 --k 这种双横线风格）──────────────────────
function Show-Help {
  Say @"
AI 生图（线上版）：官方渠道，按积分计费

用法
  gen.cmd --prompt "一只橘猫坐在窗边，暖光，写实摄影"
  gen.cmd --prompt-file prompt.txt --out 图1.png
  gen.cmd --prompt-file prompt.txt --ref 产品图.png --ref 细节图.png --out 精修.png

常用参数
  --size     只决定画面比例，不是精确像素（服务端按比例出图）：
             正方形  1024x1024 / 2048x2048  → 实际出 1254×1254
             竖版    1024x1536 / 1024x2048  → 实际出 941×1672
             横版    1536x1024              → 实际出 1672×941
             默认 1024x1024；真实像素以完成行打印的「宽×高」为准
  --quality  low / medium / high                              默认 medium
  --model    模型名，默认由服务端决定（显式指定可覆盖）
  --n        生成张数 1~8，默认 1
  --out      输出文件名，默认按时间戳生成
  --rekey    手动换新 key（余额保留）

非交互参数（供 AI 助手代为执行）
  --send-code 你的邮箱            发送注册验证码
  --complete 你的邮箱 6位验证码   完成注册并自动保存 key
  --save-key sk-xxx               导入已有 key
  --login 你的邮箱 6位验证码       用邮箱+验证码取回已注册账号的 key
  --batch 清单.json                批量出图（清单含 items 数组，逐张调用本命令）
  --progress-file 路径             批量出图的进度文件（默认 <输出目录>\_batch_progress.txt）
  --concurrency N                  批量出图并发数（默认 3；1 = 串行）
  --check                         只登录查余额，不出图

版本与更新
  version                         查看本地版本与最新版本
  update                          更新到最新版本（更新后请重启 opencode）
"@
}

$Opt = @{}
$a = @($args)
$i = 0
while ($i -lt $a.Count) {
  $t = [string]$a[$i]
  switch -Exact ($t) {
    '--prompt'      { $i++; if ($i -lt $a.Count) { $Opt['prompt'] = [string]$a[$i] } }
    '--prompt-file' { $i++; if ($i -lt $a.Count) { $Opt['prompt_file'] = [string]$a[$i] } }
    '--ref'         { $i++; if ($i -lt $a.Count) { if (-not $Opt.ContainsKey('ref')) { $Opt['ref'] = @() }; $Opt['ref'] = $Opt['ref'] + @([string]$a[$i]) } }
    '--size'        { $i++; if ($i -lt $a.Count) { $Opt['size'] = [string]$a[$i] } }
    '--quality'     { $i++; if ($i -lt $a.Count) { $Opt['quality'] = [string]$a[$i] } }
    '--n'           { $i++; if ($i -lt $a.Count) { $Opt['n'] = [int]$a[$i] } }
    '--model'       { $i++; if ($i -lt $a.Count) { $Opt['model'] = [string]$a[$i] } }
    '--out'         { $i++; if ($i -lt $a.Count) { $Opt['out'] = [string]$a[$i] } }
    '--timeout'     { $i++; if ($i -lt $a.Count) { $Opt['timeout'] = [int]$a[$i] } }
    '--rekey'       { $Opt['rekey'] = $true }
    '--send-code'   { $i++; if ($i -lt $a.Count) { $Opt['send_code'] = [string]$a[$i] } }
    '--complete'    { $i++; if ($i -lt $a.Count) { $Opt['complete_email'] = [string]$a[$i] }; $i++; if ($i -lt $a.Count) { $Opt['complete_code'] = [string]$a[$i] } }
    '--save-key'    { $i++; if ($i -lt $a.Count) { $Opt['save_key'] = [string]$a[$i] } }
    '--login'       { $i++; if ($i -lt $a.Count) { $Opt['login_email'] = [string]$a[$i] }; $i++; if ($i -lt $a.Count) { $Opt['login_code'] = [string]$a[$i] } }
    '--batch'       { $i++; if ($i -lt $a.Count) { $Opt['batch'] = [string]$a[$i] } }
    '--progress-file' { $i++; if ($i -lt $a.Count) { $Opt['progress_file'] = [string]$a[$i] } }
    '--concurrency'  { $i++; if ($i -lt $a.Count) { $Opt['concurrency'] = [int]$a[$i] } }
    '--pending-file' { $i++; if ($i -lt $a.Count) { $Opt['pending_file'] = [string]$a[$i] } }
    '--check'       { $Opt['check'] = $true }
    '--help'        { $Opt['help'] = $true }
    '-h'            { $Opt['help'] = $true }
    '--version'     { $Opt['version'] = $true }
    'version'       { $Opt['version'] = $true }
    '--update'      { $Opt['update'] = $true }
    'update'        { $Opt['update'] = $true }
    default         { }
  }
  $i++
}

# pending 文件可指定：并发批量时每张用独立文件，避免共享 pending.json 竞态（可能重放错 rid → 串图）
if ($Opt.ContainsKey('pending_file') -and -not [string]::IsNullOrWhiteSpace([string]$Opt['pending_file'])) {
  $PENDING_PATH = [string]$Opt['pending_file']
}

if ($Opt.ContainsKey('help')) { Show-Help; exit 0 }

# ── 非交互子命令 ─────────────────────────────────────────────────────────
if ($Opt.ContainsKey('send_code')) {
  $email = ([string]$Opt['send_code']).Trim()
  Assert-Email $email
  $r = Post-Json -Url ($WORKER + '/reg/send') -Payload @{ email = $email } -TimeoutSec 30
  if ($null -eq $r.data) { Die "连不上服务器（$($r.neterr)）。检查网络后重新运行本命令。" }
  if ($r.data.ok -ne $true) {
    $m0 = [string]$r.data.msg
    if ($m0 -match '已注册') {
      # 已注册 → 自动改发登录验证码（原来只能让 agent 自己用 curl 打网页接口，买家实测绕了 7 次）
      $r2 = Post-Json -Url ($WORKER + '/account/sendcode') -Payload @{ email = $email } -TimeoutSec 30
      if ($null -ne $r2.data -and $r2.data.ok -eq $true) {
        Say "[OK] 这个邮箱已经注册过了 → 已改发**登录验证码**到 $email（可能要等 1-2 分钟，30 分钟内有效）。"
        Say "     收到 6 位验证码发给我，我会用它登录并把你原来的 key 取回来（不用重新注册，余额也还在）。"
        exit 0
      }
    }
    Die "验证码发送失败：$(Get-Msg $r.data)"
  }
  Say "[OK] 验证码已发到 $email（可能要等 1-2 分钟，30 分钟内有效）。"
  Say "     收到后把 6 位验证码发给我即可。"
  exit 0
}

if ($Opt.ContainsKey('login_email')) {
  $email = ([string]$Opt['login_email']).Trim()
  $code = ([string]$Opt['login_code']).Trim()
  Assert-Email $email
  if ($code -notmatch '^\d{6}$') { Die "验证码应为 6 位数字：$code" }
  $r = Post-Json -Url ($WORKER + '/account/login') -Payload @{ email = $email; code = $code } -TimeoutSec 30
  if ($null -eq $r.data) { Die "连不上服务器（$($r.neterr)）。检查网络后重新运行本命令。" }
  if ($r.data.ok -ne $true) { Die "登录失败：$(Get-Msg $r.data)" }
  $token = [string]$r.data.token
  if ([string]::IsNullOrWhiteSpace($token)) { Die "登录失败：服务器没有返回登录凭证，请重新运行本命令。" }
  $g = Invoke-Raw -Url ($WORKER + '/account') -Method 'GET' -TimeoutSec 30 -ExtraHeaders @{ 'x-account-token' = $token }
  $d = ConvertFrom-JsonSafe $g.body
  if ($null -eq $d -or $d.ok -ne $true) {
    $why = '服务器返回无法解析的内容'
    if ($null -ne $d) { $why = Get-Msg $d }
    Die "取账户信息失败：$why"
  }
  $keys = @()
  if ($null -ne $d.keys) { $keys = @($d.keys) }
  if ($keys.Count -eq 0) {
    Die "这个邮箱下还没有 key（可能只注册过没建 key）。`n       换个邮箱重新注册，或在账户页新建一把 key。"
  }

  # 逐把核验（2026-10-27 买家实测）：原来直接拿第 1 把就宣布「已生效」，
  # 而第 1 把可能是已删除 / 已过期的死 key，买家紧接着出图被拒。现在逐把调 /auth/login 验活，
  # 取第一把真能用的；全都不行时分清「服务器暂时读不到」与「key 都失效了」。
  Say ""
  Say "已登录 $email，账号下共 $($keys.Count) 把 key，正在逐把核验…"
  $chosen = ''
  $rows = @()
  $unknown = 0
  $idx = 0
  foreach ($k in $keys) {
    $idx++
    $kk = [string]$k.key
    if (-not $kk.StartsWith('sk-')) { continue }
    $short = $kk
    if ($kk.Length -gt 18) { $short = $kk.Substring(0, 10) + '…' + $kk.Substring($kk.Length - 4) }
    $pr = Invoke-Login $kk
    $state = ''
    if ($null -eq $pr.data) {
      $unknown++
      $state = '读取超时（服务器这会儿没响应）'
    } elseif ($pr.data.ok -eq $true) {
      $b = 0
      if ($null -ne $pr.data.credits) { $b = [int]$pr.data.credits }
      $f = 0
      if ($null -ne $pr.data.free) { $f = [int]$pr.data.free }
      $freeTxt = '已用完'
      if ($f -gt 0) { $freeTxt = "还剩 $f 积分" }
      $state = "可用（余额 $b 积分，今日免费额度$freeTxt）"
      if ([string]::IsNullOrEmpty($chosen)) { $chosen = $kk }
    } elseif ($pr.data.reason -eq 'nolimit') {
      $b = 0
      if ($null -ne $pr.data.credits) { $b = [int]$pr.data.credits }
      $state = "可用但余额为 0（余额 $b 积分），充值后即可出图"
      if ([string]::IsNullOrEmpty($chosen)) { $chosen = $kk }
    } elseif ($pr.data.reason -eq 'expired') {
      $state = '已过期（到账户页点「改期」可续上）'
    } elseif ($pr.data.reason -eq 'temp') {
      $unknown++
      $state = '服务器暂时读不到（不是 key 坏了）'
    } else {
      $state = '服务器上已经没有这把 key'
    }
    $rows += ("     $idx) $short   $state")
  }
  foreach ($row in $rows) { Say $row }

  if ([string]::IsNullOrEmpty($chosen)) {
    Say ""
    if ($rows.Count -gt 0 -and $unknown -eq $rows.Count) {
      Say "[提示] 服务器暂时读不到这些 key 的记录 —— 这不代表 key 坏了，也不是你操作错了。"
      Say "       等 1-2 分钟，重新运行同一条命令即可。"
    } elseif ($unknown -gt 0) {
      Say "[提示] 有几把 key 暂时读不到（服务器那边的问题，不是 key 坏了），先等 1-2 分钟重跑一次；"
      Say "       重跑后仍全部不可用，再跟卖家核对 key。"
    } else {
      Say "[提示] 这个邮箱下的 key 都不在可出图状态（已过期或已被删除）。"
      Say "       到账户页新建一把 key：https://verify.evomindd.top/login ；或跟卖家核对。"
    }
    exit 1
  }

  Save-Cred -key $chosen -email $email
  $bal = '?'
  if ($null -ne $d.balance) { $bal = [string]$d.balance }
  Say ""
  Say "[OK] 已用邮箱 + 验证码登录，并取回你原来的 key（已自动保存在本机）："
  Say ""
  Say "     $chosen"
  Say ""
  Say "     账号余额 $bal 积分。这把 key 已核验可用，直接出图即可。"
  if ($keys.Count -gt 1) {
    Say "     这个邮箱下共 $($keys.Count) 把 key，当前用的是第一把可用的；要换另一把可以跟助手说「导入这个 key」。"
  }
  Show-Guide
  exit 0
}

if ($Opt.ContainsKey('complete_email')) {
  $email = ([string]$Opt['complete_email']).Trim()
  $code = ([string]$Opt['complete_code']).Trim()
  Assert-Email $email
  if ($code -notmatch '^\d{6}$') { Die "验证码应为 6 位数字：$code" }
  $r = Post-Json -Url ($WORKER + '/reg/complete') -Payload @{ email = $email; code = $code } -TimeoutSec 30
  if ($null -eq $r.data) { Die "连不上服务器（$($r.neterr)）。检查网络后重新运行本命令。" }
  if ($r.data.ok -ne $true -or -not ([string]$r.data.key).StartsWith('sk-')) {
    Die "注册失败：$(Get-Msg $r.data)"
  }
  Save-Cred -key ([string]$r.data.key) -email $email
  Say ""
  Say "[OK] 注册成功！key 已自动保存在本机，以后不用再管。"
  Say "     请把这串 key 备份到记事本里（换电脑时要用）："
  Say ""
  Say "     $($r.data.key)"
  Say ""
  Login-Gate ([string]$r.data.key)
  Show-Guide
  exit 0
}

if ($Opt.ContainsKey('save_key')) {
  $key = ([string]$Opt['save_key']).Trim()
  if (-not $key.StartsWith('sk-')) { Die "key 格式不对（应以 sk- 开头）：$key" }
  Save-Cred -key $key
  Login-Gate $key
  Show-Guide
  exit 0
}

if ($Opt.ContainsKey('check')) {
  $c = Get-Cred
  if ($null -eq $c) {
    Say "[提示] 本机还没有 key，请先完成注册："
    Say "       把你的邮箱发给我，我帮你发验证码。"
    exit 0
  }
  Login-Gate ([string]$c.key)
  exit 0
}

# ── 查看版本 / 更新（不涉及出图与积分）──────────────────────────────────
if ($Opt.ContainsKey('version')) {
  $lv = Get-LocalVersion
  $shown = '未知'
  if (-not [string]::IsNullOrWhiteSpace($lv)) { $shown = 'v' + $lv }
  Say "本地版本：$shown"
  $rv = Get-RemoteVersion 5
  if ($null -eq $rv -or $rv.ok -ne $true) {
    Say "最新版本：查询失败（网络或服务端不可达；不影响出图）"
    exit 0
  }
  $latest = [string]$rv.latest
  Say "最新版本：v$latest"
  if (-not [string]::IsNullOrWhiteSpace($lv)) {
    if ((Compare-Ver $latest $lv) -gt 0) {
      Say ""
      Say "有新版本可用。更新命令：scripts\gen.cmd update"
    } else {
      Say "已是最新。"
    }
  }
  exit 0
}

if ($Opt.ContainsKey('update')) {
  $lv = Get-LocalVersion
  $rv = Get-RemoteVersion 10
  if ($null -eq $rv -or $rv.ok -ne $true -or [string]::IsNullOrWhiteSpace([string]$rv.latest)) {
    Die "查不到最新版本（网络或服务端不可达）。可稍后重试，或手动下载覆盖安装：`n       $WORKER/skill/creative-design.zip"
  }
  $latest = [string]$rv.latest
  if (-not [string]::IsNullOrWhiteSpace($lv) -and (Compare-Ver $latest $lv) -le 0) {
    Say "[OK] 已是最新版本 v$lv，无需更新。"
    exit 0
  }
  Say ">> 本地 v$lv  ->  最新 v$latest，开始下载…"
  $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('cd_update_' + [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $tmp -Force | Out-Null
  $zip = Join-Path $tmp 'pkg.zip'
  $ts = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $urls = @(($WORKER + '/skill/creative-design-v' + $latest + '.zip?t=' + $ts), ($WORKER + '/skill/creative-design.zip?t=' + $ts))
  $got = $false
  foreach ($u in $urls) {
    try {
      Invoke-WebRequest -Uri $u -OutFile $zip -UseBasicParsing -TimeoutSec 180 -UserAgent $GEN_UA -ErrorAction Stop
      $got = $true
      break
    } catch { }
  }
  if (-not $got) {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Die "下载失败（网络不通或被拦截）。可稍后重试，或手动下载覆盖安装：`n       $WORKER/skill/creative-design.zip"
  }
  try {
    Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force -ErrorAction Stop
  } catch {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Die "解压失败：$($_.Exception.Message)"
  }
  $newRoot = Join-Path $tmp 'creative-design'
  $newMd = Join-Path $newRoot 'SKILL.md'
  if (-not (Test-Path -LiteralPath $newMd -PathType Leaf)) {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Die "更新包结构异常（缺 SKILL.md），已中止，本机文件未改动。"
  }
  $nv = ''
  try {
    $txt2 = [System.IO.File]::ReadAllText($newMd, [System.Text.Encoding]::UTF8)
    $m2 = [regex]::Match($txt2, '(?m)^version:\s*"?([0-9]+\.[0-9]+)"?\s*$')
    if ($m2.Success) { $nv = $m2.Groups[1].Value }
  } catch { }
  if ($nv -ne $latest) {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Die "下载到的包版本是 v$nv，与预期的 v$latest 不一致，已中止（本机文件未改动）。"
  }
  $files = @(Get-ChildItem -LiteralPath $newRoot -Recurse -File)
  $failed = @()
  foreach ($f in $files) {
    $rel = $f.FullName.Substring($newRoot.Length).TrimStart('\')
    $dst = Join-Path $SKILL_ROOT $rel
    $dir = Split-Path -Parent $dst
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $ok = $false
    for ($k = 0; $k -lt 3 -and -not $ok; $k++) {
      try { Copy-Item -LiteralPath $f.FullName -Destination $dst -Force -ErrorAction Stop; $ok = $true }
      catch { Start-Sleep -Milliseconds 400 }
    }
    if (-not $ok) { $failed += $rel }
  }
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  if ($failed.Count -gt 0) {
    Die "有 $($failed.Count) 个文件被占用，未能覆盖：`n       $($failed -join ', ')`n       请重启 opencode 后再运行一次 scripts\gen.cmd update"
  }
  Say ""
  Say "[OK] 已更新到 v$latest（共 $($files.Count) 个文件）。"
  Say "     请重启 opencode 或新开一个会话，技能才会重新加载生效。"
  exit 0
}

# ── 出图主流程 ───────────────────────────────────────────────────────────
# 出图前查一次版本：超时 2 秒、失败静默；同版本 24h 只提示一次
Show-UpdateHint

$n = 1
if ($Opt.ContainsKey('n')) { $n = [int]$Opt['n'] }
if ($n -lt 1 -or $n -gt 8) { Die "一次最多出 8 张（--n 1~8）。" }

$cred = Get-Cred
if ($Opt.ContainsKey('rekey')) {
  if ($null -eq $cred) { Die "本机还没有 key，不需要换。直接运行出图命令即可完成注册。" }
  $newKey = Rekey-Flow ([string]$cred.key)
  $cred = [PSCustomObject]@{ key = $newKey }
}
if ($null -eq $cred) {
  $newKey = Register-Flow
  $cred = [PSCustomObject]@{ key = $newKey }
}
Login-Gate ([string]$cred.key)

# ── 批量出图（--batch 清单.json）─────────────────────────────────────────
# 清单示例（UTF-8 存成 .json）：
# {
#   "outDir": "out",          # 可选；相对路径按「清单所在目录」解析
#   "defaults": { "size": "1024x1024", "quality": "medium", "refs": ["a.jpg", "b.jpg"] },
#   "items": [
#     { "out": "01_core_white.png", "prompt": "白底核心主图…" },
#     { "out": "02_main_hero.png",  "prompt": "主图首图…", "size": "1024x1536", "refs": ["a.jpg"] }
#   ]
# }
# 相对路径（outDir / refs / promptFile）都相对**清单文件所在目录**解析。
if ($Opt.ContainsKey('batch')) {
  $manifestPath = [string]$Opt['batch']
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { Die "清单文件不存在：$manifestPath" }
  $mpath = (Resolve-Path -LiteralPath $manifestPath).Path
  $mroot = Split-Path -Parent $mpath
  $mraw = [System.IO.File]::ReadAllText($mpath, [System.Text.Encoding]::UTF8)
  $man = ConvertFrom-JsonSafe $mraw
  if ($null -eq $man -or $null -eq $man.items) {
    Die "清单解析失败（要 JSON，且含 items 数组）：$manifestPath`n       文件必须是 UTF-8 编码。"
  }
  $items = @($man.items)
  if ($items.Count -eq 0) { Die "清单里 items 是空的。" }

  $outDir = $mroot
  if ($null -ne $man.outDir -and -not [string]::IsNullOrWhiteSpace([string]$man.outDir)) {
    $outDir = [string]$man.outDir
    if (-not [System.IO.Path]::IsPathRooted($outDir)) { $outDir = Join-Path $mroot $outDir }
  }
  if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
  $outDir = (Resolve-Path -LiteralPath $outDir).Path

  $def = $man.defaults
  $cliSize = '1024x1024'; if ($Opt.ContainsKey('size')) { $cliSize = [string]$Opt['size'] }
  $cliQual = 'medium'; if ($Opt.ContainsKey('quality')) { $cliQual = [string]$Opt['quality'] }
  $cliModel = ''; if ($Opt.ContainsKey('model')) { $cliModel = [string]$Opt['model'] }
  $cliRefs = @(); if ($Opt.ContainsKey('ref')) { $cliRefs = @($Opt['ref']) }

  $progFile = Join-Path $outDir '_batch_progress.txt'
  if ($Opt.ContainsKey('progress_file') -and -not [string]::IsNullOrWhiteSpace([string]$Opt['progress_file'])) {
    $progFile = [string]$Opt['progress_file']
    if (-not [System.IO.Path]::IsPathRooted($progFile)) { $progFile = Join-Path $mroot $progFile }
  }
  $utf8 = New-Object System.Text.UTF8Encoding($false)

  Say ">> 批量出图：共 $($items.Count) 张 → $outDir"
  Say "   进度文件：$progFile"
  # 额度机械核算（2026-10-21）：总额与余量算好，别让 agent 自己估、也别闷声报「生成失败」
  $perImg = 0
  if ($script:PerImage -gt 0) { $perImg = [int]$script:PerImage }
  if ($perImg -gt 0) {
    $need = $perImg * $items.Count
    $balNow = 0
    if ($null -ne $script:AccountBalance) { $balNow = [int]$script:AccountBalance }
    $room = [int][Math]::Floor($balNow / $perImg)
    Say "   本次共 $($items.Count) 张 × $perImg 积分 = $need 积分；当前余额 $balNow 积分（约可出 $room 张）"
    if ($room -lt $items.Count) {
      Say "   ⚠️ 额度不够出完整批：只够 $room 张。**先出优先级最高的几张**，并把充值链接给用户（不要硬跑）"
    } elseif ($room -eq $items.Count) {
      Say "   ⚠️ 额度刚好够这一批、**没有余量**：若中途有图要重做，得先充值"
    }
  }
  Say ""
  [System.IO.File]::WriteAllText($progFile, "start $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') total=$($items.Count)`n", $utf8)

  $okc = 0
  $failc = 0
  $plan = @()
  for ($ix = 0; $ix -lt $items.Count; $ix++) {
    $it = $items[$ix]
    $idx = $ix + 1
    $outName = 'img_' + $idx
    if ($null -ne $it.out -and -not [string]::IsNullOrWhiteSpace([string]$it.out)) { $outName = [string]$it.out }

    $ptxt = ''
    if ($null -ne $it.promptFile -and -not [string]::IsNullOrWhiteSpace([string]$it.promptFile)) {
      $pp = [string]$it.promptFile
      if (-not [System.IO.Path]::IsPathRooted($pp)) { $pp = Join-Path $mroot $pp }
      if (-not (Test-Path -LiteralPath $pp -PathType Leaf)) {
        Say "---- [$idx/$($items.Count)] $outName ----"
        Say "[跳过] 提示词文件不存在：$pp"
        $failc++
        [System.IO.File]::AppendAllText($progFile, "FAIL $idx/$($items.Count) $outName (promptFile missing)`n", $utf8)
        continue
      }
      $ptxt = [System.IO.File]::ReadAllText($pp, [System.Text.Encoding]::UTF8)
    } elseif ($null -ne $it.prompt) {
      $ptxt = [string]$it.prompt
    }
    if ([string]::IsNullOrWhiteSpace($ptxt)) {
      Say "---- [$idx/$($items.Count)] $outName ----"
      Say "[跳过] 这一项没有 prompt / promptFile。"
      $failc++
      [System.IO.File]::AppendAllText($progFile, "FAIL $idx/$($items.Count) $outName (no prompt)`n", $utf8)
      continue
    }

    $size = $cliSize
    if ($null -ne $it.size -and -not [string]::IsNullOrWhiteSpace([string]$it.size)) { $size = [string]$it.size }
    elseif ($null -ne $def -and $null -ne $def.size) { $size = [string]$def.size }
    $qual = $cliQual
    if ($null -ne $it.quality -and -not [string]::IsNullOrWhiteSpace([string]$it.quality)) { $qual = [string]$it.quality }
    elseif ($null -ne $def -and $null -ne $def.quality) { $qual = [string]$def.quality }
    $mdl = $cliModel
    if ($null -ne $it.model -and -not [string]::IsNullOrWhiteSpace([string]$it.model)) { $mdl = [string]$it.model }
    elseif ($null -ne $def -and $null -ne $def.model) { $mdl = [string]$def.model }

    $refList = @()
    $refSrc = $null
    if ($null -ne $it.refs) { $refSrc = @($it.refs) }
    elseif ($null -ne $def -and $null -ne $def.refs) { $refSrc = @($def.refs) }
    elseif ($cliRefs.Count -gt 0) { $refSrc = $cliRefs }
    foreach ($r in $refSrc) {
      $rp = [string]$r
      if (-not [System.IO.Path]::IsPathRooted($rp)) { $rp = Join-Path $mroot $rp }
      if (Test-Path -LiteralPath $rp -PathType Leaf) { $refList += (Resolve-Path -LiteralPath $rp).Path }
    }

    $tmpP = Join-Path ([System.IO.Path]::GetTempPath()) ('cd_b_' + [guid]::NewGuid().ToString('N') + '.txt')
    [System.IO.File]::WriteAllText($tmpP, $ptxt, $utf8)

    $cargs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath,
               '--prompt-file', $tmpP, '--out', $outName, '--size', $size, '--quality', $qual)
    if (-not [string]::IsNullOrWhiteSpace($mdl)) { $cargs += @('--model', $mdl) }
    foreach ($r in $refList) { $cargs += @('--ref', $r) }

    # 每张用独立 pending 文件：并发时共享 pending.json 会竞态（可能重放错 rid → 串图）
    $cargs += @('--pending-file', (Join-Path $CRED_DIR ("pending_b$idx.json")))
    $plan += [pscustomobject]@{ Idx = $idx; Name = $outName; Args = $cargs; Tmp = $tmpP; Size = $size; Qual = $qual }
  }

  # ── 阶段二：窗口式并发，完成即交付（2026-10-21）──
  # 并发不改变「逐张交付」：进度文件按**完成顺序**写，每行带完成时刻与绝对路径，
  # 助手读它就能先交付已经好的那张（不必死等清单里的第 1 张）。
  $conc = 3
  if ($Opt.ContainsKey('concurrency') -and [int]$Opt['concurrency'] -gt 0) { $conc = [int]$Opt['concurrency'] }
  if ($plan.Count -gt 0 -and $conc -gt $plan.Count) { $conc = $plan.Count }
  if ($conc -lt 1) { $conc = 1 }
  Say "   并发：$conc（完成即交付，按完成顺序写入进度文件）"
  $env:CD_NO_UPDATE_CHECK = '1'   # 版本检查父进程已经做过，子进程不再重复查
  $logDir = Join-Path ([System.IO.Path]::GetTempPath()) ('cd_bat_' + [guid]::NewGuid().ToString('N'))
  [void](New-Item -ItemType Directory -Force -Path $logDir)
  $running = @()
  $next = 0
  while ($next -lt $plan.Count -or $running.Count -gt 0) {
    while ($running.Count -lt $conc -and $next -lt $plan.Count) {
      $t = $plan[$next]; $next++
      $log = Join-Path $logDir ("item_$($t.Idx).log")
      $errf = Join-Path $logDir ("item_$($t.Idx).err")
      # Start-Process 不会自动给含空格的参数加引号 → 自己加（Windows CRT 会剥掉）
      $qargs = @()
      foreach ($a in $t.Args) { if ([string]$a -match '\s') { $qargs += ('"' + [string]$a + '"') } else { $qargs += [string]$a } }
      $proc = Start-Process -FilePath 'powershell' -ArgumentList $qargs -WorkingDirectory $outDir `
               -RedirectStandardOutput $log -RedirectStandardError $errf -PassThru -WindowStyle Hidden
      $running += [pscustomobject]@{ Proc = $proc; Idx = $t.Idx; Name = $t.Name; Tmp = $t.Tmp; Log = $log; Err = $errf; Size = $t.Size; Qual = $t.Qual }
    }
    Start-Sleep -Milliseconds 600
    $still = @()
    foreach ($r in $running) {
      if (-not $r.Proc.HasExited) { $still += $r; continue }
      try { $r.Proc.WaitForExit() } catch { }
      $code = 0
      try { $code = [int]$r.Proc.ExitCode } catch { $code = -1 }
      Say "---- [$($r.Idx)/$($items.Count)] $($r.Name)  ($($r.Size), $($r.Qual)) ----"
      if (Test-Path -LiteralPath $r.Log) {
        $txt = [System.IO.File]::ReadAllText($r.Log, [System.Text.Encoding]::UTF8)
        if ($txt.Trim()) { Say $txt.TrimEnd() }
      }
      if (Test-Path -LiteralPath $r.Err) {
        $etxt = [System.IO.File]::ReadAllText($r.Err, [System.Text.Encoding]::Default)
        if ($etxt.Trim()) { Say $etxt.TrimEnd() }
      }
      Remove-Item -LiteralPath $r.Tmp -Force -ErrorAction SilentlyContinue
      $outPath = Join-Path $outDir $r.Name
      $stamp = Get-Date -Format 'HH:mm:ss'
      if ($code -eq 0 -and (Test-Path -LiteralPath $outPath -PathType Leaf)) {
        $okc++
        $line = "OK   $($r.Idx)/$($items.Count) $($r.Name)  $stamp  $outPath"
      } else {
        $failc++
        $line = "FAIL $($r.Idx)/$($items.Count) $($r.Name)  $stamp  (exit=$code)"
      }
      [System.IO.File]::AppendAllText($progFile, $line + "`n", $utf8)
      Say ""
    }
    $running = $still
  }
  $env:CD_NO_UPDATE_CHECK = $null
  Remove-Item -LiteralPath $logDir -Recurse -Force -ErrorAction SilentlyContinue
  [System.IO.File]::AppendAllText($progFile, "DONE $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ok=$okc fail=$failc`n", $utf8)
  Say "[批量完成] 成功 $okc / 共 $($items.Count)，失败 $failc"
  Say "   进度文件：$progFile"
  if ($failc -gt 0) { exit 1 }
  exit 0
}

# 提示词
$prompt = ''
if ($Opt.ContainsKey('prompt_file')) {
  $pf = [string]$Opt['prompt_file']
  if (-not (Test-Path -LiteralPath $pf -PathType Leaf)) { Die "提示词文件不存在：$pf" }
  $prompt = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $pf).Path, [System.Text.Encoding]::UTF8)
} elseif ($Opt.ContainsKey('prompt')) {
  $prompt = [string]$Opt['prompt']
} elseif ([Console]::IsInputRedirected) {
  $prompt = [Console]::In.ReadToEnd()
} else {
  Die "没有提示词。请用 --prompt、--prompt-file，或从管道输入。"
}
$prompt = $prompt.Trim()
if ([string]::IsNullOrWhiteSpace($prompt)) { Die "提示词是空的。" }

$size = '1024x1024'
if ($Opt.ContainsKey('size')) { $size = [string]$Opt['size'] }
$quality = 'medium'
if ($Opt.ContainsKey('quality')) { $quality = [string]$Opt['quality'] }
if (@('low', 'medium', 'high') -notcontains $quality) { Die "质量参数只能是 low / medium / high：$quality" }

$prompt = Anchor-Size $prompt $size
if ($prompt.Length -gt 4000) {
  Die "提示词 $($prompt.Length) 字符，超过服务端 4000 字符上限，会被直接拒。`n       怎么减：把必须原样出现的中文文案和构图写在前段，`n       砍掉光影氛围、材质质感、背景细节这类装饰性描述。"
}

# 模型取值顺序：显式 --model → 环境变量 IMAGE_MODEL → **服务端 /auth/login 下发的 defaultModel**
# （= 运营在 KV config.mainModel 里配的当前模型，运营改配置后买家下一次出图即生效）→ 静态兜底
$model = [string]$Opt['model']
if ([string]::IsNullOrWhiteSpace($model)) { $model = $env:IMAGE_MODEL }
if ([string]::IsNullOrWhiteSpace($model)) { $model = $script:DefaultModel }
if ([string]::IsNullOrWhiteSpace($model)) { $model = $DEFAULT_MODEL }

$refInput = @()
if ($Opt.ContainsKey('ref')) { $refInput = @($Opt['ref']) }
$refs = @(Check-Refs $refInput)
if ($refs.Count -gt 3) {
  Say "[提醒] 传了 $($refs.Count) 张参考图。多图上限各线路不同，超限会直接报参数错误。"
  Say "       如果报错，先减到 3 张以内再试。"
  Say ""
}

$timeout = 360
if ($Opt.ContainsKey('timeout')) { $timeout = [int]$Opt['timeout'] }

Say ">> 模型  $model   画幅 $size（只定比例）   质量 $quality   张数 $n"
if ($refs.Count -gt 0) {
  $names = @($refs | ForEach-Object { Split-Path -Leaf $_ }) -join ', '
  Say ">> 参考图 $($refs.Count) 张：$names"
}
Say ">> 生成中（高清档可能需要 1-2 分钟，请耐心等待）…"
Say ""

$t0 = Get-Date
if ($refs.Count -gt 0) {
  $files = @()
  foreach ($p in $refs) {
    $use = (Compress-Ref $p)
    $mime = 'image/jpeg'
    if ($use.ToLower().EndsWith('.png')) { $mime = 'image/png' }
    $fn = (Split-Path -Leaf $use)
    if ($use -ne $p) { $fn = [System.IO.Path]::GetFileNameWithoutExtension($p) + '.jpg' }
    $files += @{ name = 'image'; path = $use; filename = $fn; mime = $mime }
  }
  $fields = [ordered]@{ model = $model; prompt = $prompt; size = $size; quality = $quality; n = $n }
  $mp = Build-Multipart $fields $files
  $body = $mp.body
  $ctype = $mp.ctype
} else {
  $payload = [ordered]@{ model = $model; prompt = $prompt; size = $size; quality = $quality; n = $n }
  $body = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $payload -Depth 10 -Compress))
  $ctype = 'application/json'
}

$result = Invoke-Gen $cred $body $ctype $n $timeout

$items = @()
if ($null -ne $result.data) { $items = @($result.data) }
# 备援通道提示（2026-10-20）：主通道繁忙时会自动切到备援通道，如实告知
if ($null -ne $result.channel -and [string]$result.channel -eq 'backup') {
  $noteTxt = [string]$result.note
  if ([string]::IsNullOrWhiteSpace($noteTxt)) { $noteTxt = '本次由备援通道出图' }
  Say "[说明] $noteTxt"
}
if ($items.Count -eq 0) {
  $j = (ConvertTo-Json -InputObject $result -Depth 10 -Compress)
  if ($j.Length -gt 600) { $j = $j.Substring(0, 600) }
  Die "服务端没返回图片数据。原始返回：`n$j"
}

$stem = [string]$Opt['out']
if ([string]::IsNullOrWhiteSpace($stem)) { $stem = 'img_' + (Get-Date -Format 'yyyyMMdd_HHmmss') }
$ext = [System.IO.Path]::GetExtension($stem).ToLower()
if (@('.png', '.jpg', '.jpeg', '.webp') -contains $ext) {
  $stem = $stem.Substring(0, $stem.Length - $ext.Length)
}

$written = @()
for ($idx = 0; $idx -lt $items.Count; $idx++) {
  $item = $items[$idx]
  if ($idx -eq 0) { $outp = $stem + '.png' } else { $outp = $stem + '_' + ($idx + 1) + '.png' }
  $sz = $null
  if ($null -ne $item.b64_json -and -not [string]::IsNullOrWhiteSpace([string]$item.b64_json)) {
    $sz = Save-B64 ([string]$item.b64_json) $outp
  } elseif ($null -ne $item.url -and -not [string]::IsNullOrWhiteSpace([string]$item.url)) {
    $sz = Save-Url ([string]$item.url) $outp
  } else {
    continue
  }
  $written += @{ name = (Split-Path -Leaf $outp); size = $sz; px = (Get-PngSize $outp) }
}

$first = $items[0]
if ($null -ne $first.revised_prompt -and -not [string]::IsNullOrWhiteSpace([string]$first.revised_prompt)) {
  $rp = [string]$first.revised_prompt
  $shown = $rp
  if ($rp.Length -gt 300) { $shown = $rp.Substring(0, 300) + ' ...' }
  Say ""
  Say "[注意] 服务端把提示词改写成了："
  Say "  $shown"
  Say "       如果改写后中文文案变了，把关键文字在提示词里逐字写死再跑。"
  Say "       另：出图后请亲眼看图确认中文文字没写错——出图线路可能静默降级模型，中文会变乱码。"
}

$dt = [math]::Round((((Get-Date) - $t0).TotalSeconds), 1)
$free = 0
if ($null -ne $result.free) { $free = [int]$result.free }
$note = ''
if ($free -gt 0) { $note = " + 今日免费 $free" }
$bal = '?'
if ($null -ne $result.credits) { $bal = [string]$result.credits }
Say ""
Say "[完成] 用时 $dt s   剩余 $bal 积分$note"
foreach ($w in $written) {
  $pxTxt = ''
  if (-not [string]::IsNullOrWhiteSpace([string]$w.px)) { $pxTxt = ", $($w.px)" }
  Say "  $($w.name)  ($([int]($w.size / 1024)) KB$pxTxt)"
}
if ($written.Count -eq 0) { Die "没有解析到图片，请检查服务端返回格式。" }
exit 0
