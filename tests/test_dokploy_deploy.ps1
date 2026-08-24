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
  [[ "$endpoint" == /deployment.all?applicationId=* ]] && expected_method=GET
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
  /deployment.all?applicationId=*)
    count_file="$FAKE_CURL_STATE/deployment-count"
    count=0
    [[ -f "$count_file" ]] && count="$(<"$count_file")"
    count=$((count + 1))
    printf '%s' "$count" > "$count_file"
    printf 'deployment.all\n' >> "$FAKE_CURL_STATE/requests"
    case "$FAKE_CURL_SCENARIO:$count" in
      success:1|unrelated-newer:1|new-error:1|cancelled:1|timeout:1|health-failure:1|redirect-301:1|redirect-302:1|old-revision:1|update-redirect-301:1|deploy-redirect-302:1)
        printf '[{"deploymentId":"previous-deployment","title":"Previous release","status":"done","log":"API_RESPONSE_SECRET"}]'
        ;;
      prior-reuse:1)
        printf '[{"deploymentId":"previous-deployment","title":"%s","status":"done","log":"API_RESPONSE_SECRET"}]' "$FAKE_EXPECTED_TITLE"
        ;;
      success:2)
        printf '[{"deploymentId":"previous-deployment","title":"Previous release","status":"done","log":"API_RESPONSE_SECRET"}]'
        ;;
      success:3)
        printf '[{"deploymentId":"new-deployment","title":"%s","status":"running","log":"API_RESPONSE_SECRET"}]' "$FAKE_EXPECTED_TITLE"
        ;;
      success:*)
        printf '[{"deploymentId":"new-deployment","title":"%s","status":"done","log":"API_RESPONSE_SECRET"}]' "$FAKE_EXPECTED_TITLE"
        ;;
      unrelated-newer:2)
        printf '[{"deploymentId":"manual-deployment","title":"Manual deployment","status":"done"},{"deploymentId":"new-deployment","title":"%s","status":"running","log":"API_RESPONSE_SECRET"}]' "$FAKE_EXPECTED_TITLE"
        ;;
      unrelated-newer:*)
        printf '[{"deploymentId":"manual-deployment","title":"Manual deployment","status":"done"},{"deploymentId":"new-deployment","title":"%s","status":"done","log":"API_RESPONSE_SECRET"}]' "$FAKE_EXPECTED_TITLE"
        ;;
      new-error:*)
        printf '[{"deploymentId":"failed-deployment","title":"%s","status":"error","log":"API_RESPONSE_SECRET"}]' "$FAKE_EXPECTED_TITLE"
        ;;
      cancelled:*)
        printf '[{"deploymentId":"cancelled-deployment","title":"%s","status":"cancelled","log":"API_RESPONSE_SECRET"}]' "$FAKE_EXPECTED_TITLE"
        ;;
      health-failure:*)
        printf '[{"deploymentId":"new-deployment","title":"%s","status":"done","log":"API_RESPONSE_SECRET"}]' "$FAKE_EXPECTED_TITLE"
        ;;
      redirect-301:*|redirect-302:*|old-revision:*|update-redirect-301:*|deploy-redirect-302:*)
        printf '[{"deploymentId":"new-deployment","title":"%s","status":"done","log":"API_RESPONSE_SECRET"}]' "$FAKE_EXPECTED_TITLE"
        ;;
      prior-reuse:*)
        printf '[{"deploymentId":"previous-deployment","title":"%s","status":"done","log":"API_RESPONSE_SECRET"}]' "$FAKE_EXPECTED_TITLE"
        ;;
      timeout:*)
        printf '[{"deploymentId":"running-deployment","title":"%s","status":"running","log":"API_RESPONSE_SECRET"}]' "$FAKE_EXPECTED_TITLE"
        ;;
      *)
        printf 'unexpected fixture' >&2
        exit 90
        ;;
    esac
    if [[ -n "$write_out" ]]; then
      [[ "$write_out" == $'\n%{http_code}' ]] || {
        printf 'fake curl rejected API response capture\n' >&2
        exit 98
      }
      printf '\n200'
    fi
    ;;
  /application.update)
    printf 'application.update %s\n' "$body" >> "$FAKE_CURL_STATE/requests"
    api_status=200
    api_detail=API_RESPONSE_SECRET
    if [[ "$FAKE_CURL_SCENARIO" == update-redirect-301 ]]; then
      api_status=301
      api_detail=UPDATE_REDIRECT_RESPONSE_SECRET
    fi
    printf '{"ok":true,"detail":"%s"}' "$api_detail"
    if [[ -n "$write_out" ]]; then
      [[ "$write_out" == $'\n%{http_code}' ]] || {
        printf 'fake curl rejected API response capture\n' >&2
        exit 98
      }
      printf '\n%s' "$api_status"
    fi
    ;;
  /application.deploy)
    printf 'application.deploy %s\n' "$body" >> "$FAKE_CURL_STATE/requests"
    api_status=200
    api_detail=API_RESPONSE_SECRET
    if [[ "$FAKE_CURL_SCENARIO" == deploy-redirect-302 ]]; then
      api_status=302
      api_detail=DEPLOY_REDIRECT_RESPONSE_SECRET
    fi
    printf '{"queued":true,"detail":"%s"}' "$api_detail"
    if [[ -n "$write_out" ]]; then
      [[ "$write_out" == $'\n%{http_code}' ]] || {
        printf 'fake curl rejected API response capture\n' >&2
        exit 98
      }
      printf '\n%s' "$api_status"
    fi
    ;;
  *)
    printf 'health\n' >> "$FAKE_CURL_STATE/requests"
    if [[ "$FAKE_CURL_SCENARIO" == health-failure ]]; then
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
      old-revision)
        printf '{"revision":"cccccccccccccccccccccccccccccccccccccccc","detail":"HEALTH_RESPONSE_SECRET"}\n200'
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
    [string]$ExpectedRevision = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
  )

  Remove-Item -LiteralPath (Join-Path $stateDir 'requests') -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath (Join-Path $stateDir 'deployment-count') -Force -ErrorAction SilentlyContinue

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
    DOKPLOY_DEPLOY_MAX_POLLS = '3'
    DOKPLOY_DEPLOY_POLL_SECONDS = '0'
    FAKE_CURL_SCENARIO = $Scenario
    FAKE_CURL_STATE = $bashStateDir
    FAKE_EXPECTED_TITLE = 'github:example/saas:123456:2:sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    BASH_ENV = $bashBashEnvPath
    WSLENV = 'DOKPLOY_URL:DOKPLOY_API_KEY:DOKPLOY_APPLICATION_ID:RELEASE_REF:HEALTH_URL:GITHUB_REPOSITORY:GITHUB_RUN_ID:GITHUB_RUN_ATTEMPT:EXPECTED_REVISION:DOKPLOY_DEPLOY_MAX_POLLS:DOKPLOY_DEPLOY_POLL_SECONDS:FAKE_CURL_SCENARIO:FAKE_CURL_STATE:FAKE_EXPECTED_TITLE:BASH_ENV'
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

  $healthQuery = Invoke-DeployScenario -Scenario success -HealthUrl 'https://saas.example.test/health?ready=1'
  Assert-True ($healthQuery.ExitCode -eq 0) 'Health URL query must remain supported'

  $missingRevision = Invoke-DeployScenario -Scenario success -ExpectedRevision ''
  Assert-True ($missingRevision.ExitCode -ne 0) 'Missing expected revision must fail'
  Assert-True ($missingRevision.Requests.Count -eq 0) 'Missing expected revision must fail before any API call'

  $success = Invoke-DeployScenario -Scenario success
  Assert-True ($success.ExitCode -eq 0) "Successful deployment failed: $($success.Output)"
  Assert-True (($success.Requests -join ',') -eq 'deployment.all,application.update {"applicationId":"app_123-ABC","dockerImage":"ghcr.io/example/saas@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},application.deploy {"applicationId":"app_123-ABC","title":"github:example/saas:123456:2:sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},deployment.all,deployment.all,deployment.all,health') 'Deployment requests were not issued in snapshot/update/deploy/poll/health order'
  Assert-True ($success.Requests[1] -notmatch 'username|password|registry') 'Application update must not resend registry credentials'
  Assert-True (($success.Requests -join ',') -notmatch 'DOKPLOY_API_KEY_SECRET') 'Fake curl request log must not contain the API key'
  Assert-True ($success.Output -eq 'DOKPLOY_DEPLOY_OK application=app_123-ABC image=ghcr.io/example/saas@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa') 'Success output must be exact and minimal'
  Assert-True ($success.Output -notmatch 'DOKPLOY_API_KEY_SECRET|API_RESPONSE_SECRET|HEALTH_RESPONSE_SECRET|private response') 'Success output leaked a secret or response body'

  $unrelatedNewer = Invoke-DeployScenario -Scenario unrelated-newer
  Assert-True ($unrelatedNewer.ExitCode -eq 0) "Unrelated newer deployment disrupted correlation: $($unrelatedNewer.Output)"
  Assert-True (($unrelatedNewer.Requests -join ',') -eq 'deployment.all,application.update {"applicationId":"app_123-ABC","dockerImage":"ghcr.io/example/saas@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},application.deploy {"applicationId":"app_123-ABC","title":"github:example/saas:123456:2:sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},deployment.all,deployment.all,health') 'An unrelated newer done deployment must not satisfy the correlated poll'

  $updateRedirect = Invoke-DeployScenario -Scenario update-redirect-301
  Assert-True ($updateRedirect.ExitCode -ne 0) 'Application update HTTP 301 must fail'
  Assert-True (($updateRedirect.Requests -join ',') -eq 'deployment.all,application.update {"applicationId":"app_123-ABC","dockerImage":"ghcr.io/example/saas@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}') 'Application update redirect must stop before deploy, poll, or health'
  Assert-True ($updateRedirect.Output -match 'exact HTTP 200') 'Application update redirect must report an exact-200 failure'
  Assert-True ($updateRedirect.Output -notmatch 'UPDATE_REDIRECT_RESPONSE_SECRET|DOKPLOY_API_KEY_SECRET') 'Application update redirect leaked its body or API key'

  $deployRedirect = Invoke-DeployScenario -Scenario deploy-redirect-302
  Assert-True ($deployRedirect.ExitCode -ne 0) 'Application deploy HTTP 302 must fail'
  Assert-True (($deployRedirect.Requests -join ',') -eq 'deployment.all,application.update {"applicationId":"app_123-ABC","dockerImage":"ghcr.io/example/saas@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},application.deploy {"applicationId":"app_123-ABC","title":"github:example/saas:123456:2:sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}') 'Application deploy redirect must stop before poll or health'
  Assert-True ($deployRedirect.Output -match 'exact HTTP 200') 'Application deploy redirect must report an exact-200 failure'
  Assert-True ($deployRedirect.Output -notmatch 'DEPLOY_REDIRECT_RESPONSE_SECRET|DOKPLOY_API_KEY_SECRET') 'Application deploy redirect leaked its body or API key'

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

  foreach ($redirectStatus in @(301, 302)) {
    $redirect = Invoke-DeployScenario -Scenario "redirect-$redirectStatus"
    Assert-True ($redirect.ExitCode -ne 0) "Health redirect $redirectStatus must fail"
    Assert-True ($redirect.Output -match 'exact HTTP 200') "Health redirect $redirectStatus must report an exact-200 failure"
    Assert-True ($redirect.Output -notmatch 'HEALTH_RESPONSE_SECRET|API_RESPONSE_SECRET|DOKPLOY_API_KEY_SECRET') "Health redirect $redirectStatus leaked a secret or response body"
  }

  $oldRevision = Invoke-DeployScenario -Scenario old-revision
  Assert-True ($oldRevision.ExitCode -ne 0) 'A healthy rollback revision must fail'
  Assert-True ($oldRevision.Output -match 'revision mismatch') 'Rollback false-success must report a revision mismatch'
  Assert-True ($oldRevision.Output -notmatch 'HEALTH_RESPONSE_SECRET|cccccccc|DOKPLOY_API_KEY_SECRET') 'Revision mismatch leaked the health body or a secret'

  Write-Output 'DOKPLOY_DEPLOY_TESTS_OK'
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
