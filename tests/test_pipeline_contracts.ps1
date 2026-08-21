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

$allReusableWorkflowSource = ($workflows | ForEach-Object {
  Get-Content -Raw -LiteralPath $_
}) -join "`n"

$checkoutV7Pin = 'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1'
$checkoutUses = @([regex]::Matches($allReusableWorkflowSource, '(?m)^\s*uses:\s+actions/checkout@[^\r\n]+$'))
if ($checkoutUses.Count -eq 0 -or @($checkoutUses | Where-Object { $_.Value -notmatch [regex]::Escape($checkoutV7Pin) }).Count -ne 0) {
  throw 'Every reusable workflow checkout must use the reviewed v7.0.1 commit pin'
}

$trivyUses = @([regex]::Matches($allReusableWorkflowSource, '(?m)^\s*uses:\s+aquasecurity/trivy-action@[0-9a-f]{40}'))
$trivyVersions = @([regex]::Matches($allReusableWorkflowSource, "(?m)^\s+version:\s*'?v0\.74\.0'?\s*$"))
if ($trivyUses.Count -eq 0 -or $trivyUses.Count -ne $trivyVersions.Count) {
  throw 'Every Trivy action invocation must pin Trivy CLI v0.74.0 explicitly'
}

$buildxUses = @([regex]::Matches($allReusableWorkflowSource, '(?m)^\s*uses:\s+docker/setup-buildx-action@[0-9a-f]{40}'))
$buildxVersions = @([regex]::Matches($allReusableWorkflowSource, "(?m)^\s+version:\s*'?v0\.36\.1'?\s*$"))
if ($buildxUses.Count -eq 0 -or $buildxUses.Count -ne $buildxVersions.Count) {
  throw 'Every Buildx setup invocation must pin Buildx v0.36.1 explicitly'
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
  'bash tests/infra/test_lock_modes.sh',
  'bash infra/scripts/05-resolve-locks.sh pinned',
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

$allWorkflowSource = ($workflows + '.github\workflows\validate-pipelines.yml' | ForEach-Object {
  Get-Content -Raw -LiteralPath $_
}) -join "`n"
$renovateHintCounts = @{
  'rhysd/actionlint' = 2
  'gitleaks/gitleaks' = 3
  'koalaman/shellcheck' = 1
  'pnpm' = 1
}
foreach ($dependency in $renovateHintCounts.Keys) {
  $hint = "# renovate: datasource="
  $count = @([regex]::Matches(
    $allWorkflowSource,
    "(?m)^\s*${hint}[^\s]+\s+depName=$([regex]::Escape($dependency))\s*$"
  )).Count
  if ($count -ne $renovateHintCounts[$dependency]) {
    throw "Expected $($renovateHintCounts[$dependency]) Renovate hints for $dependency, found $count"
  }
}

$renovateSource = Get-Content -Raw -LiteralPath '.github\renovate.json'
$renovate = $renovateSource | ConvertFrom-Json
$customManagerSource = ($renovate.customManagers | ConvertTo-Json -Depth 10)
if ($customManagerSource -notmatch 'github/workflows' -or $customManagerSource -notmatch 'currentValue') {
  throw 'Renovate must extract checksum-pinned CLI and pnpm default versions from workflow files'
}
$reviewedManagers = @($renovate.packageRules | ForEach-Object matchManagers | Where-Object { $_ })
if ($reviewedManagers -notcontains 'custom.regex') {
  throw 'Custom regex dependency updates must remain subject to human review'
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

$actionlintExe = $env:ACTIONLINT_EXE
if ($actionlintExe) {
  if (-not (Test-Path -LiteralPath $actionlintExe)) { throw "actionlint executable not found: $actionlintExe" }
  $exampleWorkflows = @(Get-ChildItem -LiteralPath 'examples' -Filter '*.yml' -File | ForEach-Object FullName)
  & $actionlintExe @($workflows + '.github\workflows\validate-pipelines.yml' + $exampleWorkflows)
  if ($LASTEXITCODE -ne 0) { throw "actionlint failed with exit code $LASTEXITCODE" }
}

Write-Output 'PIPELINE_CONTRACT_TESTS_OK'
