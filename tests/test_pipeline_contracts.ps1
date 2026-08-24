$ErrorActionPreference = 'Stop'

$deployActionScriptPath = '.github/actions/deploy-dokploy/deploy-dokploy.sh'
$shellEol = (& git check-attr eol -- $deployActionScriptPath) -join "`n"
if ($LASTEXITCODE -ne 0 -or $shellEol -notmatch '(?m)^\.github/actions/deploy-dokploy/deploy-dokploy\.sh: eol: lf$') {
  throw 'Shell entrypoints must stay LF in fresh Windows checkouts'
}

function ConvertTo-NormalizedLineEndingBytes {
  param([Parameter(Mandatory)][byte[]]$Bytes)

  $normalized = [System.Collections.Generic.List[byte]]::new()
  for ($index = 0; $index -lt $Bytes.Length; $index++) {
    if ($Bytes[$index] -eq 13 -and $index + 1 -lt $Bytes.Length -and $Bytes[$index + 1] -eq 10) {
      $normalized.Add(10)
      $index++
      continue
    }
    $normalized.Add($Bytes[$index])
  }
  return $normalized.ToArray()
}

function Get-GitBlobBytes {
  param([Parameter(Mandatory)][string]$RevisionPath)

  $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = 'git'
  $startInfo.UseShellExecute = $false
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $null = $startInfo.ArgumentList.Add('show')
  $null = $startInfo.ArgumentList.Add($RevisionPath)
  $process = [System.Diagnostics.Process]::Start($startInfo)
  $output = [System.IO.MemoryStream]::new()
  $process.StandardOutput.BaseStream.CopyTo($output)
  $error = $process.StandardError.ReadToEnd()
  $process.WaitForExit()
  if ($process.ExitCode -ne 0) { throw "Unable to read pinned helper '$RevisionPath': $error" }
  return $output.ToArray()
}

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
    if ($use.StartsWith('./') -or $use.StartsWith('$/')) { continue }
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
$pipelineContractsJob = [regex]::Match($selfValidation, '(?ms)^  validate:\s*$.*?(?=^  [A-Za-z0-9_-]+:\s*$|\z)')
if (-not $pipelineContractsJob.Success) { throw 'The pipeline validation workflow must contain the contracts job' }
$pipelineContractsCheckout = [regex]::Match($pipelineContractsJob.Value, '(?ms)^\s*-\s+name:\s+Checkout without persisted credentials\s*$.*?(?=^\s*-\s+name:|\z)')
if ($pipelineContractsCheckout.Value -notmatch '(?m)^\s+fetch-depth:\s*0\s*$') {
  throw 'The checkout running pipeline contracts must fetch full history for pinned-workflow interface validation'
}
if ($selfValidation -notmatch [regex]::Escape('uses: ./.github/workflows/reusable-repository-ci.yml')) {
  throw 'The pipeline repository must execute its reusable repository CI locally before consumers depend on it'
}
$actionlintSelfActionIgnore = '^specifying action "\$/\.github/actions/deploy-dokploy" in invalid format because ref is missing\. available formats are "\{owner\}/\{repo\}@\{ref\}" or "\{owner\}/\{repo\}/\{path\}@\{ref\}"$'
foreach ($lintWorkflow in @($repositoryCi, $selfValidation)) {
  if ($lintWorkflow -notmatch [regex]::Escape($actionlintSelfActionIgnore)) {
    throw 'Actionlint must ignore only its exact unsupported self-action syntax diagnostic'
  }
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

function Get-RequiredWorkflowCallFields {
  param(
    [string]$Workflow,
    [string]$Section
  )

  $sectionMatch = [regex]::Match($Workflow, "(?ms)^ {4}${Section}:\s*$.*?(?=^ {4}\S|\z)")
  if (-not $sectionMatch.Success) { return @() }

  return @([regex]::Matches($sectionMatch.Value, '(?ms)^ {6}(?<name>[A-Za-z0-9_-]+):\s*$.*?(?=^ {6}[A-Za-z0-9_-]+:\s*$|^ {4}\S|\z)') |
    Where-Object { $_.Value -match '(?m)^ {8}required:\s*true\s*$' } |
    ForEach-Object { $_.Groups['name'].Value })
}

foreach ($example in Get-ChildItem -LiteralPath 'examples' -Filter '*.yml' -File) {
  $source = Get-Content -Raw -LiteralPath $example.FullName
  $sameRepositoryCalls = @([regex]::Matches($source, '(?m)^[ \t]{4}uses:[ \t]+LouisVannobel/projetV0-pipelines/(?<path>[^@\s]+)@(?<sha>[0-9a-f]{40})(?:[ \t]+#.*)?$'))
  foreach ($call in $sameRepositoryCalls) {
    $workflowAtPin = & git show "$($call.Groups['sha'].Value):$($call.Groups['path'].Value)"
    if ($LASTEXITCODE -ne 0) { throw "Example caller references an unreadable pinned workflow: $($call.Value)" }
    $workflowAtPin = $workflowAtPin -join "`n"

    $jobStarts = @([regex]::Matches($source, '(?m)^ {2}[A-Za-z0-9_-]+:\s*$'))
    $jobStart = $jobStarts | Where-Object { $_.Index -lt $call.Index } | Select-Object -Last 1
    if ($null -eq $jobStart) { throw "Example caller has no job for reusable workflow: $($call.Value)" }
    $nextJobStart = $jobStarts | Where-Object { $_.Index -gt $jobStart.Index } | Select-Object -First 1
    $jobLength = if ($null -eq $nextJobStart) { $source.Length - $jobStart.Index } else { $nextJobStart.Index - $jobStart.Index }
    $job = $source.Substring($jobStart.Index, $jobLength)
    $with = [regex]::Match($job, '(?ms)^ {4}with:\s*$.*?(?=^ {4}\S|\z)').Value
    $secrets = [regex]::Match($job, '(?ms)^ {4}secrets:\s*$.*?(?=^ {4}\S|\z)').Value

    foreach ($requiredInput in Get-RequiredWorkflowCallFields -Workflow $workflowAtPin -Section 'inputs') {
      if ($with -notmatch "(?m)^ {6}$([regex]::Escape($requiredInput)):\s*") {
        throw "Example caller does not supply required input '$requiredInput' to its pinned reusable workflow: $($call.Value)"
      }
    }
    foreach ($requiredSecret in Get-RequiredWorkflowCallFields -Workflow $workflowAtPin -Section 'secrets') {
      if ($job -notmatch '(?m)^ {4}secrets:\s+inherit\s*$' -and $secrets -notmatch "(?m)^ {6}$([regex]::Escape($requiredSecret)):\s*") {
        throw "Example caller does not supply required secret '$requiredSecret' to its pinned reusable workflow: $($call.Value)"
      }
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
if ($gate -notmatch '(?m)^    if:\s*\$\{\{\s*always\(\)\s*\}\}\s*$') { throw 'SaaS gate must run unconditionally under always()' }
foreach ($requiredJob in @('secrets-and-source', 'quality', 'accessibility', 'lighthouse', 'container')) {
  if ($gate -notmatch [regex]::Escape($requiredJob)) { throw "SaaS gate must consume job: $requiredJob" }
}
foreach ($resultVariable in @('SECRETS_AND_SOURCE_RESULT', 'QUALITY_RESULT', 'ACCESSIBILITY_RESULT', 'LIGHTHOUSE_RESULT', 'CONTAINER_RESULT')) {
  if ($gate -notmatch [regex]::Escape($resultVariable)) { throw "SaaS gate step must validate $resultVariable" }
}
if ($gate -notmatch '(?ms)case "\$SECRETS_AND_SOURCE_RESULT" in.*?success\) ;;.*?\*\).*?exit 1.*?esac') { throw 'SaaS gate must reject non-success required results' }
if ($gate -notmatch '(?ms)case "\$QUALITY_RESULT" in.*?success\) ;;.*?\*\).*?exit 1.*?esac') { throw 'SaaS gate must reject non-success required results' }
if ($gate -notmatch '(?ms)for result in "\$ACCESSIBILITY_RESULT" "\$LIGHTHOUSE_RESULT" "\$CONTAINER_RESULT"; do.*?case "\$result" in.*?success\|skipped\) ;;.*?\*\).*?exit 1.*?esac.*?done') { throw 'SaaS gate must reject non-success/non-skipped optional results' }
if ($gate -match '(?i)permissions:.*(write|read-all)') { throw 'SaaS gate must not request write permissions' }

$containerRelease = Get-Content -Raw -LiteralPath '.github\workflows\reusable-container-release.yml'
$containerBuilds = @([regex]::Matches($containerRelease, '(?m)^\s*uses:\s+docker/build-push-action@[0-9a-f]{40}'))
if ($containerBuilds.Count -ne 1) { throw 'Container release must build exactly once before scanning its pushed digest' }
foreach ($requiredReleaseControl in @(
  'push: true',
  'sbom: true',
  'provenance: mode=max',
  'RELEASE_IMAGE="ghcr.io/${GITHUB_REPOSITORY,,}"',
  'RELEASE_DIGEST="${{ steps.build.outputs.digest }}"',
  'RELEASE_REF="${RELEASE_IMAGE}@${RELEASE_DIGEST}"',
  "if [[ ! `"`$RELEASE_DIGEST`" =~ ^sha256:[a-f0-9]{64}`$ ]]; then",
  'image-ref: ${{ env.RELEASE_REF }}'
)) {
  if ($containerRelease -notmatch [regex]::Escape($requiredReleaseControl)) {
    throw "Container release omits required build-once digest control: $requiredReleaseControl"
  }
}
if ($containerRelease -match '(?im)(^|[^a-z])latest([^a-z]|$)') {
  throw 'Container release must not publish or scan a latest image tag'
}

if ($containerRelease -match '(?m)^ {6}DOKPLOY_API_KEY:\s*\r?$') {
  throw 'Container release must read the Dokploy API key from its production environment, not workflow_call secrets'
}
$releaseJob = [regex]::Match($containerRelease, '(?ms)^  release:\s*$.*?(?=^  [A-Za-z0-9_-]+:\s*$|\z)').Value
foreach ($requiredDeployControl in @(
  'environment: production',
  'id-token: write',
  'group: container-release-${{ github.repository }}-${{ vars.DOKPLOY_APPLICATION_ID }}',
  'cancel-in-progress: false',
  'tailscale/github-action@780049a30b6ff5c378a9e7b389d15ece7a204888 # v4.1.3',
  'oauth-client-id: ${{ vars.TS_WIF_CLIENT_ID }}',
  'audience: ${{ vars.TS_WIF_AUDIENCE }}',
  'tags: tag:deploy',
  "uses: $/.github/actions/deploy-dokploy # NOSONAR: GitHub resolves $/ from this reusable workflow's exact ref.",
  'DOKPLOY_APPLICATION_ID: ${{ vars.DOKPLOY_APPLICATION_ID }}',
  'DOKPLOY_URL: ${{ vars.DOKPLOY_URL }}',
  'HEALTH_URL: ${{ vars.HEALTH_URL }}',
  'DOKPLOY_API_KEY: ${{ secrets.DOKPLOY_API_KEY }}',
  'EXPECTED_REVISION: ${{ github.sha }}',
  'RELEASE_REF: ${{ env.RELEASE_REF }}',
  'APP_REVISION=${{ github.sha }}'
)) {
  if ($releaseJob -notmatch [regex]::Escape($requiredDeployControl)) {
    throw "Container release omits private deploy control: $requiredDeployControl"
  }
}
if (@([regex]::Matches($releaseJob, '(?m)^\s+uses:\s+actions/checkout@')).Count -ne 1) {
  throw 'Container release must checkout only the caller repository'
}
if ($releaseJob -match '(?m)workflow_(repository|sha)|\.pipeline-runtime|scripts/deploy-dokploy\.sh') {
  throw 'Container release must not checkout or invoke the deploy helper through a caller-token path'
}

$deployAction = Get-Content -Raw -LiteralPath '.github\actions\deploy-dokploy\action.yml'
if ($deployAction -match '(?m)^inputs:|^\s+inputs:|^secrets:|^\s+secrets:') {
  throw 'The deploy action must receive its environment from the reusable workflow without inputs or secrets'
}
if ($deployAction -notmatch '(?m)^\s+run:\s+bash "\$GITHUB_ACTION_PATH/deploy-dokploy\.sh"\s*$') {
  throw 'The deploy action must execute its co-located helper through GITHUB_ACTION_PATH'
}
$scanIndex = $releaseJob.IndexOf('aquasecurity/trivy-action@')
$tailscaleIndex = $releaseJob.IndexOf('tailscale/github-action@')
$deployIndex = $releaseJob.IndexOf('uses: $/.github/actions/deploy-dokploy')
if ($scanIndex -lt 0 -or $tailscaleIndex -le $scanIndex -or $deployIndex -le $tailscaleIndex) {
  throw 'Private Dokploy deployment must run through Tailscale only after the exact-digest Trivy scan'
}

$selfValidation = Get-Content -Raw -LiteralPath '.github\workflows\validate-pipelines.yml'
if ($selfValidation -notmatch [regex]::Escape('pwsh -NoProfile -File tests/test_dokploy_deploy.ps1')) {
  throw 'Pipeline validation must execute the real Dokploy deploy behavior tests'
}

$containerReleaseExample = Get-Content -Raw -LiteralPath 'examples\container-release.yml'
if ($containerReleaseExample -notmatch '(?ms)^on:\s*\r?\n\s+push:\s*\r?\n\s+branches:\s*\["main"\]') {
  throw 'The container release example must trigger on pushes to main'
}
if ($containerReleaseExample -match '(?ms)^\s+with:\s*$') {
  throw 'The container release example must rely on the reusable release defaults and omit inputs'
}
$containerReleaseCallerJob = [regex]::Match($containerReleaseExample, '(?ms)^  release:\s*$.*?(?=^  [A-Za-z0-9_-]+:\s*$|\z)').Value
foreach ($requiredCallerPermission in @('contents: read', 'packages: write', 'id-token: write')) {
  if ($containerReleaseCallerJob -notmatch [regex]::Escape($requiredCallerPermission)) {
    throw "The production release caller must grant $requiredCallerPermission"
  }
}
if ($containerReleaseCallerJob -match '(?m)^ {4}secrets:\s*(inherit\s*$|$)' -or $containerReleaseCallerJob -match '(?m)^ {6}DOKPLOY_API_KEY:\s*') {
  throw 'The production release caller must not pass Dokploy secrets to the reusable workflow'
}

$releaseExamplePin = [regex]::Match($containerReleaseExample, '(?m)^ {4}uses:\s+LouisVannobel/projetV0-pipelines/\.github/workflows/reusable-container-release\.yml@(?<sha>[0-9a-f]{40})\s+#\s+v\d+\.\d+\.\d+\s*$')
if (-not $releaseExamplePin.Success) { throw 'The container release example must expose its immutable full SHA' }
$pinnedHelper = ConvertTo-NormalizedLineEndingBytes (Get-GitBlobBytes "$($releaseExamplePin.Groups['sha'].Value):$deployActionScriptPath")
$currentHelper = ConvertTo-NormalizedLineEndingBytes ([System.IO.File]::ReadAllBytes((Join-Path (Split-Path -Parent $PSScriptRoot) $deployActionScriptPath)))
if ([Convert]::ToBase64String($pinnedHelper) -ne [Convert]::ToBase64String($currentHelper)) {
  throw 'The container release example must pin the exact behavior-tested Dokploy helper'
}

$readme = Get-Content -Raw -LiteralPath 'README.md'
foreach ($requiredDeploymentPrerequisite in @(
  'sourceType: docker',
  'identifiants de pull',
  'GHCR privé',
  'compte/API Dokploy dédié',
  'permissions minimales',
  'environnement GitHub `production`',
  'protégé'
)) {
  if ($readme -notmatch [regex]::Escape($requiredDeploymentPrerequisite)) {
    throw "README omits deployment prerequisite: $requiredDeploymentPrerequisite"
  }
}

$actionlintExe = $env:ACTIONLINT_EXE
if ($actionlintExe) {
  if (-not (Test-Path -LiteralPath $actionlintExe)) { throw "actionlint executable not found: $actionlintExe" }
  $exampleWorkflows = @(Get-ChildItem -LiteralPath 'examples' -Filter '*.yml' -File | ForEach-Object FullName)
  & $actionlintExe -ignore $actionlintSelfActionIgnore @($workflows + '.github\workflows\validate-pipelines.yml' + $exampleWorkflows)
  if ($LASTEXITCODE -ne 0) { throw "actionlint failed with exit code $LASTEXITCODE" }
}

Write-Output 'PIPELINE_CONTRACT_TESTS_OK'
