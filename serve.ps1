# serve.ps1 - start the local web app and open it in the browser.
#
# usage:
#   .\serve.ps1
#   .\serve.ps1 -Port 8080

param(
    [int]$Port = 7788
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$node = (Get-Command node -ErrorAction SilentlyContinue)
if (-not $node) { throw "Node.js not found on PATH" }

$env:PORT = $Port
Write-Host "starting pixel-art workflow web app on http://127.0.0.1:$Port ..."
Write-Host "press Ctrl+C in this window to stop it."

Start-Process -FilePath "http://127.0.0.1:$Port/" | Out-Null
& $node.Source (Join-Path $root "web\server.js")
