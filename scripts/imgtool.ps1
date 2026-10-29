# imgtool.ps1 — 轻量图片处理（裁剪 / 放大 / 白场归一 / 拼总览图）
# 用途：这台机器常常没装 Python（PIL 不可用），本脚本用 .NET System.Drawing 顶替，
#       免得每次都现写一大段绘图代码。
#
# 用法（四个子命令，互斥）：
#   imgtool.ps1 -Crop  in.png -Out out.png -X 100 -Y 200 -W 400 -H 300
#   imgtool.ps1 -Zoom  in.png -Out out.png -X 100 -Y 200 -W 400 -H 300 -Scale 3
#   imgtool.ps1 -White in.png -Out out.png -Threshold 245
#   imgtool.ps1 -Sheet out.png -Files "a.png,b.png,c.png" -Cols 3 -Cell 420 -Labels "主图,详情,场景"
#
# ⚠️ 本文件必须以 UTF-8 with BOM 保存：PowerShell 5.1 读无 BOM 的 UTF-8 会按 GBK 解码，
#    中文字符串会变乱码甚至语法报错。
#Requires -Version 5.1

param(
  [string]$Crop,
  [string]$Zoom,
  [string]$White,
  [string]$Sheet,
  [string]$Size,
  [string]$Out,
  [int]$X = 0,
  [int]$Y = 0,
  [int]$W = 0,
  [int]$H = 0,
  [double]$Scale = 2,
  [int]$Threshold = 245,
  [string]$Files,
  [int]$Cols = 3,
  [int]$Cell = 420,
  [string]$Labels
)

$ErrorActionPreference = 'Stop'
# 输出统一 UTF-8：助手用 shell 捕获 stdout 时按 UTF-8 读，而 PS 5.1 默认按 GBK 输出 → 乱码
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
Add-Type -AssemblyName System.Drawing

function Say([string]$m) { Write-Host $m }

function Die([string]$m) {
  Write-Host "[错误] $m"
  exit 1
}

function Load-Img([string]$p) {
  if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { Die "文件不存在：$p" }
  return [System.Drawing.Image]::FromFile((Resolve-Path -LiteralPath $p).Path)
}

function Save-Img($img, [string]$path) {
  if ([string]::IsNullOrWhiteSpace($path)) { Die "缺少 -Out（输出路径）。" }
  $dir = Split-Path -Parent $path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $img.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
}

function Crop-Img([string]$src, [string]$dst, [int]$x, [int]$y, [int]$w, [int]$h, [double]$scale) {
  $img = Load-Img $src
  try {
    if ($w -le 0) { $w = $img.Width - $x }
    if ($h -le 0) { $h = $img.Height - $y }
    if ($x -lt 0 -or $y -lt 0 -or ($x + $w) -gt $img.Width -or ($y + $h) -gt $img.Height) {
      Die "裁剪区域超出图片范围：$src 尺寸 $($img.Width)x$($img.Height)，请求 X=$x Y=$y W=$w H=$h"
    }
    $dw = [int][Math]::Round($w * $scale)
    $dh = [int][Math]::Round($h * $scale)
    $bmp = New-Object System.Drawing.Bitmap($dw, $dh)
    try {
      $g = [System.Drawing.Graphics]::FromImage($bmp)
      try {
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $srcRect = New-Object System.Drawing.Rectangle($x, $y, $w, $h)
        $dstRect = New-Object System.Drawing.Rectangle(0, 0, $dw, $dh)
        $g.DrawImage($img, $dstRect, $srcRect, [System.Drawing.GraphicsUnit]::Pixel)
      } finally { $g.Dispose() }
      Save-Img $bmp $dst
    } finally { $bmp.Dispose() }
    Say "[OK] $src -> $dst  裁剪区域 ${x},${y} ${w}x${h}  输出 ${dw}x${dh}"
  } finally { $img.Dispose() }
}

function White-Bg([string]$src, [string]$dst, [int]$th) {
  $img = Load-Img $src
  try {
    $bmp = New-Object System.Drawing.Bitmap($img.Width, $img.Height, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    try {
      $g = [System.Drawing.Graphics]::FromImage($bmp)
      try { $g.DrawImage($img, 0, 0, $bmp.Width, $bmp.Height) } finally { $g.Dispose() }
      $rect = New-Object System.Drawing.Rectangle(0, 0, $bmp.Width, $bmp.Height)
      $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadWrite, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
      try {
        $len = [Math]::Abs($data.Stride) * $data.Height
        $buf = New-Object byte[] $len
        [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $buf, 0, $len)
        $n = 0
        for ($i = 0; $i -lt ($len - 2); $i += 3) {
          $bb = $buf[$i]
          $gg = $buf[$i + 1]
          $rr = $buf[$i + 2]
          if ($bb -ge $th -and $gg -ge $th -and $rr -ge $th) {
            $buf[$i] = 255
            $buf[$i + 1] = 255
            $buf[$i + 2] = 255
            $n++
          }
        }
        [System.Runtime.InteropServices.Marshal]::Copy($buf, 0, $data.Scan0, $len)
        Say "[OK] $src -> $dst  白场归一：$n 个近白像素(>= $th) 压到纯白 255"
      } finally { $bmp.UnlockBits($data) }
      Save-Img $bmp $dst
    } finally { $bmp.Dispose() }
  } finally { $img.Dispose() }
}

function Make-Sheet([string]$dst, [string]$fileList, [int]$cols, [int]$cell, [string]$labelList) {
  $list = @()
  foreach ($f in ($fileList -split ',')) {
    $t = $f.Trim()
    if ($t -ne '') { $list += $t }
  }
  if ($list.Count -eq 0) { Die "-Files 为空。用法：-Sheet out.png -Files "a.png,b.png"" }
  if ($cols -lt 1) { $cols = 1 }
  $rows = [int][Math]::Ceiling($list.Count / $cols)
  if ($cell -lt 80) { $cell = 80 }
  $pad = 12
  $labelH = 0
  $labels = @()
  if (-not [string]::IsNullOrWhiteSpace($labelList)) {
    foreach ($l in ($labelList -split ',')) { $labels += $l.Trim() }
  }
  if ($labels.Count -gt 0) { $labelH = 30 }
  $cellH = $cell + $labelH
  $W = $cols * ($cell + $pad) + $pad
  $H = $rows * ($cellH + $pad) + $pad
  $bmp = New-Object System.Drawing.Bitmap($W, $H)
  try {
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
      $g.Clear([System.Drawing.Color]::White)
      $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
      $font = New-Object System.Drawing.Font('Microsoft YaHei', 13)
      try {
        for ($i = 0; $i -lt $list.Count; $i++) {
          $col = $i % $cols
          $row = [int][Math]::Floor($i / $cols)
          $cx = $pad + $col * ($cell + $pad)
          $cy = $pad + $row * ($cellH + $pad)
          $im = $null
          try {
            if (Test-Path -LiteralPath $list[$i] -PathType Leaf) {
              $im = [System.Drawing.Image]::FromFile((Resolve-Path -LiteralPath $list[$i]).Path)
            }
          } catch { $im = $null }
          if ($null -ne $im) {
            try {
              $sc = [Math]::Min($cell / $im.Width, $cell / $im.Height)
              $dw = [int][Math]::Round($im.Width * $sc)
              $dh = [int][Math]::Round($im.Height * $sc)
              $dx = $cx + [int](($cell - $dw) / 2)
              $dy = $cy + [int](($cell - $dh) / 2)
              $g.DrawImage($im, $dx, $dy, $dw, $dh)
            } finally { $im.Dispose() }
          }
          if ($i -lt $labels.Count -and $labels[$i] -ne '') {
            $g.DrawString($labels[$i], $font, [System.Drawing.Brushes]::Black, [float]$cx, [float]($cy + $cell + 4))
          }
        }
      } finally { $font.Dispose() }
    } finally { $g.Dispose() }
    Save-Img $bmp $dst
  } finally { $bmp.Dispose() }
  Say "[OK] 拼总览图 $dst  ${W}x${H}  （$cols 列 x $rows 行，$($list.Count) 张）"
}

function Show-Size([string]$fileList) {
  $list = @()
  foreach ($f in ($fileList -split ',')) {
    $t = $f.Trim()
    if ($t -ne '') { $list += $t }
  }
  if ($list.Count -eq 0) { Die "-Size 为空。用法：-Size \"a.png,b.png\"" }
  foreach ($f in $list) {
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { Say "缺失：$f"; continue }
    $fi = Get-Item -LiteralPath $f
    $im = $null
    try { $im = [System.Drawing.Image]::FromFile($fi.FullName) } catch { }
    if ($null -eq $im) { Say "无法读取：$f"; continue }
    try {
      $fmt = ''
      try { $fmt = $im.RawFormat.ToString() } catch { }
      $kb = [int]($fi.Length / 1024)
      Say ("{0}  {1}x{2}  {3} KB  {4}" -f $fi.Name, $im.Width, $im.Height, $kb, $fmt)
    } finally { $im.Dispose() }
  }
}

if ($Size) {
  Show-Size $Size
  exit 0
}
if ($Crop) {
  Crop-Img $Crop $Out $X $Y $W $H 1.0
  exit 0
}
if ($Zoom) {
  Crop-Img $Zoom $Out $X $Y $W $H $Scale
  exit 0
}
if ($White) {
  White-Bg $White $Out $Threshold
  exit 0
}
if ($Sheet) {
  Make-Sheet $Sheet $Files $Cols $Cell $Labels
  exit 0
}
Write-Host "用法："
Write-Host "  imgtool.ps1 -Crop  in.png -Out out.png -X 100 -Y 200 -W 400 -H 300"
Write-Host "  imgtool.ps1 -Zoom  in.png -Out out.png -X 100 -Y 200 -W 400 -H 300 -Scale 3"
Write-Host "  imgtool.ps1 -White in.png -Out out.png -Threshold 245"
Write-Host "  imgtool.ps1 -Sheet out.png -Files ""a.png,b.png"" -Cols 3 -Cell 420 -Labels ""主图,详情"""
Write-Host "  imgtool.ps1 -Size ""a.png,b.png""                    量尺寸（宽x高 / 体积 / 格式）"
exit 1
