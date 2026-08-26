param(
  [Parameter(Mandatory, Position = 0)]
  [string]$Slug,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$owner = 'LouisVannobel'
$template = 'LouisVannobel/projetV0-saas-template'
$templateRevision = 'c7a5443333f25d990d80dcdfe3a31a29dfa0ee7b'
$pipelineRevision = '9df204d23475ca7a00922307e7df825531211db2'
$opsHost = 'ops01'
$repo = "$owner/$Slug"
$dokployUrl = 'https://ops01.tail87a1b6.ts.net:8442/api'
$tailscaleClientId = 'TimwJHWgrv11CNTRL-kxCYVq4KR421CNTRL'
$tailscaleAudience = 'api.tailscale.com/TimwJHWgrv11CNTRL-kxCYVq4KR421CNTRL'
$criticalTemplatePaths = @(
  '.github/workflows/ci.yml',
  '.github/workflows/release.yml',
  '.github/dependabot.yml',
  'Dockerfile',
  'app/health/route.ts'
)

if ($Slug -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,38}[a-z0-9])?$') {
  Write-Error 'Use a 1-40 character lowercase slug with digits or internal hyphens.'
  exit 2
}

if ($DryRun) {
  Write-Output "NEW_SAAS_PLAN slug=$Slug repo=$repo profile=private-stateless-ops01"
  Write-Output 'NEW_SAAS_PLAN health=tailnet-only resources=512MiB,1CPU database=none redis=none storage=none'
  exit 0
}

function Assert-LastExitCode([string]$Message) {
  if ($LASTEXITCODE -ne 0) { throw $Message }
}

function Invoke-GhJson([string]$Method, [string]$Path, [hashtable]$Body) {
  $json = $Body | ConvertTo-Json -Depth 10 -Compress
  $json | & gh api --method $Method $Path --input - | Out-Null
  Assert-LastExitCode "GitHub API request failed: $Path"
}

function Get-GhJson([string]$Path) {
  $raw = & gh api $Path
  Assert-LastExitCode "GitHub API request failed: $Path"
  return $raw | ConvertFrom-Json
}

function Get-BlobSha([string]$Repository, [string]$Path, [string]$Ref) {
  $encodedPath = ($Path -split '/' | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
  $blob = Get-GhJson "repos/$Repository/contents/$encodedPath`?ref=$Ref"
  if ($blob.type -cne 'file' -or $blob.sha -notmatch '^[0-9a-f]{40}$') {
    throw "Critical file is unavailable: $Repository/$Path@$Ref"
  }
  return $blob.sha
}

function Assert-TemplateSource {
  $source = Get-GhJson "repos/$template"
  if (-not $source.private -or -not $source.is_template -or $source.archived -or $source.default_branch -cne 'main') {
    throw 'The configured SaaS template repository no longer satisfies the private template contract'
  }
  $sourceHead = (& gh api "repos/$template/commits/main" --jq .sha).Trim()
  Assert-LastExitCode 'Cannot resolve the SaaS template main revision'
  if ($sourceHead -cne $templateRevision) {
    throw "Template main moved: expected $templateRevision, observed $sourceHead"
  }
}

function Assert-TargetRepository([object]$Repository) {
  if (-not $Repository.private -or $Repository.archived -or $Repository.default_branch -cne 'main' -or
      $Repository.template_repository.full_name -cne $template) {
    throw "$repo does not satisfy the private generated-repository contract"
  }
  foreach ($path in $criticalTemplatePaths) {
    $sourceSha = Get-BlobSha -Repository $template -Path $path -Ref $templateRevision
    $targetSha = Get-BlobSha -Repository $repo -Path $path -Ref 'main'
    if ($sourceSha -cne $targetSha) { throw "Critical generated file drifted before bootstrap: $path" }
  }
  $release = & gh api "repos/$repo/contents/.github/workflows/release.yml?ref=main" --jq .content
  Assert-LastExitCode 'Cannot inspect generated release workflow'
  $releaseText = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($release -replace '\s', '')))
  if ($releaseText -notmatch [regex]::Escape("@$pipelineRevision")) {
    throw 'Generated release workflow does not pin the reviewed pipeline revision'
  }
}

function Assert-RepositoryVariable([string]$Name, [string]$Expected, [string]$Environment = '') {
  $arguments = @('variable', 'get', $Name, '--repo', $repo)
  if ($Environment) { $arguments += @('--env', $Environment) }
  $actual = (& gh @arguments).Trim()
  Assert-LastExitCode "Cannot read back variable $Name"
  if ($actual -cne $Expected) { throw "GitHub variable $Name did not converge" }
}

function Send-DokploySecret([string]$TargetRepo, [string]$TargetSlug) {
  $sshInfo = [Diagnostics.ProcessStartInfo]::new()
  $sshInfo.FileName = (Get-Command ssh).Source
  $sshInfo.UseShellExecute = $false
  $sshInfo.RedirectStandardOutput = $true
  [void]$sshInfo.ArgumentList.Add($opsHost)
  [void]$sshInfo.ArgumentList.Add("sudo -n studio-saas secret $TargetSlug")

  $ghInfo = [Diagnostics.ProcessStartInfo]::new()
  $ghInfo.FileName = (Get-Command gh).Source
  $ghInfo.UseShellExecute = $false
  $ghInfo.RedirectStandardInput = $true
  foreach ($argument in @('secret', 'set', 'DOKPLOY_API_KEY', '--repo', $TargetRepo, '--env', 'production')) {
    [void]$ghInfo.ArgumentList.Add($argument)
  }

  $sshProcess = [Diagnostics.Process]::Start($sshInfo)
  $ghProcess = [Diagnostics.Process]::Start($ghInfo)
  try {
    $sshProcess.StandardOutput.BaseStream.CopyTo($ghProcess.StandardInput.BaseStream)
    $sshProcess.WaitForExit()
    if ($sshProcess.ExitCode -ne 0) {
      $ghProcess.Kill($true)
      throw 'Cannot read the app-scoped Dokploy key from ops01'
    }
    $ghProcess.StandardInput.Close()
    $ghProcess.WaitForExit()
    if ($ghProcess.ExitCode -ne 0) { throw 'Cannot set the production Dokploy key in GitHub' }
  } finally {
    $sshProcess.Dispose()
    $ghProcess.Dispose()
  }
}

foreach ($command in @('gh', 'ssh')) {
  if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw "$command is required" }
}
& gh auth status --hostname github.com *> $null
Assert-LastExitCode 'gh is not authenticated to github.com'
& ssh $opsHost true
Assert-LastExitCode 'ops01 is not reachable over SSH/Tailscale'

$remoteScript = Join-Path $PSScriptRoot 'studio-saas.sh'
if (-not (Test-Path -LiteralPath $remoteScript)) { throw 'studio-saas.sh is missing' }
$expectedHelperHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $remoteScript).Hash.ToLowerInvariant()
$installedVersion = @(& ssh $opsHost 'studio-saas version' 2>&1) -join "`n"
Assert-LastExitCode 'The reviewed studio-saas helper is not installed on ops01'
if ($installedVersion -cne "STUDIO_SAAS_VERSION sha256=$expectedHelperHash") {
  throw 'The installed studio-saas helper does not match this reviewed checkout'
}
& ssh $opsHost "sudo -n studio-saas validate-slug $Slug" *> $null
Assert-LastExitCode 'The persistent sudo boundary does not allow the reviewed studio-saas helper'
Assert-TemplateSource

$repoJson = & gh api "repos/$repo" 2>$null
if ($LASTEXITCODE -eq 0) {
  $repoObject = $repoJson | ConvertFrom-Json
} else {
  & gh repo create $repo --template LouisVannobel/projetV0-saas-template --private --description "Private stateless SaaS: $Slug" *> $null
  Assert-LastExitCode "Cannot create $repo from $template"
}

$mainReady = $false
for ($attempt = 1; $attempt -le 15; $attempt++) {
  & gh api "repos/$repo/commits/main" --jq .sha *> $null
  if ($LASTEXITCODE -eq 0) { $mainReady = $true; break }
  Start-Sleep -Seconds 2
}
if (-not $mainReady) { throw "$repo did not expose its main branch" }
$repoObject = Get-GhJson "repos/$repo"
Assert-TargetRepository -Repository $repoObject

$provisionOutput = @(& ssh $opsHost "sudo -n studio-saas provision $Slug" 2>&1)
Assert-LastExitCode 'Dokploy/Tailscale provisioning failed'
$provisionLine = ($provisionOutput | Where-Object { $_ -match '^SAAS_PROVISIONED ' } | Select-Object -Last 1)
if (-not $provisionLine -or $provisionLine -notmatch '^SAAS_PROVISIONED slug=(?<slug>[a-z0-9-]+) application=(?<application>[A-Za-z0-9_-]+) published_port=(?<port>35[0-9]{2}) health_url=(?<health>https://ops01[.]tail87a1b6[.]ts[.]net:85[0-9]{2}/health)$') {
  throw 'studio-saas returned malformed provisioning evidence'
}
if ($Matches.slug -cne $Slug) { throw 'studio-saas returned another slug' }
$applicationId = $Matches.application
$healthUrl = $Matches.health

Invoke-GhJson PUT "repos/$repo/environments/production" @{
  deployment_branch_policy = @{ protected_branches = $true; custom_branch_policies = $false }
}
Invoke-GhJson PUT "repos/$repo/actions/permissions" @{
  enabled = $true
  allowed_actions = 'all'
  sha_pinning_required = $true
}
Invoke-GhJson PUT "repos/$repo/branches/main/protection" @{
  required_status_checks = @{ strict = $true; contexts = @('ci / CI / gate') }
  enforce_admins = $true
  required_pull_request_reviews = @{
    dismiss_stale_reviews = $false
    require_code_owner_reviews = $false
    require_last_push_approval = $false
    required_approving_review_count = 0
  }
  restrictions = $null
  required_linear_history = $true
  allow_force_pushes = $false
  allow_deletions = $false
  block_creations = $false
  required_conversation_resolution = $true
  lock_branch = $false
  allow_fork_syncing = $false
}
& gh api --method PUT "repos/$repo/vulnerability-alerts" | Out-Null
Assert-LastExitCode 'Cannot enable Dependabot alerts'
& gh api --method PUT "repos/$repo/automated-security-fixes" | Out-Null
Assert-LastExitCode 'Cannot enable Dependabot security updates'

foreach ($entry in @(
    @{ Name = 'DOKPLOY_URL'; Value = $dokployUrl },
    @{ Name = 'TS_WIF_CLIENT_ID'; Value = $tailscaleClientId },
    @{ Name = 'TS_WIF_AUDIENCE'; Value = $tailscaleAudience }
  )) {
  & gh variable set $entry.Name --repo $repo --body $entry.Value
  Assert-LastExitCode "Cannot set repository variable $($entry.Name)"
  Assert-RepositoryVariable -Name $entry.Name -Expected $entry.Value
}
& gh variable set HEALTH_URL --repo $repo --body $healthUrl
Assert-LastExitCode 'Cannot set HEALTH_URL'
Assert-RepositoryVariable -Name HEALTH_URL -Expected $healthUrl
& gh variable set DOKPLOY_APPLICATION_ID --repo $repo --env production --body $applicationId
Assert-LastExitCode 'Cannot set production DOKPLOY_APPLICATION_ID'
Assert-RepositoryVariable -Name DOKPLOY_APPLICATION_ID -Expected $applicationId -Environment production

Send-DokploySecret -TargetRepo $repo -TargetSlug $Slug

$headSha = (& gh api "repos/$repo/commits/main" --jq .sha).Trim()
Assert-LastExitCode 'Cannot resolve the initial main revision'

$run = $null
for ($attempt = 1; $attempt -le 20; $attempt++) {
  $runs = & gh run list --repo $repo --workflow release.yml --event push --limit 10 --json databaseId,headSha,status,conclusion,url | ConvertFrom-Json
  Assert-LastExitCode 'Cannot list the initial release run'
  $run = $runs | Where-Object { $_.headSha -eq $headSha } | Select-Object -First 1
  if ($run) { break }
  Start-Sleep -Seconds 2
}
if (-not $run) { throw 'The template creation push produced no release run' }
if ($run.status -ne 'completed') {
  & gh run watch $run.databaseId --repo $repo --exit-status
  $run = & gh run view $run.databaseId --repo $repo --json databaseId,headSha,status,conclusion,url | ConvertFrom-Json
  Assert-LastExitCode 'Cannot refresh the template creation release state'
}
if ($run.conclusion -ne 'success') {
  & gh run rerun $run.databaseId --repo $repo --failed
  Assert-LastExitCode 'Cannot rerun only the failed portion of the configured template creation release'
  Start-Sleep -Seconds 2
  & gh run watch $run.databaseId --repo $repo --exit-status
  Assert-LastExitCode "Initial release failed after one failed-job rerun: $($run.url)"
}

$runtimeOutput = @(& ssh $opsHost "sudo -n studio-saas inspect $Slug" 2>&1)
Assert-LastExitCode 'Runtime verification failed after the initial release'
$runtimeLine = $runtimeOutput | Where-Object { $_ -match '^SAAS_RUNTIME_OK ' } | Select-Object -Last 1
if (-not $runtimeLine) { throw 'studio-saas returned no runtime success marker' }
Write-Output "SAAS_READY repo=https://github.com/$repo health=$healthUrl application=$applicationId run=$($run.url)"
