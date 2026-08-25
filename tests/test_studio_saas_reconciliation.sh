#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source <(sed '/^command_name=/,$d' "$ROOT/scripts/studio-saas.sh")

declare -F reconcile_deployment_key >/dev/null || die 'reconcile_deployment_key is missing'
declare -F verify_peer_application_isolation >/dev/null || die 'verify_peer_application_isolation is missing'

TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_DIR"' EXIT
FAKE_LOG="$TEST_DIR/requests.log"
CREATED_MARKER="$TEST_DIR/created"

preflight_failures=()
PORT_SAVE_MARKER="$TEST_DIR/port-save"
set +e
(
  ss() { return 70; }
  docker() { return 0; }
  tailscale() { builtin printf '{}'; }
  save_state() { : >"$PORT_SAVE_MARKER"; }
  STATE_DIR="$TEST_DIR/port-state"
  mkdir -p "$STATE_DIR"
  PUBLISHED_PORT=''
  HEALTH_PORT=''
  allocate_ports
) >/dev/null 2>&1
port_probe_status=$?
set -e
if [[ "$port_probe_status" -eq 0 || -e "$PORT_SAVE_MARKER" ]]; then
  preflight_failures+=('failed port inventory probe allocated or persisted a port pair')
fi

RANGE_SAVE_MARKER="$TEST_DIR/range-save"
set +e
(
  ss() { return 0; }
  docker() {
    case "$*" in
      'service ls --format {{.Ports}}') builtin printf '*:3500-3501->3000-3001/tcp\n' ;;
      'service ls -q') builtin printf 'service-1\n' ;;
      'service inspect --format {{range .Endpoint.Spec.Ports}}{{println .PublishedPort}}{{end}} service-1') builtin printf '3500\n3501\n' ;;
      *) return 64 ;;
    esac
  }
  tailscale() { builtin printf '{}'; }
  save_state() { builtin printf '%s/%s\n' "$PUBLISHED_PORT" "$HEALTH_PORT" >"$RANGE_SAVE_MARKER"; }
  STATE_DIR="$TEST_DIR/range-state"
  mkdir -p "$STATE_DIR"
  PUBLISHED_PORT=''
  HEALTH_PORT=''
  allocate_ports
) >/dev/null 2>&1
range_status=$?
set -e
if [[ "$range_status" -ne 0 || ! -f "$RANGE_SAVE_MARKER" || "$(<"$RANGE_SAVE_MARKER")" != '3502/8502' ]]; then
  preflight_failures+=('Docker published-port ranges were not allocated around exactly')
fi

HEADER_PREP_LOG="$TEST_DIR/header-prep.log"
set +e
(
  mktemp() { builtin printf '%s\n' "$TEST_DIR/header-file"; }
  chmod() { return 0; }
  printf() {
    if [[ "${1:-}" == 'x-api-key: %s\n' ]]; then return 1; fi
    builtin printf "$@"
  }
  curl() { builtin printf 'curl-called\n' >>"$HEADER_PREP_LOG"; builtin printf '401'; }
  observed="$(api_key_status GET /application.one '' "$TEST_DIR/header-response" stored-key)"
) >/dev/null 2>&1
header_prep_status=$?
set -e
if [[ "$header_prep_status" -eq 0 || -e "$HEADER_PREP_LOG" ]]; then
  preflight_failures+=('API key header write failure reached curl or returned success')
fi

LOGIN_ARG_LOG="$TEST_DIR/login-args.log"
LOGIN_SECRET='owner-password-must-not-be-an-argument'
set +e
(
  jq() {
    builtin printf '%s\n' "$@" >"$LOGIN_ARG_LOG"
    cat >/dev/null
    builtin printf '{"email":"owner@example.test","password":"encoded"}'
  }
  curl() {
    local cookie='' output=''
    while (($#)); do
      case "$1" in
        -c) cookie="$2"; shift 2 ;;
        -o) output="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    builtin printf 'localhost FALSE / FALSE 0 session value\n' >"$cookie"
    builtin printf '{}' >"$output"
    cat >/dev/null
    builtin printf '200'
  }
  login owner@example.test "$LOGIN_SECRET" "$TEST_DIR/login-cookie" "$TEST_DIR/login-response"
) >/dev/null 2>&1
login_status=$?
set -e
if [[ "$login_status" -ne 0 ]] || grep -Fq "$LOGIN_SECRET" "$LOGIN_ARG_LOG"; then
  preflight_failures+=('Dokploy login exposed its password in jq arguments')
fi

if ((${#preflight_failures[@]})); then
  printf 'studio-saas test: %s\n' "${preflight_failures[@]}" >&2
  exit 1
fi

jq() {
  local name='' id='' organization='' filter='' input=''
  while (($#)); do
    case "$1" in
      -r|-e|-c|-n|-cn) shift ;;
      --arg)
        case "$2" in
          name) name="$3" ;;
          id) id="$3" ;;
          organization) organization="$3" ;;
        esac
        shift 3
        ;;
      *)
        if [[ -z "$filter" ]]; then filter="$1"; else input="$1"; fi
        shift
        ;;
    esac
  done
  case "$filter" in
    *'(.user.apiKeys | type) == "array"'*)
      python3 - "$input" <<'PY'
import json, re, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
    keys = data["user"]["apiKeys"]
    ok = isinstance(keys, list) and all(
        isinstance(item, dict)
        and isinstance(item.get("name"), str)
        and isinstance(item.get("id"), str)
        and re.fullmatch(r"[A-Za-z0-9_-]+", item["id"])
        for item in keys
    )
except Exception:
    ok = False
raise SystemExit(0 if ok else 1)
PY
      ;;
    '.user.apiKeys[] | select(.name==$name) | .id')
      python3 - "$input" "$name" <<'PY'
import json, sys
for item in json.load(open(sys.argv[1], encoding="utf-8"))["user"]["apiKeys"]:
    if item["name"] == sys.argv[2]:
        print(item["id"])
PY
      ;;
    '{apiKeyId:$id}')
      python3 - "$id" <<'PY'
import json, sys
print(json.dumps({"apiKeyId": sys.argv[1]}, separators=(",", ":")))
PY
      ;;
    '{name:$name,prefix:"pv0",expiresIn:31536000,metadata:{organizationId:$organization},rateLimitEnabled:false}')
      python3 - "$name" "$organization" <<'PY'
import json, sys
print(json.dumps({"name": sys.argv[1], "prefix": "pv0", "expiresIn": 31536000,
                  "metadata": {"organizationId": sys.argv[2]}, "rateLimitEnabled": False},
                 separators=(",", ":")))
PY
      ;;
    '.key // empty')
      python3 - "$input" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8")).get("key", ""))
PY
      ;;
    *) printf 'unsupported fake jq filter: %s\n' "$filter" >&2; return 2 ;;
  esac
}

api_key_status() {
  printf 'KEY %s %s %s\n' "$1" "$2" "$3" >>"$FAKE_LOG"
  printf '%s\n' "$KEY_PROBE_STATUS"
}

api_cookie() {
  local method="$1" path="$2" body="$3" output="$4"
  printf 'COOKIE %s %s %s\n' "$method" "$path" "$body" >>"$FAKE_LOG"
  case "$method $path" in
    'GET /user.get')
      if [[ -f "$CREATED_MARKER" ]]; then printf '%s' "$FINAL_INVENTORY" >"$output"; else printf '%s' "$INITIAL_INVENTORY" >"$output"; fi
      ;;
    'POST /user.deleteApiKey') printf '{}' >"$output" ;;
    'POST /user.createApiKey') printf '{"key":"new-api-key-abcdefghijklmnopqrstuvwxyz"}' >"$output"; : >"$CREATED_MARKER" ;;
    *) die "unexpected cookie request: $method $path" ;;
  esac
}

save_state() { printf 'SAVE %s\n' "${API_KEY:-}" >>"$FAKE_LOG"; }

run_reconcile() {
  local name="$1" probe="$2" initial="$3" final="$4" expected_status="$5" expected_deletes="$6" expected_creates="$7"
  : >"$FAKE_LOG"
  rm -f -- "$CREATED_MARKER"
  KEY_PROBE_STATUS="$probe"
  INITIAL_INVENTORY="$initial"
  FINAL_INVENTORY="$final"
  SLUG='invoice-ai'
  APPLICATION_ID='app-own'
  API_KEY='stored-api-key-abcdefghijklmnopqrstuvwxyz'
  local response="$TEST_DIR/$name.json" status delete_count create_count
  set +e
  (reconcile_deployment_key member-cookie "$response" organization-1) >"$TEST_DIR/$name.out" 2>&1
  status=$?
  set -e
  [[ "$status" == "$expected_status" ]] || die "$name returned status=$status expected=$expected_status"
  delete_count="$(grep -c '^COOKIE POST /user.deleteApiKey ' "$FAKE_LOG" || true)"
  create_count="$(grep -c '^COOKIE POST /user.createApiKey ' "$FAKE_LOG" || true)"
  [[ "$delete_count" == "$expected_deletes" ]] || die "$name deleted $delete_count keys expected=$expected_deletes"
  [[ "$create_count" == "$expected_creates" ]] || die "$name created $create_count keys expected=$expected_creates"
}

one='{"user":{"apiKeys":[{"id":"key-1","name":"ci-invoice-ai"}]}}'
zero='{"user":{"apiKeys":[]}}'
two_with_other='{"user":{"apiKeys":[{"id":"key-1","name":"ci-invoice-ai"},{"id":"key-2","name":"ci-invoice-ai"},{"id":"keep-me","name":"manual"}]}}'

run_reconcile valid_one 200 "$one" "$one" 0 0 0
run_reconcile invalid_one 401 "$one" "$one" 0 1 1
run_reconcile valid_zero 200 "$zero" "$one" 0 0 1
run_reconcile duplicate_names 200 "$two_with_other" "$one" 0 2 1
grep -q 'apiKeyId":"keep-me' "$FAKE_LOG" && die 'reconciliation deleted a nonmatching key'

for transient in 000 429 500; do
  run_reconcile "transient_$transient" "$transient" "$one" "$one" 1 0 0
done
run_reconcile missing_inventory 200 '{"user":{}}' "$one" 1 0 0
run_reconcile malformed_inventory 200 '{broken' "$one" 1 0 0
run_reconcile duplicate_after_create 401 "$one" "$two_with_other" 1 1 1

: >"$FAKE_LOG"
KEY_PROBE_STATUS=401
verify_peer_application_isolation peer-app response-file stored-key
mapfile -t peer_requests <"$FAKE_LOG"
[[ ${#peer_requests[@]} -eq 1 ]] || die 'peer isolation emitted more than one request'
[[ "${peer_requests[0]}" == 'KEY GET /application.one?applicationId=peer-app ' ]] || die 'peer isolation must be read-only'

printf 'STUDIO_SAAS_RECONCILIATION_TESTS_OK\n'
