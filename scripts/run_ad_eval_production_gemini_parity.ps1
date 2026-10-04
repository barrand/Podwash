$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$keyPointer = [IntPtr]::Zero
$sessionKeyActive = $false

Push-Location $projectRoot
try {
    if ([string]::IsNullOrWhiteSpace($env:GEMINI_API_KEY) -and -not [string]::IsNullOrWhiteSpace($global:PodwashGeminiApiKey)) {
        $env:GEMINI_API_KEY = $global:PodwashGeminiApiKey
        $sessionKeyActive = $true
        Write-Host "Using the Gemini API key already cached in this PowerShell session."
    }
    if ([string]::IsNullOrWhiteSpace($env:GEMINI_API_KEY)) {
        $secureKey = Read-Host "Gemini API key" -AsSecureString
        $keyPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
        $env:GEMINI_API_KEY = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($keyPointer)
        $sessionKeyActive = $true
    }
    $global:PodwashGeminiApiKey = $env:GEMINI_API_KEY

    python scripts\ad_eval_production_gemini_parity.py --dry-run
    if ($LASTEXITCODE -ne 0) { throw "Production-parity dry-run failed with exit code $LASTEXITCODE" }
    if ((Read-Host "Replay the production Gemini contract against the Jev pilot? Type YES to continue") -ne "YES") {
        Write-Host "Stopped before any Gemini request."
        return
    }
    python scripts\ad_eval_production_gemini_parity.py
    if ($LASTEXITCODE -ne 0) {
        if ($sessionKeyActive) {
            Remove-Variable PodwashGeminiApiKey -Scope Global -ErrorAction SilentlyContinue
            Remove-Item Env:GEMINI_API_KEY -ErrorAction SilentlyContinue
            Write-Host "The cached Gemini key was cleared because the run failed."
        }
        throw "Production-parity Gemini run failed with exit code $LASTEXITCODE"
    }
}
finally {
    if ($keyPointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($keyPointer)
    }
    Pop-Location
}
