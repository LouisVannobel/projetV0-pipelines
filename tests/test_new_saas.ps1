$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$localScript = Join-Path $root 'scripts\new-saas.ps1'
$remoteScript = Join-Path $root 'scripts\studio-saas.sh'

if (-not (Test-Path -LiteralPath $localScript)) { throw 'Missing scripts/new-saas.ps1' }
if (-not (Test-Path -LiteralPath $remoteScript)) { throw 'Missing scripts/studio-saas.sh' }

$invalidOutput = @(& pwsh -NoProfile -File $localScript 'Bad Name' -DryRun 2>&1)
if ($LASTEXITCODE -eq 0 -or ($invalidOutput -join "`n") -notmatch 'lowercase slug') {
  throw 'new-saas must reject unsafe slugs before doing any work'
}

$dryRunOutput = @(& pwsh -NoProfile -File $localScript 'invoice-ai' -DryRun 2>&1)
if ($LASTEXITCODE -ne 0) { throw "new-saas dry-run failed: $($dryRunOutput -join "`n")" }
$expectedDryRun = @(
  'NEW_SAAS_PLAN slug=invoice-ai repo=LouisVannobel/invoice-ai profile=private-stateless-ops01',
  'NEW_SAAS_PLAN health=tailnet-only resources=512MiB,1CPU database=none redis=none storage=none'
) -join "`n"
if (($dryRunOutput -join "`n") -cne $expectedDryRun) {
  throw "new-saas dry-run output drifted: $($dryRunOutput -join "`n")"
}

$localSource = Get-Content -Raw -LiteralPath $localScript
foreach ($required in @(
    'gh repo create',
    '--template LouisVannobel/projetV0-saas-template',
    '--private',
    'environments/production',
    'branches/main/protection',
    'actions/permissions',
    'vulnerability-alerts',
    'automated-security-fixes',
    'DOKPLOY_APPLICATION_ID',
    'DOKPLOY_API_KEY',
    'gh secret set',
    '--body -',
    'workflow run release.yml'
  )) {
  if (-not $localSource.Contains($required)) { throw "new-saas omits required golden-path control: $required" }
}
if ($localSource -notmatch '(?s)& ssh .*studio-saas secret.*\|\s*& gh secret set DOKPLOY_API_KEY.*--body -') {
  throw 'Dokploy API key must pass directly from the root helper to gh secret set over stdin'
}
foreach ($required in @('template_repository.full_name', '$secretTransferSucceeded = $?', 'mktemp /tmp/studio-saas.XXXXXX')) {
  if (-not $localSource.Contains($required)) { throw "new-saas omits required collision/transport guard: $required" }
}
if ($localSource -match '(?i)Get-Clipboard|Set-Clipboard|Write-(Output|Host).*API_KEY|DOKPLOY_API_KEY\s*=') {
  throw 'new-saas must never materialize or print the Dokploy API key'
}

$remoteSource = Get-Content -Raw -LiteralPath $remoteScript
foreach ($required in @(
    'flock',
    '8500',
    '8599',
    '3500',
    '3599',
    '/auth/sign-in/email',
    '/application.create',
    '/application.update',
    'endpointSpecSwarm',
    '/user.createUserWithCredentials',
    '/user.assignPermissions',
    '/user.createApiKey',
    'studio.projetv0.managed',
    '536870912',
    '1000000000',
    'start-first',
    'rollback',
    'tailscale serve --bg',
    '/environment.create',
    '/sshKey.all',
    '/registry.all'
  )) {
  if (-not $remoteSource.Contains($required)) { throw "studio-saas omits required invariant: $required" }
}
if (-not $remoteSource.Contains('printf ''%s\n'' "$API_KEY"')) {
  throw 'studio-saas secret command must emit only the stored API key'
}
foreach ($required in @('APP_NAME=', 'trap ''rm -f -- "$admin_cookie" "$member_cookie" "$response"'' EXIT', 'pre-existing Dokploy application', 'no second real application')) {
  if (-not $remoteSource.Contains($required)) { throw "studio-saas omits required state/cleanup/isolation guard: $required" }
}
if ($remoteSource.Contains('not-an-application')) { throw 'Isolation tests must never use a fabricated application ID' }
if ($remoteSource.Contains('--data "$body"') -or $remoteSource.Contains('-H "x-api-key: $key"')) {
  throw 'Dokploy passwords, request bodies, and API keys must not appear in curl argv'
}
if ($remoteSource -match 'printf.*(MEMBER_PASSWORD|API_KEY).*application=') {
  throw 'studio-saas provision output must stay non-secret'
}

& bash -n 'scripts/studio-saas.sh'
if ($LASTEXITCODE -ne 0) { throw 'studio-saas shell syntax is invalid' }
& bash 'scripts/studio-saas.sh' validate-slug invoice-ai
if ($LASTEXITCODE -ne 0) { throw 'studio-saas must accept the canonical slug' }
& bash 'scripts/studio-saas.sh' validate-slug 'Bad Name' 2>$null
if ($LASTEXITCODE -eq 0) { throw 'studio-saas must reject an unsafe slug' }

Write-Output 'NEW_SAAS_TESTS_OK'
