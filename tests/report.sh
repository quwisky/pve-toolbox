#!/usr/bin/env bash
# Tests for the shared automation result schema and launcher output modes.
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
ROOT=$PWD
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass() { printf 'ok  %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }

# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=lib/report.sh
source "$ROOT/lib/report.sh"

report_reset example
[[ $(report_exit_code) == 0 ]] || fail "empty report was not successful"
report_add unsupported example.unsupported "not available"
[[ $(report_exit_code) == 69 ]] || fail "unsupported-only report did not exit 69"
report_add pass example.pass "healthy"
[[ $(report_exit_code) == 0 ]] || fail "a passing result did not outrank unsupported"
report_add warn example.warn "attention"
[[ $(report_exit_code) == 2 ]] || fail "warning report did not exit 2"
report_add fail example.fail "broken"
[[ $(report_exit_code) == 1 ]] || fail "failure report did not exit 1"
pass "result exit-code precedence is stable"

report_reset redaction
report_add fail redaction.example \
    'API_TOKEN=top-secret https://user:password@example.invalid' \
    'https://discord.com/api/webhooks/12345/private-token /etc/pve/priv/token.cfg'
rendered=$(report_render_json 1)
jq -e '.schema_version == 1 and .command == "redaction" and .status == "failed"
    and .exit_code == 1 and (.results | length) == 1' <<<"$rendered" >/dev/null \
    || fail "JSON envelope does not match schema version 1"
for secret in top-secret password private-token token.cfg; do
    [[ $rendered != *"$secret"* ]] || fail "JSON report leaked $secret"
done
[[ $rendered == *"[redacted]"* && $rendered == *"[redacted-webhook]"* \
    && $rendered == *"[redacted-path]"* ]] || fail "redaction markers are missing"
pass "report text is redacted before JSON rendering"

report_reset ordering
report_add pass z.last "last"
report_add pass a.first "first"
first=$(report_render_json 0)
second=$(report_render_json 0)
[[ $first == "$second" ]] || fail "identical results produced different JSON"
[[ $(jq -r '.results | map(.id) | join(" ")' <<<"$first") == "z.last a.first" ]] \
    || fail "JSON renderer changed insertion order"
pass "JSON rendering is deterministic"

# A packaged-layout fixture drives all three public commands. Its output
# deliberately contains credentials so the launcher path proves redaction too.
fixture="$WORK/fixture"
fake_bin="$WORK/bin"
mkdir -p "$fixture/lib" "$fixture/modules/example" "$fake_bin" "$WORK/empty-pve"
cp "$ROOT/lib/common.sh" "$ROOT/lib/discord.sh" "$ROOT/lib/doctor.sh" \
    "$ROOT/lib/report.sh" "$fixture/lib/"
cp "$ROOT/pve-toolbox" "$fixture/pve-toolbox"
cp "$ROOT/VERSION" "$fixture/VERSION"
printf '%s\n' \
    'MODULE_NAME="example"' \
    'MODULE_TITLE="Example"' \
    'MODULE_DESC="report fixture"' \
    'MODULE_TAGS="test"' \
    'MODULE_HOST_ONLY=0' \
    'module_status() { printf installed; }' \
    'module_status_long() { printf "installed API_TOKEN=do-not-print\\n"; }' \
    'module_update() {' \
    '    if [[ ${REPORT_FIXTURE_FAIL:-0} -eq 1 ]]; then printf "API_TOKEN=failed-secret\\n" >&2; return 7; fi' \
    '    printf "update available: https://user:pass@example.invalid\\n"' \
    '}' \
    'module_doctor() { doctor_result pass health "fixture is healthy"; }' \
    > "$fixture/modules/example/module.sh"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$fake_bin/systemctl"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$fake_bin/zpool"
printf '%s\n' '#!/usr/bin/env bash' \
    "printf 'Name Type Status Total Used Available %%\\nlocal dir active 100 20 80 20.00%%%%\\n'" \
    > "$fake_bin/pvesm"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'case ${2:-} in' \
    '    /nodes) printf '\''[{"node":"pve1"}]\n'\'' ;;' \
    '    /nodes/pve1/tasks) printf '\''[]\n'\'' ;;' \
    '    *) exit 64 ;;' \
    'esac' \
    > "$fake_bin/pvesh"
chmod 0755 "$fake_bin"/* "$fixture/pve-toolbox"

run_fixture() {
    PATH="$fake_bin:$PATH" PVE_TOOLBOX_ROOT="$fixture" \
    PVE_TOOLBOX_PVE_ETC="$WORK/empty-pve" \
    PVE_TOOLBOX_REBOOT_FILE="$WORK/no-reboot" \
    "$fixture/pve-toolbox" "$@"
}

doctor_json=$(run_fixture --json doctor) || fail "JSON doctor command failed"
jq -e '.command == "doctor" and .status == "success"
    and any(.results[]; .id == "module.example.health")' \
    <<<"$doctor_json" >/dev/null || fail "doctor JSON omitted module health"
[[ $doctor_json != *$'\e['* ]] || fail "doctor JSON contained terminal color escapes"
status_json=$(run_fixture status --json example) || fail "JSON status command failed"
jq -e '.command == "status" and .results[0].state == "pass"' \
    <<<"$status_json" >/dev/null || fail "status JSON is malformed"
[[ $status_json != *do-not-print* && $status_json == *"[redacted]"* ]] \
    || fail "status JSON did not redact module output"

rc=0
check_json=$(run_fixture --json check example) || rc=$?
[[ $rc -eq 2 ]] || fail "available update did not return warning status 2"
jq -e '.command == "check" and .status == "warning"
    and .results[0].state == "warn" and .exit_code == 2' \
    <<<"$check_json" >/dev/null || fail "check JSON did not describe the update warning"
[[ $check_json != *"user:pass"* ]] || fail "check JSON leaked URL credentials"

rc=0
failed_json=$(
    export REPORT_FIXTURE_FAIL=1
    run_fixture --json check example
) || rc=$?
[[ $rc -eq 1 ]] || fail "failed module check did not return operational failure 1"
jq -e '.status == "failed" and .results[0].state == "fail"' \
    <<<"$failed_json" >/dev/null || fail "module failure did not remain valid JSON"
[[ $failed_json != *failed-secret* ]] || fail "failed module JSON leaked a token"

rc=0
quiet_output=$(run_fixture check example --quiet) || rc=$?
[[ $rc -eq 2 && -z $quiet_output ]] \
    || fail "quiet check did not return only the warning status"
quiet_output=$(run_fixture doctor --quiet) || fail "quiet doctor command failed"
[[ -z $quiet_output ]] || fail "quiet doctor emitted output"
pass "status, check, and doctor support JSON and quiet modes"

rc=0
run_fixture --json --quiet doctor >/dev/null 2>&1 || rc=$?
[[ $rc -eq 64 ]] || fail "conflicting output flags did not exit 64"
rc=0
run_fixture --json status missing >/dev/null 2>&1 || rc=$?
[[ $rc -eq 64 ]] || fail "unknown module did not exit 64"
rc=0
run_fixture --definitely-invalid >/dev/null 2>&1 || rc=$?
[[ $rc -eq 64 ]] || fail "unknown flag did not exit 64"
pass "invalid input uses the documented exit status"
