#!/usr/bin/env bash
set -Eeuo pipefail

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

for required_name in \
  DOKPLOY_URL \
  DOKPLOY_API_KEY \
  DOKPLOY_APPLICATION_ID \
  RELEASE_REF \
  HEALTH_URL \
  GITHUB_REPOSITORY \
  GITHUB_RUN_ID \
  GITHUB_RUN_ATTEMPT \
  EXPECTED_REVISION; do
  [[ -n "${!required_name:-}" ]] || fail "Missing required environment variable: ${required_name}"
done

validate_https_url() {
  local value="$1"
  local policy="$2"
  python3 -c '
import ipaddress
import re
import sys
from urllib.parse import urlsplit

value, policy = sys.argv[1:]
if any(ord(character) < 33 or character.isspace() for character in value):
    raise ValueError("URL contains whitespace or control characters")
parts = urlsplit(value)
if parts.scheme != "https" or not parts.netloc or not parts.hostname:
    raise ValueError("URL must have an HTTPS authority")
if parts.username is not None or parts.password is not None or "@" in parts.netloc:
    raise ValueError("URL must not contain userinfo")
try:
    port = parts.port
except ValueError as error:
    raise ValueError("URL port is invalid") from error
if port is not None and not 1 <= port <= 65535:
    raise ValueError("URL port is invalid")
host = parts.hostname
try:
    ipaddress.ip_address(host)
except ValueError:
    if len(host) > 253 or any(
        not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", label)
        for label in host.rstrip(".").split(".")
    ):
        raise ValueError("URL hostname is invalid")
if parts.fragment:
    raise ValueError("URL fragment is not allowed")
if policy == "dokploy" and parts.query:
    raise ValueError("Dokploy URL query is not allowed")
' "$value" "$policy" >/dev/null 2>&1
}

validate_https_url "$DOKPLOY_URL" dokploy || fail 'DOKPLOY_URL must have a valid HTTPS authority without userinfo, query, or fragment'
validate_https_url "$HEALTH_URL" health || fail 'HEALTH_URL must have a valid HTTPS authority without userinfo or fragment'
[[ "$DOKPLOY_APPLICATION_ID" =~ ^[A-Za-z0-9_-]+$ ]] || fail 'DOKPLOY_APPLICATION_ID contains unsupported characters'
[[ "$RELEASE_REF" =~ ^[a-z0-9][a-z0-9._:-]*(/[a-z0-9._-]+)+@sha256:[a-f0-9]{64}$ ]] || fail 'RELEASE_REF must be an immutable image digest'
[[ "$GITHUB_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail 'GITHUB_REPOSITORY is invalid'
[[ "$GITHUB_RUN_ID" =~ ^[1-9][0-9]*$ ]] || fail 'GITHUB_RUN_ID must be a positive integer'
[[ "$GITHUB_RUN_ATTEMPT" =~ ^[1-9][0-9]*$ ]] || fail 'GITHUB_RUN_ATTEMPT must be a positive integer'
[[ "$EXPECTED_REVISION" =~ ^[a-f0-9]{40}$ ]] || fail 'EXPECTED_REVISION must be a full lowercase Git commit SHA'

preflight_max_attempts="${DOKPLOY_PREFLIGHT_MAX_ATTEMPTS:-5}"
preflight_retry_seconds="${DOKPLOY_PREFLIGHT_RETRY_SECONDS:-2}"
max_polls="${DOKPLOY_DEPLOY_MAX_POLLS:-120}"
poll_seconds="${DOKPLOY_DEPLOY_POLL_SECONDS:-5}"
health_max_attempts="${DOKPLOY_HEALTH_MAX_ATTEMPTS:-12}"
health_retry_seconds="${DOKPLOY_HEALTH_RETRY_SECONDS:-5}"
health_success_checks="${DOKPLOY_HEALTH_SUCCESS_CHECKS:-7}"
[[ "$preflight_max_attempts" =~ ^[1-9][0-9]*$ ]] || fail 'DOKPLOY_PREFLIGHT_MAX_ATTEMPTS must be a positive integer'
[[ "$preflight_retry_seconds" =~ ^[0-9]+$ ]] || fail 'DOKPLOY_PREFLIGHT_RETRY_SECONDS must be a non-negative integer'
[[ "$max_polls" =~ ^[1-9][0-9]*$ ]] || fail 'DOKPLOY_DEPLOY_MAX_POLLS must be a positive integer'
[[ "$poll_seconds" =~ ^[0-9]+$ ]] || fail 'DOKPLOY_DEPLOY_POLL_SECONDS must be a non-negative integer'
[[ "$health_max_attempts" =~ ^[1-9][0-9]*$ ]] || fail 'DOKPLOY_HEALTH_MAX_ATTEMPTS must be a positive integer'
[[ "$health_retry_seconds" =~ ^[0-9]+$ ]] || fail 'DOKPLOY_HEALTH_RETRY_SECONDS must be a non-negative integer'
[[ "$health_success_checks" =~ ^[1-9][0-9]*$ ]] || fail 'DOKPLOY_HEALTH_SUCCESS_CHECKS must be a positive integer'
((health_success_checks <= health_max_attempts)) || fail 'DOKPLOY_HEALTH_SUCCESS_CHECKS must not exceed DOKPLOY_HEALTH_MAX_ATTEMPTS'

dokploy_url="${DOKPLOY_URL%/}"
release_digest="${RELEASE_REF##*@}"
deployment_title="github:${GITHUB_REPOSITORY}:${GITHUB_RUN_ID}:${GITHUB_RUN_ATTEMPT}:${release_digest}"
recovery_deployment_title="github-recovery:${GITHUB_REPOSITORY}:${GITHUB_RUN_ID}:${GITHUB_RUN_ATTEMPT}:${release_digest}"
api_request() {
  local method="$1"
  local endpoint="$2"
  local body="${3:-}"
  local exchange
  local response
  local status
  local -a args=(
    --silent
    --show-error
    --request "$method"
    --connect-timeout 5
    --max-time 20
    --max-redirs 0
    --write-out $'\n%{http_code}'
    --header "x-api-key: ${DOKPLOY_API_KEY}"
    --header 'Content-Type: application/json'
  )
  if [[ -n "$body" ]]; then
    args+=(--data "$body")
  fi
  if ! exchange="$(curl "${args[@]}" "${dokploy_url}${endpoint}" 2>/dev/null)"; then
    printf 'Dokploy API request failed: %s\n' "$endpoint" >&2
    return 1
  fi
  status="${exchange##*$'\n'}"
  response="${exchange%$'\n'*}"
  if [[ "$status" != 200 ]]; then
    printf 'Dokploy API request did not return exact HTTP 200: %s\n' "$endpoint" >&2
    return 1
  fi
  printf '%s' "$response"
}

parse_application_contract() {
  local application="$1"
  local expected_repository="ghcr.io/${GITHUB_REPOSITORY,,}"
  local prior_image
  if ! prior_image="$(python3 -c '
import json
import re
import sys

expected_repository = sys.argv[1]
value = json.load(sys.stdin)
if not isinstance(value, dict) or value.get("sourceType") != "docker":
    raise ValueError("application is not Docker-backed")
image = value.get("dockerImage")
pattern = re.compile(
    r"^[a-z0-9]+(?:[._-][a-z0-9]+)*(?::[0-9]+)?"
    r"(?:/[a-z0-9]+(?:[._-][a-z0-9]+)*)+"
    r"(?::[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}|@sha256:[a-f0-9]{64})?$"
)
if not isinstance(image, str) or not pattern.fullmatch(image):
    raise ValueError("application Docker image is missing or unsafe")
if "@sha256:" in image:
    repository = image.rsplit("@sha256:", 1)[0]
else:
    repository = image.rsplit(":", 1)[0] if ":" in image.rsplit("/", 1)[-1] else image
if repository != expected_repository:
    raise ValueError("application Docker image belongs to another repository")
print(image)
' "$expected_repository" <<< "$application" 2>/dev/null)"; then
    fail 'Dokploy application must use Docker source with a safe existing image'
  fi
  printf '%s' "$prior_image"
}

application_update_body() {
  local image="$1"
  python3 -c '
import json
import sys

print(json.dumps(
    {"applicationId": sys.argv[1], "dockerImage": sys.argv[2]},
    separators=(",", ":"),
))
' "$DOKPLOY_APPLICATION_ID" "$image"
}

recovery_armed=false
recovery_running=false
restore_update_body=''
recover_desired_image() {
  local original_status=$?
  local recovery_deploy_body
  trap - EXIT
  if [[ "$original_status" -eq 0 || "$recovery_armed" != true || "$recovery_running" == true ]]; then
    exit "$original_status"
  fi

  recovery_running=true
  recovery_armed=false
  if ! api_request POST '/application.update' "$restore_update_body" >/dev/null; then
    printf 'Desired-image recovery failed\n' >&2
  else
    recovery_deploy_body="{\"applicationId\":\"${DOKPLOY_APPLICATION_ID}\",\"title\":\"${recovery_deployment_title}\"}"
    if ! api_request POST '/application.deploy' "$recovery_deploy_body" >/dev/null; then
      printf 'Desired-image recovery failed\n' >&2
    fi
  fi
  exit "$original_status"
}

newest_deployment() {
  local deployments="$1"
  local parsed
  if ! parsed="$(python3 -c '
import json
import sys

value = json.load(sys.stdin)
if not isinstance(value, list):
    raise ValueError("deployment response is not a list")
if not value:
    print("__NONE__")
else:
    newest = value[0]
    deployment_id = newest.get("deploymentId")
    status = newest.get("status")
    if not isinstance(deployment_id, str) or not deployment_id or not isinstance(status, str) or not status:
        raise ValueError("newest deployment is malformed")
    print(f"{deployment_id}\t{status}")
' <<< "$deployments" 2>/dev/null)"; then
    fail 'Dokploy returned an invalid deployment response'
  fi
  printf '%s' "$parsed"
}

correlated_deployment() {
  local deployments="$1"
  local expected_title="$2"
  local previous_id="$3"
  local parsed
  if ! parsed="$(python3 -c '
import json
import sys

expected_title, previous_id = sys.argv[1:]
value = json.load(sys.stdin)
if not isinstance(value, list):
    raise ValueError("deployment response is not a list")
for deployment in value:
    if not isinstance(deployment, dict):
        raise ValueError("deployment record is malformed")
    if deployment.get("title") != expected_title:
        continue
    deployment_id = deployment.get("deploymentId")
    status = deployment.get("status")
    if not isinstance(deployment_id, str) or not deployment_id or not isinstance(status, str) or not status:
        raise ValueError("correlated deployment is malformed")
    if deployment_id != previous_id:
        print(f"{deployment_id}\t{status}")
        break
else:
    print("__NONE__")
' "$expected_title" "$previous_id" <<< "$deployments" 2>/dev/null)"; then
    fail 'Dokploy returned an invalid deployment response'
  fi
  printf '%s' "$parsed"
}

health_matches_expected_revision() {
  local actual_revision
  local health_body
  local health_exchange
  local health_status
  if ! health_exchange="$(curl \
    --silent \
    --show-error \
    --request GET \
    --connect-timeout 5 \
    --max-time 20 \
    --max-redirs 0 \
    --write-out $'\n%{http_code}' \
    "$HEALTH_URL" 2>/dev/null)"; then
    return 1
  fi

  health_status="${health_exchange##*$'\n'}"
  health_body="${health_exchange%$'\n'*}"
  [[ "$health_status" == 200 ]] || return 1
  if ! actual_revision="$(python3 -c '
import json
import sys

value = json.load(sys.stdin)
if not isinstance(value, dict) or not isinstance(value.get("revision"), str):
    raise ValueError("health response has no revision")
print(value["revision"])
' <<< "$health_body" 2>/dev/null)"; then
    return 1
  fi
  [[ "$actual_revision" == "$EXPECTED_REVISION" ]]
}

application_response=''
preflight_ok=false
for ((attempt = 1; attempt <= preflight_max_attempts; attempt++)); do
  if application_response="$(api_request GET "/application.one?applicationId=${DOKPLOY_APPLICATION_ID}")"; then
    preflight_ok=true
    break
  fi
  if ((attempt < preflight_max_attempts)); then
    sleep "$preflight_retry_seconds"
  fi
done
[[ "$preflight_ok" == true ]] || fail 'Dokploy application preflight retries exhausted'

prior_image="$(parse_application_contract "$application_response")"
desired_update_body="$(application_update_body "$RELEASE_REF")"
restore_update_body="$(application_update_body "$prior_image")"

deployments="$(api_request GET "/deployment.all?applicationId=${DOKPLOY_APPLICATION_ID}")" || exit 1
previous="$(newest_deployment "$deployments")"
previous_id=''
if [[ "$previous" != '__NONE__' ]]; then
  IFS=$'\t' read -r previous_id _ <<< "$previous"
fi

trap recover_desired_image EXIT
recovery_armed=true
api_request POST '/application.update' "$desired_update_body" >/dev/null || exit 1

deploy_body="{\"applicationId\":\"${DOKPLOY_APPLICATION_ID}\",\"title\":\"${deployment_title}\"}"
api_request POST '/application.deploy' "$deploy_body" >/dev/null || exit 1

deployment_done=false
for ((poll = 1; poll <= max_polls; poll++)); do
  deployments="$(api_request GET "/deployment.all?applicationId=${DOKPLOY_APPLICATION_ID}")" || exit 1
  correlated="$(correlated_deployment "$deployments" "$deployment_title" "$previous_id")"
  if [[ "$correlated" != '__NONE__' ]]; then
    IFS=$'\t' read -r correlated_id correlated_status <<< "$correlated"
    case "$correlated_status" in
      done)
        deployment_done=true
        break
        ;;
      error|cancelled)
        fail "Dokploy deployment failed with status ${correlated_status}"
        ;;
    esac
  fi
  if ((poll < max_polls)); then
    sleep "$poll_seconds"
  fi
done

[[ "$deployment_done" == true ]] || fail 'Timed out waiting for a new Dokploy deployment'

health_converged=false
health_consecutive=0
for ((attempt = 1; attempt <= health_max_attempts; attempt++)); do
  if health_matches_expected_revision; then
    health_consecutive=$((health_consecutive + 1))
    if ((health_consecutive >= health_success_checks)); then
      health_converged=true
      break
    fi
  else
    health_consecutive=0
  fi
  if ((attempt < health_max_attempts)); then
    sleep "$health_retry_seconds"
  fi
done
[[ "$health_converged" == true ]] || fail 'External health did not converge and remain healthy through stabilization window'

recovery_armed=false
trap - EXIT
printf 'DOKPLOY_DEPLOY_OK application=%s image=%s\n' "$DOKPLOY_APPLICATION_ID" "$RELEASE_REF"
