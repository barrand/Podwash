$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$keyPointer = [IntPtr]::Zero

Push-Location $projectRoot
try {
    if ([string]::IsNullOrWhiteSpace($env:TYPESAFE_API_KEY)) {
        $secureKey = Read-Host "TypeSafe API key" -AsSecureString
        $keyPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
        $env:TYPESAFE_API_KEY = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($keyPointer)
        Write-Host "API key cached in this PowerShell process for the V7 run."
    }
    else {
        Write-Host "Using TYPESAFE_API_KEY already cached in this PowerShell session."
    }

    python scripts\ad_eval_jev_v7.py --dry-run
    if ($LASTEXITCODE -ne 0) { throw "V7 dry-run failed with exit code $LASTEXITCODE" }

    if ((Read-Host "Run the live three-episode Jev V7 evaluation? Type YES to continue") -ne "YES") {
        Write-Host "Stopped before any TypeSafe request."
        return
    }

    python scripts\ad_eval_jev_v7.py
    if ($LASTEXITCODE -ne 0) { throw "V7 run failed with exit code $LASTEXITCODE" }
}
finally {
    if ($keyPointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($keyPointer)
    }
    Pop-Location
}
