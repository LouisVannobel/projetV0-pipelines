$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$localScript = Join-Path $root 'scripts\new-saas.ps1'
$remoteScript = Join-Path $root 'scripts\studio-saas.sh'
$installerScript = Join-Path $root 'scripts\install-studio-saas.ps1'

if (-not (Test-Path -LiteralPath $localScript)) { throw 'Missing scripts/new-saas.ps1' }
if (-not (Test-Path -LiteralPath $remoteScript)) { throw 'Missing scripts/studio-saas.sh' }
if (-not (Test-Path -LiteralPath $installerScript)) { throw 'Missing scripts/install-studio-saas.ps1' }
$reviewedHelperHash = 'd55edde4cf838dc38cb92b86e88a65d38c07ee409cca071ac877874ebded7543'
$actualHelperHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $remoteScript).Hash.ToLowerInvariant()
if ($actualHelperHash -cne $reviewedHelperHash) { throw "Repository studio-saas.sh is not the reviewed artifact: $actualHelperHash" }

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
    '''secret'', ''set'', ''DOKPLOY_API_KEY''',
    'gh run rerun',
    '--event push'
  )) {
  if (-not $localSource.Contains($required)) { throw "new-saas omits required golden-path control: $required" }
}
if ($localSource -notmatch '(?s)StandardOutput[.]BaseStream[.]CopyTo\(.*StandardInput[.]BaseStream\)') {
  throw 'Dokploy API key must pass directly from the root helper to gh secret set over stdin'
}
foreach ($required in @('template_repository.full_name', '$templateRevision', '9df204d23475ca7a00922307e7df825531211db2', 'STUDIO_SAAS_VERSION', 'sshProcess.ExitCode', 'ghProcess.ExitCode', 'gh run rerun $run.databaseId --repo $repo --failed')) {
  if (-not $localSource.Contains($required)) { throw "new-saas omits required collision/transport guard: $required" }
}
if (-not $localSource.Contains("`$templateRevision = '321f007caadca4b604e7c365d201d6dd8219dd7a'")) {
  throw 'new-saas must pin the reviewed template commit'
}
if ($localSource.Contains('$installCommand') -or $localSource -match 'install .*studio-saas') {
  throw 'The normal SaaS path must not install or update a root helper'
}
$installerSource = Get-Content -Raw -LiteralPath $installerScript
$installerTestRoot = Join-Path ([IO.Path]::GetTempPath()) "studio-saas-installer-$([guid]::NewGuid().ToString('N'))"
$fakeBin = Join-Path $installerTestRoot 'bin'
$bashMarker = Join-Path $installerTestRoot 'bash-ran'
$scpMarker = Join-Path $installerTestRoot 'scp-ran'
$sshMarker = Join-Path $installerTestRoot 'ssh-ran'
try {
  New-Item -ItemType Directory -Path $fakeBin | Out-Null
  Copy-Item -LiteralPath $installerScript -Destination (Join-Path $installerTestRoot 'install-studio-saas.ps1')
  Copy-Item -LiteralPath $remoteScript -Destination (Join-Path $installerTestRoot 'studio-saas.sh')
  Add-Content -LiteralPath (Join-Path $installerTestRoot 'studio-saas.sh') -Value '# unreviewed drift'
  Set-Content -LiteralPath (Join-Path $fakeBin 'bash.cmd') -Value "@echo off`r`ntype nul > `"$bashMarker`"`r`nexit /b 0"
  Set-Content -LiteralPath (Join-Path $fakeBin 'scp.cmd') -Value "@echo off`r`ntype nul > `"$scpMarker`"`r`nexit /b 0"
  Set-Content -LiteralPath (Join-Path $fakeBin 'ssh.cmd') -Value "@echo off`r`ntype nul > `"$sshMarker`"`r`nexit /b 1"
  $previousPath = $env:PATH
  $env:PATH = "$fakeBin;$previousPath"
  $driftOutput = @(& pwsh -NoProfile -File (Join-Path $installerTestRoot 'install-studio-saas.ps1') 2>&1)
  $driftStatus = $LASTEXITCODE
  $prematureCommands = @($bashMarker, $scpMarker, $sshMarker) | Where-Object { Test-Path -LiteralPath $_ }
  if ($driftStatus -eq 0 -or $prematureCommands.Count -ne 0) {
    throw "Installer must reject unreviewed helper bytes before any command: $($driftOutput -join "`n")"
  }
} finally {
  if ($null -ne $previousPath) { $env:PATH = $previousPath }
  Remove-Item -LiteralPath $installerTestRoot -Recurse -Force -ErrorAction SilentlyContinue
}
foreach ($required in @(
    '/etc/sudoers.d/studio-saas',
    'visudo -cf',
    '^(validate-slug|provision|inspect|secret) [a-z0-9][a-z0-9-]*$',
    "`$expectedHash = 'd55edde4cf838dc38cb92b86e88a65d38c07ee409cca071ac877874ebded7543'",
    'mktemp -d /tmp/studio-saas.',
    'mktemp /usr/local/sbin/.studio-saas.',
    'mktemp /etc/sudoers.d/.studio-saas.',
    'sha256sum -c -',
    'test -s',
    'cmp -s',
    'mv -fT --'
  )) {
  if (-not $installerSource.Contains($required)) { throw "One-time studio-saas installer omits: $required" }
}
if ($installerSource.Contains('sudo -n tee')) { throw 'Sudoers staging must not pipe into root tee' }
if ($localSource -match '(?i)Get-Clipboard|Set-Clipboard|Write-(Output|Host).*API_KEY|DOKPLOY_API_KEY\s*=') {
  throw 'new-saas must never materialize or print the Dokploy API key'
}
if ($localSource -match '''--body'',\s*''-''') {
  throw 'gh secret set must read stdin by omitting --body, not store a literal hyphen'
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
    '.Spec.UpdateConfig.Monitor',
    '.Spec.RollbackConfig.Monitor',
    'Handlers["/"].Proxy',
    'tailscale serve --bg',
    '/environment.create',
    '/sshKey.all',
    '/registry.all'
  )) {
  if (-not $remoteSource.Contains($required)) { throw "studio-saas omits required invariant: $required" }
}
if (-not $remoteSource.Contains('printf ''%s'' "$API_KEY"')) {
  throw 'studio-saas secret command must emit only the stored API key'
}
foreach ($required in @('APP_NAME=', 'STUDIO_SAAS_VERSION', 'trap ''rm -f -- "$admin_cookie" "$member_cookie" "$response"'' EXIT', 'ambiguous Dokploy application matches', '/user.deleteApiKey', 'matching_key_ids', 'verify_peer_application_isolation')) {
  if (-not $remoteSource.Contains($required)) { throw "studio-saas omits required state/cleanup/isolation guard: $required" }
}
if ($remoteSource.Contains('not-an-application')) { throw 'Isolation tests must never use a fabricated application ID' }
if ($remoteSource.Contains('--data "$body"') -or $remoteSource.Contains('-H "x-api-key: $key"')) {
  throw 'Dokploy passwords, request bodies, and API keys must not appear in curl argv'
}
foreach ($forbiddenPasswordArgument in @('--arg password "$password"', '--arg password "$MEMBER_PASSWORD"')) {
  if ($remoteSource.Contains($forbiddenPasswordArgument)) {
    throw 'Dokploy passwords must not appear in external process arguments'
  }
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
$versionOutput = @(& bash 'scripts/studio-saas.sh' version 2>&1) -join "`n"
$expectedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $remoteScript).Hash.ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $versionOutput -cne "STUDIO_SAAS_VERSION sha256=$expectedHash") {
  throw "studio-saas version must identify the exact helper bytes: $versionOutput"
}
& bash 'tests/test_studio_saas_reconciliation.sh'
if ($LASTEXITCODE -ne 0) { throw 'studio-saas reconciliation behavior failed' }

Write-Output 'NEW_SAAS_TESTS_OK'
