#!/usr/bin/env bash
#
# setup-diag-user.sh
#
# Run this FROM the machine that runs linux-mcp-server, against a remote
# target host. It bootstraps (or re-syncs) a locked-down, read-only
# "diag" account on the target for use with linux-mcp-server over SSH.
#
# Safe to re-run: every step checks current state before changing anything.
#
# Usage:
#   ./setup-diag-user.sh <admin_user>@<target_host> [diag_username] [--with-sudo-grants]
#
# Examples:
#   ./setup-diag-user.sh jdoe@silverblue-host.example.com diag
#   ./setup-diag-user.sh jdoe@silverblue-host.example.com diag --with-sudo-grants
#
# --with-sudo-grants (optional):
#   Installs /etc/sudoers.d/<diag_user> granting passwordless sudo for ONLY
#   journalctl, ss, and dmidecode -- the handful of things that need root
#   even with adm/systemd-journal group membership (audit-transport journal
#   queries, full network-connection ownership info, hardware details).
#   This is a real privilege expansion, not just log-read access, so it's
#   opt-in rather than default. Omit it if the group grants are enough for
#   what you're using linux-mcp-server for.
#
# Requirements:
#   - <admin_user>@<target_host> must already have working SSH access
#     (password or existing key) and sudo (password prompt is fine) on
#     the target. This bootstrap login is NOT the diag account.

set -euo pipefail

WITH_SUDO_GRANTS=0
POSITIONAL=()
for arg in "$@"; do
  case "${arg}" in
    --with-sudo-grants)
      WITH_SUDO_GRANTS=1
      ;;
    *)
      POSITIONAL+=("${arg}")
      ;;
  esac
done

if [[ ${#POSITIONAL[@]} -lt 1 ]]; then
  echo "Usage: $0 <admin_user>@<target_host> [diag_username] [--with-sudo-grants]" >&2
  exit 1
fi

ADMIN_TARGET="${POSITIONAL[0]}"                 # e.g. jdoe@silverblue-host
DIAG_USER="${POSITIONAL[1]:-diag}"
TARGET_HOST="${ADMIN_TARGET#*@}"  # strip user@ for display/key comment
KEY_PATH="${HOME}/.ssh/id_ed25519_${DIAG_USER}_${TARGET_HOST}"
KEY_COMMENT="${DIAG_USER}@linux-mcp-server"

echo "==> Target host:      ${TARGET_HOST}"
echo "==> Diag account:     ${DIAG_USER}"
echo "==> Local key path:   ${KEY_PATH}"
echo "==> Sudo grants:      $([[ ${WITH_SUDO_GRANTS} -eq 1 ]] && echo "enabled (journalctl, ss, dmidecode)" || echo "disabled")"
echo

# ---------------------------------------------------------------------------
# 1. Generate a dedicated keypair for this account, if it doesn't exist yet.
# ---------------------------------------------------------------------------
if [[ -f "${KEY_PATH}" ]]; then
  echo "==> Key already exists locally, reusing it."
else
  echo "==> Generating new ed25519 keypair..."
  ssh-keygen -t ed25519 -f "${KEY_PATH}" -N "" -C "${KEY_COMMENT}"
fi

# A private key with no .pub beside it would otherwise abort the run under
# set -e on the read below; derive the public half back out instead.
if [[ ! -f "${KEY_PATH}.pub" ]]; then
  echo "==> Public key missing, deriving it from the private key..."
  ssh-keygen -y -f "${KEY_PATH}" > "${KEY_PATH}.pub"
  # ssh-keygen -y drops the comment; restore it so authorized_keys stays labelled.
  printf '%s %s\n' "$(cut -d' ' -f1,2 < "${KEY_PATH}.pub")" "${KEY_COMMENT}" \
    > "${KEY_PATH}.pub"
fi

PUBKEY_CONTENTS="$(cat "${KEY_PATH}.pub")"

# ---------------------------------------------------------------------------
# 2. Bootstrap the remote side over the admin account (idempotent).
#    This block creates the user, sets groups, installs the key with
#    restricted options, and locks the password -- but only if each
#    thing isn't already in place.
# ---------------------------------------------------------------------------
echo "==> Configuring ${DIAG_USER} on ${TARGET_HOST} (via ${ADMIN_TARGET})..."

REMOTE_TMP="/tmp/.diag-setup-$$.sh"
cleanup_remote_tmp() {
  ssh "${ADMIN_TARGET}" "rm -f ${REMOTE_TMP} ${REMOTE_TMP}.lock ${REMOTE_TMP}.sudoers" 2>/dev/null || true
}
trap cleanup_remote_tmp EXIT

# Step A: write the script to a temp file on the target as the admin user.
# No sudo needed here (writing to /tmp), so no tty is required and the
# heredoc can safely occupy stdin.
ssh "${ADMIN_TARGET}" "cat > ${REMOTE_TMP}" <<'REMOTE_SCRIPT'
set -euo pipefail
DIAG_USER="$1"
PUBKEY="$2"

echo "  -> Checking user ${DIAG_USER}..."
if id "${DIAG_USER}" &>/dev/null; then
  echo "     User already exists, skipping useradd."
else
  useradd -m -s /bin/bash "${DIAG_USER}"
  echo "     Created user ${DIAG_USER}."
fi

echo "  -> Ensuring group membership (adm, systemd-journal)..."
# On ostree hosts (Fedora Silverblue/CoreOS) the stock groups ship in
# /usr/lib/group and are merged in by nss-altfiles at lookup time, so getent
# resolves them while /etc/group holds only locally-created groups. usermod
# validates the group through NSS (so it finds it) but writes membership by
# rewriting /etc/group -- where the entry does not exist. It therefore EXITS 0
# having done nothing at all: no error, no membership. See rpm-ostree#1318 and
# fedora-silverblue/issue-tracker#657; copying the entry into /etc/group is the
# documented workaround. nsswitch uses "[SUCCESS=merge]", so the duplicated
# entry merges with the /usr/lib one rather than conflicting -- the same shape
# the stock "wheel" group already has on these systems.
WANTED_GROUPS="adm systemd-journal"
ADD_GROUPS=""
for g in ${WANTED_GROUPS}; do
  if grep -q "^${g}:" /etc/group; then
    :
  elif [[ -f /usr/lib/group ]] && grep -q "^${g}:" /usr/lib/group; then
    echo "     ${g} is image-provided (/usr/lib/group), copying entry to /etc/group."
    grep "^${g}:" /usr/lib/group >> /etc/group
  elif ! getent group "${g}" >/dev/null 2>&1; then
    echo "     !! group ${g} does not exist on this host, skipping it." >&2
    continue
  fi
  ADD_GROUPS="${ADD_GROUPS:+${ADD_GROUPS},}${g}"
done

# Non-fatal: losing a group degrades journal access but must not abort the key
# install. The check below reports what actually stuck.
if [[ -n "${ADD_GROUPS}" ]]; then
  usermod -a -G "${ADD_GROUPS}" "${DIAG_USER}" \
    || echo "     !! usermod failed for: ${ADD_GROUPS}" >&2
fi

CURRENT_GROUPS=" $(id -nG "${DIAG_USER}") "
for g in ${WANTED_GROUPS}; do
  case "${CURRENT_GROUPS}" in
    *" ${g} "*) echo "     ${DIAG_USER} is in ${g}." ;;
    *) echo "     !! ${DIAG_USER} is NOT in ${g} -- journal access will be limited." >&2 ;;
  esac
done

HOME_DIR="$(getent passwd "${DIAG_USER}" | cut -d: -f6)"
SSH_DIR="${HOME_DIR}/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"
RESTRICTED_KEY_LINE="no-pty,no-port-forwarding,no-x11-forwarding,no-agent-forwarding ${PUBKEY}"

echo "  -> Ensuring ${SSH_DIR} exists with correct permissions..."
mkdir -p "${SSH_DIR}"
touch "${AUTH_KEYS}"
chmod 700 "${SSH_DIR}"
chmod 600 "${AUTH_KEYS}"
chown -R "${DIAG_USER}:${DIAG_USER}" "${SSH_DIR}"

# Match on the actual key material (2nd-to-last field of the pubkey),
# not the whole line, so re-runs update stale option strings too.
KEY_MATERIAL="$(echo "${PUBKEY}" | awk '{print $2}')"

if grep -qF "${KEY_MATERIAL}" "${AUTH_KEYS}" 2>/dev/null; then
  echo "     Key already present, refreshing options line..."
  grep -vF "${KEY_MATERIAL}" "${AUTH_KEYS}" > "${AUTH_KEYS}.tmp" || true
  echo "${RESTRICTED_KEY_LINE}" >> "${AUTH_KEYS}.tmp"
  mv "${AUTH_KEYS}.tmp" "${AUTH_KEYS}"
else
  echo "     Adding new key with restricted options..."
  echo "${RESTRICTED_KEY_LINE}" >> "${AUTH_KEYS}"
fi
chmod 600 "${AUTH_KEYS}"
chown "${DIAG_USER}:${DIAG_USER}" "${AUTH_KEYS}"

echo "  -> Remote-side setup complete (password NOT yet locked)."
REMOTE_SCRIPT

# Step B: run it with sudo. -t allocates a real pty so sudo can prompt for
# your password on this terminal; no heredoc here, so local stdin is free
# for you to actually type it. Arguments are pre-escaped with printf %q so
# the pubkey's embedded spaces survive as ONE argument, not several.
RUN_CMD="sudo bash ${REMOTE_TMP}$(printf ' %q' "${DIAG_USER}" "${PUBKEY_CONTENTS}")"
ssh -t "${ADMIN_TARGET}" "${RUN_CMD}"

# ---------------------------------------------------------------------------
# 3. Verify the new key actually works BEFORE locking the password.
# ---------------------------------------------------------------------------
echo
echo "==> Verifying key-based login as ${DIAG_USER}@${TARGET_HOST}..."
# IdentityAgent=none + IdentitiesOnly=yes are load-bearing, not belt-and-braces:
# without them ssh offers every key in the agent, so this check passes as long as
# ANY key authenticates -- including the admin's. The password would then get
# locked on the strength of a key that was never installed. Restrict the attempt
# to the keypair this script manages so a failure here is a real failure.
if ssh -i "${KEY_PATH}" -o IdentitiesOnly=yes -o IdentityAgent=none \
     -o BatchMode=yes -o ConnectTimeout=10 \
     "${DIAG_USER}@${TARGET_HOST}" "echo '    SSH key auth OK, whoami:' \$(whoami)"; then
  echo "==> Verified."
else
  echo "!! Could not log in as ${DIAG_USER} with the new key." >&2
  echo "!! Password has NOT been locked. Fix the issue and re-run this script." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 4. (Optional, --with-sudo-grants) Install a narrowly-scoped, passwordless
#    sudoers file for the handful of commands group membership can't cover:
#    journalctl (needed for --transport=audit), ss (full connection owner
#    info), and dmidecode (hardware details). Nothing else is granted.
# ---------------------------------------------------------------------------
if [[ ${WITH_SUDO_GRANTS} -eq 1 ]]; then
  echo
  echo "==> Installing scoped sudoers grant for ${DIAG_USER} on ${TARGET_HOST}..."

  ssh "${ADMIN_TARGET}" "cat > ${REMOTE_TMP}.sudoers" <<'SUDOERS_SCRIPT'
set -euo pipefail
DIAG_USER="$1"

JOURNALCTL_PATH="$(command -v journalctl || echo /usr/bin/journalctl)"
SS_PATH="$(command -v ss || echo /usr/sbin/ss)"
DMIDECODE_PATH="$(command -v dmidecode || echo /usr/sbin/dmidecode)"

SUDOERS_FILE="/etc/sudoers.d/${DIAG_USER}"
SUDOERS_LINE="${DIAG_USER} ALL=(root) NOPASSWD: ${JOURNALCTL_PATH}, ${SS_PATH}, ${DMIDECODE_PATH}"

if [[ -f "${SUDOERS_FILE}" ]] && grep -qF "${SUDOERS_LINE}" "${SUDOERS_FILE}" 2>/dev/null; then
  echo "     ${SUDOERS_FILE} already up to date, skipping."
  exit 0
fi

TMP_SUDOERS="$(mktemp)"
echo "${SUDOERS_LINE}" > "${TMP_SUDOERS}"

if visudo -cf "${TMP_SUDOERS}"; then
  install -m 0440 -o root -g root "${TMP_SUDOERS}" "${SUDOERS_FILE}"
  echo "     Installed ${SUDOERS_FILE}:"
  echo "       ${SUDOERS_LINE}"
else
  echo "     ERROR: generated sudoers syntax failed validation, not installed." >&2
  rm -f "${TMP_SUDOERS}"
  exit 1
fi
rm -f "${TMP_SUDOERS}"
SUDOERS_SCRIPT

  SUDOERS_RUN_CMD="sudo bash ${REMOTE_TMP}.sudoers$(printf ' %q' "${DIAG_USER}")"
  ssh -t "${ADMIN_TARGET}" "${SUDOERS_RUN_CMD}"
fi

# ---------------------------------------------------------------------------
# 5. Only now, lock the account's password (idempotent).
# ---------------------------------------------------------------------------
echo
echo "==> Locking password for ${DIAG_USER} on ${TARGET_HOST}..."

ssh "${ADMIN_TARGET}" "cat > ${REMOTE_TMP}.lock" <<'LOCK_SCRIPT'
set -euo pipefail
DIAG_USER="$1"
STATUS="$(passwd -S "${DIAG_USER}" | awk '{print $2}')"
if [[ "${STATUS}" == "L" ]]; then
  echo "     Password already locked."
else
  passwd -l "${DIAG_USER}"
  echo "     Password locked."
fi
LOCK_SCRIPT

LOCK_RUN_CMD="sudo bash ${REMOTE_TMP}.lock$(printf ' %q' "${DIAG_USER}")"
ssh -t "${ADMIN_TARGET}" "${LOCK_RUN_CMD}"

# ---------------------------------------------------------------------------
# 6. Print the ~/.ssh/config snippet for the linux-mcp-server client.
# ---------------------------------------------------------------------------
echo
if [[ ${WITH_SUDO_GRANTS} -eq 1 ]]; then
  echo "==> ${DIAG_USER} can now run journalctl, ss, and dmidecode via passwordless sudo."
fi
echo "==> Done. Add this to ~/.ssh/config on this machine:"
echo
cat <<EOF
Host ${TARGET_HOST}
  HostName ${TARGET_HOST}
  User ${DIAG_USER}
  IdentityFile ${KEY_PATH}
EOF
echo
echo "==> Then point linux-mcp-server at LINUX_MCP_ALLOWED_LOG_PATHS as needed,"
echo "    and use host=\"${TARGET_HOST}\" in MCP tool calls."
