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
#
# Kept beside the file it becomes, not in /tmp, and deliberately not deleted when
# the run ends early. It used to be a mktemp removed by the EXIT trap, so any
# stop at all — including declining to delete a volume, or a mistyped
# confirmation — threw away every answer given so far. Somebody lost fifteen
# minutes of typing to a lower-case "delete", and the wizard's own text had told
# them nothing was written, which was true and not what they had lost.
#
# It holds the storage secret and the database password, so it is created 600
# before anything goes into it, and .gitignore covers it.
CANDIDATE="${COMPOSE_DIR}/.env.draft"

cleanup() {
  ui_restore
  # A draft that was never finished is worth more than the tidiness of removing
  # it: the next run offers to carry on from it.
  if [ -s "${CANDIDATE}" ] && [ "${INSTALL_COMPLETED:-0}" = "0" ]; then
    printf '\n  %sYour answers are saved.%s Run ./tasksense again to carry on from here.\n' \
      "$C_BOLD" "$C_OFF"
    printf '  %s%s%s\n\n' "$C_DIM" "${CANDIDATE}" "$C_OFF"
  fi
}
trap cleanup EXIT INT TERM

ui_require_tty

# ── Editing the file directly ────────────────────────────────────────────────

# Which editor, and a straight answer when there is none.
#
# $EDITOR is unset more often than not on a freshly provisioned server, and a
# wizard that responds by opening nothing — or by opening `ed` — has stopped
# being useful at the one moment it promised to help.
pick_editor() {
  local candidate
  for candidate in "${EDITOR:-}" "${VISUAL:-}" nano vim vi; do
    [ -n "${candidate}" ] || continue
    command -v "${candidate%% *}" >/dev/null 2>&1 && { printf '%s' "${candidate}"; return 0; }
  done
  return 1
}

# Start from .env.example, hand it to an editor, then check what came back.
#
# The example is the starting point rather than an empty file because it carries
# the explanation of every setting inline — the same text the questions read
# out. Somebody who wants to paste a prepared .env can select all and replace it;
# somebody who wants the comments has them.
edit_candidate() {
  local editor
  if ! editor="$(pick_editor)"; then
    die "no editor found"         "Set EDITOR, or install nano or vim."         "You can also write the file yourself and run ./scripts/install.sh:"         "  cp ${COMPOSE_DIR}/.env.example ${ENV_FILE}"
  fi

  [ -s "${CANDIDATE}" ] || {
    cp "${COMPOSE_DIR}/.env.example" "${CANDIDATE}"
    chmod 600 "${CANDIDATE}"
  }

  cat <<EOF

  Opening ${C_BOLD}${editor}${C_OFF}.

  The file is ${C_BOLD}.env.example${C_OFF} with its explanations intact. Either fill in the
  values marked REQUIRED, or select everything and paste a configuration you
  already have.

  ${C_DIM}Six values have no default: TASKSENSE_VERSION, APP_URL, FIRST_ADMIN_EMAIL,
  STORAGE_SECRET, MONGO_USER, MONGO_PASSWORD.${C_OFF}

  ${C_DIM}Generate the two secrets with:
    openssl rand -base64 32     # STORAGE_SECRET
    openssl rand -hex 24        # MONGO_PASSWORD — hex, it goes inside a URI${C_OFF}

EOF
  ui_yesno "Open it now?" y || { note "your draft is at ${CANDIDATE}"; exit 0; }

  while true; do
    "${editor}" "${CANDIDATE}" || warn "the editor exited with an error"
    chmod 600 "${CANDIDATE}"

    local blank=""
    local key value
    for key in TASKSENSE_VERSION APP_URL FIRST_ADMIN_EMAIL STORAGE_SECRET MONGO_USER MONGO_PASSWORD; do
      value="$(sed -n "s/^${key}=//p" "${CANDIDATE}" | tail -n1)"
      [ -n "${value}" ] || blank="${blank} ${key}"
    done

    # The example ships STORAGE_SECRET and MONGO_PASSWORD empty, so an untouched
    # file fails the check above. This catches the other half: a file where the
    # placeholders were left as they came.
    local placeholder=""
    grep -q '^APP_URL=https://tasksense.bank.internal$' "${CANDIDATE}" && placeholder="APP_URL"
    grep -q '^FIRST_ADMIN_EMAIL=admin@bank.internal$' "${CANDIDATE}" && placeholder="${placeholder} FIRST_ADMIN_EMAIL"

    if [ -z "${blank}" ] && [ -z "${placeholder}" ]; then
      ok "the required values are set"
      return 0
    fi

    printf '\n'
    [ -n "${blank}" ] && warn "still empty:${blank}"
    [ -n "${placeholder}" ] && warn "still the example's placeholder:${placeholder}"
    ui_text "The application refuses to start without these, and it reports them all at once — which is a worse place to read them than here."
    printf '\n'
    ui_menu "Now?"       "Back to the editor|fix them"       "Carry on anyway|I know what I am doing"       "Stop|the draft is kept"
    case "${UI_CHOICE}" in
      1) ;;
      2) return 0 ;;
      3) exit 0 ;;
    esac
  done
}

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

# ── How to answer ────────────────────────────────────────────────────────────

# An unfinished draft from an earlier run.
if [ -s "${CANDIDATE}" ]; then
  printf '\n'
  ui_text "There are answers here from a run that did not finish."
  ui_menu "Carry on from them?" \
    "Resume|keep what was entered, review it, and continue" \
    "Start again|discard them and answer from the beginning" \
    "Stop|leave everything as it is"
  case "${UI_CHOICE}" in
    1) RESUME=1 ;;
    2) rm -f "${CANDIDATE}" ;;
    3) exit 0 ;;
  esac
fi

# Two ways to fill in a configuration, and the questions are not right for
# everybody.
#
# Somebody installing their fourth environment already knows what goes in the
# file, has the values in a ticket, and wants to paste them. Making them answer
# ten questions to arrive at a file they could have written in thirty seconds is
# not guidance, it is a toll. Both routes end at the same compose/.env and the
# same scripts/install.sh — see the note at the top of configure.sh.
if [ "${RESUME:-0}" = "0" ]; then
  ui_menu "How would you like to configure it?" \
    "Answer questions|one setting at a time, each one explained" \
    "Edit the file|open .env in an editor — paste a prepared one, or fill in the example"
  [ "${UI_CHOICE}" = "2" ] && CONFIGURE_BY_EDITOR=1
fi

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

if [ "${CONFIGURE_BY_EDITOR:-0}" = "1" ]; then
  edit_candidate
elif [ "${RESUME:-0}" = "1" ]; then
  # Resuming: show what is there and let them change anything before going on.
  "${WIZARD_DIR}/configure.sh" --edit-candidate "${CANDIDATE}" || true
else
  "${WIZARD_DIR}/configure.sh" --collect "${CANDIDATE}" \
    || { note "your answers are kept — re-run and choose Resume"; exit 1; }
fi

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
  # The pull is where a bad token finally shows itself — `docker login` accepts
  # one that cannot read this package — so a refusal here is offered a second
  # try rather than ending the installation. Bounded, because an expired token
  # will not become valid by being typed again.
  PULL_ATTEMPT=1
  while ! ui_spinner "pulling ${IMAGE}" -- "${RUNTIME}" pull "${IMAGE}"; do
    ui_show_log 15
    if [ "$(registry_host)" != "ghcr.io" ] || [ "${PULL_ATTEMPT}" -ge 3 ]; then
      die "could not pull ${IMAGE}" \
          "If the tag does not exist, check the releases page for the right version." \
          "If access was denied, the token may have expired — ask at ${SUPPORT_EMAIL}." \
          "If there is no route to ghcr.io, install from an archive instead." \
          "See docs/13-REGISTRY-ACCESS.md."
    fi
    printf '\n'
    ui_text "Signing in succeeded, so the credential is stored — but it cannot read this image. A token typed short, or issued for something else, looks exactly like this: the sign-in works and the pull does not."
    ui_yesno "Try a different token?" y || die "stopped at the image" \
      "Nothing was written. Ask for a token at ${SUPPORT_EMAIL} and run ./tasksense again."
    "${RUNTIME}" logout ghcr.io >/dev/null 2>&1 || true
    prompt_registry_login ghcr.io
    PULL_ATTEMPT=$((PULL_ATTEMPT + 1))
  done
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
  if [ "${PROBE_FAILED[0]}" = "configuration" ]; then
    warn "the configuration is not valid — the message above names the setting"
  else
    warn "${#PROBE_FAILED[@]} check(s) failed: ${PROBE_FAILED[*]}"
  fi
  ui_text "The reason is printed above each one. Installing on top of this would produce a system that starts but that nobody can sign in to."
  printf '\n'

  ui_menu "What now?" \
    "Fix it|go back to the settings that failed" \
    "Test again|you changed something outside TaskSense — a firewall, a certificate" \
    "Install anyway|you know why it fails and it is not a problem" \
    "Stop|nothing has been written"

  case "${UI_CHOICE}" in
    1)
      # A rejected configuration names its own variable and belongs to no single
      # section, so it opens the whole menu rather than guessing.
      if [ "${PROBE_FAILED[0]}" = "configuration" ]; then
        "${WIZARD_DIR}/configure.sh" --edit-candidate "${CANDIDATE}" || true
      else
        for check in "${PROBE_FAILED[@]}"; do
          "${WIZARD_DIR}/configure.sh" --section "$(section_for "${check}")" "${CANDIDATE}"
        done
      fi
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

# Before anything is written, because the failure it prevents is a fifteen-minute
# detour through a stack trace that names neither the volume nor the password.
if mongo_volume_exists; then
  printf '\n'
  warn "${MONGO_VOLUME} already exists on this host"
  ui_text "MongoDB sets its username and password only when it first creates its data directory. That volume kept the credentials it was made with, so the password just generated will be refused — the application will start, fail to authenticate, and say so without mentioning the volume."
  printf '\n'
  ui_menu "Which is it?" \
    "Left over from an install that did not finish|remove the volume and start clean" \
    "A database I need|I will put its original password back myself" \
    "Not sure|stop here and let me look"

  # Declining is an answer, not a reason to end the run — see the note on
  # CANDIDATE. Anything that stops here leaves the draft behind and says so.
  case "${UI_CHOICE}" in
    1)
      printf '\n'
      ui_text "This deletes the database and the uploaded files in those volumes. It cannot be undone, and no backup is taken by this step."
      printf '\n  Type %sDELETE%s to confirm: ' "$C_BOLD" "$C_OFF"
      IFS= read -r typed
      if [ "${typed}" = "DELETE" ]; then
        compose --env-file "${CANDIDATE}" down -v >/dev/null 2>&1 || true
        ok "removed"
      else
        warn "not confirmed — the volume is untouched"
        ui_text "Nothing was deleted and nothing was lost. Installing over it would fail to authenticate, so this stops here rather than starting something that cannot work."
        exit 0
      fi
      ;;
    2)
      ui_text "Then set MONGO_PASSWORD to that database's original password. The wizard cannot know it; it is in the .env from the install that created the volume, or in your password manager."
      note "your answers are kept — re-run and choose Resume once you have it"
      exit 0
      ;;
    3)
      note "look with:"
      note "  ${RUNTIME} volume inspect ${MONGO_VOLUME}"
      note "  ${RUNTIME} run --rm -v ${MONGO_VOLUME}:/data mongo:7 ls -la /data/db"
      note "docs/10-TROUBLESHOOTING.md covers what to do with either answer."
      exit 0
      ;;
  esac
fi

ui_yesno "Install now?" y || { note "nothing was written"; exit 0; }

[ -f "${ENV_FILE}" ] && cp "${ENV_FILE}" "${ENV_FILE}.bak"
cp "${CANDIDATE}" "${ENV_FILE}"
chmod 600 "${ENV_FILE}"
ok "wrote ${ENV_FILE}"

# The draft has become the configuration; keeping a second copy of the storage
# secret and the database password lying beside it serves nobody.
rm -f "${CANDIDATE}"
INSTALL_COMPLETED=1

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
