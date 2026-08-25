$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$deployScript = Join-Path $repoRoot '.github/actions/deploy-dokploy/deploy-dokploy.sh'
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
connect_timeout=''
max_time=''
max_redirs=''
follow_redirects=false
output_path=''
write_out=''
headers=()
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
    --header)
      headers+=("$2")
      shift 2
      ;;
    --connect-timeout)
      connect_timeout="$2"
      shift 2
      ;;
    --max-time)
      max_time="$2"
      shift 2
      ;;
    --max-redirs)
      max_redirs="$2"
      shift 2
      ;;
    --location)
      follow_redirects=true
      shift
      ;;
    --output)
      output_path="$2"
      shift 2
      ;;
    --write-out)
      write_out="$2"
      shift 2
      ;;
    --retry|--retry-delay)
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
[[ "$connect_timeout" == 5 && "$max_time" == 20 ]] || {
  printf 'fake curl rejected missing request time bounds\n' >&2
  exit 91
}

if [[ "$endpoint" == /application.* || "$endpoint" == /deployment.* ]]; then
  expected_method=POST
  [[ "$endpoint" == /deployment.all?applicationId=* || "$endpoint" == /application.one?applicationId=* ]] && expected_method=GET
  [[ "$method" == "$expected_method" ]] || {
    printf 'fake curl rejected API method\n' >&2
    exit 92
  }
  [[ "$follow_redirects" == false && "$max_redirs" == 0 ]] || {
    printf 'fake curl rejected API redirect settings\n' >&2
    exit 95
  }
  [[ -z "$output_path" && "$write_out" == $'\n%{http_code}' ]] || {
    printf 'fake curl rejected API response capture\n' >&2
    exit 98
  }
  api_key_headers=0
  content_type_headers=0
  for header in "${headers[@]}"; do
    [[ "$header" == "x-api-key: ${DOKPLOY_API_KEY}" ]] && api_key_headers=$((api_key_headers + 1))
    [[ "$header" == 'Content-Type: application/json' ]] && content_type_headers=$((content_type_headers + 1))
  done
  [[ "$api_key_headers" -eq 1 && "$content_type_headers" -eq 1 ]] || {
    printf 'fake curl rejected API headers\n' >&2
    exit 93
  }
else
  [[ "$method" == GET ]] || {
    printf 'fake curl rejected health method\n' >&2
    exit 94
  }
  [[ "$follow_redirects" == false && "$max_redirs" == 0 ]] || {
    printf 'fake curl rejected redirect settings\n' >&2
    exit 95
  }
  [[ -z "$output_path" && "$write_out" == $'\n%{http_code}' ]] || {
    printf 'fake curl rejected health response capture\n' >&2
    exit 97
  }
  for header in "${headers[@]}"; do
    [[ "$header" != x-api-key:* ]] || {
      printf 'fake curl rejected API key on health request\n' >&2
      exit 96
    }
  done
fi

case "$endpoint" in
  /application.one?applicationId=*)
    count_file="$FAKE_CURL_STATE/application-one-count"
    count=0
    [[ -f "$count_file" ]] && count="$(<"$count_file")"
    count=$((count + 1))
    printf '%s' "$count" > "$count_file"
    printf 'application.one\n' >> "$FAKE_CURL_STATE/requests"
    if [[ "$FAKE_CURL_SCENARIO" == preflight-exhausted || ("$FAKE_CURL_SCENARIO" == preflight-transient && "$count" -lt 3) ]]; then
      printf 'APPLICATION_ONE_RESPONSE_SECRET'
      printf 'APPLICATION_ONE_RESPONSE_SECRET' >&2
      exit 22
    fi
    case "$FAKE_CURL_SCENARIO" in
      git-source)
        printf '{"sourceType":"git","dockerImage":"ghcr.io/example/saas@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","username":"APPLICATION_RESPONSE_SECRET"}\n200'
        ;;
      github-source)
        printf '{"sourceType":"github","dockerImage":"ghcr.io/example/saas@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","username":"APPLICATION_RESPONSE_SECRET"}\n200'
        ;;
      missing-image)
        printf '{"sourceType":"docker","username":"APPLICATION_RESPONSE_SECRET"}\n200'
        ;;
      malformed-image)
        printf '{"sourceType":"docker","dockerImage":"bad image with spaces","username":"APPLICATION_RESPONSE_SECRET"}\n200'
        ;;
      wrong-repository)
        printf '{"sourceType":"docker","dockerImage":"ghcr.io/attacker/saas@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","username":"APPLICATION_RESPONSE_SECRET"}\n200'
        ;;
      bootstrap-tag)
        printf '{"sourceType":"docker","dockerImage":"ghcr.io/example/saas:bootstrap","username":"APPLICATION_RESPONSE_SECRET"}\n200'
        ;;
      *)
        printf '{"sourceType":"docker","dockerImage":"ghcr.io/example/saas@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","username":"APPLICATION_RESPONSE_SECRET"}\n200'
        ;;
    esac
    ;;
  /deployment.all?applicationId=*)
    count_file="$FAKE_CURL_STATE/deployment-count"
    count=0
    [[ -f "$count_file" ]] && count="$(<"$count_file")"
    count=$((count + 1))
    printf '%s' "$count" > "$count_file"
    printf 'deployment.all\n' >> "$FAKE_CURL_STATE/requests"
    if [[ "$count" -eq 1 ]]; then
      if [[ "$FAKE_CURL_SCENARIO" == prior-reuse ]]; then
        printf '[{"deploymentId":"previous-deployment","title":"%s","status":"done","log":"API_RESPONSE_SECRET"}]\n200' "$FAKE_EXPECTED_TITLE"
      else
        printf '[{"deploymentId":"previous-deployment","title":"Previous release","status":"done","log":"API_RESPONSE_SECRET"}]\n200'
      fi
    else
      case "$FAKE_CURL_SCENARIO:$count" in
        success:2)
          printf '[{"deploymentId":"previous-deployment","title":"Previous release","status":"done","log":"API_RESPONSE_SECRET"}]\n200'
          ;;
        success:3)
          printf '[{"deploymentId":"new-deployment","title":"%s","status":"running","log":"API_RESPONSE_SECRET"}]\n200' "$FAKE_EXPECTED_TITLE"
          ;;
        unrelated-newer:2)
          printf '[{"deploymentId":"manual-deployment","title":"Manual deployment","status":"done"},{"deploymentId":"new-deployment","title":"%s","status":"running","log":"API_RESPONSE_SECRET"}]\n200' "$FAKE_EXPECTED_TITLE"
          ;;
        unrelated-newer:*)
          printf '[{"deploymentId":"manual-deployment","title":"Manual deployment","status":"done"},{"deploymentId":"new-deployment","title":"%s","status":"done","log":"API_RESPONSE_SECRET"}]\n200' "$FAKE_EXPECTED_TITLE"
          ;;
        new-error:*)
          printf '[{"deploymentId":"failed-deployment","title":"%s","status":"error","log":"API_RESPONSE_SECRET"}]\n200' "$FAKE_EXPECTED_TITLE"
          ;;
        cancelled:*)
          printf '[{"deploymentId":"cancelled-deployment","title":"%s","status":"cancelled","log":"API_RESPONSE_SECRET"}]\n200' "$FAKE_EXPECTED_TITLE"
          ;;
        prior-reuse:*)
          printf '[{"deploymentId":"previous-deployment","title":"%s","status":"done","log":"API_RESPONSE_SECRET"}]\n200' "$FAKE_EXPECTED_TITLE"
          ;;
        timeout:*)
          printf '[{"deploymentId":"running-deployment","title":"%s","status":"running","log":"API_RESPONSE_SECRET"}]\n200' "$FAKE_EXPECTED_TITLE"
          ;;
        *)
          printf '[{"deploymentId":"new-deployment","title":"%s","status":"done","log":"API_RESPONSE_SECRET"}]\n200' "$FAKE_EXPECTED_TITLE"
          ;;
      esac
    fi
    ;;
  /application.update)
    count_file="$FAKE_CURL_STATE/update-count"
    count=0
    [[ -f "$count_file" ]] && count="$(<"$count_file")"
    count=$((count + 1))
    printf '%s' "$count" > "$count_file"
    printf 'application.update %s\n' "$body" >> "$FAKE_CURL_STATE/requests"
    api_status=200
    api_detail=API_RESPONSE_SECRET
    if [[ "$count" -eq 1 ]]; then
      case "$FAKE_CURL_SCENARIO" in
        update-redirect-301)
          api_status=301
          api_detail=UPDATE_REDIRECT_RESPONSE_SECRET
          ;;
        update-server-error-500)
          api_status=500
          api_detail=UPDATE_SERVER_ERROR_RESPONSE_SECRET
          ;;
        update-lost-response)
          printf 'UPDATE_LOST_RESPONSE_SECRET'
          printf 'UPDATE_LOST_RESPONSE_SECRET' >&2
          exit 22
          ;;
      esac
    elif [[ "$FAKE_CURL_SCENARIO" == recovery-failure && "$count" -gt 1 ]]; then
      api_status=500
      api_detail=RECOVERY_RESPONSE_SECRET
    fi
    printf '{"ok":true,"detail":"%s"}\n%s' "$api_detail" "$api_status"
    ;;
  /application.deploy)
    count_file="$FAKE_CURL_STATE/deploy-count"
    count=0
    [[ -f "$count_file" ]] && count="$(<"$count_file")"
    count=$((count + 1))
    printf '%s' "$count" > "$count_file"
    printf 'application.deploy %s\n' "$body" >> "$FAKE_CURL_STATE/requests"
    api_status=200
    api_detail=API_RESPONSE_SECRET
    if [[ "$FAKE_CURL_SCENARIO" == deploy-redirect-302 && "$count" -eq 1 ]]; then
      api_status=302
      api_detail=DEPLOY_REDIRECT_RESPONSE_SECRET
    elif [[ ("$FAKE_CURL_SCENARIO" == deploy-post-failure || "$FAKE_CURL_SCENARIO" == recovery-failure) && "$count" -eq 1 ]]; then
      api_status=500
      api_detail=DEPLOY_FAILURE_RESPONSE_SECRET
    fi
    printf '{"queued":true,"detail":"%s"}\n%s' "$api_detail" "$api_status"
    ;;
  *)
    count_file="$FAKE_CURL_STATE/health-count"
    count=0
    [[ -f "$count_file" ]] && count="$(<"$count_file")"
    count=$((count + 1))
    printf '%s' "$count" > "$count_file"
    printf 'health\n' >> "$FAKE_CURL_STATE/requests"
    if [[ "$FAKE_CURL_SCENARIO" == health-failure || ("$FAKE_CURL_SCENARIO" == health-transient && "$count" -eq 1) || ("$FAKE_CURL_SCENARIO" == healthy-then-unhealthy && "$count" -gt 1) ]]; then
      printf 'HEALTH_RESPONSE_SECRET'
      printf 'HEALTH_RESPONSE_SECRET' >&2
      exit 22
    fi
    case "$FAKE_CURL_SCENARIO" in
      redirect-301)
        printf '{"revision":"%s","detail":"HEALTH_RESPONSE_SECRET"}\n301' "$EXPECTED_REVISION"
        ;;
      redirect-302)
        printf '{"revision":"%s","detail":"HEALTH_RESPONSE_SECRET"}\n302' "$EXPECTED_REVISION"
        ;;
      invalid-health-json)
        printf 'not-json-HEALTH_RESPONSE_SECRET\n200'
        ;;
      old-revision)
        printf '{"revision":"cccccccccccccccccccccccccccccccccccccccc","detail":"HEALTH_RESPONSE_SECRET"}\n200'
        ;;
      old-then-current)
        if [[ "$count" -eq 1 ]]; then
          printf '{"revision":"cccccccccccccccccccccccccccccccccccccccc","detail":"HEALTH_RESPONSE_SECRET"}\n200'
        else
          printf '{"revision":"%s","detail":"HEALTH_RESPONSE_SECRET"}\n200' "$EXPECTED_REVISION"
        fi
        ;;
      *)
        printf '{"revision":"%s","detail":"HEALTH_RESPONSE_SECRET"}\n200' "$EXPECTED_REVISION"
        ;;
    esac
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
    [string]$ReleaseRef = 'ghcr.io/example/saas@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    [string]$HealthUrl = 'https://saas.example.test/health',
    [string]$DokployUrl = 'https://dokploy.internal.example/api',
    [string]$ExpectedRevision = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    [string]$PreflightMaxAttempts = '3',
    [string]$PreflightRetrySeconds = '0',
    [string]$HealthMaxAttempts = '3',
    [string]$HealthRetrySeconds = '0',
    [string]$HealthSuccessChecks = '2'
  )

  Remove-Item -LiteralPath (Join-Path $stateDir 'requests') -Force -ErrorAction SilentlyContinue
  foreach ($counter in @('application-one-count', 'deployment-count', 'health-count', 'update-count', 'deploy-count')) {
    Remove-Item -LiteralPath (Join-Path $stateDir $counter) -Force -ErrorAction SilentlyContinue
  }

  $saved = @{}
  $values = @{
    DOKPLOY_URL = $DokployUrl
    DOKPLOY_API_KEY = 'DOKPLOY_API_KEY_SECRET'
    DOKPLOY_APPLICATION_ID = 'app_123-ABC'
    RELEASE_REF = $ReleaseRef
    HEALTH_URL = $HealthUrl
    GITHUB_REPOSITORY = 'example/saas'
    GITHUB_RUN_ID = '123456'
    GITHUB_RUN_ATTEMPT = '2'
    EXPECTED_REVISION = $ExpectedRevision
    DOKPLOY_PREFLIGHT_MAX_ATTEMPTS = $PreflightMaxAttempts
    DOKPLOY_PREFLIGHT_RETRY_SECONDS = $PreflightRetrySeconds
    DOKPLOY_DEPLOY_MAX_POLLS = '3'
    DOKPLOY_DEPLOY_POLL_SECONDS = '0'
    DOKPLOY_HEALTH_MAX_ATTEMPTS = $HealthMaxAttempts
    DOKPLOY_HEALTH_RETRY_SECONDS = $HealthRetrySeconds
    DOKPLOY_HEALTH_SUCCESS_CHECKS = $HealthSuccessChecks
    FAKE_CURL_SCENARIO = $Scenario
    FAKE_CURL_STATE = $bashStateDir
    FAKE_EXPECTED_TITLE = 'github:example/saas:123456:2:sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    BASH_ENV = $bashBashEnvPath
    WSLENV = 'DOKPLOY_URL:DOKPLOY_API_KEY:DOKPLOY_APPLICATION_ID:RELEASE_REF:HEALTH_URL:GITHUB_REPOSITORY:GITHUB_RUN_ID:GITHUB_RUN_ATTEMPT:EXPECTED_REVISION:DOKPLOY_PREFLIGHT_MAX_ATTEMPTS:DOKPLOY_PREFLIGHT_RETRY_SECONDS:DOKPLOY_DEPLOY_MAX_POLLS:DOKPLOY_DEPLOY_POLL_SECONDS:DOKPLOY_HEALTH_MAX_ATTEMPTS:DOKPLOY_HEALTH_RETRY_SECONDS:DOKPLOY_HEALTH_SUCCESS_CHECKS:FAKE_CURL_SCENARIO:FAKE_CURL_STATE:FAKE_EXPECTED_TITLE:BASH_ENV'
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
  $newUpdate = 'application.update {"applicationId":"app_123-ABC","dockerImage":"ghcr.io/example/saas@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}'
  $restoreUpdate = 'application.update {"applicationId":"app_123-ABC","dockerImage":"ghcr.io/example/saas@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"}'
  $deployRequest = 'application.deploy {"applicationId":"app_123-ABC","title":"github:example/saas:123456:2:sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}'
  $recoveryDeployRequest = 'application.deploy {"applicationId":"app_123-ABC","title":"github-recovery:example/saas:123456:2:sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}'

  $invalid = Invoke-DeployScenario -Scenario success -ReleaseRef 'ghcr.io/example/saas:latest'
  Assert-True ($invalid.ExitCode -ne 0) 'Malformed digest must fail'
  Assert-True ($invalid.Requests.Count -eq 0) 'Malformed digest must fail before any API call'

  $invalidHealthUrl = Invoke-DeployScenario -Scenario success -HealthUrl 'https:///health'
  Assert-True ($invalidHealthUrl.ExitCode -ne 0) 'Health URL without an authority must fail'
  Assert-True ($invalidHealthUrl.Requests.Count -eq 0) 'Malformed health URL must fail before any API call'

  $userinfoUrl = Invoke-DeployScenario -Scenario success -DokployUrl 'https://user:password@dokploy.internal.example/api'
  Assert-True ($userinfoUrl.ExitCode -ne 0) 'Dokploy URL with userinfo must fail'
  Assert-True ($userinfoUrl.Requests.Count -eq 0) 'Dokploy userinfo must fail before any API call'

  $dokployQuery = Invoke-DeployScenario -Scenario success -DokployUrl 'https://dokploy.internal.example/api?tenant=wrong'
  Assert-True ($dokployQuery.ExitCode -ne 0) 'Dokploy URL query must fail'
  Assert-True ($dokployQuery.Requests.Count -eq 0) 'Dokploy URL query must fail before any API call'

  $healthFragment = Invoke-DeployScenario -Scenario success -HealthUrl 'https://saas.example.test/health#ignored'
  Assert-True ($healthFragment.ExitCode -ne 0) 'Health URL fragment must fail'
  Assert-True ($healthFragment.Requests.Count -eq 0) 'Health URL fragment must fail before any API call'

  $missingRevision = Invoke-DeployScenario -Scenario success -ExpectedRevision ''
  Assert-True ($missingRevision.ExitCode -ne 0) 'Missing expected revision must fail'
  Assert-True ($missingRevision.Requests.Count -eq 0) 'Missing expected revision must fail before any API call'

  foreach ($invalidBound in @(
    (Invoke-DeployScenario -Scenario success -PreflightMaxAttempts '0'),
    (Invoke-DeployScenario -Scenario success -PreflightRetrySeconds '-1'),
    (Invoke-DeployScenario -Scenario success -HealthMaxAttempts '0'),
    (Invoke-DeployScenario -Scenario success -HealthRetrySeconds '-1'),
    (Invoke-DeployScenario -Scenario success -HealthSuccessChecks '0'),
    (Invoke-DeployScenario -Scenario success -HealthSuccessChecks '4')
  )) {
    Assert-True ($invalidBound.ExitCode -ne 0) 'Invalid retry/poll bound must fail'
    Assert-True ($invalidBound.Requests.Count -eq 0) 'Invalid retry/poll bound must fail before any request'
  }

  foreach ($invalidApplication in @('git-source', 'github-source', 'missing-image', 'malformed-image')) {
    $preflightReject = Invoke-DeployScenario -Scenario $invalidApplication
    Assert-True ($preflightReject.ExitCode -ne 0) "Invalid Docker application contract '$invalidApplication' must fail"
    Assert-True (($preflightReject.Requests -join ',') -eq 'application.one') "Invalid application '$invalidApplication' must cause zero POSTs"
    Assert-True ($preflightReject.Output -notmatch 'APPLICATION_RESPONSE_SECRET|dddddddd|DOKPLOY_API_KEY_SECRET') "Application preflight '$invalidApplication' leaked its body or API key"
  }

  $wrongRepository = Invoke-DeployScenario -Scenario wrong-repository
  Assert-True ($wrongRepository.ExitCode -ne 0) 'Application bound to another GHCR repository must fail'
  Assert-True (($wrongRepository.Requests -join ',') -eq 'application.one') 'Wrong application repository must cause zero mutations'
  Assert-True ($wrongRepository.Output -notmatch 'attacker|dddddddd|APPLICATION_RESPONSE_SECRET|DOKPLOY_API_KEY_SECRET') 'Wrong repository preflight leaked its body or API key'

  $bootstrapTag = Invoke-DeployScenario -Scenario bootstrap-tag
  Assert-True ($bootstrapTag.ExitCode -eq 0) "Same-repository bootstrap tag must be accepted: $($bootstrapTag.Output)"

  $preflightTransient = Invoke-DeployScenario -Scenario preflight-transient
  Assert-True ($preflightTransient.ExitCode -eq 0) "Transient application preflight did not recover: $($preflightTransient.Output)"
  Assert-True (($preflightTransient.Requests | Select-Object -First 3) -join ',' -eq 'application.one,application.one,application.one') 'Only the initial application.one GET may be retried'
  Assert-True ($preflightTransient.Output -notmatch 'APPLICATION_ONE_RESPONSE_SECRET|DOKPLOY_API_KEY_SECRET') 'Transient preflight leaked its response or API key'

  $preflightExhausted = Invoke-DeployScenario -Scenario preflight-exhausted
  Assert-True ($preflightExhausted.ExitCode -ne 0) 'Exhausted application preflight retries must fail'
  Assert-True (($preflightExhausted.Requests -join ',') -eq 'application.one,application.one,application.one') 'Exhausted application preflight must cause zero mutations'
  Assert-True ($preflightExhausted.Output -notmatch 'APPLICATION_ONE_RESPONSE_SECRET|DOKPLOY_API_KEY_SECRET') 'Exhausted preflight leaked its response or API key'

  $healthQuery = Invoke-DeployScenario -Scenario success -HealthUrl 'https://saas.example.test/health?ready=1'
  Assert-True ($healthQuery.ExitCode -eq 0) 'Health URL query must remain supported'

  $success = Invoke-DeployScenario -Scenario success
  Assert-True ($success.ExitCode -eq 0) "Successful deployment failed: $($success.Output)"
  Assert-True (($success.Requests -join ',') -eq (@('application.one', 'deployment.all', $newUpdate, $deployRequest, 'deployment.all', 'deployment.all', 'deployment.all', 'health', 'health') -join ',')) 'Deployment requests were not issued in preflight/snapshot/update/deploy/poll/health-soak order'
  Assert-True (@($success.Requests | Where-Object { $_ -like 'application.update *' }).Count -eq 1) 'Successful deployment must not restore the prior image'
  Assert-True (($success.Requests -join ',') -notmatch 'username|password|registry|DOKPLOY_API_KEY_SECRET') 'Success request trace leaked credentials'
  Assert-True ($success.Output -eq 'DOKPLOY_DEPLOY_OK application=app_123-ABC image=ghcr.io/example/saas@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa') 'Success output must be exact and minimal'
  Assert-True ($success.Output -notmatch 'DOKPLOY_API_KEY_SECRET|API_RESPONSE_SECRET|APPLICATION_RESPONSE_SECRET|HEALTH_RESPONSE_SECRET') 'Success output leaked a secret or response body'

  $unrelatedNewer = Invoke-DeployScenario -Scenario unrelated-newer
  Assert-True ($unrelatedNewer.ExitCode -eq 0) "Unrelated newer deployment disrupted correlation: $($unrelatedNewer.Output)"
  Assert-True (($unrelatedNewer.Requests -join ',') -eq (@('application.one', 'deployment.all', $newUpdate, $deployRequest, 'deployment.all', 'deployment.all', 'health', 'health') -join ',')) 'An unrelated newer done deployment must not satisfy the correlated poll'

  foreach ($ambiguousUpdateFailure in @(
    @{ Scenario = 'update-redirect-301'; Message = 'application.update'; Secret = 'UPDATE_REDIRECT_RESPONSE_SECRET' },
    @{ Scenario = 'update-server-error-500'; Message = 'application.update'; Secret = 'UPDATE_SERVER_ERROR_RESPONSE_SECRET' },
    @{ Scenario = 'update-lost-response'; Message = 'Dokploy API request failed: /application.update'; Secret = 'UPDATE_LOST_RESPONSE_SECRET' }
  )) {
    $updateFailure = Invoke-DeployScenario -Scenario $ambiguousUpdateFailure.Scenario
    Assert-True ($updateFailure.ExitCode -ne 0) "Ambiguous application update '$($ambiguousUpdateFailure.Scenario)' must fail"
    Assert-True ($updateFailure.Output -match [regex]::Escape($ambiguousUpdateFailure.Message)) "Ambiguous application update '$($ambiguousUpdateFailure.Scenario)' must preserve its original failure"
    Assert-True (($updateFailure.Requests -join ',') -eq (@('application.one', 'deployment.all', $newUpdate, $restoreUpdate, $recoveryDeployRequest) -join ',')) "Ambiguous application update '$($ambiguousUpdateFailure.Scenario)' must restore and redeploy exactly once without poll/health"
    Assert-True ($updateFailure.Output -notmatch "$($ambiguousUpdateFailure.Secret)|DOKPLOY_API_KEY_SECRET") "Ambiguous application update '$($ambiguousUpdateFailure.Scenario)' leaked its body or API key"
  }

  foreach ($deployFailureScenario in @('deploy-redirect-302', 'deploy-post-failure')) {
    $deployFailure = Invoke-DeployScenario -Scenario $deployFailureScenario
    Assert-True ($deployFailure.ExitCode -ne 0) "Deploy failure '$deployFailureScenario' must fail"
    Assert-True (($deployFailure.Requests -join ',') -eq (@('application.one', 'deployment.all', $newUpdate, $deployRequest, $restoreUpdate, $recoveryDeployRequest) -join ',')) "Deploy failure '$deployFailureScenario' must restore and redeploy once without poll/health"
    Assert-True ($deployFailure.Output -notmatch 'DEPLOY_REDIRECT_RESPONSE_SECRET|DEPLOY_FAILURE_RESPONSE_SECRET|DOKPLOY_API_KEY_SECRET') "Deploy failure '$deployFailureScenario' leaked its body or API key"
  }

  foreach ($terminalFailure in @(
    @{ Scenario = 'new-error'; Message = 'failed with status error' },
    @{ Scenario = 'cancelled'; Message = 'failed with status cancelled' },
    @{ Scenario = 'prior-reuse'; Message = 'Timed out' },
    @{ Scenario = 'timeout'; Message = 'Timed out' }
  )) {
    $failed = Invoke-DeployScenario -Scenario $terminalFailure.Scenario
    Assert-True ($failed.ExitCode -ne 0) "Deployment failure '$($terminalFailure.Scenario)' must fail"
    Assert-True ($failed.Output -match [regex]::Escape($terminalFailure.Message)) "Deployment failure '$($terminalFailure.Scenario)' lost its original status"
    Assert-True (($failed.Requests | Select-Object -Last 2) -join ',' -eq (@($restoreUpdate, $recoveryDeployRequest) -join ',')) "Deployment failure '$($terminalFailure.Scenario)' must restore and redeploy the prior image"
    Assert-True (@($failed.Requests | Where-Object { $_ -like 'application.deploy *' }).Count -eq 2) "Deployment failure '$($terminalFailure.Scenario)' must issue only the original and recovery deploy POSTs"
  }

  foreach ($healthFailureScenario in @('health-failure', 'healthy-then-unhealthy', 'redirect-301', 'redirect-302', 'invalid-health-json', 'old-revision')) {
    $healthFailed = Invoke-DeployScenario -Scenario $healthFailureScenario
    Assert-True ($healthFailed.ExitCode -ne 0) "Health convergence '$healthFailureScenario' must exhaust and fail"
    Assert-True ($healthFailed.Output -match 'did not converge') "Health convergence '$healthFailureScenario' must report exhaustion"
    Assert-True (@($healthFailed.Requests | Where-Object { $_ -eq 'health' }).Count -eq 3) "Health convergence '$healthFailureScenario' must use the configured attempt bound"
    Assert-True (($healthFailed.Requests | Select-Object -Last 2) -join ',' -eq (@($restoreUpdate, $recoveryDeployRequest) -join ',')) "Health convergence '$healthFailureScenario' must restore and redeploy the prior image"
    Assert-True ($healthFailed.Output -notmatch 'HEALTH_RESPONSE_SECRET|cccccccc|DOKPLOY_API_KEY_SECRET') "Health convergence '$healthFailureScenario' leaked a body or key"
  }

  foreach ($healthRecoveryScenario in @('old-then-current', 'health-transient')) {
    $healthRecovered = Invoke-DeployScenario -Scenario $healthRecoveryScenario
    Assert-True ($healthRecovered.ExitCode -eq 0) "Health convergence '$healthRecoveryScenario' did not recover"
    Assert-True (@($healthRecovered.Requests | Where-Object { $_ -eq 'health' }).Count -eq 3) "Health convergence '$healthRecoveryScenario' must remain healthy for the configured consecutive checks"
    Assert-True (@($healthRecovered.Requests | Where-Object { $_ -like 'application.update *' }).Count -eq 1) "Health convergence '$healthRecoveryScenario' must not restore after success"
  }

  $recoveryFailure = Invoke-DeployScenario -Scenario recovery-failure
  Assert-True ($recoveryFailure.ExitCode -ne 0) 'Failed recovery must preserve failure'
  Assert-True ($recoveryFailure.Output -match 'application.deploy') 'Failed recovery must retain the original deploy failure'
  Assert-True ($recoveryFailure.Output -match 'Desired-image recovery failed') 'Failed recovery must be explicit'
  Assert-True ($recoveryFailure.Output -notmatch 'RECOVERY_RESPONSE_SECRET|DEPLOY_FAILURE_RESPONSE_SECRET|DOKPLOY_API_KEY_SECRET') 'Failed recovery leaked a response or key'
  Assert-True (($recoveryFailure.Requests -join ',') -eq (@('application.one', 'deployment.all', $newUpdate, $deployRequest, $restoreUpdate) -join ',')) 'Recovery update failure must stop before recovery deploy'

  Write-Output 'DOKPLOY_DEPLOY_TESTS_OK'
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
