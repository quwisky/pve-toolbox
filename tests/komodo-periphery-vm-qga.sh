#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
BRIDGE=modules/komodo-periphery/qga-bridge.pl
[[ -f $BRIDGE ]] || fail 'QGA bridge missing'
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
mkdir -p "$WORK/lib/PVE/QemuServer" "$WORK/lib/PVE"
cat > "$WORK/lib/PVE/INotify.pm" <<'PERL'
package PVE::INotify;
sub nodename { 'pve1' }
1;
PERL
cat > "$WORK/lib/PVE/QemuConfig.pm" <<'PERL'
package PVE::QemuConfig;
sub load_config { die 'wrong VM' unless $_[1] == 201; return { agent => 1 } }
1;
PERL
cat > "$WORK/lib/PVE/RPCEnvironment.pm" <<'PERL'
package PVE::RPCEnvironment;
sub setup_default_cli_env { 1 }
1;
PERL
cat > "$WORK/lib/PVE/QemuServer/Helpers.pm" <<'PERL'
package PVE::QemuServer::Helpers;
sub vm_running_locally { $_[0] == 201 }
1;
PERL
cat > "$WORK/lib/PVE/QemuServer/Agent.pm" <<'PERL'
package PVE::QemuServer::Agent;
sub qemu_exec {
    my ($vmid, $config, $input, $command) = @_;
    die 'bad command' unless $vmid == 201 && $command->[0] eq '/bin/bash';
    die 'lost input' unless $input eq 'fixture-secret';
    return { pid => 17 };
}
sub qemu_exec_status { return { exited => 1, exitcode => 0, 'out-data' => 'ok', 'err-data' => '' } }
sub agent_cmd {
    return 5 if $_[2] eq 'file-open';
    return { count => 1 } if $_[2] eq 'file-write';
    return {};
}
1;
PERL
bridge() { PERL5LIB="$WORK/lib" perl "$BRIDGE"; }
secret_b64=$(printf fixture-secret | base64 -w0)
request=$(jq -nc --arg input "$secret_b64" '{schema:1,node:"pve1",vmid:201,action:"exec",command:["/bin/bash","-s","--","inspect"],input_data_b64:$input}')
result=$(printf '%s' "$request" | bridge) || fail 'valid exec rejected'
jq -e '.pid == 17' <<<"$result" >/dev/null || fail 'wrong QGA PID'
result=$(printf '%s' '{"schema":1,"node":"pve1","vmid":201,"action":"exec-status","pid":17}' | bridge) || fail 'valid status rejected'
jq -e '.exited == 1 and .exitcode == 0 and .["out-data"] == "ok"' <<<"$result" >/dev/null || fail 'wrong QGA exit status'
result=$(printf '%s' '{"schema":1,"node":"pve1","vmid":201,"action":"file-write","file":"/run/pve-toolbox-komodo-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/receiver.sh","content_b64":"YQ=="}' | bridge) || fail 'bounded receiver write rejected'
jq -e '.written == 1' <<<"$result" >/dev/null || fail 'wrong receiver write count'
for invalid in \
    '{"schema":1,"node":"pve2","vmid":201,"action":"exec","command":["/bin/bash"]}' \
    '{"schema":1,"node":"pve1","vmid":0,"action":"exec","command":["/bin/bash"]}' \
    '{"schema":1,"node":"pve1","vmid":201,"action":"shutdown"}' \
    '{"schema":1,"node":"pve1","vmid":201,"action":"exec","command":"/bin/bash"}' \
    '{"schema":1,"node":"pve1","vmid":201,"action":"file-write","file":"/etc/shadow","content_b64":"YQ=="}'; do
    if printf '%s' "$invalid" | bridge > "$WORK/out" 2>&1; then fail 'invalid QGA request accepted'; fi
done
big=$(head -c 49153 /dev/zero | base64 -w0)
oversized=$(jq -nc --arg input "$big" '{schema:1,node:"pve1",vmid:201,action:"exec",command:["/bin/bash"],input_data_b64:$input}')
if printf '%s' "$oversized" | bridge > "$WORK/out" 2>&1; then fail 'oversized QGA input accepted'; fi
if grep -RFq fixture-secret "$WORK/out"; then fail 'bridge leaked input'; fi
printf 'ok QGA bridge limits requests and keeps input off argv\n'
