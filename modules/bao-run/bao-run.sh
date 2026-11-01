#!/usr/bin/env bash
# bao-run — inject OpenBao KV v2 secrets as env vars, then exec a command.
#
#   bao-run [-r <role>] <kv-path> [<kv-path> ...] -- <command ...>
#   bao-run --check [-r <role>]
#   e.g. Komodo compose wrapper:
#        bao-run -r myapp komodo/myhost/myapp -- [[COMPOSE_COMMAND]]
#
# Every key under each path becomes an env var with exactly that name.
# Later paths override earlier ones; OpenBao values override Komodo's .env
# (docker compose prefers the process env over --env-file).
#
# --check logs in, revokes the token and prints one word: ok, rejected,
# unavailable, tls or unreachable. It exits 0 only for ok.
#
# Config in /etc/bao-run/ (root:root, dir 0700, files 0600):
#   addr                     e.g. https://openbao.lan:8200
#   ca.pem                   optional, CA for OpenBao's cert
#   mount                    optional, KV v2 mount (default: kv)
#   role_id, secret_id       default AppRole (used without -r, or with -r default)
#   roles/<role>/role_id     additional AppRoles, selected with -r <role>
#   roles/<role>/secret_id
set -euo pipefail

_BR_CONF="${BAO_RUN_CONF:-/etc/bao-run}"
die() { echo "bao-run: $*" >&2; exit 1; }

_BR_ROLE=""
_BR_CHECK=0
while [[ ${1:-} == "-r" || ${1:-} == "--role" || ${1:-} == "--check" ]]; do
  if [[ $1 == "--check" ]]; then _BR_CHECK=1; shift; continue; fi
  _BR_ROLE="${2:-}"; shift 2 || die "-r needs a role name"
  [[ $_BR_ROLE =~ ^[A-Za-z0-9_-]+$ ]] || die "invalid role name '$_BR_ROLE'"
  # default means the top-level files, as the guest module treats it.
  [[ $_BR_ROLE != default ]] || _BR_ROLE=""
done
_BR_CREDS="$_BR_CONF${_BR_ROLE:+/roles/$_BR_ROLE}"
[[ -r $_BR_CREDS/role_id && -r $_BR_CREDS/secret_id ]] || die "no credentials in $_BR_CREDS"

_BR_PATHS=()
if [[ $_BR_CHECK -eq 1 ]]; then
  [[ $# -eq 0 ]] || die "usage: bao-run --check [-r <role>]"
else
  while [[ $# -gt 0 && $1 != "--" ]]; do _BR_PATHS+=("$1"); shift; done
  [[ ${1:-} == "--" ]] || die "usage: bao-run <path>... -- <command>"
  shift
  [[ $# -gt 0 ]] || die "no command given"
  [[ ${#_BR_PATHS[@]} -gt 0 ]] || die "no secret path given"
fi

# command -v also accepts a file that cannot run; OpenBao would then get the blame.
curl --version >/dev/null 2>&1 || die "curl not found or not executable"
jq -n 1 >/dev/null 2>&1 || die "jq not found or not executable"

_BR_ADDR=""
[[ ! -r $_BR_CONF/addr ]] || _BR_ADDR=$(<"$_BR_CONF/addr")
[[ -n ${_BR_ADDR//[[:space:]]/} ]] || die "no OpenBao address in $_BR_CONF/addr"
_BR_MOUNT=$(cat "$_BR_CONF/mount" 2>/dev/null || echo kv)
_BR_CURL=(curl -sS --fail-with-body --max-time 10 --proto "=https")
[[ -f $_BR_CONF/ca.pem ]] && _BR_CURL+=(--cacert "$_BR_CONF/ca.pem")

# Login. Credentials go via stdin, so they never appear in the process list.
# -w appends the HTTP status after a newline; curl prints it even on failure.
_BR_RC=0
_br_login() {
  jq -n --rawfile r "$_BR_CREDS/role_id" --rawfile s "$_BR_CREDS/secret_id" \
    '{role_id: ($r|rtrimstr("\n")), secret_id: ($s|rtrimstr("\n"))}' \
    | "${_BR_CURL[@]}" -w '\n%{http_code}' -X POST --data @- "$_BR_ADDR/v1/auth/approle/login"
}
# curl's stderr is the operator's only diagnosis in run mode; --check stays quiet.
if [[ $_BR_CHECK -eq 1 ]]; then _BR_OUT=$(_br_login 2>/dev/null) || _BR_RC=$?
else _BR_OUT=$(_br_login) || _BR_RC=$?; fi
_BR_STATUS=000
[[ $_BR_OUT == *$'\n'* ]] && { _BR_STATUS=${_BR_OUT##*$'\n'}; _BR_OUT=${_BR_OUT%$'\n'*}; }
_BR_TOKEN=""
[[ $_BR_RC -ne 0 ]] || _BR_TOKEN=$(jq -er '.auth.client_token' <<<"$_BR_OUT" 2>/dev/null) || _BR_TOKEN=""
unset _BR_OUT

# Token goes in a header read from stdin, never in curl's arguments.
revoke() {
  "${_BR_CURL[@]}" -H @- -X POST "$_BR_ADDR/v1/auth/token/revoke-self" \
    <<<"X-Vault-Token: $_BR_TOKEN" >/dev/null 2>&1 || true
}

if [[ $_BR_CHECK -eq 1 ]]; then
  if [[ -n $_BR_TOKEN ]]; then _BR_WORD=ok
  elif [[ $_BR_RC -eq 0 ]]; then _BR_WORD=unavailable
  else
    case $_BR_RC in
      22) case $_BR_STATUS in 400|401|403) _BR_WORD=rejected ;; *) _BR_WORD=unavailable ;; esac ;;
      35|51|58|60|77|83|90|91) _BR_WORD=tls ;;
      *) _BR_WORD=unreachable ;;
    esac
  fi
  [[ $_BR_WORD != ok ]] || revoke
  echo "$_BR_WORD"
  [[ $_BR_WORD == ok ]]
  exit
fi

[[ -n $_BR_TOKEN ]] || die "AppRole login failed (${_BR_ROLE:-default})"
trap revoke EXIT

# Secrets stay in this array and are exported only right before exec, so a KV
# key can never overwrite a variable this script is still using.
declare -A _BR_SECRETS=()
for _BR_P in "${_BR_PATHS[@]}"; do
  _BR_JSON=$("${_BR_CURL[@]}" -H @- "$_BR_ADDR/v1/$_BR_MOUNT/data/$_BR_P" \
              <<<"X-Vault-Token: $_BR_TOKEN") || die "cannot read $_BR_MOUNT/$_BR_P"
  # An object with at least one key, and no NUL in any key or value.
  jq -e '.data.data | type == "object" and length > 0
         and ([to_entries[] | .key, (.value | tostring) | explode | any(. == 0)] | any | not)' \
    <<<"$_BR_JSON" >/dev/null 2>&1 || die "no usable secrets at $_BR_MOUNT/$_BR_P"
  # NUL-separated key/value pairs: safe for newlines, quotes and '$' in values
  while IFS= read -r -d '' _BR_KEY && IFS= read -r -d '' _BR_VAL; do
    [[ $_BR_KEY =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "invalid env var name in $_BR_P"
    # Bash's special variables are evaluated arithmetically on export (RANDOM,
    # OPTIND, HISTCMD ... would run a $(...) in the value) or silently ignore it.
    # This list reduces, and does not remove, the trust placed in whoever can
    # write to KV: they can still set any other name the command reads.
    case $_BR_KEY in
      PATH|IFS|ENV|BASH_ENV|SHELLOPTS|BASHOPTS|PS4|HOME|GCONV_PATH|LOCPATH|BAO_RUN_CONF \
        |RANDOM|SRANDOM|OPTIND|OPTARG|OPTERR|HISTCMD|LINENO|SECONDS|EPOCHSECONDS|EPOCHREALTIME \
        |UID|EUID|PPID|GROUPS|FUNCNAME|DIRSTACK|PIPESTATUS \
        |BASH*|LD_*|DOCKER_*|COMPOSE_*|BUILDKIT_*|BUILDX_*|_BR_*)
        die "refused env var name '$_BR_KEY' in $_BR_P" ;;
    esac
    _BR_SECRETS[$_BR_KEY]=$_BR_VAL
  done < <(jq -j '.data.data | to_entries[] | "\(.key)\u0000\(.value|tostring)\u0000"' <<<"$_BR_JSON")
done

revoke; trap - EXIT
unset _BR_TOKEN _BR_JSON
echo "bao-run: injected ${#_BR_SECRETS[@]} secret(s) from ${_BR_PATHS[*]} as ${_BR_ROLE:-default}" >&2
for _BR_KEY in "${!_BR_SECRETS[@]}"; do export "$_BR_KEY=${_BR_SECRETS[$_BR_KEY]}"; done
exec "$@"
