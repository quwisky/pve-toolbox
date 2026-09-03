#!/usr/bin/env bash
# Sent to pct exec on stdin. All inputs are positional, never shell fragments.
set -Eeuo pipefail
export LC_ALL=C DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none
export NEEDRESTART_MODE=a

phase=${1:?missing phase}
removals=${2:?missing removal policy}
[[ $removals == 0 || $removals == 1 ]] || exit 64
case $phase in probe|preview|refresh|simulate|upgrade|autoremove|autoclean|inspect) ;; *) exit 64 ;; esac

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
os_value() {
    awk -F= -v key="$1" '$1 == key {v=substr($0,index($0,"=")+1); gsub(/^["\047]|["\047]$/, "", v); print v; exit}' /etc/os-release
}
os=$(os_value ID)
codename=$(os_value VERSION_CODENAME)
case $os in debian|ubuntu) ;; *) printf 'Unsupported guest OS\n'; exit 69 ;; esac
[[ $codename =~ ^[a-z][a-z0-9]+$ ]] || fail 'cannot determine installed release codename'
for cmd in apt-get apt-mark dpkg awk; do
    command -v "$cmd" >/dev/null || fail "missing $cmd"
done
printf 'Guest: %s %s\n' "$os" "$codename"
[[ $phase != probe ]] || exit 0

# Explicit options prevent permissive apt.conf defaults from weakening policy.
# Clear inherited dpkg force options; preserve changed conffiles noninteractively.
apt_options=(
    -o DPkg::Lock::Timeout=120
    -o APT::Get::AutomaticRemove=false -o APT::Get::Purge=false
    -o APT::Get::force-yes=false -o APT::Ignore-Hold=false
    -o APT::Get::allow-downgrades=false
    -o APT::Get::allow-remove-essential=false
    -o APT::Get::allow-change-held-packages=false
    -o APT::Get::AllowUnauthenticated=false
    -o Acquire::AllowInsecureRepositories=false
    -o Acquire::AllowDowngradeToInsecureRepositories=false
    -o Acquire::AllowReleaseInfoChange=false
    -o Acquire::AllowReleaseInfoChange::Codename=false
    -o Acquire::Retries=2 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30
)
apt_run() {
    apt-get -c <(printf '#clear Dpkg::Options;\nDpkg::Options { "--force-confold"; };\n') \
        "${apt_options[@]}" "$@"
}

check_release() {
    local targets
    targets=$(apt-get indextargets) || fail 'cannot inspect repository metadata'
    # indextargets describes currently configured indexes, including deb822
    # sources and aliases resolved to signed release codenames. Third-party
    # repositories remain configured, but must have authenticated metadata.
    if ! awk -v os="$os" -v code="$codename" '
        BEGIN { RS=""; FS="\n"; base=0; bad=0 }
        {
            origin=""; name=""; trusted=""; identifier=""
            for (i=1; i<=NF; i++) {
                if ($i ~ /^Origin: /) origin=substr($i,9)
                if ($i ~ /^Codename: /) name=substr($i,11)
                if ($i ~ /^Trusted: /) trusted=substr($i,10)
                if ($i ~ /^Identifier: /) identifier=substr($i,13)
            }
            if (identifier != "Packages") next
            if (trusted != "yes") bad=1
            if (origin == "Debian" || origin == "Ubuntu") {
                base++
                if ((os == "debian" && origin != "Debian") ||
                    (os == "ubuntu" && origin != "Ubuntu")) bad=1
                if (name != code && index(name,code "-") != 1) bad=1
            }
        }
        END { exit (base == 0 || bad) }
    ' <<<"$targets"; then
        fail 'base release mismatch, unverifiable release, or untrusted repository; fix repositories manually'
    fi
}

if [[ $phase == refresh ]]; then
    printf 'Phase: refresh package indexes\n'
    apt_run -o APT::Update::Error-Mode=any update || fail 'package index refresh failed; upgrade not attempted'
fi
check_release

audit=$(dpkg --audit) || fail 'package database audit failed'
[[ -z $audit ]] || fail 'package database needs manual repair'
[[ $phase != refresh ]] || exit 0
action=(upgrade --with-new-pkgs --no-remove)
[[ $removals == 0 ]] || action=(dist-upgrade)

changed=0
case $phase in
    preview|simulate)
        printf 'Phase: simulate upgrade (%s)\n' "$phase"
        plan=$(apt_run --simulate "${action[@]}") || fail 'upgrade simulation failed'
        printf '%s\n' "$plan"
        changed=$(awk '/^(Inst|Remv) / {n++} END {print n+0}' <<<"$plan")
        if [[ $phase == preview && $removals == 1 ]]; then
            printf 'Cleanup preview uses current dependencies; the post-upgrade list may differ.\n'
            apt_run --simulate autoremove || fail 'cleanup simulation failed'
        fi ;;
    upgrade)
        printf 'Phase: upgrade packages\n'
        apt_run --assume-yes "${action[@]}" || fail 'package upgrade failed; manual attention required' ;;
    autoremove)
        [[ $removals == 1 ]] || fail 'cleanup requires explicit removal policy'
        printf 'Phase: remove unused dependencies\n'
        apt_run --assume-yes autoremove || fail 'unused dependency cleanup failed' ;;
    autoclean)
        [[ $removals == 1 ]] || fail 'cleanup requires explicit removal policy'
        printf 'Phase: clear obsolete downloads\n'
        apt_run autoclean || fail 'download cleanup failed' ;;
    inspect) ;;
esac

held=$(apt-mark showhold) || fail 'cannot read package holds'
printf 'Held packages:\n%s\n' "$held"
printf 'Remaining upgrade plan (includes packages held back):\n'
remaining=$(apt_run --simulate upgrade --with-new-pkgs --no-remove) || fail 'cannot inspect remaining upgrades'
printf '%s\n' "$remaining"
kept=$(awk '/^The following packages have been kept back:/ {keep=1; next}
    keep && /^  / {sub(/^  */, ""); printf "%s ", $0; next} {keep=0}' <<<"$remaining")
reboot=none-reported
if [[ -e /var/run/reboot-required ]]; then
    reboot=required
    printf 'Reboot requirement reported by guest: yes (no reboot performed)\n'
else
    printf 'Reboot requirement reported by guest: none (marker check only)\n'
fi
printf 'Result: planned-changes=%s; holds=%s; kept-back=%s; reboot=%s\n' \
    "$changed" "${held//$'\n'/,}" "${kept:-none}" "$reboot"
