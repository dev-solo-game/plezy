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

    Write-Host "==> 3/3 Building standalone binary media-library.exe..." -ForegroundColor Cyan
    $env:CGO_ENABLED = "0"
    $TargetExe = Join-Path $Root "media-library.exe"
    $StageExe = Join-Path $Root "media-library.new.exe"
    Get-ChildItem -Path $Root -Filter "media-library.old*.exe" -ErrorAction SilentlyContinue | ForEach-Object {
        try { Remove-Item $_.FullName -Force -ErrorAction Stop } catch {}
    }
    go build -trimpath -ldflags="-s -w" -o $StageExe ./cmd/media-library
    if ($LASTEXITCODE -ne 0) { throw "Go build failed" }
    $BackupExe = Join-Path $Root ("media-library.old." + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + ".exe")
    if (Test-Path $TargetExe) {
        Move-Item $TargetExe $BackupExe -Force
    }
    Move-Item $StageExe $TargetExe -Force
    try { Remove-Item $BackupExe -Force -ErrorAction Stop } catch {}
} finally {
    Pop-Location
}

Write-Host "Build succeeded: $(Join-Path $Root 'media-library.exe')" -ForegroundColor Green
