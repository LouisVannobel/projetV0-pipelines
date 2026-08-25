param(
  [Parameter(Mandatory, Position = 0)]
  [string]$Slug,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$owner = 'LouisVannobel'
$template = 'LouisVannobel/projetV0-saas-template'
$opsHost = 'ops01'
$repo = "$owner/$Slug"

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

foreach ($command in @('gh', 'ssh')) {
  if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw "$command is required" }
}
& gh auth status --hostname github.com *> $null
Assert-LastExitCode 'gh is not authenticated to github.com'
& ssh $opsHost true
Assert-LastExitCode 'ops01 is not reachable over SSH/Tailscale'

$remoteScript = Join-Path $PSScriptRoot 'studio-saas.sh'
if (-not (Test-Path -LiteralPath $remoteScript)) { throw 'studio-saas.sh is missing' }
$installCommand = 'set -Eeuo pipefail; sudo bash -c ''set -Eeuo pipefail; incoming="$(mktemp /tmp/studio-saas.XXXXXX)"; trap "rm -f -- \"$incoming\"" EXIT; tr -d "\r" > "$incoming"; bash -n "$incoming"; install -o root -g root -m 0755 "$incoming" /usr/local/sbin/studio-saas'''
Get-Content -Raw -LiteralPath $remoteScript | & ssh $opsHost $installCommand
Assert-LastExitCode 'Cannot install the versioned studio-saas helper on ops01'

$repoJson = & gh api "repos/$repo" 2>$null
if ($LASTEXITCODE -eq 0) {
  $repoObject = $repoJson | ConvertFrom-Json
  if ($repoObject.template_repository.full_name -cne $template) {
    throw "$repo already exists and was not generated from $template"
  }
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

$provisionOutput = @(& ssh $opsHost "sudo studio-saas provision $Slug" 2>&1)
Assert-LastExitCode 'Dokploy/Tailscale provisioning failed'
$provisionLine = ($provisionOutput | Where-Object { $_ -match '^SAAS_PROVISIONED ' } | Select-Object -Last 1)
if (-not $provisionLine -or $provisionLine -notmatch '^SAAS_PROVISIONED slug=(?<slug>[a-z0-9-]+) application=(?<application>[A-Za-z0-9_-]+) published_port=(?<port>35[0-9]{2}) health_url=(?<health>https://ops01[.]tail87a1b6[.]ts[.]net:85[0-9]{2}/health)$') {
  throw 'studio-saas returned malformed provisioning evidence'
}
if ($Matches.slug -cne $Slug) { throw 'studio-saas returned another slug' }
$applicationId = $Matches.application
$healthUrl = $Matches.health

Invoke-GhJson PUT "repos/$repo/environments/production" @{
  wait_timer = 0
  prevent_self_review = $false
  reviewers = @()
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

foreach ($name in @('DOKPLOY_URL', 'TS_WIF_CLIENT_ID', 'TS_WIF_AUDIENCE')) {
  $value = (& gh variable get $name --repo $template).Trim()
  Assert-LastExitCode "Cannot read template variable $name"
  if (-not $value) { throw "Template variable $name is empty" }
  & gh variable set $name --repo $repo --body $value
  Assert-LastExitCode "Cannot set repository variable $name"
}
& gh variable set HEALTH_URL --repo $repo --body $healthUrl
Assert-LastExitCode 'Cannot set HEALTH_URL'
& gh variable set DOKPLOY_APPLICATION_ID --repo $repo --env production --body $applicationId
Assert-LastExitCode 'Cannot set production DOKPLOY_APPLICATION_ID'

& ssh $opsHost "sudo studio-saas secret $Slug" |
  & gh secret set DOKPLOY_API_KEY --repo $repo --env production --body -
$secretTransferSucceeded = $?
if (-not $secretTransferSucceeded) {
  throw 'Cannot transfer the app-scoped Dokploy key to the production environment'
}

$headSha = (& gh api "repos/$repo/commits/main" --jq .sha).Trim()
Assert-LastExitCode 'Cannot resolve the initial main revision'
& gh workflow run release.yml --repo $repo --ref main
Assert-LastExitCode 'Cannot dispatch the initial release'

$run = $null
for ($attempt = 1; $attempt -le 20; $attempt++) {
  $runs = & gh run list --repo $repo --workflow release.yml --event workflow_dispatch --limit 10 --json databaseId,headSha,status,url | ConvertFrom-Json
  Assert-LastExitCode 'Cannot list the initial release run'
  $run = $runs | Where-Object { $_.headSha -eq $headSha } | Select-Object -First 1
  if ($run) { break }
  Start-Sleep -Seconds 2
}
if (-not $run) { throw 'The initial release run was not created' }
& gh run watch $run.databaseId --repo $repo --exit-status
Assert-LastExitCode "Initial release failed: $($run.url)"

$runtimeOutput = @(& ssh $opsHost "sudo studio-saas inspect $Slug" 2>&1)
Assert-LastExitCode 'Runtime verification failed after the initial release'
$runtimeLine = $runtimeOutput | Where-Object { $_ -match '^SAAS_RUNTIME_OK ' } | Select-Object -Last 1
if (-not $runtimeLine) { throw 'studio-saas returned no runtime success marker' }
Write-Output "SAAS_READY repo=https://github.com/$repo health=$healthUrl application=$applicationId run=$($run.url)"
