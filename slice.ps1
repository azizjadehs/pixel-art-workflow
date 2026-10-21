# slice.ps1 - workflow step 3: detect the individual sprites in a
# character sheet and turn them into an import-ready sprite sheet
# (uniform cells + Aseprite JSON) and a multi-frame .aseprite.
#
# Detection is done by background-colour segmentation and row/column
# projection, which gives exact pixel bounding boxes (a vision model only
# gives approximate boxes and would break pixel alignment).
#
# usage:
#   .\slice.ps1 output\my-art-generated.png
#   .\slice.ps1 output\my-art-generated.png -Gap 3 -Pad 1

param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$InputFile,

    [string]$OutDir = "",
    # max empty columns inside one row before splitting it into 2 sprites
    [int]$Gap = 3,
    # ignore blobs smaller than this many px
    [int]$MinArea = 16,
    # padding inside each uniform cell
    [int]$Pad = 1
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $scriptDir "output" }

if (-not (Test-Path $InputFile)) { throw "Input image not found: $InputFile" }

$inPath = (Resolve-Path $InputFile).Path
$base = [System.IO.Path]::GetFileNameWithoutExtension($inPath)
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$img = [System.Drawing.Image]::FromFile($inPath)
$bmp = New-Object System.Drawing.Bitmap $img
$w = $bmp.Width
$h = $bmp.Height

# ------------------------------------------------------ background colour
# most frequent colour around the border of the image
$counts = @{}
for ($x = 0; $x -lt $w; $x++) {
    foreach ($y in @(0, ($h - 1))) {
        $c = $bmp.GetPixel($x, $y)
        $k = "$($c.R),$($c.G),$($c.B)"
        if ($counts.ContainsKey($k)) { $counts[$k]++ } else { $counts[$k] = 1 }
    }
}
for ($y = 0; $y -lt $h; $y++) {
    foreach ($x in @(0, ($w - 1))) {
        $c = $bmp.GetPixel($x, $y)
        $k = "$($c.R),$($c.G),$($c.B)"
        if ($counts.ContainsKey($k)) { $counts[$k]++ } else { $counts[$k] = 1 }
    }
}
$bgKey = ($counts.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key
$bgParts = $bgKey.Split(',')
$bgR = [int]$bgParts[0]; $bgG = [int]$bgParts[1]; $bgB = [int]$bgParts[2]
Write-Host "background: rgb($bgR,$bgG,$bgB)"

# ------------------------------------------------------------- foreground
$tol = 28
$fg = New-Object 'bool[,]' $w, $h
for ($y = 0; $y -lt $h; $y++) {
    for ($x = 0; $x -lt $w; $x++) {
        $c = $bmp.GetPixel($x, $y)
        $d = [math]::Abs($c.R - $bgR) + [math]::Abs($c.G - $bgG) + [math]::Abs($c.B - $bgB)
        $fg[$x, $y] = ($d -gt $tol)
    }
}

# ------------------------------------------------------- row projection
# a band = consecutive rows that contain any sprite pixel
$bands = New-Object System.Collections.ArrayList
$start = -1
for ($y = 0; $y -lt $h; $y++) {
    $any = $false
    for ($x = 0; $x -lt $w -and -not $any; $x++) { if ($fg[$x, $y]) { $any = $true } }
    if ($any -and $start -lt 0) { $start = $y }
    elseif (-not $any -and $start -ge 0) {
        [void]$bands.Add([pscustomobject]@{ Y0 = $start; Y1 = $y - 1 })
        $start = -1
    }
}
if ($start -ge 0) { [void]$bands.Add([pscustomobject]@{ Y0 = $start; Y1 = $h - 1 }) }

if ($bands.Count -eq 0) { throw "No sprites detected - is the background one flat colour?" }

# ------------------------------------------------- column projection
# inside each band, split on runs of empty columns; small runs (<= Gap)
# are tolerated so a held weapon stays with its body
$boxes = New-Object System.Collections.ArrayList
foreach ($band in $bands) {
    $runs = New-Object System.Collections.ArrayList
    $runStart = -1
    $emptyRun = 0
    for ($x = 0; $x -lt $w; $x++) {
        $any = $false
        for ($y = $band.Y0; $y -le $band.Y1 -and -not $any; $y++) { if ($fg[$x, $y]) { $any = $true } }
        if ($any) {
            if ($runStart -lt 0) { $runStart = $x }
            $emptyRun = 0
        } else {
            if ($runStart -ge 0) {
                $emptyRun++
                if ($emptyRun -gt $Gap) {
                    [void]$runs.Add(@($runStart, ($x - $emptyRun)))
                    $runStart = -1
                    $emptyRun = 0
                }
            }
        }
    }
    if ($runStart -ge 0) { [void]$runs.Add(@($runStart, ($w - 1))) }

    foreach ($r in $runs) {
        # tight bounding box of this sprite
        $minX = $w; $maxX = 0; $minY = $h; $maxY = 0; $area = 0
        for ($x = $r[0]; $x -le $r[1]; $x++) {
            for ($y = $band.Y0; $y -le $band.Y1; $y++) {
                if ($fg[$x, $y]) {
                    $area++
                    if ($x -lt $minX) { $minX = $x }
                    if ($x -gt $maxX) { $maxX = $x }
                    if ($y -lt $minY) { $minY = $y }
                    if ($y -gt $maxY) { $maxY = $y }
                }
            }
        }
        if ($area -lt $MinArea) { continue }
        [void]$boxes.Add([pscustomobject]@{
            X = $minX; Y = $minY
            W = $maxX - $minX + 1; H = $maxY - $minY + 1
            Area = $area
        })
    }
}

if ($boxes.Count -eq 0) { throw "No sprites detected - is the background one flat colour?" }

# ----------------------------------------------------- reading order
$sorted = @($boxes | Sort-Object Y, X)

$maxW = ($sorted | Measure-Object -Property W -Maximum).Maximum
$maxH = ($sorted | Measure-Object -Property H -Maximum).Maximum
$cellW = [int]$maxW + 2 * $Pad
$cellH = [int]$maxH + 2 * $Pad
$n = $sorted.Count

Write-Host ("detected {0} sprite(s)" -f $n)
for ($i = 0; $i -lt $n; $i++) {
    $b = $sorted[$i]
    Write-Host ("  #{0}: x={1} y={2} {3}x{4}  (cell {5}x{6})" -f ($i + 1), $b.X, $b.Y, $b.W, $b.H, $cellW, $cellH)
}

# --------------------------------------------------- uniform sheet + JSON
# transparent background, sprites centred and bottom-aligned on a shared
# baseline so they are animation-ready
$sheet = New-Object System.Drawing.Bitmap ([int]($cellW * $n)), ([int]$cellH)
for ($i = 0; $i -lt $n; $i++) {
    $b = $sorted[$i]
    $dx = $i * $cellW + [int][math]::Floor(($cellW - $b.W) / 2)
    $dy = $cellH - $Pad - $b.H
    for ($y = 0; $y -lt $b.H; $y++) {
        for ($x = 0; $x -lt $b.W; $x++) {
            $sheet.SetPixel($dx + $x, $dy + $y, $bmp.GetPixel($b.X + $x, $b.Y + $y))
        }
    }
}

$sheetPath = Join-Path $OutDir "$base-sheet.png"
$jsonPath = Join-Path $OutDir "$base-sheet.json"
$asePath = Join-Path $OutDir "$base-sprites.aseprite"
$sheet.Save($sheetPath, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose(); $img.Dispose(); $sheet.Dispose()

$viewNames = @()
for ($i = 0; $i -lt $n; $i++) {
    $viewNames += if ($n -eq 4) { @("front", "three-quarter", "side", "back")[$i] } else { "view-$($i + 1)" }
}

$frames = [ordered]@{}
$tags = @()
for ($i = 0; $i -lt $n; $i++) {
    $frames[$viewNames[$i]] = [ordered]@{
        frame            = [ordered]@{ x = $i * $cellW; y = 0; w = $cellW; h = $cellH }
        rotated          = $false
        trimmed          = $false
        spriteSourceSize = [ordered]@{ x = 0; y = 0; w = $cellW; h = $cellH }
        sourceSize       = [ordered]@{ w = $cellW; h = $cellH }
        duration         = 100
    }
    $tags += [ordered]@{ name = $viewNames[$i]; from = $i; to = $i; direction = "forward" }
}
$doc = [ordered]@{
    frames = $frames
    meta   = [ordered]@{
        app       = "pixel-art-workflow"
        version   = "1.0"
        image     = (Split-Path $sheetPath -Leaf)
        format    = "RGBA8888"
        size      = [ordered]@{ w = $cellW * $n; h = $cellH }
        scale     = "1"
        frameTags = $tags
    }
}
$doc | ConvertTo-Json -Depth 8 | Set-Content -Path $jsonPath -Encoding UTF8

# --------------------------------------------- multi-frame .aseprite
. (Join-Path $scriptDir "scripts\resolve-aseprite.ps1")
$ase = Resolve-Aseprite -ScriptDir $scriptDir
$lua = Join-Path $scriptDir "scripts\build_frames.lua"
$log = Join-Path $env:TEMP "pixel-art-workflow.log"
if ($ase) {
    $namesStr = $viewNames -join ";"
    $cmd = "`"$ase`" -b `"--script-param`" `"cellW=$cellW`" `"--script-param`" `"cellH=$cellH`" " +
           "`"--script-param`" `"count=$n`" `"--script-param`" `"names=$namesStr`" " +
           "`"--script-param`" `"out=$asePath`" `"$sheetPath`" `"--script`" `"$lua`" > `"$log`" 2>&1"
    cmd /c $cmd
    if ($LASTEXITCODE -ne 0) {
        Get-Content $log
        Write-Host "warning: could not build the multi-frame .aseprite (sheet PNG + JSON are still valid)"
    } else {
        Write-Host "built : $asePath"
    }
}

Write-Host "sheet : $sheetPath"
Write-Host "json  : $jsonPath"
Write-Host "cells : $n x ${cellW}x${cellH} (uniform)"

