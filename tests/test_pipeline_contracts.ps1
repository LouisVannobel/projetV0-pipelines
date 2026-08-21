$ErrorActionPreference = 'Stop'

$workflows = @(
  '.github\workflows\reusable-saas-ci.yml',
  '.github\workflows\reusable-container-release.yml',
  '.github\workflows\reusable-repository-ci.yml'
)

foreach ($path in $workflows) {
  if (-not (Test-Path -LiteralPath $path)) { throw "Missing reusable workflow: $path" }
  $workflow = Get-Content -Raw -LiteralPath $path
  if ($workflow -notmatch '(?m)^\s*workflow_call:\s*$') { throw "$path is not callable" }
  foreach ($match in [regex]::Matches($workflow, '(?m)^\s*-?\s*uses:\s*([^\s#]+)')) {
    $use = $match.Groups[1].Value
    if ($use.StartsWith('./')) { continue }
    if ($use -notmatch '@[0-9a-f]{40}$') { throw "Action is not pinned to a full commit SHA: $use" }
  }
}

$repositoryCi = Get-Content -Raw -LiteralPath '.github\workflows\reusable-repository-ci.yml'
foreach ($requiredControl in @(
  'permissions:',
  'contents: read',
  'fetch-depth: 0',
  'gitleaks git',
  '--config .gitleaks.toml',
  "scan-type: 'fs'",
  'actionlint'
)) {
  if ($repositoryCi -notmatch [regex]::Escape($requiredControl)) {
    throw "Repository CI omits required control: $requiredControl"
  }
}
if ($repositoryCi -match 'pnpm|setup-node|Dockerfile|build-push-action') {
  throw 'Repository CI must not assume an application or container build'
}

$selfValidation = Get-Content -Raw -LiteralPath '.github\workflows\validate-pipelines.yml'
if ($selfValidation -notmatch [regex]::Escape('pwsh -File tests/test_pipeline_contracts.ps1')) {
  throw 'The pipeline repository must run its contract tests in GitHub Actions'
}

$actionlintExe = $env:ACTIONLINT_EXE
if ($actionlintExe) {
  if (-not (Test-Path -LiteralPath $actionlintExe)) { throw "actionlint executable not found: $actionlintExe" }
  $exampleWorkflows = @(Get-ChildItem -LiteralPath 'examples' -Filter '*.yml' -File | ForEach-Object FullName)
  & $actionlintExe @($workflows + '.github\workflows\validate-pipelines.yml' + $exampleWorkflows)
  if ($LASTEXITCODE -ne 0) { throw "actionlint failed with exit code $LASTEXITCODE" }
}

Write-Output 'PIPELINE_CONTRACT_TESTS_OK'
