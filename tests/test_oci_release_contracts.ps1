$ErrorActionPreference = 'Stop'

$releaseContractsDir = Join-Path $PSScriptRoot 'oci-release-contracts'
$releaseValidator = Join-Path $releaseContractsDir 'validate-release-workflow.mjs'
$smokeValidator = Join-Path $releaseContractsDir 'validate-smoke-workflow.mjs'
$releaseWorkflow = Join-Path $PSScriptRoot '..\.github\workflows\reusable-oci-release.yml'
$smokeWorkflow = Join-Path $PSScriptRoot '..\.github\workflows\smoke-oci-release.yml'
$releaseExample = Join-Path $PSScriptRoot '..\examples\oci-release.yml'
if (-not (Test-Path -LiteralPath $releaseValidator)) { throw "Missing OCI release validator: $releaseValidator" }
if (-not (Test-Path -LiteralPath $smokeValidator)) { throw "Missing OCI smoke validator: $smokeValidator" }
& npm ci --prefix $releaseContractsDir --ignore-scripts --no-audit --no-fund
if ($LASTEXITCODE -ne 0) { throw "OCI release contract dependency install failed with exit code $LASTEXITCODE" }
& npm test --prefix $releaseContractsDir
if ($LASTEXITCODE -ne 0) { throw "OCI release contract and run-block behavior tests failed with exit code $LASTEXITCODE" }
& node $releaseValidator $releaseWorkflow
if ($LASTEXITCODE -ne 0) { throw "OCI release contract validator failed with exit code $LASTEXITCODE" }
& node $smokeValidator $smokeWorkflow $releaseExample
if ($LASTEXITCODE -ne 0) { throw "OCI smoke contract validator failed with exit code $LASTEXITCODE" }

Write-Output 'OCI_RELEASE_CONTRACT_TESTS_OK'
