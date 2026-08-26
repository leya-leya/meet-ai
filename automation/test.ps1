[CmdletBinding()]
param(
    [string]$OutputPath
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot "lib/Autodev.Core.psm1") -Force
$results = [System.Collections.Generic.List[string]]::new()
$failed = $false
$testTempRoot = Join-Path $PSScriptRoot "state/test-temp"

function Add-TestOutput {
    param([string]$Text)

    $safeText = Protect-AutodevLogText -Text $Text
    $script:results.Add($safeText)
    Write-Host $safeText
}

function Invoke-TestStep {
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [string]$WorkingDirectory,
        [Parameter(Mandatory)]
        [string]$Command,
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    Add-TestOutput "`n===== $Name ====="
    Push-Location $WorkingDirectory
    try {
        $output = & $Command @Arguments 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
        Add-TestOutput $output.TrimEnd()
        Add-TestOutput "[$Name] exit code: $exitCode"
        if ($exitCode -ne 0) {
            $script:failed = $true
        }
    }
    catch {
        Add-TestOutput "[$Name] failed to start: $($_.Exception.Message)"
        $script:failed = $true
    }
    finally {
        Pop-Location
    }
}

Invoke-AutodevIsolatedTestEnvironment -TempRoot $testTempRoot -Action {
    param($testRunTemp)

    $backendPython = Join-Path $projectRoot "backend/.venv/Scripts/python.exe"
    if (-not (Test-Path -LiteralPath $backendPython -PathType Leaf)) {
        $pythonCommand = Get-Command python -ErrorAction SilentlyContinue
        if ($null -eq $pythonCommand) {
            Add-TestOutput "Backend Python was not found. Create backend/.venv and install backend/requirements.txt."
            $script:failed = $true
        }
        else {
            $backendPython = $pythonCommand.Source
        }
    }

    if (-not $script:failed) {
        $pytestBaseTemp = Join-Path $testRunTemp "pytest"
        $pythonCacheRoot = Join-Path $testRunTemp "pycache"
        Invoke-TestStep -Name "backend pytest" -WorkingDirectory (Join-Path $projectRoot "backend") -Command $backendPython -Arguments @("-X", "pycache_prefix=$pythonCacheRoot", "-m", "pytest", "-v", "-p", "no:cacheprovider", "--basetemp", $pytestBaseTemp)
    }

    $npmCommand = Get-Command npm -ErrorAction SilentlyContinue
    if ($null -eq $npmCommand) {
        Add-TestOutput "npm was not found. Install the frontend Node.js runtime before running automation."
        $script:failed = $true
    }
    else {
        $nodeModulesRoot = [System.IO.Path]::GetFullPath((Join-Path $projectRoot "frontend/node_modules")).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
        foreach ($cacheName in @(".vite", ".cache")) {
            $cachePath = [System.IO.Path]::GetFullPath((Join-Path $nodeModulesRoot $cacheName))
            $cachePrefix = $nodeModulesRoot + [System.IO.Path]::DirectorySeparatorChar
            if (-not $cachePath.StartsWith($cachePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Refusing to clean frontend cache outside node_modules."
            }
            if (Test-Path -LiteralPath $cachePath -PathType Container) {
                Remove-Item -LiteralPath $cachePath -Recurse -Force
            }
        }
        Invoke-TestStep -Name "frontend tests" -WorkingDirectory (Join-Path $projectRoot "frontend") -Command $npmCommand.Source -Arguments @("test")
        foreach ($buildInfoName in @("tsconfig.app.tsbuildinfo", "tsconfig.node.tsbuildinfo")) {
            $buildInfoPath = Join-Path (Join-Path $projectRoot "frontend") $buildInfoName
            if (Test-Path -LiteralPath $buildInfoPath -PathType Leaf) {
                Remove-Item -LiteralPath $buildInfoPath -Force
            }
        }
        Invoke-TestStep -Name "frontend typecheck and build" -WorkingDirectory (Join-Path $projectRoot "frontend") -Command $npmCommand.Source -Arguments @("run", "build")
    }
}

$finalOutput = ($results -join "`n") + "`n"
if ($OutputPath) {
    $outputDirectory = Split-Path -Parent $OutputPath
    if ($outputDirectory -and -not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    }
    $finalOutput | Set-Content -LiteralPath $OutputPath -Encoding utf8
}

if ($failed) {
    exit 1
}

exit 0
