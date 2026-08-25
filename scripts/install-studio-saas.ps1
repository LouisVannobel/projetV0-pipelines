param(
  [string]$OpsHost = 'ops01'
)

$ErrorActionPreference = 'Stop'

function Assert-LastExitCode([string]$Message) {
  if ($LASTEXITCODE -ne 0) { throw $Message }
}

function Convert-ToBashPath([string]$Path) {
  if ($Path -match '^([A-Za-z]):\\(.*)$') {
    return "/mnt/$($Matches[1].ToLowerInvariant())/$($Matches[2].Replace('\', '/'))"
  }
  return $Path.Replace('\', '/')
}

foreach ($command in @('bash', 'scp', 'ssh')) {
  if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw "$command is required" }
}

$helper = Join-Path $PSScriptRoot 'studio-saas.sh'
if (-not (Test-Path -LiteralPath $helper)) { throw 'studio-saas.sh is missing' }
& bash -n (Convert-ToBashPath $helper)
Assert-LastExitCode 'studio-saas.sh has invalid shell syntax'

$suffix = [guid]::NewGuid().ToString('N')
$remoteHelper = "/tmp/studio-saas-$suffix"
$remoteSudoers = "/tmp/studio-saas-sudoers-$suffix"
$sudoersRule = @'
# Managed projetV0 SaaS bootstrap boundary.
Cmnd_Alias STUDIO_SAAS = /usr/local/sbin/studio-saas ^(validate-slug|provision|inspect|secret) [a-z0-9][a-z0-9-]*$
ops01 ALL=(root) NOPASSWD: STUDIO_SAAS
'@

try {
  & scp $helper "${OpsHost}:$remoteHelper" *> $null
  Assert-LastExitCode 'Cannot stage studio-saas on ops01'
  $sudoersRule | & ssh $OpsHost "tr -d '\r' | sudo -n tee '$remoteSudoers' >/dev/null"
  Assert-LastExitCode 'Cannot stage the studio-saas sudo policy'
  & ssh $OpsHost "sudo -n bash -n '$remoteHelper' && sudo -n chown root:root '$remoteHelper' '$remoteSudoers' && sudo -n chmod 0755 '$remoteHelper' && sudo -n chmod 0440 '$remoteSudoers' && sudo -n visudo -cf '$remoteSudoers' && sudo -n install -o root -g root -m 0755 '$remoteHelper' /usr/local/sbin/studio-saas && sudo -n install -o root -g root -m 0440 '$remoteSudoers' /etc/sudoers.d/studio-saas"
  Assert-LastExitCode 'Cannot install the reviewed studio-saas boundary'
} finally {
  & ssh $OpsHost "sudo -n rm -f -- '$remoteHelper' '$remoteSudoers'" *> $null
}

$expectedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $helper).Hash.ToLowerInvariant()
$version = @(& ssh $OpsHost 'studio-saas version' 2>&1) -join "`n"
Assert-LastExitCode 'Installed studio-saas version is unavailable'
if ($version -cne "STUDIO_SAAS_VERSION sha256=$expectedHash") { throw 'Installed studio-saas bytes do not match this checkout' }
& ssh $OpsHost 'sudo -n studio-saas validate-slug installer-smoke' *> $null
Assert-LastExitCode 'Installed studio-saas sudo boundary is unavailable'
Write-Output "STUDIO_SAAS_INSTALLED host=$OpsHost sha256=$expectedHash"
