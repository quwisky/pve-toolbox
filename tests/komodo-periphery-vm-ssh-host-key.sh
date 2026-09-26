#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
if [[ $EUID != 0 || ! -x /usr/sbin/sshd ]]; then
    [[ ${TUI_TEST_REQUIRED:-0} != 1 ]] || fail 'SSH host-key fixture requires root and openssh-server'
    printf 'skip SSH host-key fixture (root and openssh-server required)\n'
    exit 0
fi
WORK=$(mktemp -d)
created_sshd_dir=0
cleanup() {
    rm -rf -- "$WORK"
    if [[ $created_sshd_dir == 1 ]]; then rmdir /run/sshd; fi
}
trap cleanup EXIT
if [[ ! -d /run/sshd ]]; then mkdir -m 0755 /run/sshd; created_sshd_dir=1; fi
mkdir "$WORK/bin"
export LC_ALL=C KP_SSH_FIXTURE="$WORK" KP_SSH_REAL
KP_SSH_REAL=$(command -v ssh)
ssh-keygen -q -t ed25519 -N '' -f "$WORK/client"
ssh-keygen -q -t ed25519 -N '' -f "$WORK/server"
ssh-keygen -q -t ed25519 -N '' -f "$WORK/wrong"
ssh-keygen -q -t ecdsa -N '' -f "$WORK/other-type"
for name in server wrong other-type; do
    printf 'vm.example.invalid %s\n' "$(cut -d ' ' -f1-2 "$WORK/$name.pub")" > "$WORK/$name.hosts"
done
cat > "$WORK/sshd.conf" <<EOF
HostKey $WORK/server
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication no
EOF
# Use sshd's inetd mode over a pipe: no listening port, system configuration,
# account changes or authorized keys. Successful host verification proceeds to
# an intentional authentication denial. The fallback global file models a
# system trust entry; OpenSSH's first-value rule preserves production overrides.
cat > "$WORK/bin/ssh" <<'CLIENT'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
exec "$KP_SSH_REAL" "${args[@]:0:${#args[@]}-2}" \
    -o "GlobalKnownHostsFile=$KP_SSH_FIXTURE/server.hosts" \
    -o "ProxyCommand=/usr/sbin/sshd -i -e -f $KP_SSH_FIXTURE/sshd.conf" \
    "${args[@]: -2}"
CLIENT
chmod +x "$WORK/bin/ssh"
export PATH="$WORK/bin:$PATH"
source modules/komodo-periphery/host.sh
source modules/komodo-periphery/transport-ssh.sh
kp_ssh_prepare 201 vm.example.invalid 22 "$WORK/client" "$WORK/server.hosts" || fail 'correct pin rejected during preparation'
if kp_ssh_run true 2> "$WORK/correct.log"; then fail 'authentication unexpectedly enabled'; fi
grep -q 'Permission denied' "$WORK/correct.log" || { cat "$WORK/correct.log" >&2; fail 'correct pin did not reach authentication'; }
for name in wrong other-type; do
    kp_ssh_prepare 201 vm.example.invalid 22 "$WORK/client" "$WORK/$name.hosts" || fail 'valid dedicated pin rejected during preparation'
    if kp_ssh_run true 2> "$WORK/wrong.log"; then fail 'incorrect pin authenticated'; fi
    grep -q 'Host key verification failed' "$WORK/wrong.log" || { cat "$WORK/wrong.log" >&2; fail 'global trust bypassed the dedicated pin'; }
done
printf 'ok real SSH host verification accepts the dedicated pin and rejects global trust bypasses\n'
