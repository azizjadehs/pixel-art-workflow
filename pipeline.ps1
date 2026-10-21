# pipeline.ps1 - the whole workflow in one go:
#   your art -> Gemini image API -> 32px/26-color .aseprite + PNG
#
# usage:
#   .\pipeline.ps1                     # picks the newest image in input\
#   .\pipeline.ps1 input\my-art.png    # or names the art explicitly
#   .\pipeline.ps1 -Open               # also opens the result in Aseprite
#   .\pipeline.ps1 -Size 48 -Colors 32 # different grid / palette

param(
    [Parameter(Position = 0)]
    [string]$ArtFile,

    [string]$PromptFile = "",
    [string]$Model = "gemini-2.5-flash-image",

    # downscale to this % of the source size (e.g. 30). Overrides -Size.
    [int]$Percent = 0,

    [int]$Size = 32,
    [int]$Colors = 26,
    [ValidateSet("nearest", "average")]
    [string]$Filter = "nearest",

    [switch]$Open
)

$ErrorActionPreference = "Stop"
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $root "scripts\resolve-aseprite.ps1")
$ase  = Resolve-Aseprite -ScriptDir $root
if (-not $PromptFile) { $PromptFile = Join-Path $root "prompt.txt" }

# ------------------------------------------- find the art to work from
if (-not $ArtFile) {
    $exts = @("*.png", "*.jpg", "*.jpeg", "*.webp", "*.gif")
    $candidate = Get-ChildItem -Path (Join-Path $root "input") -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -match '^\.(png|jpe?g|webp|gif)$' } |
        Where-Object { $_.Name -notlike "*-generated*" } |   # skip our own outputs
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $candidate) {
        throw ("No art found. Drop an image into " +
               "$(Join-Path $root 'input') and run this again.")
    }
    $ArtFile = $candidate.FullName
    Write-Host "picked : $($candidate.Name) (newest in input\)"
}
if (-not (Test-Path $ArtFile)) { throw "Art file not found: $ArtFile" }

$base = [System.IO.Path]::GetFileNameWithoutExtension((Resolve-Path $ArtFile).Path)

Write-Host ""
Write-Host "=== 1/3: Gemini image generation ===" -ForegroundColor Cyan
& (Join-Path $root "generate.ps1") -ImageFile $ArtFile -PromptFile $PromptFile -Model $Model

Write-Host ""
Write-Host "=== 2/3: Aseprite pixelation ===" -ForegroundColor Cyan
& (Join-Path $root "run.ps1") -InputFile (Join-Path $root "input\$base-generated.png") `
    -Percent $Percent -Size $Size -Colors $Colors -Filter $Filter

Write-Host ""
Write-Host "=== 3/3: sprite detection and slicing ===" -ForegroundColor Cyan
& (Join-Path $root "slice.ps1") -InputFile (Join-Path $root "output\$base-generated.png") `
    -OutDir (Join-Path $root "output")

# ------------------------------------------------------------- summary
$finalAse = Join-Path $root "output\$base-generated.aseprite"
$finalPng = Join-Path $root "output\$base-generated.png"
$spritesAse = Join-Path $root "output\$base-generated-sprites.aseprite"
$sheetPng = Join-Path $root "output\$base-generated-sheet.png"
if (-not (Test-Path $finalAse)) { throw "Pipeline finished but $finalAse is missing" }

Write-Host ""
Write-Host "=== done ===" -ForegroundColor Green
Write-Host "art      : $ArtFile"
Write-Host "raw      : input\$base-generated.png / .aseprite"
Write-Host "pixel art: output\$base-generated.aseprite   <- whole sheet"
Write-Host "preview  : output\$base-generated.png"
if (Test-Path $spritesAse) {
    Write-Host "sprites  : output\$base-generated-sprites.aseprite   <- one frame per view"
    Write-Host "import   : output\$base-generated-sheet.png + .json  <- Aseprite 'Import Sprite Sheet'"
}

if ($Open) {
    $toOpen = if (Test-Path $spritesAse) { $spritesAse } else { $finalAse }
    if ($ase) {
        Write-Host "opening $toOpen in Aseprite..."
        Start-Process -FilePath $ase -ArgumentList "`"$toOpen`""
    } else {
        Write-Host "warning: Aseprite not found (set ASEPRITE_EXE) - open the file manually"
    }
}
