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
$expectedHash = 'd55edde4cf838dc38cb92b86e88a65d38c07ee409cca071ac877874ebded7543'
$localHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $helper).Hash.ToLowerInvariant()
if ($localHash -cne $expectedHash) { throw "Local studio-saas.sh is not the reviewed artifact: $localHash" }
& bash -n (Convert-ToBashPath $helper)
Assert-LastExitCode 'studio-saas.sh has invalid shell syntax'

$sudoersRule = @'
# Managed projetV0 SaaS bootstrap boundary.
Cmnd_Alias STUDIO_SAAS = /usr/local/sbin/studio-saas ^(validate-slug|provision|inspect|secret) [a-z0-9][a-z0-9-]*$
ops01 ALL=(root) NOPASSWD: STUDIO_SAAS
'@

$remoteStage = ''
try {
  $remoteStage = @(& ssh $OpsHost "set -eu; umask 077; mktemp -d /tmp/studio-saas.XXXXXXXXXX" 2>&1) -join "`n"
  Assert-LastExitCode 'Cannot create a private studio-saas staging directory'
  $remoteStage = $remoteStage.Trim()
  if ($remoteStage -notmatch '^/tmp/studio-saas[.][A-Za-z0-9]+$') { throw 'Remote studio-saas staging path is invalid' }
  $remoteHelper = "$remoteStage/studio-saas"
  $remoteSudoers = "$remoteStage/studio-saas.sudoers"

  & scp $helper "${OpsHost}:$remoteHelper" *> $null
  Assert-LastExitCode 'Cannot stage studio-saas on ops01'
  $sudoersRule | & ssh $OpsHost "set -eu; umask 077; tr -d '\r' > '$remoteSudoers'"
  Assert-LastExitCode 'Cannot stage the studio-saas sudo policy'
  $installCommand = @'
set -euo pipefail
remote_stage='__REMOTE_STAGE__'
remote_helper='__REMOTE_HELPER__'
remote_sudoers='__REMOTE_SUDOERS__'
expected_hash='__EXPECTED_HASH__'
helper_install=''
sudoers_install=''
cleanup_install() {
  if [[ -n "$helper_install" ]]; then sudo -n rm -f -- "$helper_install"; fi
  if [[ -n "$sudoers_install" ]]; then sudo -n rm -f -- "$sudoers_install"; fi
}
trap cleanup_install EXIT

sudo -n chown root:root "$remote_stage" "$remote_helper" "$remote_sudoers"
sudo -n chmod 0700 "$remote_stage"
sudo -n chmod 0755 "$remote_helper"
sudo -n chmod 0440 "$remote_sudoers"
printf '%s  %s\n' "$expected_hash" "$remote_helper" | sudo -n sha256sum -c -
sudo -n test -s "$remote_sudoers"
sudo -n bash -n "$remote_helper"
sudo -n visudo -cf "$remote_sudoers"

helper_install="$(sudo -n mktemp /usr/local/sbin/.studio-saas.XXXXXXXXXX)"
sudoers_install="$(sudo -n mktemp /etc/sudoers.d/.studio-saas.XXXXXXXXXX)"
sudo -n install -o root -g root -m 0755 "$remote_helper" "$helper_install"
sudo -n install -o root -g root -m 0440 "$remote_sudoers" "$sudoers_install"
printf '%s  %s\n' "$expected_hash" "$helper_install" | sudo -n sha256sum -c -
sudo -n test -s "$sudoers_install"
sudo -n bash -n "$helper_install"
sudo -n visudo -cf "$sudoers_install"
sudo -n cmp -s "$remote_sudoers" "$sudoers_install"

sudo -n mv -fT -- "$helper_install" /usr/local/sbin/studio-saas
helper_install=''
sudo -n mv -fT -- "$sudoers_install" /etc/sudoers.d/studio-saas
sudoers_install=''
sudo -n cmp -s "$remote_sudoers" /etc/sudoers.d/studio-saas
printf '%s  %s\n' "$expected_hash" /usr/local/sbin/studio-saas | sudo -n sha256sum -c -
'@
  $installCommand = $installCommand.Replace('__REMOTE_STAGE__', $remoteStage).Replace('__REMOTE_HELPER__', $remoteHelper).Replace('__REMOTE_SUDOERS__', $remoteSudoers).Replace('__EXPECTED_HASH__', $expectedHash).Replace("`r", '')
  & ssh $OpsHost $installCommand
  Assert-LastExitCode 'Cannot install the reviewed studio-saas boundary'
} finally {
  if ($remoteStage -match '^/tmp/studio-saas[.][A-Za-z0-9]+$') {
    & ssh $OpsHost "sudo -n rm -rf -- '$remoteStage'" *> $null
  }
}

$version = @(& ssh $OpsHost 'studio-saas version' 2>&1) -join "`n"
Assert-LastExitCode 'Installed studio-saas version is unavailable'
if ($version -cne "STUDIO_SAAS_VERSION sha256=$expectedHash") { throw 'Installed studio-saas interface does not identify the reviewed bytes' }
& ssh $OpsHost 'sudo -n studio-saas validate-slug installer-smoke' *> $null
Assert-LastExitCode 'Installed studio-saas command boundary is unavailable'
Write-Output "STUDIO_SAAS_INSTALLED host=$OpsHost sha256=$expectedHash"
