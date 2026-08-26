#!/usr/bin/env bash
set -Eeuo pipefail

STATE_DIR="${STUDIO_SAAS_STATE_DIR:-/var/lib/studio-saas}"
ADMIN_ENV="${STUDIO_DOKPLOY_ADMIN_ENV:-/etc/studio/recovery/dokploy-admin.env}"
API_BASE=http://127.0.0.1:3000/api
OWNER=LouisVannobel
PROJECT_NAME=SaaS
ENVIRONMENT_NAME=production

die() { printf 'studio-saas: %s\n' "$*" >&2; exit 1; }

version() {
  local digest
  digest="$(sha256sum "${BASH_SOURCE[0]}" | awk '{print $1}')"
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || die 'cannot identify installed helper bytes'
  printf 'STUDIO_SAAS_VERSION sha256=%s\n' "$digest"
}

validate_slug() {
  [[ "$1" =~ ^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$ ]] ||
    die 'slug must contain 1-40 lowercase letters, digits, or internal hyphens'
}

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die 'run as root'
}

api_cookie() {
  local method="$1" path="$2" body="$3" output="$4" cookie="$5" status
  local -a args=(--silent --show-error --connect-timeout 5 --max-time 30 -b "$cookie" -o "$output" -w '%{http_code}' -X "$method")
  if [[ -n "$body" ]]; then
    args+=(-H 'content-type: application/json' --data-binary @-)
    status="$(curl "${args[@]}" "$API_BASE$path" <<<"$body")" || die "Dokploy request failed: $path"
  else
    status="$(curl "${args[@]}" "$API_BASE$path")" || die "Dokploy request failed: $path"
  fi
  [[ "$status" =~ ^2[0-9][0-9]$ ]] || die "Dokploy request rejected: $path status=$status"
}

api_key_status() {
  local method="$1" path="$2" body="$3" output="$4" key="$5"
  local header_file status
  header_file="$(mktemp)" || die 'cannot create API key header file'
  chmod 0600 "$header_file" || {
    rm -f -- "$header_file" || :
    die 'cannot protect API key header file'
  }
  printf 'x-api-key: %s\n' "$key" >"$header_file" || {
    rm -f -- "$header_file" || :
    die 'cannot write API key header file'
  }
  local -a args=(--silent --show-error --connect-timeout 5 --max-time 30 -H "@$header_file" -o "$output" -w '%{http_code}' -X "$method")
  if [[ -n "$body" ]]; then
    args+=(-H 'content-type: application/json' --data-binary @-)
    status="$(curl "${args[@]}" "$API_BASE$path" <<<"$body")" || status=000
  else
    status="$(curl "${args[@]}" "$API_BASE$path")" || status=000
  fi
  rm -f -- "$header_file" || die 'cannot remove API key header file'
  printf '%s\n' "$status"
}

save_state() {
  local temporary="$STATE_FILE.new"
  umask 0077
  {
    printf 'SLUG=%q\n' "$SLUG"
    printf 'APPLICATION_ID=%q\n' "${APPLICATION_ID:-}"
    printf 'APP_NAME=%q\n' "${APP_NAME:-}"
    printf 'PUBLISHED_PORT=%q\n' "${PUBLISHED_PORT:-}"
    printf 'HEALTH_PORT=%q\n' "${HEALTH_PORT:-}"
    printf 'MEMBER_USER_ID=%q\n' "${MEMBER_USER_ID:-}"
    printf 'MEMBER_EMAIL=%q\n' "${MEMBER_EMAIL:-}"
    printf 'MEMBER_PASSWORD=%q\n' "${MEMBER_PASSWORD:-}"
    printf 'API_KEY=%q\n' "${API_KEY:-}"
  } >"$temporary"
  chown root:root "$temporary"
  chmod 0600 "$temporary"
  mv -f -- "$temporary" "$STATE_FILE"
}

load_state() {
  APPLICATION_ID=''
  APP_NAME=''
  PUBLISHED_PORT=''
  HEALTH_PORT=''
  MEMBER_USER_ID=''
  MEMBER_EMAIL="github-deployer-$SLUG@projetv0.invalid"
  MEMBER_PASSWORD=''
  API_KEY=''
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    [[ "${SLUG:-}" == "$REQUESTED_SLUG" ]] || die 'state slug mismatch'
  fi
}

port_taken() {
  local port="$1" observed status
  local -a state_files=() service_ids=()
  observed="$(ss -H -ltn | awk '{print $4}')" || die 'cannot inspect listening TCP ports'
  if grep -Eq "(^|:)$port$" <<<"$observed"; then return 0; else status=$?; [[ "$status" == 1 ]] || die 'cannot match listening TCP ports'; fi

  observed="$(docker service ls -q)" || die 'cannot list Docker services'
  if [[ -n "$observed" ]]; then
    mapfile -t service_ids <<<"$observed" || die 'cannot decode Docker service inventory'
    observed="$(docker service inspect --format '{{range .Endpoint.Spec.Ports}}{{println .PublishedPort}}{{end}}' "${service_ids[@]}")" ||
      die 'cannot inspect Docker service ports'
    if grep -qx "$port" <<<"$observed"; then return 0; else status=$?; [[ "$status" == 1 ]] || die 'cannot match Docker service ports'; fi
  fi

  observed="$(tailscale serve status --json)" || die 'cannot inspect Tailscale Serve ports'
  if grep -Eq "[:\"]$port([/\"]|$)" <<<"$observed"; then return 0; else status=$?; [[ "$status" == 1 ]] || die 'cannot match Tailscale Serve ports'; fi

  shopt -s nullglob
  state_files=("$STATE_DIR"/*.env)
  shopt -u nullglob
  if ((${#state_files[@]})); then
    if grep -hEq "^(PUBLISHED_PORT|HEALTH_PORT)=$port$" "${state_files[@]}"; then return 0; else status=$?; [[ "$status" == 1 ]] || die 'cannot inspect stored SaaS ports'; fi
  fi
  return 1
}

allocate_ports() {
  local offset published health
  if [[ -n "$PUBLISHED_PORT" || -n "$HEALTH_PORT" ]]; then
    [[ "$PUBLISHED_PORT" =~ ^35[0-9]{2}$ && "$HEALTH_PORT" =~ ^85[0-9]{2}$ ]] || die 'stored port allocation is invalid'
    [[ $((HEALTH_PORT - PUBLISHED_PORT)) -eq 5000 ]] || die 'stored port pair is inconsistent'
    return
  fi
  for offset in $(seq 0 99); do
    published=$((3500 + offset))
    health=$((8500 + offset))
    if ! port_taken "$published" && ! port_taken "$health"; then
      PUBLISHED_PORT="$published"
      HEALTH_PORT="$health"
      save_state
      return
    fi
  done
  die 'no free SaaS port pair remains in 3500-3599/8500-8599'
}

login() {
  local email="$1" password="$2" cookie="$3" output="$4" body status
  body="$(printf '%s' "$password" | jq -Rsc --arg email "$email" '{email:$email,password:.}')" ||
    die 'cannot encode Dokploy login request'
  status="$(curl --silent --show-error --connect-timeout 5 --max-time 30 -c "$cookie" -o "$output" -w '%{http_code}' -H 'content-type: application/json' -X POST --data-binary @- "$API_BASE/auth/sign-in/email" <<<"$body")" ||
    die 'Dokploy login request failed'
  [[ "$status" == 200 ]] || die "Dokploy login rejected status=$status"
  awk '(!/^#/ || /^#HttpOnly_/) && NF >= 7 {found=1} END {exit !found}' "$cookie" || die 'Dokploy login returned no session cookie'
}

read_matching_key_ids() {
  local response="$1" key_name="$2"
  jq -e '
    (.user.apiKeys | type) == "array" and
    all(.user.apiKeys[];
      (.name | type) == "string" and
      (.id | type) == "string" and
      (.id | test("^[A-Za-z0-9_-]+$")))
  ' "$response" >/dev/null || die 'Dokploy returned an invalid API key inventory'
  jq -r --arg name "$key_name" '.user.apiKeys[] | select(.name==$name) | .id' "$response"
}

reconcile_deployment_key() {
  local member_cookie="$1" response="$2" organization_id="$3"
  local key_name key_probe_status key_valid key_body key_id matching_key_output
  local -a matching_key_ids=()
  key_name="ci-${SLUG:0:20}"
  key_valid=false
  if [[ -n "$API_KEY" ]]; then
    key_probe_status="$(api_key_status GET "/application.one?applicationId=$APPLICATION_ID" '' "$response" "$API_KEY")"
    case "$key_probe_status" in
      200) key_valid=true ;;
      401) key_valid=false ;;
      *) die "cannot determine deployment key validity status=$key_probe_status" ;;
    esac
  fi

  api_cookie GET /user.get '' "$response" "$member_cookie"
  matching_key_output="$(read_matching_key_ids "$response" "$key_name")" || die 'cannot read Dokploy API key inventory'
  if [[ -n "$matching_key_output" ]]; then mapfile -t matching_key_ids <<<"$matching_key_output"; fi
  if [[ ${#matching_key_ids[@]} -ne 1 || "$key_valid" != true ]]; then
    for key_id in "${matching_key_ids[@]}"; do
      api_cookie POST /user.deleteApiKey "$(jq -cn --arg id "$key_id" '{apiKeyId:$id}')" "$response" "$member_cookie"
    done
    API_KEY=''
    save_state
    key_body="$(jq -cn --arg name "$key_name" --arg organization "$organization_id" '{name:$name,prefix:"pv0",expiresIn:31536000,metadata:{organizationId:$organization},rateLimitEnabled:false}')"
    api_cookie POST /user.createApiKey "$key_body" "$response" "$member_cookie"
    API_KEY="$(jq -r '.key // empty' "$response")"
    [[ ${#API_KEY} -ge 20 ]] || die 'Dokploy returned an invalid API key'
    api_cookie GET /user.get '' "$response" "$member_cookie"
    matching_key_output="$(read_matching_key_ids "$response" "$key_name")" || die 'cannot read reconciled Dokploy API key inventory'
    matching_key_ids=()
    if [[ -n "$matching_key_output" ]]; then mapfile -t matching_key_ids <<<"$matching_key_output"; fi
    [[ ${#matching_key_ids[@]} -eq 1 ]] || die 'Dokploy API key reconciliation did not converge'
    save_state
  fi
}

verify_peer_application_isolation() {
  local other_application="$1" response="$2" key="$3"
  [[ -z "$other_application" ]] ||
    api_key_status GET "/application.one?applicationId=$other_application" '' "$response" "$key" | grep -qx 401 ||
    die 'deployment key can access another application'
}

provision() {
  local admin_cookie member_cookie response project_id environment_id project_count environment_count current_image application_count matched_environment
  local member_count member_body permission_body organization_id key_status other_application negative_body
  require_root
  for command_name in curl jq openssl flock docker tailscale ss; do command -v "$command_name" >/dev/null || die "$command_name is unavailable"; done
  [[ -f "$ADMIN_ENV" ]] || die 'Dokploy admin recovery file is absent'
  # shellcheck disable=SC1090
  source "$ADMIN_ENV"
  : "${EMAIL:?missing admin email}"
  : "${PASSWORD:?missing admin password}"

  install -d -o root -g root -m 0700 "$STATE_DIR"
  exec 9>"$STATE_DIR/provision.lock"
  flock -x 9
  load_state

  admin_cookie="$(mktemp)"
  member_cookie="$(mktemp)"
  response="$(mktemp)"
  trap 'rm -f -- "$admin_cookie" "$member_cookie" "$response"' EXIT
  login "$EMAIL" "$PASSWORD" "$admin_cookie" "$response"

  api_cookie GET /project.all '' "$response" "$admin_cookie"
  project_count="$(jq --arg name "$PROJECT_NAME" '[.[] | select(.name==$name)] | length' "$response")"
  [[ "$project_count" == 1 ]] || die 'expected exactly one Dokploy SaaS project'
  project_id="$(jq -r --arg name "$PROJECT_NAME" '.[] | select(.name==$name) | .projectId' "$response")"
  environment_count="$(jq --arg project "$PROJECT_NAME" --arg environment "$ENVIRONMENT_NAME" '[.[] | select(.name==$project) | .environments[] | select(.name==$environment)] | length' "$response")"
  [[ "$environment_count" == 1 ]] || die 'expected exactly one Dokploy SaaS production environment'
  environment_id="$(jq -r --arg project "$PROJECT_NAME" --arg environment "$ENVIRONMENT_NAME" '.[] | select(.name==$project) | .environments[] | select(.name==$environment) | .environmentId' "$response")"

  api_cookie GET "/project.one?projectId=$project_id" '' "$response" "$admin_cookie"
  if [[ -z "$APPLICATION_ID" ]]; then
    application_count="$(jq --arg slug "$SLUG" '[.environments[].applications[]? | select(.name==$slug or .appName==$slug)] | length' "$response")"
    case "$application_count" in
      0)
        member_body="$(jq -cn --arg slug "$SLUG" --arg environment "$environment_id" '{name:$slug,appName:$slug,environmentId:$environment,sourceType:"docker"}')"
        api_cookie POST /application.create "$member_body" "$response" "$admin_cookie"
        APPLICATION_ID="$(jq -r '.applicationId // empty' "$response")"
        APP_NAME="$(jq -r '.appName // empty' "$response")"
        [[ "$APPLICATION_ID" =~ ^[A-Za-z0-9_-]+$ ]] || die 'Dokploy returned an invalid application ID'
        ;;
      1)
        APPLICATION_ID="$(jq -r --arg slug "$SLUG" '.environments[].applications[]? | select(.name==$slug or .appName==$slug) | .applicationId' "$response")"
        matched_environment="$(jq -r --arg slug "$SLUG" '.environments[] | select(any(.applications[]?; .name==$slug or .appName==$slug)) | .environmentId' "$response")"
        [[ "$matched_environment" == "$environment_id" ]] || die 'ambiguous Dokploy application matches outside production environment'
        api_cookie GET "/application.one?applicationId=$APPLICATION_ID" '' "$response" "$admin_cookie"
        [[ "$(jq -r '.name // empty' "$response")" == "$SLUG" ]] || die 'ambiguous Dokploy application matches another logical name'
        [[ "$(jq -r '.environmentId // empty' "$response")" == "$environment_id" ]] || die 'ambiguous Dokploy application matches another environment'
        [[ "$(jq -r '.sourceType // empty' "$response")" == docker ]] || die 'ambiguous Dokploy application is not a Docker source'
        current_image="$(jq -r '.dockerImage // empty' "$response")"
        [[ -z "$current_image" || "$current_image" == "ghcr.io/${OWNER,,}/$SLUG:"* || "$current_image" == "ghcr.io/${OWNER,,}/$SLUG@sha256:"* ]] ||
          die 'ambiguous Dokploy application points to another repository'
        APP_NAME="$(jq -r '.appName // empty' "$response")"
        ;;
      *) die 'ambiguous Dokploy application matches are duplicated' ;;
    esac
  else
    api_cookie GET "/application.one?applicationId=$APPLICATION_ID" '' "$response" "$admin_cookie"
    [[ "$(jq -r '.name // empty' "$response")" == "$SLUG" ]] || die 'stored Dokploy application belongs to another slug'
    APP_NAME="$(jq -r '.appName // empty' "$response")"
  fi
  [[ "$APP_NAME" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || die 'Dokploy returned an invalid application service name'
  save_state
  allocate_ports

  api_cookie GET "/application.one?applicationId=$APPLICATION_ID" '' "$response" "$admin_cookie"
  APP_NAME="$(jq -r '.appName // empty' "$response")"
  [[ "$APP_NAME" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || die 'Dokploy application service name drifted'
  current_image="$(jq -r '.dockerImage // empty' "$response")"
  if [[ -z "$current_image" ]]; then
    current_image="ghcr.io/${OWNER,,}/$SLUG:bootstrap"
  fi
  [[ "$current_image" == "ghcr.io/${OWNER,,}/$SLUG:"* || "$current_image" == "ghcr.io/${OWNER,,}/$SLUG@sha256:"* ]] ||
    die 'existing Dokploy image belongs to another repository'
  member_body="$(jq -cn \
    --arg application "$APPLICATION_ID" --arg image "$current_image" \
    --arg memory 536870912 --arg cpu 1000000000 \
    --argjson published "$PUBLISHED_PORT" \
    '{applicationId:$application,dockerImage:$image,memoryLimit:$memory,cpuLimit:$cpu,rollbackActive:true,labelsSwarm:{"studio.projetv0.managed":"true"},modeSwarm:{Replicated:{Replicas:1}},updateConfigSwarm:{Parallelism:1,Delay:5000000000,FailureAction:"rollback",Monitor:30000000000,MaxFailureRatio:0,Order:"start-first"},rollbackConfigSwarm:{Parallelism:1,Delay:5000000000,FailureAction:"pause",Monitor:30000000000,MaxFailureRatio:0,Order:"stop-first"},endpointSpecSwarm:{Mode:"vip",Ports:[{Protocol:"tcp",TargetPort:3000,PublishedPort:$published,PublishMode:"ingress"}]}}')"
  api_cookie POST /application.update "$member_body" "$response" "$admin_cookie"

  tailscale serve --bg --https="$HEALTH_PORT" "http://127.0.0.1:$PUBLISHED_PORT" >/dev/null
  tailscale serve status --json | grep -Eq "[:\"]$HEALTH_PORT([/\"]|$)" || die 'Tailscale Serve route did not persist'

  api_cookie GET /user.all '' "$response" "$admin_cookie"
  member_count="$(jq --arg email "$MEMBER_EMAIL" '[.[] | select(.user.email==$email)] | length' "$response")"
  [[ "$member_count" -le 1 ]] || die 'duplicate Dokploy deployment members found'
  if [[ "$member_count" == 0 ]]; then
    if [[ -z "$MEMBER_PASSWORD" ]]; then MEMBER_PASSWORD="$(openssl rand -base64 36 | tr -d '\r\n')"; save_state; fi
    member_body="$(printf '%s' "$MEMBER_PASSWORD" | jq -Rsc --arg email "$MEMBER_EMAIL" '{email:$email,password:.,role:"member"}')" ||
      die 'cannot encode deployment member request'
    api_cookie POST /user.createUserWithCredentials "$member_body" "$response" "$admin_cookie"
    MEMBER_USER_ID="$(jq -r '.userId // empty' "$response")"
  else
    MEMBER_USER_ID="$(jq -r --arg email "$MEMBER_EMAIL" '.[] | select(.user.email==$email) | .userId' "$response")"
  fi
  [[ "$MEMBER_USER_ID" =~ ^[A-Za-z0-9_-]+$ ]] || die 'Dokploy returned an invalid member user ID'
  [[ -n "$MEMBER_PASSWORD" ]] || die 'deployment member recovery password is unavailable'
  save_state

  permission_body="$(jq -cn --arg id "$MEMBER_USER_ID" --arg environment "$environment_id" --arg application "$APPLICATION_ID" '{id:$id,accessedProjects:[],accessedEnvironments:[$environment],accessedServices:[$application],accessedGitProviders:[],accessedServers:[],canCreateProjects:false,canCreateServices:true,canDeleteProjects:false,canDeleteServices:false,canAccessToDocker:false,canAccessToTraefikFiles:false,canAccessToAPI:false,canAccessToSSHKeys:false,canAccessToGitProviders:false,canDeleteEnvironments:false,canCreateEnvironments:false}')"
  api_cookie POST /user.assignPermissions "$permission_body" "$response" "$admin_cookie"

  login "$MEMBER_EMAIL" "$MEMBER_PASSWORD" "$member_cookie" "$response"
  api_cookie GET /user.session '' "$response" "$member_cookie"
  organization_id="$(jq -r '.session.activeOrganizationId // empty' "$response")"
  [[ "$organization_id" =~ ^[A-Za-z0-9_-]+$ ]] || die 'Dokploy session returned an invalid organization ID'
  reconcile_deployment_key "$member_cookie" "$response" "$organization_id"

  api_cookie GET "/project.one?projectId=$project_id" '' "$response" "$admin_cookie"
  other_application="$(jq -r --arg environment "$environment_id" --arg own "$APPLICATION_ID" '[.environments[] | select(.environmentId==$environment) | .applications[]? | select(.applicationId!=$own)] | if length>0 then .[0].applicationId else empty end' "$response")"
  key_status="$(api_key_status GET "/application.one?applicationId=$APPLICATION_ID" '' "$response" "$API_KEY")"
  [[ "$key_status" == 200 ]] || die 'deployment key cannot read its application'
  api_key_status POST /application.update "$(jq -cn --arg application "$APPLICATION_ID" --arg image "$current_image" '{applicationId:$application,dockerImage:$image}')" "$response" "$API_KEY" | grep -qx 200 || die 'deployment key cannot update its application'
  verify_peer_application_isolation "$other_application" "$response" "$API_KEY"
  negative_body="$(jq -cn --arg environment "$environment_id" '{name:"forbidden",appName:"forbidden",environmentId:$environment,sourceType:"docker"}')"
  api_key_status POST /application.create "$negative_body" "$response" "$API_KEY" | grep -qx 401 || die 'deployment key can create applications'
  api_key_status POST /environment.create "$(jq -cn --arg project "$project_id" '{name:"forbidden",projectId:$project}')" "$response" "$API_KEY" | grep -qx 401 || die 'deployment key can create environments'
  api_key_status GET /sshKey.all '' "$response" "$API_KEY" | grep -qx 401 || die 'deployment key can read SSH keys'
  api_key_status GET /registry.all '' "$response" "$API_KEY" | grep -qx 401 || die 'deployment key can read registries'

  save_state
  printf 'SAAS_PROVISIONED slug=%s application=%s published_port=%s health_url=https://ops01.tail87a1b6.ts.net:%s/health\n' \
    "$SLUG" "$APPLICATION_ID" "$PUBLISHED_PORT" "$HEALTH_PORT"
  trap - EXIT
  rm -f -- "$admin_cookie" "$member_cookie" "$response"
}

inspect_runtime() {
  local spec image memory cpu managed replicas failure order parallelism update_delay update_monitor max_failure_ratio rollback_failure rollback_order rollback_parallelism rollback_delay rollback_monitor rollback_failure_ratio container_inventory container health health_body revision labels endpoint_ports serve_status serve_key expected_proxy
  local -a containers=()
  require_root
  load_state
  [[ -n "$APPLICATION_ID" && -n "$PUBLISHED_PORT" && -n "$HEALTH_PORT" ]] || die 'SaaS state is incomplete'
  [[ "$APP_NAME" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || die 'stored Dokploy application service name is invalid'
  spec="$(docker service inspect "$APP_NAME" --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}|{{.Spec.TaskTemplate.Resources.Limits.MemoryBytes}}|{{.Spec.TaskTemplate.Resources.Limits.NanoCPUs}}|{{index .Spec.TaskTemplate.ContainerSpec.Labels "studio.projetv0.managed"}}|{{.Spec.Mode.Replicated.Replicas}}|{{.Spec.UpdateConfig.FailureAction}}|{{.Spec.UpdateConfig.Order}}|{{.Spec.UpdateConfig.Parallelism}}|{{.Spec.UpdateConfig.Delay}}|{{.Spec.UpdateConfig.Monitor}}|{{.Spec.UpdateConfig.MaxFailureRatio}}|{{.Spec.RollbackConfig.FailureAction}}|{{.Spec.RollbackConfig.Order}}|{{.Spec.RollbackConfig.Parallelism}}|{{.Spec.RollbackConfig.Delay}}|{{.Spec.RollbackConfig.Monitor}}|{{.Spec.RollbackConfig.MaxFailureRatio}}')" || die 'SaaS service is absent'
  IFS='|' read -r image memory cpu managed replicas failure order parallelism update_delay update_monitor max_failure_ratio rollback_failure rollback_order rollback_parallelism rollback_delay rollback_monitor rollback_failure_ratio <<<"$spec"
  [[ "$image" =~ ^ghcr\.io/louisvannobel/$SLUG@sha256:[0-9a-f]{64}$ ]] || die 'SaaS service image is not the expected immutable digest'
  [[ "$memory|$cpu|$managed|$replicas|$failure|$order|$parallelism|$update_delay|$update_monitor|$max_failure_ratio" == '536870912|1000000000|true|1|rollback|start-first|1|5s|30s|0' ]] || die 'SaaS service policy drifted'
  [[ "$rollback_failure|$rollback_order|$rollback_parallelism|$rollback_delay|$rollback_monitor|$rollback_failure_ratio" == 'pause|stop-first|1|5s|30s|0' ]] || die 'SaaS rollback policy drifted'
  endpoint_ports="$(docker service inspect "$APP_NAME" --format '{{json .Endpoint.Spec.Ports}}')"
  jq -e --argjson published "$PUBLISHED_PORT" 'length==1 and .[0].Protocol=="tcp" and .[0].TargetPort==3000 and .[0].PublishedPort==$published and .[0].PublishMode=="ingress"' <<<"$endpoint_ports" >/dev/null || die 'SaaS published port policy drifted'
  container_inventory="$(docker ps --filter "label=com.docker.swarm.service.name=$APP_NAME" --filter status=running --format '{{.ID}}')" ||
    die 'cannot inspect running SaaS containers'
  if [[ -n "$container_inventory" ]]; then mapfile -t containers <<<"$container_inventory"; fi
  [[ ${#containers[@]} -eq 1 ]] || die 'SaaS does not have exactly one running container'
  container="${containers[0]}"
  health="$(docker inspect "$container" --format '{{if .Config.Healthcheck}}{{.State.Health.Status}}{{else}}absent{{end}}')"
  [[ "$health" == healthy ]] || die 'SaaS container is not healthy'
  health_body="$(curl -fsS --connect-timeout 5 --max-time 20 "http://127.0.0.1:$PUBLISHED_PORT/health")"
  [[ "$(jq -r '.status // empty' <<<"$health_body")" == ok ]] || die 'SaaS health status is not ready'
  revision="$(jq -r '.revision // empty' <<<"$health_body")"
  [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || die 'SaaS health revision is invalid'
  labels="$(docker image inspect "$image" --format '{{index .Config.Labels "org.opencontainers.image.revision"}}|{{index .Config.Labels "org.opencontainers.image.source"}}')"
  [[ "$labels" == "$revision|https://github.com/$OWNER/$SLUG" ]] || die 'SaaS OCI labels do not match runtime health'
  serve_status="$(tailscale serve status --json)"
  serve_key="ops01.tail87a1b6.ts.net:$HEALTH_PORT"
  expected_proxy="http://127.0.0.1:$PUBLISHED_PORT"
  jq -e --arg port "$HEALTH_PORT" --arg key "$serve_key" --arg proxy "$expected_proxy" '.TCP[$port].HTTPS==true and .Web[$key].Handlers["/"].Proxy==$proxy' <<<"$serve_status" >/dev/null || die 'SaaS private health route is absent or drifted'
  printf 'SAAS_RUNTIME_OK slug=%s application=%s image=%s health=https://ops01.tail87a1b6.ts.net:%s/health\n' "$SLUG" "$APPLICATION_ID" "$image" "$HEALTH_PORT"
}

command_name="${1:-}"
REQUESTED_SLUG="${2:-}"
case "$command_name" in
  version)
    [[ $# -eq 1 ]] || die 'usage: studio-saas version'
    version
    ;;
  validate-slug)
    [[ $# -eq 2 ]] || die 'usage: studio-saas validate-slug <slug>'
    validate_slug "$REQUESTED_SLUG"
    ;;
  provision)
    [[ $# -eq 2 ]] || die 'usage: studio-saas provision <slug>'
    validate_slug "$REQUESTED_SLUG"
    SLUG="$REQUESTED_SLUG"
    STATE_FILE="$STATE_DIR/$SLUG.env"
    provision
    ;;
  inspect)
    [[ $# -eq 2 ]] || die 'usage: studio-saas inspect <slug>'
    validate_slug "$REQUESTED_SLUG"
    SLUG="$REQUESTED_SLUG"
    STATE_FILE="$STATE_DIR/$SLUG.env"
    inspect_runtime
    ;;
  secret)
    [[ $# -eq 2 ]] || die 'usage: studio-saas secret <slug>'
    require_root
    validate_slug "$REQUESTED_SLUG"
    SLUG="$REQUESTED_SLUG"
    STATE_FILE="$STATE_DIR/$SLUG.env"
    load_state
    [[ -n "$API_KEY" ]] || die 'deployment API key is unavailable'
    printf '%s' "$API_KEY"
    ;;
  *) die 'usage: studio-saas {version|validate-slug|provision|inspect|secret} [slug]' ;;
esac
