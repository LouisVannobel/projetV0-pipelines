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
  foreach ($match in [regex]::Matches($workflow, '(?m)^\s*-?\s*uses:\s*(?<use>[^\s#]+)(?<comment>\s+#\s+v\d+\.\d+\.\d+)?\s*$')) {
    $use = $match.Groups['use'].Value
    if ($use.StartsWith('./')) { continue }
    if ($use -notmatch '@[0-9a-f]{40}$') { throw "Action is not pinned to a full commit SHA: $use" }
    if (-not $match.Groups['comment'].Success) { throw "Action pin has no Renovate-compatible version comment: $use" }
  }
}

$allReusableWorkflowSource = ($workflows | ForEach-Object {
  Get-Content -Raw -LiteralPath $_
}) -join "`n"

$trivyUses = @([regex]::Matches($allReusableWorkflowSource, '(?m)^\s*uses:\s+aquasecurity/trivy-action@[0-9a-f]{40}'))
$trivyVersions = @([regex]::Matches($allReusableWorkflowSource, "(?ms)^\s*uses:\s+aquasecurity/trivy-action@[^\r\n]+\r?\n\s+with:\s*\r?\n(?:(?!^\s*-\s+name:).)*?^\s+version:\s*'?v\d+\.\d+\.\d+'?\s*$"))
if ($trivyUses.Count -eq 0 -or $trivyUses.Count -ne $trivyVersions.Count) {
  throw 'Every Trivy action invocation must pin an explicit stable Trivy CLI version'
}

$buildxUses = @([regex]::Matches($allReusableWorkflowSource, '(?m)^\s*uses:\s+docker/setup-buildx-action@[0-9a-f]{40}'))
$buildxVersions = @([regex]::Matches($allReusableWorkflowSource, "(?ms)^\s*uses:\s+docker/setup-buildx-action@[^\r\n]+\r?\n\s+with:\s*\r?\n(?:(?!^\s*-\s+name:).)*?^\s+version:\s*'?v\d+\.\d+\.\d+'?\s*$"))
if ($buildxUses.Count -eq 0 -or $buildxUses.Count -ne $buildxVersions.Count) {
  throw 'Every Buildx setup invocation must pin an explicit stable Buildx version'
}
$buildKitPins = @([regex]::Matches($allReusableWorkflowSource, '(?m)^\s+driver-opts:\s+image=moby/buildkit:v\d+\.\d+\.\d+@sha256:[a-f0-9]{64}\s*$'))
if ($buildKitPins.Count -ne $buildxUses.Count) {
  throw 'Every Buildx invocation must use an immutable versioned BuildKit image'
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

foreach ($requiredInfraControl in @(
  'run-infrastructure-static:',
  'if: inputs.run-infrastructure-static',
  'bash -n',
  'shellcheck',
  '--severity=error',
  'pwsh -NoProfile -File tests/infra/test_shared_ci.ps1',
  'bash tests/infra/test_lib.sh',
  'docker compose --env-file infra/locks/images.env',
  'config --no-interpolate --quiet'
)) {
  if ($repositoryCi -notmatch [regex]::Escape($requiredInfraControl)) {
    throw "Repository CI omits infrastructure-specific control: $requiredInfraControl"
  }
}
$selfValidation = Get-Content -Raw -LiteralPath '.github\workflows\validate-pipelines.yml'
if ($selfValidation -notmatch [regex]::Escape('pwsh -File tests/test_pipeline_contracts.ps1')) {
  throw 'The pipeline repository must run its contract tests in GitHub Actions'
}
if ($selfValidation -notmatch [regex]::Escape('uses: ./.github/workflows/reusable-repository-ci.yml')) {
  throw 'The pipeline repository must execute its reusable repository CI locally before consumers depend on it'
}

foreach ($example in Get-ChildItem -LiteralPath 'examples' -Filter '*.yml' -File) {
  $source = Get-Content -Raw -LiteralPath $example.FullName
  foreach ($call in [regex]::Matches($source, '(?m)^\s*uses:\s+([^\s]+)(?<comment>\s+#\s+v\d+\.\d+\.\d+)?\s*$')) {
    if ($call.Groups[1].Value -notmatch '^LouisVannobel/projetV0-pipelines/.+@[0-9a-f]{40}$') {
      throw "Example caller must use the personal Pro repository at an immutable SHA: $($call.Groups[1].Value)"
    }
    if (-not $call.Groups['comment'].Success) {
      throw "Example caller must retain a semantic version comment for Renovate: $($call.Groups[1].Value)"
    }
  }
}

$repositoryExample = Get-Content -Raw -LiteralPath 'examples\repository-ci.yml'
if ($repositoryExample -notmatch '(?ms)^\s*with:\s*$.*^\s+run-infrastructure-static:\s*true\s*$') {
  throw 'The infrastructure example must enable repository-local static validation'
}

$saasExample = Get-Content -Raw -LiteralPath 'examples\saas-ci.yml'
if ($saasExample -match '(?ms)^\s+with:\s*$') {
  throw 'The SaaS example must rely on reusable workflow defaults and omit inputs'
}

$saasCi = Get-Content -Raw -LiteralPath '.github\workflows\reusable-saas-ci.yml'
$gateMatch = [regex]::Match($saasCi, '(?ms)^  gate:\s*$.*?(?=^  \w[^\r\n]*:\s*$|\z)')
if (-not $gateMatch.Success) { throw 'Reusable SaaS CI must expose a gate job' }
$gate = $gateMatch.Value
if ($gate -notmatch '(?m)^    name:\s*CI / gate\s*$') { throw 'SaaS gate must be named CI / gate' }
if ($gate -notmatch '(?m)^    if:\s*\$\{\{\s*always\(\)') { throw 'SaaS gate must run under always()' }
foreach ($requiredJob in @('secrets-and-source', 'quality', 'accessibility', 'lighthouse', 'container')) {
  if ($gate -notmatch [regex]::Escape($requiredJob)) { throw "SaaS gate must consume job: $requiredJob" }
}
if ($gate -notmatch "needs\.secrets-and-source\.result\s*==\s*'success'") { throw 'SaaS gate must require secrets-and-source success' }
if ($gate -notmatch "needs\.quality\.result\s*==\s*'success'") { throw 'SaaS gate must require quality success' }
foreach ($optionalJob in @('accessibility', 'lighthouse', 'container')) {
  if ($gate -notmatch "needs\.$optionalJob\.result\s*==\s*'success'") { throw "SaaS gate must accept $optionalJob success" }
  if ($gate -notmatch "needs\.$optionalJob\.result\s*==\s*'skipped'") { throw "SaaS gate must accept $optionalJob skipped" }
}
if ($gate -match '(?i)permissions:.*(write|read-all)') { throw 'SaaS gate must not request write permissions' }

$actionlintExe = $env:ACTIONLINT_EXE
if ($actionlintExe) {
  if (-not (Test-Path -LiteralPath $actionlintExe)) { throw "actionlint executable not found: $actionlintExe" }
  $exampleWorkflows = @(Get-ChildItem -LiteralPath 'examples' -Filter '*.yml' -File | ForEach-Object FullName)
  & $actionlintExe @($workflows + '.github\workflows\validate-pipelines.yml' + $exampleWorkflows)
  if ($LASTEXITCODE -ne 0) { throw "actionlint failed with exit code $LASTEXITCODE" }
}

Write-Output 'PIPELINE_CONTRACT_TESTS_OK'
