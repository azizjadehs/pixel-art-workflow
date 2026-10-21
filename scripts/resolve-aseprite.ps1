# resolve-aseprite.ps1 - find the Aseprite binary without hardcoding a
# personal install path (this repo is public, so local paths stay out).
#
# lookup order:
#   1. $env:ASEPRITE_EXE
#   2. ASEPRITE_EXE=... in a local .env / .env.txt (both are gitignored)
#   3. aseprite on PATH
#   4. the usual Windows install locations
#
# returns $null when nothing is found; the caller decides if that is fatal.

function Resolve-Aseprite {
    param([string]$ScriptDir)

    if ($env:ASEPRITE_EXE -and (Test-Path $env:ASEPRITE_EXE)) {
        return (Resolve-Path $env:ASEPRITE_EXE).Path
    }

    foreach ($name in @(".env", ".env.txt")) {
        $file = Join-Path $ScriptDir $name
        if (-not (Test-Path $file)) { continue }
        $line = Select-String -Path $file -Pattern '^\s*ASEPRITE_EXE\s*=\s*(.+?)\s*$' |
            Select-Object -First 1
        if ($line) {
            $p = $line.Matches[0].Groups[1].Value.Trim().Trim('"', "'")
            if (Test-Path $p) { return (Resolve-Path $p).Path }
        }
    }

    $cmd = Get-Command aseprite -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
        if (-not $base) { continue }
        $candidate = Join-Path $base "Aseprite\Aseprite.exe"
        if (Test-Path $candidate) { return $candidate }
    }

    return $null
}
