$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$deployScript = Join-Path $repoRoot 'scripts/deploy-dokploy.sh'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("dokploy-deploy-tests-{0}" -f [guid]::NewGuid())
$fakeBin = Join-Path $tempRoot 'bin'
$stateDir = Join-Path $tempRoot 'state'
New-Item -ItemType Directory -Path $fakeBin, $stateDir | Out-Null

$fakeCurl = @'
#!/usr/bin/env bash
set -Eeuo pipefail

method=GET
body=''
url=''
while (($#)); do
  case "$1" in
    --request)
      method="$2"
      shift 2
      ;;
    --data|--data-raw)
      body="$2"
      shift 2
      ;;
    --header|--connect-timeout|--max-time|--retry|--retry-delay)
      shift 2
      ;;
    --*)
      shift
      ;;
    *)
      url="$1"
      shift
      ;;
  esac
done

endpoint="${url#${DOKPLOY_URL%/}}"
case "$endpoint" in
  /deployment.all?applicationId=*)
    count_file="$FAKE_CURL_STATE/deployment-count"
    count=0
    [[ -f "$count_file" ]] && count="$(<"$count_file")"
    count=$((count + 1))
    printf '%s' "$count" > "$count_file"
    printf 'deployment.all\n' >> "$FAKE_CURL_STATE/requests"
    case "$FAKE_CURL_SCENARIO:$count" in
      success:1|prior-reuse:1|new-error:1|cancelled:1|timeout:1|health-failure:1)
        printf '[{"deploymentId":"previous-deployment","status":"done","log":"API_RESPONSE_SECRET"}]'
        ;;
      success:2)
        printf '[{"deploymentId":"previous-deployment","status":"done","log":"API_RESPONSE_SECRET"}]'
        ;;
      success:3)
        printf '[{"deploymentId":"new-deployment","status":"running","log":"API_RESPONSE_SECRET"}]'
        ;;
      success:*)
        printf '[{"deploymentId":"new-deployment","status":"done","log":"API_RESPONSE_SECRET"}]'
        ;;
      new-error:*)
        printf '[{"deploymentId":"failed-deployment","status":"error","log":"API_RESPONSE_SECRET"}]'
        ;;
      cancelled:*)
        printf '[{"deploymentId":"cancelled-deployment","status":"cancelled","log":"API_RESPONSE_SECRET"}]'
        ;;
      health-failure:*)
        printf '[{"deploymentId":"new-deployment","status":"done","log":"API_RESPONSE_SECRET"}]'
        ;;
      prior-reuse:*)
        printf '[{"deploymentId":"previous-deployment","status":"done","log":"API_RESPONSE_SECRET"}]'
        ;;
      timeout:*)
        printf '[{"deploymentId":"running-deployment","status":"running","log":"API_RESPONSE_SECRET"}]'
        ;;
      *)
        printf 'unexpected fixture' >&2
        exit 90
        ;;
    esac
    ;;
  /application.update)
    printf 'application.update %s\n' "$body" >> "$FAKE_CURL_STATE/requests"
    printf '{"ok":true,"detail":"API_RESPONSE_SECRET"}'
    ;;
  /application.deploy)
    printf 'application.deploy %s\n' "$body" >> "$FAKE_CURL_STATE/requests"
    printf '{"queued":true,"detail":"API_RESPONSE_SECRET"}'
    ;;
  *)
    printf 'health\n' >> "$FAKE_CURL_STATE/requests"
    if [[ "$FAKE_CURL_SCENARIO" == health-failure ]]; then
      printf 'HEALTH_RESPONSE_SECRET'
      printf 'HEALTH_RESPONSE_SECRET' >&2
      exit 22
    fi
    printf 'healthy but private response'
    ;;
esac
'@
[System.IO.File]::WriteAllText(
  (Join-Path $fakeBin 'curl'),
  $fakeCurl.Replace("`r`n", "`n"),
  [System.Text.UTF8Encoding]::new($false)
)

function ConvertTo-BashPath {
  param([Parameter(Mandatory)][string]$Path)
  if ($Path -notmatch '^([A-Za-z]):\\(.*)$') { return $Path.Replace('\', '/') }
  return '/mnt/{0}/{1}' -f $Matches[1].ToLowerInvariant(), $Matches[2].Replace('\', '/')
}

$bashFakeCurl = ConvertTo-BashPath (Join-Path $fakeBin 'curl')
$bashFakeBin = ConvertTo-BashPath $fakeBin
$bashStateDir = ConvertTo-BashPath $stateDir
$bashDeployScript = ConvertTo-BashPath $deployScript
$bashEnvPath = Join-Path $tempRoot 'bash-env'
$bashBashEnvPath = ConvertTo-BashPath $bashEnvPath
[System.IO.File]::WriteAllText(
  $bashEnvPath,
  "export PATH='$bashFakeBin':`"`$PATH`"`n",
  [System.Text.UTF8Encoding]::new($false)
)
& bash -lc "chmod +x '$bashFakeCurl'"
if ($LASTEXITCODE -ne 0) { throw 'Unable to make fake curl executable' }

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
}

function Invoke-DeployScenario {
  param(
    [Parameter(Mandatory)][string]$Scenario,
    [string]$ReleaseRef = 'ghcr.io/example/saas@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  )

  Remove-Item -LiteralPath (Join-Path $stateDir 'requests') -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath (Join-Path $stateDir 'deployment-count') -Force -ErrorAction SilentlyContinue

  $saved = @{}
  $values = @{
    DOKPLOY_URL = 'https://dokploy.internal.example/api'
    DOKPLOY_API_KEY = 'DOKPLOY_API_KEY_SECRET'
    DOKPLOY_APPLICATION_ID = 'app_123-ABC'
    RELEASE_REF = $ReleaseRef
    HEALTH_URL = 'https://saas.example.test/health'
    DOKPLOY_DEPLOY_MAX_POLLS = '3'
    DOKPLOY_DEPLOY_POLL_SECONDS = '0'
    FAKE_CURL_SCENARIO = $Scenario
    FAKE_CURL_STATE = $bashStateDir
    BASH_ENV = $bashBashEnvPath
    WSLENV = 'DOKPLOY_URL:DOKPLOY_API_KEY:DOKPLOY_APPLICATION_ID:RELEASE_REF:HEALTH_URL:DOKPLOY_DEPLOY_MAX_POLLS:DOKPLOY_DEPLOY_POLL_SECONDS:FAKE_CURL_SCENARIO:FAKE_CURL_STATE:BASH_ENV'
  }
  foreach ($name in $values.Keys) {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    [Environment]::SetEnvironmentVariable($name, $values[$name], 'Process')
  }

  try {
    $lines = @(& bash $bashDeployScript 2>&1)
    $exitCode = $LASTEXITCODE
  } finally {
    foreach ($name in $values.Keys) {
      [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process')
    }
  }

  $requestsPath = Join-Path $stateDir 'requests'
  [pscustomobject]@{
    ExitCode = $exitCode
    Output = ($lines -join "`n")
    Requests = if (Test-Path -LiteralPath $requestsPath) {
      @(Get-Content -LiteralPath $requestsPath)
    } else {
      @()
    }
  }
}

try {
  $invalid = Invoke-DeployScenario -Scenario success -ReleaseRef 'ghcr.io/example/saas:latest'
  Assert-True ($invalid.ExitCode -ne 0) 'Malformed digest must fail'
  Assert-True ($invalid.Requests.Count -eq 0) 'Malformed digest must fail before any API call'

  $success = Invoke-DeployScenario -Scenario success
  Assert-True ($success.ExitCode -eq 0) "Successful deployment failed: $($success.Output)"
  Assert-True (($success.Requests -join ',') -eq 'deployment.all,application.update {"applicationId":"app_123-ABC","dockerImage":"ghcr.io/example/saas@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},application.deploy {"applicationId":"app_123-ABC"},deployment.all,deployment.all,deployment.all,health') 'Deployment requests were not issued in snapshot/update/deploy/poll/health order'
  Assert-True ($success.Requests[1] -notmatch 'username|password|registry') 'Application update must not resend registry credentials'
  Assert-True ($success.Output -eq 'DOKPLOY_DEPLOY_OK application=app_123-ABC image=ghcr.io/example/saas@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa') 'Success output must be exact and minimal'
  Assert-True ($success.Output -notmatch 'DOKPLOY_API_KEY_SECRET|API_RESPONSE_SECRET|private response') 'Success output leaked a secret or response body'

  $priorReuse = Invoke-DeployScenario -Scenario prior-reuse
  Assert-True ($priorReuse.ExitCode -ne 0) 'Prior deployment record must not be accepted as the queued deployment'
  Assert-True ($priorReuse.Output -match 'Timed out') 'Prior deployment reuse must end in an explicit timeout'
  Assert-True ($priorReuse.Requests[-1] -ne 'health') 'Health must not run when no new deployment record appears'

  $newError = Invoke-DeployScenario -Scenario new-error
  Assert-True ($newError.ExitCode -ne 0) 'A new errored deployment must fail'
  Assert-True ($newError.Output -match 'failed with status error') 'Errored deployment must report only its status'
  Assert-True ($newError.Output -notmatch 'API_RESPONSE_SECRET|DOKPLOY_API_KEY_SECRET') 'Errored deployment leaked a secret or API response'
  Assert-True ($newError.Requests[-1] -ne 'health') 'Health must not run after a deployment error'

  $cancelled = Invoke-DeployScenario -Scenario cancelled
  Assert-True ($cancelled.ExitCode -ne 0) 'A new cancelled deployment must fail'
  Assert-True ($cancelled.Output -match 'failed with status cancelled') 'Cancelled deployment must report only its status'
  Assert-True ($cancelled.Output -notmatch 'API_RESPONSE_SECRET|DOKPLOY_API_KEY_SECRET') 'Cancelled deployment leaked a secret or API response'
  Assert-True ($cancelled.Requests[-1] -ne 'health') 'Health must not run after a cancelled deployment'

  $timeout = Invoke-DeployScenario -Scenario timeout
  Assert-True ($timeout.ExitCode -ne 0) 'Deployment polling timeout must fail'
  Assert-True ($timeout.Output -match 'Timed out') 'Deployment timeout must be explicit'
  Assert-True ($timeout.Output -notmatch 'API_RESPONSE_SECRET|DOKPLOY_API_KEY_SECRET') 'Timeout output leaked a secret or API response'

  $healthFailure = Invoke-DeployScenario -Scenario health-failure
  Assert-True ($healthFailure.ExitCode -ne 0) 'External health failure must fail the deployment boundary'
  Assert-True ($healthFailure.Output -match 'External health check failed') 'Health failure must be explicit'
  Assert-True ($healthFailure.Output -notmatch 'HEALTH_RESPONSE_SECRET|API_RESPONSE_SECRET|DOKPLOY_API_KEY_SECRET') 'Health failure leaked a secret or response body'

  Write-Output 'DOKPLOY_DEPLOY_TESTS_OK'
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
