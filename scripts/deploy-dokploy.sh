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
  HEALTH_URL; do
  [[ -n "${!required_name:-}" ]] || fail "Missing required environment variable: ${required_name}"
done

[[ "$DOKPLOY_URL" =~ ^https://[^[:space:]?#]+(/[^[:space:]?#]*)?$ ]] || fail 'DOKPLOY_URL must be an HTTPS URL without a query or fragment'
[[ "$HEALTH_URL" =~ ^https://[^[:space:]]+$ ]] || fail 'HEALTH_URL must be an HTTPS URL'
[[ "$DOKPLOY_APPLICATION_ID" =~ ^[A-Za-z0-9_-]+$ ]] || fail 'DOKPLOY_APPLICATION_ID contains unsupported characters'
[[ "$RELEASE_REF" =~ ^[a-z0-9][a-z0-9._:-]*(/[a-z0-9._-]+)+@sha256:[a-f0-9]{64}$ ]] || fail 'RELEASE_REF must be an immutable image digest'

max_polls="${DOKPLOY_DEPLOY_MAX_POLLS:-120}"
poll_seconds="${DOKPLOY_DEPLOY_POLL_SECONDS:-5}"
[[ "$max_polls" =~ ^[1-9][0-9]*$ ]] || fail 'DOKPLOY_DEPLOY_MAX_POLLS must be a positive integer'
[[ "$poll_seconds" =~ ^[0-9]+$ ]] || fail 'DOKPLOY_DEPLOY_POLL_SECONDS must be a non-negative integer'

dokploy_url="${DOKPLOY_URL%/}"
api_request() {
  local method="$1"
  local endpoint="$2"
  local body="${3:-}"
  local response
  local -a args=(
    --silent
    --show-error
    --fail
    --request "$method"
    --header "x-api-key: ${DOKPLOY_API_KEY}"
    --header 'Content-Type: application/json'
  )
  if [[ -n "$body" ]]; then
    args+=(--data "$body")
  fi
  if ! response="$(curl "${args[@]}" "${dokploy_url}${endpoint}" 2>/dev/null)"; then
    printf 'Dokploy API request failed: %s\n' "$endpoint" >&2
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

deployments="$(api_request GET "/deployment.all?applicationId=${DOKPLOY_APPLICATION_ID}")" || exit 1
previous="$(newest_deployment "$deployments")"
previous_id=''
if [[ "$previous" != '__NONE__' ]]; then
  IFS=$'\t' read -r previous_id _ <<< "$previous"
fi

update_body="{\"applicationId\":\"${DOKPLOY_APPLICATION_ID}\",\"dockerImage\":\"${RELEASE_REF}\"}"
api_request POST '/application.update' "$update_body" >/dev/null || exit 1

deploy_body="{\"applicationId\":\"${DOKPLOY_APPLICATION_ID}\"}"
api_request POST '/application.deploy' "$deploy_body" >/dev/null || exit 1

deployment_done=false
for ((poll = 1; poll <= max_polls; poll++)); do
  deployments="$(api_request GET "/deployment.all?applicationId=${DOKPLOY_APPLICATION_ID}")" || exit 1
  newest="$(newest_deployment "$deployments")"
  if [[ "$newest" != '__NONE__' ]]; then
    IFS=$'\t' read -r newest_id newest_status <<< "$newest"
    if [[ "$newest_id" != "$previous_id" ]]; then
      case "$newest_status" in
        done)
          deployment_done=true
          break
          ;;
        error|cancelled)
          fail "Dokploy deployment failed with status ${newest_status}"
          ;;
      esac
    fi
  fi
  if ((poll < max_polls)); then
    sleep "$poll_seconds"
  fi
done

[[ "$deployment_done" == true ]] || fail 'Timed out waiting for a new Dokploy deployment'

if ! curl --silent --show-error --fail --output /dev/null "$HEALTH_URL" >/dev/null 2>&1; then
  fail 'External health check failed'
fi

printf 'DOKPLOY_DEPLOY_OK application=%s image=%s\n' "$DOKPLOY_APPLICATION_ID" "$RELEASE_REF"
