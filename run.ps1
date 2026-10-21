# run.ps1 - pixel-art workflow step 2: downscale a ChatGPT image to a
# 32px grid with <=26 colors, ready for editing in Aseprite.
#
# usage:
#   .\run.ps1 input\character.png
#   .\run.ps1 input\character.png -Size 32 -Colors 26 -Filter nearest

param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$InputFile,

    # downscale to this % of the source size (e.g. 30). Overrides -Size.
    [int]$Percent = 0,

    [int]$Size = 32,
    [int]$Colors = 26,

    [ValidateSet("nearest", "average")]
    [string]$Filter = "nearest",

    [string]$OutDir = ""
)

$ErrorActionPreference = "Stop"

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $scriptDir "output" }

. (Join-Path $scriptDir "scripts\resolve-aseprite.ps1")
$ase    = Resolve-Aseprite -ScriptDir $scriptDir
$script = Join-Path $scriptDir "scripts\pixelate.lua"
$log    = Join-Path $env:TEMP "pixel-art-workflow.log"

if (-not $ase) {
    throw "Aseprite not found. Set ASEPRITE_EXE (env var or .env / .env.txt) or add aseprite to PATH."
}
if (-not (Test-Path $InputFile)) {
    throw "Input image not found: $InputFile"
}

$inPath  = (Resolve-Path $InputFile).Path
$base    = [System.IO.Path]::GetFileNameWithoutExtension($inPath)
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$outAse = Join-Path $OutDir "$base.aseprite"
$outPng = Join-Path $OutDir "$base.png"

# percent mode overrides the fixed-size grid
$percentArg = ""
$gridDesc = "${Size}px max"
if ($Percent -gt 0) {
    $percentArg = "--script-param percent=$Percent "
    $gridDesc = "$Percent% of source"
}

Write-Host "input : $inPath"
Write-Host "grid  : $gridDesc, $Colors colors, filter=$Filter"
Write-Host "output: $outAse"

# NOTE: --script-param must come before --script, and the input file before
# the script, so the sprite is open when the script runs.
$cmd = "`"$ase`" -b " +
       "--script-param input=`"$inPath`" " +
       $percentArg +
       "--script-param size=$Size " +
       "--script-param colors=$Colors " +
       "--script-param filter=$Filter " +
       "--script-param outAse=`"$outAse`" " +
       "--script-param outPng=`"$outPng`" " +
       "`"$inPath`" " +
       "--script `"$script`" > `"$log`" 2>&1"

cmd /c $cmd
if ($LASTEXITCODE -ne 0) {
    Get-Content $log
    throw "Aseprite failed with exit code $LASTEXITCODE"
}

Get-Content $log
if (-not (Test-Path $outAse)) {
    throw "Script reported success but $outAse was not created"
}
Write-Host "done."
