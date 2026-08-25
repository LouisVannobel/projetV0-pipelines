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

$ociReleaseWorkflow = '.github\workflows\reusable-oci-release.yml'
$workflows = @(
  '.github\workflows\reusable-saas-ci.yml',
  '.github\workflows\reusable-container-release.yml',
  '.github\workflows\reusable-repository-ci.yml',
  $ociReleaseWorkflow
)
if ($workflows -notcontains $ociReleaseWorkflow) {
  throw 'The local actionlint workflow set must include the serialized OCI release workflow'
}

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
$actionlintQueueIgnore = '^unexpected key "queue" for "concurrency" section\. expected one of "cancel-in-progress", "group"$'
function Test-ExactActionlintIgnores {
  param([Parameter(Mandatory)][string]$Workflow)

  $queueAssignment = "queue_ignore='$actionlintQueueIgnore'"
  return @([regex]::Matches($Workflow, [regex]::Escape($queueAssignment))).Count -eq 1 `
    -and @([regex]::Matches($Workflow, '(?m)^\s*self_action_ignore=')).Count -eq 0 `
    -and @([regex]::Matches($Workflow, '(?<![A-Za-z0-9_-])-ignore(?:\s|$)')).Count -eq 1 `
    -and @([regex]::Matches($Workflow, '-ignore\s+"\$queue_ignore"')).Count -eq 1
}
foreach ($lintWorkflow in @($repositoryCi, $selfValidation)) {
  if (-not (Test-ExactActionlintIgnores -Workflow $lintWorkflow)) {
    throw 'Actionlint must keep only the anchored concurrency-queue parser compatibility ignore'
  }
  foreach ($invalidIgnoreMutation in @(
    $lintWorkflow.Replace("queue_ignore='$actionlintQueueIgnore'", ''),
    $lintWorkflow.Replace($actionlintQueueIgnore, $actionlintQueueIgnore.Replace('"queue"', '"queues"')),
    $lintWorkflow.Replace('-ignore "$queue_ignore"', '-ignore "$queue_ignore" -ignore ".*"')
  )) {
    if (Test-ExactActionlintIgnores -Workflow $invalidIgnoreMutation) {
      throw 'Actionlint ignore contract accepted a missing, altered, or broader diagnostic ignore'
    }
  }
}

foreach ($example in Get-ChildItem -LiteralPath 'examples' -Filter '*.yml' -File) {
  $source = Get-Content -Raw -LiteralPath $example.FullName
  foreach ($call in [regex]::Matches($source, '(?m)^\s*uses:\s+([^\s]+)(?<comment>\s+#\s+v\d+\.\d+\.\d+)?\s*$')) {
    $use = $call.Groups[1].Value
    if ($use -notmatch '@[0-9a-f]{40}$') {
      throw "Example action must use an immutable full SHA: $use"
    }
    if ($use -match '/\.github/workflows/' -and $use -notmatch '^LouisVannobel/projetV0-pipelines/') {
      throw "Example reusable workflow must use the personal Pro repository: $use"
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
if ($saasCi -notmatch '(?ms)^      run-lighthouse:\s*$.*?^        default:\s*false\s*$') {
  throw 'Lighthouse must be opt-in because a one-run score is noisy and axe already gates accessibility'
}
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
  'outputs: type=image,name=${{ steps.release-image.outputs.image }},push-by-digest=true,name-canonical=true,push=true',
  'sbom: generator=docker/buildkit-syft-scanner:1.11.0@sha256:79e7b013cbec16bbb436f312819a49a4a57752b2270c1a9332ae1a10fcc82a68',
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
if ($containerRelease -match '(?m)^\s*sbom:\s*true\s*$') {
  throw 'Container release must pin its SBOM generator by version and digest'
}
if ($containerRelease -match '(?m)^\s*tags:\s*\$\{\{ steps\.release-image\.outputs\.image \}\}:sha-') {
  throw 'Container release must not expose its pre-scan candidate through a final-looking SHA tag'
}
if ($containerRelease -match '(?m)^\s*tags:\s*\$\{\{ steps\.release-image\.outputs\.image \}\}:candidate-') {
  throw 'Container release must push only an untagged canonical digest before scanning'
}

$containerWorkflowCall = [regex]::Match($containerRelease, '(?ms)^  workflow_call:\s*$.*?(?=^permissions:|^jobs:|\z)').Value
foreach ($requiredWorkflowOutput in @{
  'release-ref' = '(?ms)^ {6}release-ref:\s*$.*?^ {8}value:\s*\$\{\{\s*jobs\.release\.outputs\.release-ref\s*\}\}\s*$'
  'digest' = '(?ms)^ {6}digest:\s*$.*?^ {8}value:\s*\$\{\{\s*jobs\.release\.outputs\.digest\s*\}\}\s*$'
}.GetEnumerator()) {
  if ($containerWorkflowCall -notmatch $requiredWorkflowOutput.Value) {
    throw "Reusable container release omits safe workflow output: $($requiredWorkflowOutput.Key)"
  }
}
if ($containerWorkflowCall -match '(?m)^\s+secrets:\s*$|\$\{\{\s*secrets\.') {
  throw 'Reusable container release must not accept or expose deployment secrets'
}
$releaseJob = [regex]::Match($containerRelease, '(?ms)^  release:\s*$.*?(?=^  [A-Za-z0-9_-]+:\s*$|\z)').Value
foreach ($requiredReleaseOutput in @(
  'release-ref: ${{ steps.release-artifact.outputs.release-ref }}',
  'digest: ${{ steps.release-artifact.outputs.digest }}',
  'id: release-artifact',
  'printf ''release-ref=%s\n'' "$RELEASE_REF" >> "$GITHUB_OUTPUT"',
  'printf ''digest=%s\n'' "$RELEASE_DIGEST" >> "$GITHUB_OUTPUT"',
  'APP_REVISION=${{ github.sha }}'
)) {
  if ($releaseJob -notmatch [regex]::Escape($requiredReleaseOutput)) {
    throw "Container release omits immutable caller output: $requiredReleaseOutput"
  }
}
if (@([regex]::Matches($releaseJob, '(?m)^\s+uses:\s+actions/checkout@')).Count -ne 1) {
  throw 'Container release must checkout only the caller repository'
}
foreach ($forbiddenReusableDeployContext in @(
  'environment: production',
  'id-token: write',
  'tailscale/github-action@',
  'deploy-dokploy',
  'DOKPLOY_',
  'HEALTH_URL',
  '${{ secrets.'
)) {
  if ($containerRelease -match [regex]::Escape($forbiddenReusableDeployContext)) {
    throw "Reusable container release must not own caller production context: $forbiddenReusableDeployContext"
  }
}

$deployAction = Get-Content -Raw -LiteralPath '.github\actions\deploy-dokploy\action.yml'
if ($deployAction -match '(?m)^inputs:|^\s+inputs:|^secrets:|^\s+secrets:') {
  throw 'The deploy action must receive its environment from the reusable workflow without inputs or secrets'
}
if ($deployAction -notmatch '(?m)^\s+run:\s+bash "\$GITHUB_ACTION_PATH/deploy-dokploy\.sh"\s*$') {
  throw 'The deploy action must execute its co-located helper through GITHUB_ACTION_PATH'
}
$selfValidation = Get-Content -Raw -LiteralPath '.github\workflows\validate-pipelines.yml'
if ($selfValidation -notmatch [regex]::Escape('pwsh -NoProfile -File tests/test_dokploy_deploy.ps1')) {
  throw 'Pipeline validation must execute the real Dokploy deploy behavior tests'
}
if ($selfValidation -notmatch [regex]::Escape('pwsh -NoProfile -File tests/test_new_saas.ps1')) {
  throw 'Pipeline validation must execute the SaaS bootstrap boundary tests'
}

$containerReleaseExample = Get-Content -Raw -LiteralPath 'examples\container-release.yml'
if ($containerReleaseExample -notmatch '(?ms)^on:\s*\r?\n\s+push:\s*\r?\n\s+branches:\s*\["main"\]') {
  throw 'The container release example must trigger on pushes to main'
}
foreach ($requiredWorkflowConcurrency in @(
  'group: container-release-${{ github.repository }}',
  'cancel-in-progress: false'
)) {
  if ($containerReleaseExample -notmatch "(?ms)^concurrency:\s*`r?`n.*?$([regex]::Escape($requiredWorkflowConcurrency))") {
    throw "The complete release workflow must serialize build through deploy: $requiredWorkflowConcurrency"
  }
}
$containerBuildCallerJob = [regex]::Match($containerReleaseExample, '(?ms)^  build:\s*$.*?(?=^  [A-Za-z0-9_-]+:\s*$|\z)').Value
if ($containerBuildCallerJob -match '(?m)^ {4}with:\s*$') {
  throw 'The container release example must rely on the reusable release defaults and omit inputs'
}
foreach ($requiredBuildPermission in @('contents: read', 'packages: write')) {
  if ($containerBuildCallerJob -notmatch [regex]::Escape($requiredBuildPermission)) {
    throw "The reusable build caller must grant $requiredBuildPermission"
  }
}
if ($containerBuildCallerJob -match 'id-token:\s*write|environment:\s*production|\$\{\{\s*secrets\.') {
  throw 'The reusable build caller must not receive production identity or secrets'
}

$containerDeployCallerJob = [regex]::Match($containerReleaseExample, '(?ms)^  deploy:\s*$.*?(?=^  [A-Za-z0-9_-]+:\s*$|\z)').Value
foreach ($requiredLocalDeployControl in @(
  'needs: build',
  'contents: read',
  'id-token: write',
  'environment: production',
  'tailscale/github-action@780049a30b6ff5c378a9e7b389d15ece7a204888 # v4.1.3',
  'oauth-client-id: ${{ vars.TS_WIF_CLIENT_ID }}',
  'audience: ${{ vars.TS_WIF_AUDIENCE }}',
  'tags: tag:deploy',
  'DOKPLOY_APPLICATION_ID: ${{ vars.DOKPLOY_APPLICATION_ID }}',
  'DOKPLOY_URL: ${{ vars.DOKPLOY_URL }}',
  'HEALTH_URL: ${{ vars.HEALTH_URL }}',
  'DOKPLOY_API_KEY: ${{ secrets.DOKPLOY_API_KEY }}',
  'EXPECTED_REVISION: ${{ github.sha }}',
  'RELEASE_REF: ${{ needs.build.outputs.release-ref }}'
)) {
  if ($containerDeployCallerJob -notmatch [regex]::Escape($requiredLocalDeployControl)) {
    throw "Local production deploy omits required control: $requiredLocalDeployControl"
  }
}
if ($containerDeployCallerJob -match 'packages:\s*write|\$GITHUB_OUTPUT|::set-output') {
  throw 'The local deploy job must neither publish packages nor emit secret-bearing outputs'
}
if ($containerDeployCallerJob -match '(?m)^ {4}concurrency:\s*$') {
  throw 'Deploy-only concurrency cannot prevent an older build from deploying after a newer revision'
}
if ($containerReleaseExample -match '(?m)^\s+secrets:\s*(inherit\s*$|$)') {
  throw 'The release caller must read the environment secret only in its local production job'
}

$releaseExamplePin = [regex]::Match($containerReleaseExample, '(?m)^ {4}uses:\s+LouisVannobel/projetV0-pipelines/\.github/workflows/reusable-container-release\.yml@(?<sha>[0-9a-f]{40})\s+#\s+v\d+\.\d+\.\d+\s*$')
if (-not $releaseExamplePin.Success) { throw 'The container release example must expose its immutable full SHA' }
$pinnedContainerRelease = (& git show "$($releaseExamplePin.Groups['sha'].Value):.github/workflows/reusable-container-release.yml") -join "`n"
if ($LASTEXITCODE -ne 0) { throw 'The container release example must pin a readable reusable workflow revision' }
foreach ($requiredPinnedOutput in @{
  'release-ref' = '(?ms)^ {6}release-ref:\s*$.*?^ {8}value:\s*\$\{\{\s*jobs\.release\.outputs\.release-ref\s*\}\}\s*$'
  'digest' = '(?ms)^ {6}digest:\s*$.*?^ {8}value:\s*\$\{\{\s*jobs\.release\.outputs\.digest\s*\}\}\s*$'
}.GetEnumerator()) {
  if ($pinnedContainerRelease -notmatch $requiredPinnedOutput.Value) {
    throw "The pinned reusable release does not expose caller output: $($requiredPinnedOutput.Key)"
  }
}
$deployActionPin = [regex]::Match($containerDeployCallerJob, '(?m)^\s+uses:\s+LouisVannobel/projetV0-pipelines/\.github/actions/deploy-dokploy@(?<sha>[0-9a-f]{40})\s+#\s+v\d+\.\d+\.\d+\s*$')
if (-not $deployActionPin.Success) { throw 'The local production deploy must pin the private Dokploy action by full SHA' }
$pinnedHelper = ConvertTo-NormalizedLineEndingBytes (Get-GitBlobBytes "$($deployActionPin.Groups['sha'].Value):$deployActionScriptPath")
$currentHelper = ConvertTo-NormalizedLineEndingBytes ([System.IO.File]::ReadAllBytes((Join-Path (Split-Path -Parent $PSScriptRoot) $deployActionScriptPath)))
if ([Convert]::ToBase64String($pinnedHelper) -ne [Convert]::ToBase64String($currentHelper)) {
  throw 'The container release example must pin the exact behavior-tested Dokploy helper'
}

$readme = Get-Content -Raw -LiteralPath 'README.md'
$immutablePublishedTagPolicy = 'Tous les tags publiés sont immuables et ne doivent jamais être déplacés, notamment les tags actuels `v1.1.0`, `v1.1.1` et `v1.1.2`.'
if (-not $readme.Contains($immutablePublishedTagPolicy)) {
  throw 'README must make every published tag immutable and cover v1.1.0, v1.1.1 and v1.1.2'
}
foreach ($requiredDeploymentPrerequisite in @(
  'sourceType: docker',
  'identifiants de pull',
  'repository GHCR',
  'identité CI non personnelle',
  'révocable',
  'limitée au projet, à l''environnement et aux services SaaS',
  'environnement GitHub `production`',
  'branches protégées',
  'FailureAction=rollback',
  'Order=start-first',
  'Parallelism=1'
)) {
  if ($readme -notmatch [regex]::Escape($requiredDeploymentPrerequisite)) {
    throw "README omits deployment prerequisite: $requiredDeploymentPrerequisite"
  }
}

$actionlintExe = $env:ACTIONLINT_EXE
if ($actionlintExe) {
  if (-not (Test-Path -LiteralPath $actionlintExe)) { throw "actionlint executable not found: $actionlintExe" }
  $exampleWorkflows = @(Get-ChildItem -LiteralPath 'examples' -Filter '*.yml' -File | ForEach-Object FullName)
  & $actionlintExe -ignore $actionlintSelfActionIgnore -ignore $actionlintQueueIgnore @($workflows + '.github\workflows\validate-pipelines.yml' + $exampleWorkflows)
  if ($LASTEXITCODE -ne 0) { throw "actionlint failed with exit code $LASTEXITCODE" }
}

Write-Output 'PIPELINE_CONTRACT_TESTS_OK'
