$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$slugs = @(
    "stage2-this-american-life",
    "stage2-ai-news",
    "stage2-dr-death"
)

Push-Location $projectRoot
try {
    foreach ($slug in $slugs) {
        python scripts\ad_golden_transcribe.py --show $slug
        if ($LASTEXITCODE -ne 0) { throw "Stage 2 transcription failed for $slug with exit code $LASTEXITCODE" }
    }
}
finally {
    Pop-Location
}
