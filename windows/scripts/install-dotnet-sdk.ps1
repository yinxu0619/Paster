param(
    [string]$Channel = "8.0"
)

$ErrorActionPreference = "Stop"

function Test-DotNetSdk {
    $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
    if (-not $dotnet) {
        $programFilesDotnet = Join-Path $env:ProgramFiles "dotnet\dotnet.exe"
        if (Test-Path $programFilesDotnet) {
            $env:DOTNET_ROOT = Split-Path $programFilesDotnet
            $env:PATH = "$env:DOTNET_ROOT;$env:PATH"
            $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
        }
    }
    if (-not $dotnet) {
        return $false
    }

    $sdks = & dotnet --list-sdks 2>$null
    return ($sdks -match "^(8|9|10)\.")
}

if (Test-DotNetSdk) {
    Write-Host ".NET SDK is already available." -ForegroundColor Green
    & dotnet --info
    exit 0
}

Write-Host ".NET SDK 8+ was not found. Installing .NET SDK $Channel..." -ForegroundColor Yellow

$winget = Get-Command winget -ErrorAction SilentlyContinue
if ($winget) {
    & winget install --id Microsoft.DotNet.SDK.8 --source winget --accept-package-agreements --accept-source-agreements
    $programFilesDotnet = Join-Path $env:ProgramFiles "dotnet\dotnet.exe"
    if (Test-Path $programFilesDotnet) {
        $env:DOTNET_ROOT = Split-Path $programFilesDotnet
        $env:PATH = "$env:DOTNET_ROOT;$env:PATH"
    }
    if (Test-DotNetSdk) {
        Write-Host ".NET SDK installed successfully." -ForegroundColor Green
        Write-Host "If another terminal still cannot find dotnet, close and reopen PowerShell." -ForegroundColor Yellow
        exit 0
    }
}

$installRoot = Join-Path $PSScriptRoot "..\.dotnet"
New-Item -ItemType Directory -Force -Path $installRoot | Out-Null

$installer = Join-Path $env:TEMP "dotnet-install.ps1"
Invoke-WebRequest -Uri "https://dot.net/v1/dotnet-install.ps1" -OutFile $installer
& powershell -NoProfile -ExecutionPolicy Bypass -File $installer -Channel $Channel -InstallDir $installRoot

$env:DOTNET_ROOT = (Resolve-Path $installRoot).Path
$env:PATH = "$env:DOTNET_ROOT;$env:PATH"

if (-not (Test-DotNetSdk)) {
    throw "Failed to install or locate .NET SDK. Install .NET SDK 8+ manually from https://dotnet.microsoft.com/download and reopen PowerShell."
}

Write-Host ".NET SDK installed under $env:DOTNET_ROOT for this workspace." -ForegroundColor Green
Write-Host "For this PowerShell session, PATH has been updated. Re-run build scripts from this same session." -ForegroundColor Yellow
