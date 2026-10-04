$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$keyPointer = [IntPtr]::Zero
$sessionKeyActive = $false

Push-Location $projectRoot
try {
    if ([string]::IsNullOrWhiteSpace($env:TYPESAFE_API_KEY) -and -not [string]::IsNullOrWhiteSpace($global:PodwashTypeSafeApiKey)) {
        $env:TYPESAFE_API_KEY = $global:PodwashTypeSafeApiKey
        $sessionKeyActive = $true
        Write-Host "Using the TypeSafe API key already cached in this PowerShell session."
    }

    if ([string]::IsNullOrWhiteSpace($env:TYPESAFE_API_KEY)) {
        $secureKey = Read-Host "TypeSafe API key" -AsSecureString
        $keyPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
        $env:TYPESAFE_API_KEY = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($keyPointer)
        $sessionKeyActive = $true
    }
    $global:PodwashTypeSafeApiKey = $env:TYPESAFE_API_KEY

    python scripts\ad_eval_jev_v72.py --dry-run
    if ($LASTEXITCODE -ne 0) { throw "V7.2 dry-run failed with exit code $LASTEXITCODE" }

    if ((Read-Host "Run the live Jev V7.2 boundary refinement? Type YES to continue") -ne "YES") {
        Write-Host "Stopped before any TypeSafe request."
        return
    }

    python scripts\ad_eval_jev_v72.py
    if ($LASTEXITCODE -ne 0) {
        if ($sessionKeyActive) {
            Remove-Variable PodwashTypeSafeApiKey -Scope Global -ErrorAction SilentlyContinue
            Remove-Item Env:TYPESAFE_API_KEY -ErrorAction SilentlyContinue
            Write-Host "The cached TypeSafe key was cleared because the run failed."
        }
        throw "V7.2 run failed with exit code $LASTEXITCODE"
    }
}
finally {
    if ($keyPointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($keyPointer)
    }
    Pop-Location
}
