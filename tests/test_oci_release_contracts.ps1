$ErrorActionPreference = 'Stop'

$releaseContractsDir = Join-Path $PSScriptRoot 'oci-release-contracts'
$releaseValidator = Join-Path $releaseContractsDir 'validate-release-workflow.mjs'
$smokeValidator = Join-Path $releaseContractsDir 'validate-smoke-workflow.mjs'
if (-not (Test-Path -LiteralPath $releaseValidator)) { throw "Missing OCI release validator: $releaseValidator" }
if (-not (Test-Path -LiteralPath $smokeValidator)) { throw "Missing OCI smoke validator: $smokeValidator" }

$previousPython = [Environment]::GetEnvironmentVariable('OCI_TEST_PYTHON3', 'Process')
try {
  if ($IsWindows) {
    $pythonProbeOutput = @(& py -3 -c 'import sys; print(sys.executable)')
    if ($LASTEXITCODE -ne 0) { throw "Python discovery with py -3 failed with exit code $LASTEXITCODE" }
    $pythonProbe = [string]($pythonProbeOutput | Select-Object -Last 1)
    if ([string]::IsNullOrWhiteSpace($pythonProbe)) { throw 'Python discovery with py -3 returned an empty path' }
    if (-not [IO.Path]::IsPathFullyQualified($pythonProbe)) {
      throw "Python discovery returned a non-absolute path: $pythonProbe"
    }
    $pythonExecutable = (Resolve-Path -LiteralPath $pythonProbe).ProviderPath
    if (-not (Test-Path -LiteralPath $pythonExecutable -PathType Leaf)) {
      throw "Python discovery did not resolve to a file: $pythonExecutable"
    }
    [Environment]::SetEnvironmentVariable('OCI_TEST_PYTHON3', $pythonExecutable, 'Process')
  }

  & npm ci --prefix $releaseContractsDir --ignore-scripts --no-audit --no-fund
  if ($LASTEXITCODE -ne 0) { throw "OCI release contract dependency install failed with exit code $LASTEXITCODE" }
  & npm test --prefix $releaseContractsDir
  if ($LASTEXITCODE -ne 0) { throw "OCI release contract and run-block behavior tests failed with exit code $LASTEXITCODE" }
  & node $releaseValidator
  if ($LASTEXITCODE -ne 0) { throw "OCI release contract validator failed with exit code $LASTEXITCODE" }
  & node $smokeValidator
  if ($LASTEXITCODE -ne 0) { throw "OCI smoke contract validator failed with exit code $LASTEXITCODE" }

  Write-Output 'OCI_RELEASE_CONTRACT_TESTS_OK'
}
finally {
  if ($IsWindows) {
    [Environment]::SetEnvironmentVariable('OCI_TEST_PYTHON3', $previousPython, 'Process')
  }
}
