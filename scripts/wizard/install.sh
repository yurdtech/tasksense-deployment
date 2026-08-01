#!/usr/bin/env bash
#
# The installation wizard: from a freshly cloned directory to a working system.
#
#   ./tasksense            (this, via the entry point)
#   scripts/wizard/install.sh
#
# Nine steps. The order is not arbitrary — the image has to be on the host
# before the live checks can run, and the live checks have to pass before
# anything is written, so that a wrong bind DN costs one question rather than an
# install, a failed sign-in, and a support call.
#
# What it does NOT do is install differently from the documented path. Step 9
# calls scripts/install.sh with the .env this produced. There is one installer;
# this is a way of arriving at it with the answers already right.

# shellcheck source=../lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
# shellcheck source=../ui.sh
. "${SCRIPT_DIR}/ui.sh"
# shellcheck source=probe.sh
. "${SCRIPT_DIR}/wizard/probe.sh"

WIZARD_DIR="${SCRIPT_DIR}/wizard"
OFFLINE=0

# The candidate configuration, until it is proven and promoted to compose/.env.
CANDIDATE="$(mktemp)"
chmod 600 "${CANDIDATE}"
# Half-finished configuration must not be left in /tmp: it holds the storage
# secret and the database password.
cleanup() { rm -f "${CANDIDATE}"; ui_restore; }
trap cleanup EXIT INT TERM

ui_require_tty

# ── 1. Welcome ───────────────────────────────────────────────────────────────

ui_clear
ui_banner "guided installation"
cat <<EOF

  Nine steps, about fifteen minutes:

    ${C_DIM}1${C_OFF}  check this host meets the requirements
    ${C_DIM}2${C_OFF}  choose a platform — Compose, Kubernetes or OpenShift
    ${C_DIM}3${C_OFF}  get the image: our registry, your registry, or an archive
    ${C_DIM}4${C_OFF}  answer about ten questions, each one explained
    ${C_DIM}5${C_OFF}  test the answers against your real directory and mail relay
    ${C_DIM}6${C_OFF}  review, then install

  Nothing is written to this machine until step 6, and nothing is sent
  anywhere at any point.

EOF
ui_yesno "Ready?" y || { note "nothing was changed"; exit 0; }

# ── 2. Preflight ─────────────────────────────────────────────────────────────

ui_step 1 9 "Requirements"
ui_text "Checking this host before anything else, so a missing dependency surfaces now rather than halfway through."
printf '\n'

if ! "${SCRIPT_DIR}/preflight.sh"; then
  printf '\n'
  ui_text "Some checks failed. They are worth fixing first — an install on a host that fails preflight usually fails later, somewhere less obvious."
  ui_yesno "Continue anyway?" n || exit 1
fi

# ── 3. Platform ──────────────────────────────────────────────────────────────

ui_step 2 9 "Platform"
ui_menu "Where will TaskSense run?" \
  "Docker Compose|one VM — the usual answer, and the easiest to back up" \
  "Kubernetes|an existing cluster, via the Helm chart" \
  "OpenShift|the same chart with the OpenShift overlay"

case "${UI_CHOICE}" in
  2) exec "${WIZARD_DIR}/platform-helm.sh" ;;
  3) exec "${WIZARD_DIR}/platform-helm.sh" --openshift ;;
esac

detect_runtime
ok "using ${RUNTIME}"

# ── 4. Image source ──────────────────────────────────────────────────────────

ui_step 3 9 "The image"
ui_text "TaskSense ships as one container image. There are three ways to get it onto this host, and which one is right depends on what this network allows."

ui_menu "How should the image get here?" \
  "Pull from ghcr.io|needs a registry token from us, and a route out" \
  "An offline archive|for a host with no route to the internet at all" \
  "Your own registry|you have already mirrored it into Harbor, Nexus, Quay"

case "${UI_CHOICE}" in
  1)
    # The token step, at the moment it is needed and not before. This is the
    # first thing that can stop an installation dead, and the error it produces
    # without help — "denied: denied" — is correct for the wrong audience:
    # somebody who was emailed a token has no reason to know that `docker login`
    # is the missing step, or which of three plausible usernames to use.
    ensure_registry_login
    ;;
  2)
    OFFLINE=1
    ui_text "The release archive contains the images, this repository, and the checksums. Unpack it here, so that ./images/ sits beside compose/."
    ui_hint "Verify it first if you have not: ./scripts/verify-signature.sh tasksense-onprem-<version>.tar.gz"
    printf '\n'
    if [ ! -d "${ROOT_DIR}/images" ]; then
      die "no ./images directory here" \
          "Unpack the release archive into ${ROOT_DIR} and run this again." \
          "See docs/13-REGISTRY-ACCESS.md."
    fi
    ok "found $(find "${ROOT_DIR}/images" -name '*.tar' | wc -l | tr -d ' ') image archive(s)"
    ;;
  3)
    ui_text "Point the configuration at your mirror. If you have not copied the images across yet, the script that does it runs from a machine that can reach both:"
    ui_hint "./scripts/load-images.sh --registry harbor.bank.internal/tasksense"
    printf '\n'
    ui_ask "Your image path" "harbor.bank.internal/tasksense/tasksense" \
      "Registry, project and repository — without the tag. The version is set separately in the next step."
    MIRROR_IMAGE="${UI_VALUE}"
    ;;
esac

# ── 5. Configure ─────────────────────────────────────────────────────────────
# Before the pull, because the version to pull is one of the answers.

ui_step 4 9 "Configuration"
ui_text "About ten questions. Each says what the setting does and what goes wrong if it is wrong. Nothing is written yet — this all goes into a temporary file that is tested first."
printf '\n'

"${WIZARD_DIR}/configure.sh" --collect "${CANDIDATE}" \
  || die "configuration was not completed" "Nothing was written. Run ./tasksense to start again."

if [ -n "${MIRROR_IMAGE:-}" ]; then
  # Written after the questions so it survives the render.
  printf 'TASKSENSE_IMAGE=%s\n' "${MIRROR_IMAGE}" >> "${CANDIDATE}"
  ok "image source: ${MIRROR_IMAGE}"
fi

# ── 6. Pull ──────────────────────────────────────────────────────────────────

ui_step 5 9 "Getting the image"

VERSION="$(sed -n 's/^TASKSENSE_VERSION=//p' "${CANDIDATE}" | tail -n1)"
IMAGE="$(sed -n 's/^TASKSENSE_IMAGE=//p' "${CANDIDATE}" | tail -n1)"
IMAGE="${IMAGE:-ghcr.io/yurdtech/tasksense}:${VERSION}"

if [ "${OFFLINE}" = "1" ]; then
  if ! ui_spinner "loading images from ./images" -- "${SCRIPT_DIR}/load-images.sh" --offline; then
    ui_show_log 15
    die "could not load the images" "See docs/13-REGISTRY-ACCESS.md."
  fi
else
  if ! ui_spinner "pulling ${IMAGE}" -- "${RUNTIME}" pull "${IMAGE}"; then
    ui_show_log 15
    die "could not pull ${IMAGE}" \
        "If the tag does not exist, check the releases page for the right version." \
        "If access was denied, the token may have expired — ask at ${SUPPORT_EMAIL}." \
        "If there is no route to ghcr.io, install from an archive instead." \
        "See docs/13-REGISTRY-ACCESS.md."
  fi
fi

# ── 7. Live checks ───────────────────────────────────────────────────────────

ui_step 6 9 "Testing the answers"
ui_text "Now that the image is here, the application's own code checks what you entered — the same LDAP client, the same configuration parser it will use once installed. A wrong bind DN or an untrusted CA is worth finding here, not from the first colleague who cannot sign in."
printf '\n'

# Which section owns which check, so a failure sends you back to the right one.
section_for() {
  case "$1" in
    ldap|oidc) printf 'signin' ;;
    smtp) printf 'mail' ;;
    mongo) printf 'version' ;;
    *) printf 'identity' ;;
  esac
}

while ! probe_run "${CANDIDATE}"; do
  printf '\n'
  warn "${#PROBE_FAILED[@]} check(s) failed: ${PROBE_FAILED[*]}"
  ui_text "The reason is printed above each one. Installing on top of this would produce a system that starts but that nobody can sign in to."
  printf '\n'

  ui_menu "What now?" \
    "Fix it|go back to the settings that failed" \
    "Test again|you changed something outside TaskSense — a firewall, a certificate" \
    "Install anyway|you know why it fails and it is not a problem" \
    "Stop|nothing has been written"

  case "${UI_CHOICE}" in
    1)
      for check in "${PROBE_FAILED[@]}"; do
        "${WIZARD_DIR}/configure.sh" --section "$(section_for "${check}")" "${CANDIDATE}"
      done
      ;;
    2) ;;
    3) warn "continuing with failing checks"; break ;;
    4) note "nothing was written"; exit 0 ;;
  esac
done

# ── 8. Review ────────────────────────────────────────────────────────────────

ui_step 7 9 "Review"

ADMIN="$(sed -n 's/^FIRST_ADMIN_EMAIL=//p' "${CANDIDATE}" | tail -n1)"
URL="$(sed -n 's/^APP_URL=//p' "${CANDIDATE}" | tail -n1)"
BIND="$(sed -n 's/^BIND_ADDRESS=//p' "${CANDIDATE}" | tail -n1)"
PORT="$(sed -n 's/^HTTP_PORT=//p' "${CANDIDATE}" | tail -n1)"

cat <<EOF

  About to write ${C_BOLD}${ENV_FILE}${C_OFF} and start TaskSense.

    Version        ${VERSION}
    Image          ${IMAGE}
    Address        ${URL}
    Listening on   ${BIND}:${PORT}
    Administrator  ${ADMIN}

  ${C_DIM}The file holds your database password and storage key. It is written
  with mode 600 — readable only by you.${C_OFF}

EOF

if [ -f "${ENV_FILE}" ]; then
  warn "${ENV_FILE} already exists and will be replaced"
  note "a copy is kept as .env.bak"
fi

ui_yesno "Install now?" y || { note "nothing was written"; exit 0; }

[ -f "${ENV_FILE}" ] && cp "${ENV_FILE}" "${ENV_FILE}.bak"
cp "${CANDIDATE}" "${ENV_FILE}"
chmod 600 "${ENV_FILE}"
ok "wrote ${ENV_FILE}"

# ── 9. Install ───────────────────────────────────────────────────────────────

ui_step 8 9 "Installing"
printf '\n'

INSTALL_ARGS=(--skip-preflight)   # already done, as step 1
[ "${OFFLINE}" = "1" ] && INSTALL_ARGS+=(--offline)

if ! "${SCRIPT_DIR}/install.sh" "${INSTALL_ARGS[@]}"; then
  printf '\n'
  die "the installation did not complete" \
      "The output above says why. Your configuration is saved at ${ENV_FILE}," \
      "so fixing the cause and running ./scripts/install.sh again picks up where this stopped." \
      "See docs/10-TROUBLESHOOTING.md."
fi

# ── done ─────────────────────────────────────────────────────────────────────

ui_step 9 9 "Done"
cat <<EOF

  TaskSense ${VERSION} is running.

  ${C_BOLD}Three things left, and the first one matters today:${C_OFF}

  ${C_BOLD}1. Put TLS in front of it.${C_OFF}
     It listens on ${BIND}:${PORT} with no encryption of its own — that is the
     reverse proxy's job, and until one is there, ${URL} does not resolve to
     anything. Ready-made configuration: examples/nginx.conf, examples/Caddyfile

  ${C_BOLD}2. Sign in as ${ADMIN}.${C_OFF}
     No password was set for that account. Use your identity provider, or
     register with that address to choose one.

  ${C_BOLD}3. Schedule a backup, and restore it once.${C_OFF}
     ./tasksense → Backup, or ./scripts/backup.sh from cron.
     A backup nobody has restored is a hypothesis. docs/07-BACKUP-DR.md

  ${C_DIM}Everything after this — status, upgrades, backups, diagnostics —
  lives behind ./tasksense${C_OFF}

EOF
