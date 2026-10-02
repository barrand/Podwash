$Experiment = "role-boundary-v4"
$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$keyPointer = [IntPtr]::Zero

Push-Location $projectRoot
try {
    if ([string]::IsNullOrWhiteSpace($env:TYPESAFE_API_KEY)) {
        $secureKey = Read-Host "TypeSafe API key" -AsSecureString
        $keyPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
        $env:TYPESAFE_API_KEY = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($keyPointer)
        Write-Host "API key cached in this PowerShell session. Close the terminal or run Remove-Item Env:TYPESAFE_API_KEY to clear it."
    }
    else {
        Write-Host "Using TYPESAFE_API_KEY already cached in this PowerShell session."
    }

    python scripts\ad_eval_jev.py --experiment $Experiment --dry-run
    if ($LASTEXITCODE -ne 0) {
        throw "Jev dry-run failed with exit code $LASTEXITCODE"
    }

    if ((Read-Host "Run the live Jev $Experiment micro-evaluation now? Type YES to continue") -ne "YES") {
        Write-Host "Stopped before any TypeSafe request."
        return
    }

    python scripts\ad_eval_jev.py --experiment $Experiment
    if ($LASTEXITCODE -ne 0) {
        throw "Jev live run failed with exit code $LASTEXITCODE"
    }
}
finally {
    if ($keyPointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($keyPointer)
    }
    Pop-Location
}
