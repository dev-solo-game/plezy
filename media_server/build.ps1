$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Write-Host "==> 1/3 Building Web SPA..." -ForegroundColor Cyan
Push-Location (Join-Path $Root "web")
try {
    if (-not (Test-Path "node_modules")) {
        npm install
    }
    npm run build
    if ($LASTEXITCODE -ne 0) { throw "Frontend build failed" }
} finally {
    Pop-Location
}

Write-Host "==> 2/3 Running Go tests..." -ForegroundColor Cyan
Push-Location $Root
try {
    go test ./...
    if ($LASTEXITCODE -ne 0) { throw "Go tests failed" }

    Write-Host "==> 3/3 Building standalone binary ttplay-server.exe..." -ForegroundColor Cyan
    $env:CGO_ENABLED = "0"
    go build -trimpath -ldflags="-s -w" -o (Join-Path $Root "ttplay-server.exe") ./cmd/ttplay-server
    if ($LASTEXITCODE -ne 0) { throw "Go build failed" }
} finally {
    Pop-Location
}

Write-Host "Build succeeded: $(Join-Path $Root 'ttplay-server.exe')" -ForegroundColor Green
