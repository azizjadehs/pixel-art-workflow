# generate.ps1 - workflow step 1: send your art + prompt.txt to the
# Gemini image API and save the pixel art character into input/.
#
# requires: a Gemini API key (see README.md)
#
# usage:
#   .\generate.ps1 my-art.png
#   .\generate.ps1 my-art.png -PromptFile prompt.txt -Model gemini-2.5-flash-image
#   .\generate.ps1 my-art.png -Chain      # also runs run.ps1 on the result

param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$ImageFile,

    [string]$PromptFile = "",
    [string]$Model = "gemini-2.5-flash-image",

    [string]$OutDir = "",
    [switch]$Chain
)

$ErrorActionPreference = "Stop"

# $PSScriptRoot is empty in param() defaults when the script is started
# with -File (e.g. from the web app), so resolve paths here instead
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $PromptFile) { $PromptFile = Join-Path $scriptDir "prompt.txt" }
if (-not $OutDir) { $OutDir = Join-Path $scriptDir "input" }

# ---------------------------------------------------------------- key
$apiKey = $env:GEMINI_API_KEY
if (-not $apiKey) {
    # accept .env or .env.txt (Windows Notepad loves adding that extension)
    foreach ($name in @(".env", ".env.txt")) {
        $envFile = Join-Path $scriptDir $name
        if (Test-Path $envFile) {
            $line = Select-String -Path $envFile -Pattern '^\s*(?:GEMINI_API_KEY|GOOGLE_API_KEY|OPENAI_API_KEY)\s*=\s*(.+?)\s*$' |
                Select-Object -First 1
            if ($line) { $apiKey = $line.Matches[0].Groups[1].Value.Trim("'`""); break }
        }
    }
}
if (-not $apiKey) {
    throw ("No Gemini API key found. Set the GEMINI_API_KEY environment " +
           "variable or put GEMINI_API_KEY=... in .env (or .env.txt)")
}

# ------------------------------------------------------------- inputs
if (-not (Test-Path $ImageFile)) { throw "Image not found: $ImageFile" }
if (-not (Test-Path $PromptFile)) { throw "Prompt file not found: $PromptFile" }

$imagePath = (Resolve-Path $ImageFile).Path
$prompt = (Get-Content -Raw -Path (Resolve-Path $PromptFile).Path).Trim()
if (-not $prompt) { throw "Prompt file is empty: $PromptFile" }

$mimeType = switch ([System.IO.Path]::GetExtension($imagePath).ToLower()) {
    ".png"  { "image/png" }
    ".jpg"  { "image/jpeg" }
    ".jpeg" { "image/jpeg" }
    ".webp" { "image/webp" }
    ".gif"  { "image/gif" }
    default { throw "Unsupported image type: $imagePath (use png/jpg/webp/gif)" }
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$base = [System.IO.Path]::GetFileNameWithoutExtension($imagePath)
$outPath = Join-Path $OutDir "$base-generated.png"

Write-Host "art    : $imagePath"
Write-Host "model  : $Model"
Write-Host "output : $outPath"

# --------------------------------------------------------------- call
# .NET HttpClient lives in System.Net.Http, not loaded by default in
# Windows PowerShell 5.1
Add-Type -AssemblyName System.Net.Http

# Gemini generateContent: prompt + reference image in, image out
$uri = "https://generativelanguage.googleapis.com/v1beta/models/${Model}:generateContent"

$b64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($imagePath))
$payload = @{
    contents = @(
        @{
            parts = @(
                @{ text = $prompt }
                @{ inlineData = @{ mimeType = $mimeType; data = $b64 } }
            )
        }
    )
    generationConfig = @{ responseModalities = @("TEXT", "IMAGE") }
} | ConvertTo-Json -Depth 12

$client = New-Object System.Net.Http.HttpClient
$client.Timeout = [TimeSpan]::FromSeconds(180)
try {
    $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, $uri)
    $req.Headers.Add("x-goog-api-key", $apiKey)
    $req.Content = New-Object System.Net.Http.StringContent($payload, [System.Text.Encoding]::UTF8, "application/json")
    try {
        $resp = $client.SendAsync($req).GetAwaiter().GetResult()
        $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if (-not $resp.IsSuccessStatusCode) {
            # surface the API's own error message (bad key, quota, billing)
            $msg = try { ($body | ConvertFrom-Json).error.message } catch { $body }
            throw "Gemini API returned $([int]$resp.StatusCode): $msg"
        }
    } finally {
        $req.Dispose()
    }
} finally {
    $client.Dispose()
}

# ----------------------------------------------------------- response
$json = $body | ConvertFrom-Json
$cand = $json.candidates
if (-not $cand) {
    $block = try { $json.promptFeedback.blockReason } catch { $null }
    throw "No candidates in response$(if ($block) { " (blocked: $block)" }): $body"
}

$bytes = $null
foreach ($part in $cand[0].content.parts) {
    if ($part.inlineData.data) { $bytes = [Convert]::FromBase64String($part.inlineData.data); break }
}
if (-not $bytes) {
    # some replies are text-only - explain instead of writing an empty file
    $txt = ($cand[0].content.parts | Where-Object { $_.text } | ForEach-Object { $_.text }) -join " "
    throw "Model replied without an image.$(if ($txt) { " Text: $($txt.Substring(0, [Math]::Min(300, $txt.Length)))" })"
}
[System.IO.File]::WriteAllBytes($outPath, $bytes)
Write-Host "saved  : $outPath ($([math]::Round($bytes.Length/1KB)) KB)"

# ------------------------------------------- also save an .aseprite copy
# keep the raw result in Aseprite's own format so it opens directly in the
# editor, before any pixelation happens
. (Join-Path $scriptDir "scripts\resolve-aseprite.ps1")
$ase = Resolve-Aseprite -ScriptDir $scriptDir
$outAse = Join-Path $OutDir "$base-generated.aseprite"
if ($ase) {
    $log = Join-Path $env:TEMP "pixel-art-workflow.log"
    cmd /c "`"$ase`" -b `"$outPath`" --save-as `"$outAse`" > `"$log`" 2>&1"
    if ($LASTEXITCODE -eq 0 -and (Test-Path $outAse)) {
        Write-Host "saved  : $outAse"
    } else {
        Get-Content $log
        Write-Host "warning: could not create the .aseprite copy (PNG is still there)"
    }
} else {
    Write-Host "warning: $ase not found - skipped the .aseprite copy"
}

# -------------------------------------------------------------- chain
if ($Chain) {
    & (Join-Path $scriptDir "run.ps1") $outPath
}
