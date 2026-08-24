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

max_polls="${DOKPLOY_DEPLOY_MAX_POLLS:-120}"
poll_seconds="${DOKPLOY_DEPLOY_POLL_SECONDS:-5}"
[[ "$max_polls" =~ ^[1-9][0-9]*$ ]] || fail 'DOKPLOY_DEPLOY_MAX_POLLS must be a positive integer'
[[ "$poll_seconds" =~ ^[0-9]+$ ]] || fail 'DOKPLOY_DEPLOY_POLL_SECONDS must be a non-negative integer'

dokploy_url="${DOKPLOY_URL%/}"
release_digest="${RELEASE_REF##*@}"
deployment_title="github:${GITHUB_REPOSITORY}:${GITHUB_RUN_ID}:${GITHUB_RUN_ATTEMPT}:${release_digest}"
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

deployments="$(api_request GET "/deployment.all?applicationId=${DOKPLOY_APPLICATION_ID}")" || exit 1
previous="$(newest_deployment "$deployments")"
previous_id=''
if [[ "$previous" != '__NONE__' ]]; then
  IFS=$'\t' read -r previous_id _ <<< "$previous"
fi

update_body="{\"applicationId\":\"${DOKPLOY_APPLICATION_ID}\",\"dockerImage\":\"${RELEASE_REF}\"}"
api_request POST '/application.update' "$update_body" >/dev/null || exit 1

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

if ! health_exchange="$(curl \
  --silent \
  --show-error \
  --request GET \
  --connect-timeout 5 \
  --max-time 20 \
  --max-redirs 0 \
  --write-out $'\n%{http_code}' \
  "$HEALTH_URL" 2>/dev/null)"; then
  fail 'External health check failed'
fi

health_status="${health_exchange##*$'\n'}"
health_body="${health_exchange%$'\n'*}"
[[ "$health_status" == 200 ]] || fail 'External health check did not return exact HTTP 200'
if ! actual_revision="$(python3 -c '
import json
import sys

value = json.load(sys.stdin)
if not isinstance(value, dict) or not isinstance(value.get("revision"), str):
    raise ValueError("health response has no revision")
print(value["revision"])
' <<< "$health_body" 2>/dev/null)"; then
  fail 'External health response is invalid'
fi
[[ "$actual_revision" == "$EXPECTED_REVISION" ]] || fail 'External health revision mismatch'

printf 'DOKPLOY_DEPLOY_OK application=%s image=%s\n' "$DOKPLOY_APPLICATION_ID" "$RELEASE_REF"
