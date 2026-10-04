$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$keyPointer = [IntPtr]::Zero

Push-Location $projectRoot
try {
    if ([string]::IsNullOrWhiteSpace($env:TYPESAFE_API_KEY)) {
        $secureKey = Read-Host "TypeSafe API key" -AsSecureString
        $keyPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
        $env:TYPESAFE_API_KEY = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($keyPointer)
    }

    python scripts\ad_eval_jev_v81_boundary.py --dry-run
    if ($LASTEXITCODE -ne 0) { throw "V8.1 Stage 0 dry-run failed with exit code $LASTEXITCODE" }

    if ((Read-Host "Run the four live Jev V8.1 boundary requests? Type YES to continue") -ne "YES") {
        Write-Host "Stopped before any TypeSafe request."
        return
    }

    python scripts\ad_eval_jev_v81_boundary.py
    if ($LASTEXITCODE -ne 0) { throw "V8.1 Stage 0 failed with exit code $LASTEXITCODE" }
}
finally {
    if ($keyPointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($keyPointer)
    }
    Pop-Location
}
