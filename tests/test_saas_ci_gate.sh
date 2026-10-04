#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/reusable-saas-ci.yml"
# Execute the gate shipped to callers, rather than a second implementation.
gate_script="$(sed 's/\r$//' "$WORKFLOW" | sed -n '/^  gate:$/,$p' | sed -n '/^        run: |$/,$p' | sed '1d;s/^          //')"
[[ -n "$gate_script" ]] || { echo 'Missing SaaS gate run block' >&2; exit 1; }

cases=0
failures=()
check_gate() {
  local name="$1" expected="$2" source_result="$3" quality_result="$4"
  local run_a11y="$5" a11y_result="$6" run_container="$7" container_result="$8"
  local status=0 output
  output="$(SECRETS_AND_SOURCE_RESULT="$source_result" QUALITY_RESULT="$quality_result" \
    RUN_A11Y="$run_a11y" ACCESSIBILITY_RESULT="$a11y_result" \
    RUN_CONTAINER="$run_container" CONTAINER_RESULT="$container_result" \
    bash -c "$gate_script" 2>&1)" || status=$?
  cases=$((cases + 1))
  if [[ "$expected" == pass && "$status" -ne 0 || "$expected" == fail && "$status" -eq 0 ]]; then
    failures+=("$name: exit=$status expected=$expected $output")
  fi
}

for run_a11y in true false; do
  for run_container in true false; do
    a11y_result=skipped; [[ "$run_a11y" != true ]] || a11y_result=success
    container_result=skipped; [[ "$run_container" != true ]] || container_result=success
    check_gate "enabled controls pass; a11y=$run_a11y container=$run_container" pass \
      success success "$run_a11y" "$a11y_result" "$run_container" "$container_result"
  done
done

for result in failure cancelled skipped neutral ''; do
  check_gate "source security $result" fail "$result" success true success true success
  check_gate "tests, lint, coverage or Fallow $result" fail success "$result" true success true success
done

for enabled in true false; do
  for result in success failure cancelled skipped neutral unknown ''; do
    expected=fail
    if [[ "$enabled:$result" == true:success || "$enabled:$result" == false:skipped ]]; then expected=pass; fi
    check_gate "a11y=$enabled result=$result" "$expected" success success "$enabled" "$result" true success
    check_gate "container=$enabled result=$result" "$expected" success success true success "$enabled" "$result"
  done
done

for enabled in '' unknown TRUE; do
  check_gate "invalid a11y option $enabled" fail success success "$enabled" success true success
  check_gate "invalid container option $enabled" fail success success true success "$enabled" success
done

if ((${#failures[@]})); then
  printf 'SaaS gate: %s\n' "${failures[@]}" >&2
  exit 1
fi
printf 'SAAS_GATE_BEHAVIOR_CASES_OK %s\n' "$cases"
