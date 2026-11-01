#!/usr/bin/env bash
# Create an OpenBao AppRole for bao-run on a Komodo Periphery host.
#   export BAO_ADDR=https://openbao.lan:8200 BAO_TOKEN=<admin token>
#
#   ./openbao-setup.sh [--new-secret-id] <host> <host-ip>
#       host-wide role "komodo-<host>"
#       reads kv/komodo/shared/*  and  kv/komodo/<host>/*
#
#   ./openbao-setup.sh [--new-secret-id] <host> <host-ip> <stack>
#       per-stack role "komodo-<host>-<stack>"
#       reads kv/komodo/shared/*  and  kv/komodo/<host>/<stack>(/*)  only
#
# Run it again with another <stack> for each extra AppRole on the same host.
# A re-run creates no new secret ID unless --new-secret-id is given.
set -euo pipefail

USAGE="usage: $0 [--new-secret-id] <host> <host-ip> [stack]"
die() { echo "openbao-setup: $*" >&2; exit 1; }

NEW_SID=0
ARGS=()
for a in "$@"; do
  case $a in
    --new-secret-id) NEW_SID=1 ;;
    -*) die "$USAGE" ;;
    *) ARGS+=("$a") ;;
  esac
done
[[ ${#ARGS[@]} -ge 2 && ${#ARGS[@]} -le 3 ]] || die "$USAGE"
HOST=${ARGS[0]} IP=${ARGS[1]} STACK=${ARGS[2]:-}

: "${BAO_ADDR:?set BAO_ADDR to the OpenBao address}"
: "${BAO_TOKEN:?set BAO_TOKEN to an admin token}"
command -v bao >/dev/null || die "bao not found"
command -v jq  >/dev/null || die "jq not found"

[[ -n $HOST ]] || die "<host> must not be empty"
for v in "$HOST" "$STACK"; do [[ -z $v || $v =~ ^[A-Za-z0-9_-]+$ ]] || die "invalid name: $v"; done
OCTET='(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])'
[[ $IP =~ ^$OCTET(\.$OCTET){3}$ ]] || die "invalid IPv4 address: $IP"

NAME="komodo-$HOST${STACK:+-$STACK}"
SCOPE="komodo/$HOST${STACK:+/$STACK}"

POLICY=$(cat <<POL
path "kv/data/komodo/shared"    { capabilities = ["read"] }
path "kv/data/komodo/shared/*"  { capabilities = ["read"] }
path "kv/data/$SCOPE"           { capabilities = ["read"] }
path "kv/data/$SCOPE/*"         { capabilities = ["read"] }
POL
)

# All checks first: nothing is written until they pass.
SECRETS=$(bao secrets list -format=json)
if jq -e 'has("kv/")' <<<"$SECRETS" >/dev/null; then
  jq -e '."kv/" | .type == "kv" and .options.version == "2"' <<<"$SECRETS" >/dev/null \
    || die "kv/ exists but is not a KV v2 mount; refusing to change anything"
  KV_EXISTS=1
else
  KV_EXISTS=0
fi
AUTH=$(bao auth list -format=json)

trim() { sed -e 's/[[:space:]]*$//'; }
POLICIES=$(bao policy list -format=json) || die "cannot list policies"
if jq -e --arg n "$NAME" 'index($n) != null' <<<"$POLICIES" >/dev/null; then
  [[ $(bao policy read "$NAME" | trim) == "$(trim <<<"$POLICY")" ]] \
    || die "policy '$NAME' already exists with different rules; refusing to overwrite role $NAME"
fi

# Absent must be told apart from a failed lookup. Assumption: with no roles,
# bao's LIST exits non-zero with "No value found"; any other failure is fatal.
# Without the approle mount there are no roles to look up.
ROLE_EXISTED=0
if jq -e 'has("approle/")' <<<"$AUTH" >/dev/null; then
  if ROLES=$(bao list -format=json auth/approle/role 2>&1); then
    jq -e 'type == "array"' <<<"$ROLES" >/dev/null || die "unexpected AppRole listing"
    if jq -e --arg n "$NAME" 'index($n) != null' <<<"$ROLES" >/dev/null; then ROLE_EXISTED=1; fi
  elif [[ $ROLES != *"No value found"* ]]; then
    die "cannot list AppRoles: $ROLES"
  fi
fi

[[ $KV_EXISTS -eq 1 ]] || bao secrets enable -path=kv -version=2 kv
jq -e 'has("approle/")' <<<"$AUTH" >/dev/null || bao auth enable approle

bao policy write "$NAME" - <<<"$POLICY"

bao write "auth/approle/role/$NAME" \
  token_policies="$NAME" \
  token_ttl=2m token_max_ttl=5m \
  secret_id_ttl=0 secret_id_num_uses=0 \
  secret_id_bound_cidrs="$IP/32" \
  token_bound_cidrs="$IP/32"

ROLE_ID=$(bao read -field=role_id "auth/approle/role/$NAME/role-id")
echo "AppRole:   $NAME"
echo "Role ID:   $ROLE_ID"
if [[ $ROLE_EXISTED -eq 0 || $NEW_SID -eq 1 ]]; then
  SECRET_ID=$(bao write -f -field=secret_id "auth/approle/role/$NAME/secret-id")
  echo "Secret ID: $SECRET_ID   (shown once; store it now)"
  if [[ $ROLE_EXISTED -eq 1 ]]; then
    echo
    echo "Older secret IDs for $NAME stay valid until destroyed. List them with:"
    echo "  bao list auth/approle/role/$NAME/secret-id"
    echo "then destroy each old one by its accessor through the AppRole secret-id-accessor endpoint."
  fi
else
  echo "No new secret ID was created (role already existed); use --new-secret-id for one."
fi
echo
echo "Next, as root on the PVE host: pve-toolbox install bao-run"
echo "Komodo wrapper line:"
echo "  bao-run${STACK:+ -r $STACK} komodo/shared $SCOPE -- [[COMPOSE_COMMAND]]"
