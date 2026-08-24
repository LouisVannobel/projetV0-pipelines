$ErrorActionPreference = 'Stop'

$releaseContractsDir = Join-Path $PSScriptRoot 'oci-release-contracts'
$releaseValidator = Join-Path $releaseContractsDir 'validate-release-workflow.mjs'
$smokeValidator = Join-Path $releaseContractsDir 'validate-smoke-workflow.mjs'
if (-not (Test-Path -LiteralPath $releaseValidator)) { throw "Missing OCI release validator: $releaseValidator" }
if (-not (Test-Path -LiteralPath $smokeValidator)) { throw "Missing OCI smoke validator: $smokeValidator" }
& npm ci --prefix $releaseContractsDir --ignore-scripts --no-audit --no-fund
if ($LASTEXITCODE -ne 0) { throw "OCI release contract dependency install failed with exit code $LASTEXITCODE" }
& npm test --prefix $releaseContractsDir
if ($LASTEXITCODE -ne 0) { throw "OCI release contract and run-block behavior tests failed with exit code $LASTEXITCODE" }
& node $releaseValidator
if ($LASTEXITCODE -ne 0) { throw "OCI release contract validator failed with exit code $LASTEXITCODE" }
& node $smokeValidator
if ($LASTEXITCODE -ne 0) { throw "OCI smoke contract validator failed with exit code $LASTEXITCODE" }

Write-Output 'OCI_RELEASE_CONTRACT_TESTS_OK'
