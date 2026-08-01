#!/usr/bin/env bash
#
# The operations panel: what `./tasksense` shows once something is installed.
#
#   scripts/wizard/panel.sh              the menu
#   scripts/wizard/panel.sh status       one action, directly
#
# This is navigation. Every item runs one of the scripts beside it — upgrade.sh,
# backup.sh, restore.sh — unchanged and with the same arguments a person would
# type. Nothing here reimplements them, because two paths that do the same thing
# differently is how a support call becomes an investigation.

# shellcheck source=../lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"
# shellcheck source=../ui.sh
. "${SCRIPT_DIR}/ui.sh"

WIZARD_DIR="${SCRIPT_DIR}/wizard"

detect_runtime
require_env_file

# ── status ───────────────────────────────────────────────────────────────────

panel_status() {
  ui_step 1 1 "Status"

  local url; url="$(health_url)"
  if curl -fsS --max-time 5 "${url}" >/dev/null 2>&1; then
    ok "healthy — ${url}"
  else
    warn "not answering on ${url}"
    note "if it has only just started, give it a minute; otherwise item 6 (Logs)"
  fi

  printf '\n  %sVersion%s\n' "$C_BOLD" "$C_OFF"
  # /version reports what is actually running, which is not always what .env
  # says: a `compose up` that failed to pull leaves the old image in place.
  running_version | sed 's/^/    /' || true
  printf '    %sconfigured: %s%s\n' "$C_DIM" "$(env_value TASKSENSE_VERSION)" "$C_OFF"

  printf '\n  %sContainers%s\n' "$C_BOLD" "$C_OFF"
  compose ps | sed 's/^/    /'

  printf '\n  %sDisk%s\n' "$C_BOLD" "$C_OFF"
  local data="${COMPOSE_DIR}/data"
  if [ -d "${data}" ]; then
    du -sh "${data}"/* 2>/dev/null | sed 's/^/    /' || true
  else
    note "  data lives in a named volume — ${RUNTIME} system df -v"
  fi
  df -h "${COMPOSE_DIR}" | tail -n1 | sed 's/^/    /'
  printf '\n'
}

# ── lifecycle ────────────────────────────────────────────────────────────────

panel_start() {
  ui_step 1 1 "Start"
  compose up -d
  wait_for_health 180 || {
    warn "not healthy yet"
    compose logs --tail 40 app || true
  }
}

panel_stop() {
  ui_step 1 1 "Stop"
  ui_text "Stops the containers. Data is untouched — this is not an uninstall."
  ui_yesno "Stop TaskSense now?" n || return 0
  compose stop
  ok "stopped"
}

panel_logs() {
  ui_step 1 1 "Logs"
  ui_hint "Ctrl-C to stop following. This does not affect the running system."
  printf '\n'
  # Ctrl-C here should return to the panel, not kill it.
  trap 'trap - INT; return 0' INT
  compose logs -f --tail 100 app || true
  trap - INT
}

panel_upgrade() {
  ui_step 1 1 "Upgrade"
  local current; current="$(env_value TASKSENSE_VERSION)"
  cat <<EOF

  Currently on ${C_BOLD}${current}${C_OFF}.

  An upgrade backs up first, pulls the new image, restarts, and waits for
  health. If the new version does not come up, it puts ${current} back
  automatically and stops — your data is not touched by a failed upgrade.

  Releases: https://github.com/yurdtech/tasksense-deployment/releases

EOF
  ui_ask "Version to upgrade to" "" "The tag from the release page, for example 1.1.0 — without a leading v."
  local target="${UI_VALUE}"

  local offline=()
  if ui_yesno "Is this host offline (load the image from ./images)?" n; then
    offline=(--offline)
  fi

  "${SCRIPT_DIR}/upgrade.sh" "${target}" "${offline[@]}"
}

panel_rollback() {
  ui_step 1 1 "Roll back"
  ui_text "Puts the previous version's image back. It does NOT restore data: if the newer version ran a migration, the older code may not understand the database it finds. When in doubt, restore the backup the upgrade took instead."
  ui_yesno "Roll back anyway?" n || return 0
  "${SCRIPT_DIR}/rollback.sh"
}

# ── data ─────────────────────────────────────────────────────────────────────

panel_backup() {
  ui_step 1 1 "Backup"
  ui_text "Takes a full, restorable copy: database, uploaded files and configuration. The archive contains your database password and the storage encryption key — store it where you store those."
  printf '\n'
  ui_ask "Where to write it" "${ROOT_DIR}/backups" \
    "A directory. On a production host this should be a mount you back up off the machine — a copy on the same disk does not survive the disk."
  "${SCRIPT_DIR}/backup.sh" --output "${UI_VALUE}"
}

panel_restore() {
  ui_step 1 1 "Restore"
  ui_text "This REPLACES the current database and uploaded files. Before overwriting anything it takes a safety backup of what is here now, so a restore aimed at the wrong host is recoverable."
  printf '\n'

  # Offer what is actually on disk. Typing a timestamped path from memory is
  # how the wrong archive gets restored.
  local -a archives=()
  local dir
  for dir in "${ROOT_DIR}/backups" "${PWD}"; do
    [ -d "${dir}" ] || continue
    while IFS= read -r found; do archives+=("${found}"); done \
      < <(find "${dir}" -maxdepth 1 -name 'tasksense-*.tar.gz' -type f 2>/dev/null | sort -r | head -8)
  done

  local archive
  if [ "${#archives[@]}" -gt 0 ]; then
    local -a options=()
    local path size
    for path in "${archives[@]}"; do
      size="$(du -h "${path}" | cut -f1)"
      options+=("$(basename "${path}")|${size}")
    done
    options+=("Somewhere else|type a path")
    ui_menu "Which backup?" "${options[@]}"
    if [ "${UI_CHOICE}" -le "${#archives[@]}" ]; then
      archive="${archives[$((UI_CHOICE - 1))]}"
    else
      ui_ask "Path to the archive" "" "A tasksense-<timestamp>.tar.gz taken by backup.sh."
      archive="${UI_VALUE}"
    fi
  else
    ui_ask "Path to the archive" "" "A tasksense-<timestamp>.tar.gz taken by backup.sh."
    archive="${UI_VALUE}"
  fi

  "${SCRIPT_DIR}/restore.sh" "${archive}"
}

# ── support ──────────────────────────────────────────────────────────────────

panel_diagnostics() {
  ui_step 1 1 "Diagnostics"
  ui_text "Bundles versions, container status, resource usage, recent logs, and your configuration with every secret replaced by <redacted>. No database content, no uploaded files, no task data."
  ui_hint "It is a plain tarball. Open it and read it before sending it to us."
  printf '\n'
  "${SCRIPT_DIR}/collect-diagnostics.sh"
  printf '\n'
  ui_text "Send it to ${SUPPORT_EMAIL} with what you were doing when the problem appeared."
}

panel_configure() {
  ui_step 1 1 "Configure"
  "${WIZARD_DIR}/configure.sh" --edit || return 0

  printf '\n'
  ui_text "Changed settings take effect on restart."
  ui_yesno "Restart now?" y || { note "restart later with: ./tasksense" ; return 0; }
  compose up -d
  wait_for_health 180 || {
    warn "not healthy after the restart"
    compose logs --tail 40 app || true
  }
}

panel_uninstall() {
  ui_step 1 1 "Uninstall"
  cat <<EOF

  ${C_BOLD}Stops and removes the containers.${C_OFF}

  Your data — the database, uploaded files and ${ENV_FILE} — stays on disk
  unless you say otherwise below. Reinstalling over it brings everything back.

EOF
  ui_yesno "Remove the containers?" n || return 0
  compose down
  ok "containers removed"

  printf '\n'
  ui_text "The data is still here. Deleting it cannot be undone, and no backup is taken by this step."
  ui_yesno "Also delete all data permanently?" n || {
    note "data kept — ./tasksense will start it again"
    return 0
  }
  # Twice, and the second time by typing the word: a stray Enter on a `[y/N]`
  # must not be able to destroy a bank's task history.
  printf '\n  Type %sDELETE%s to confirm: ' "$C_BOLD" "$C_OFF"
  local typed; IFS= read -r typed
  [ "${typed}" = "DELETE" ] || { ok "cancelled — data kept"; return 0; }

  compose down -v
  rm -rf "${COMPOSE_DIR}/data"
  ok "data deleted"
  note "${ENV_FILE} was left in place — it holds your secrets; remove it yourself"
}

# ── menu ─────────────────────────────────────────────────────────────────────

state_summary() {
  local version address
  version="$(env_value TASKSENSE_VERSION)"
  address="$(env_value APP_URL)"
  if curl -fsS --max-time 3 "$(health_url)" >/dev/null 2>&1; then
    printf '%s · %shealthy%s · %s' "${version}" "$C_GREEN" "$C_OFF" "${address}"
  elif [ -n "$(compose ps -q app 2>/dev/null)" ]; then
    printf '%s · %snot answering%s · %s' "${version}" "$C_YELLOW" "$C_OFF" "${address}"
  else
    printf '%s · %sstopped%s · %s' "${version}" "$C_YELLOW" "$C_OFF" "${address}"
  fi
}

panel_menu() {
  while true; do
    ui_clear
    ui_banner "$(state_summary)"

    local running=0
    [ -n "$(compose ps -q --status running app 2>/dev/null)" ] && running=1

    local -a items=()
    if [ "${running}" = "1" ]; then
      items+=("Status|health, version, containers, disk")
      items+=("Logs|follow the application log")
      items+=("Configure|change settings and restart")
      items+=("Upgrade|backup, pull, restart, verify — rolls back on failure")
      items+=("Backup|database, files and configuration")
      items+=("Restore|from a backup archive")
      items+=("Diagnostics|a bundle for support, secrets removed")
      items+=("Stop|stop the containers, keep the data")
      items+=("More|roll back, uninstall")
      items+=("Quit|")
    else
      items+=("Start|bring the containers up")
      items+=("Status|what is here")
      items+=("Logs|why it stopped")
      items+=("Configure|change settings")
      items+=("Restore|from a backup archive")
      items+=("Diagnostics|a bundle for support, secrets removed")
      items+=("More|roll back, uninstall")
      items+=("Quit|")
    fi

    ui_menu "What would you like to do?" "${items[@]}"
    local label="${items[$((UI_CHOICE - 1))]%%|*}"

    case "${label}" in
      Status)      panel_status ;;
      Logs)        panel_logs ;;
      Configure)   panel_configure ;;
      Upgrade)     panel_upgrade ;;
      Backup)      panel_backup ;;
      Restore)     panel_restore ;;
      Diagnostics) panel_diagnostics ;;
      Start)       panel_start ;;
      Stop)        panel_stop ;;
      More)        panel_more ;;
      Quit)        printf '\n'; exit 0 ;;
    esac

    printf '\n  %sEnter to return to the menu%s ' "$C_DIM" "$C_OFF"
    IFS= read -r _
  done
}

panel_more() {
  ui_menu "Less common operations" \
    "Roll back|return to the previous version's image" \
    "Uninstall|remove the containers, optionally the data" \
    "Back|"
  case "${UI_CHOICE}" in
    1) panel_rollback ;;
    2) panel_uninstall ;;
    *) return 0 ;;
  esac
}

case "${1:-}" in
  status)      panel_status ;;
  logs)        panel_logs ;;
  upgrade)     panel_upgrade ;;
  backup)      panel_backup ;;
  restore)     panel_restore ;;
  diagnostics) panel_diagnostics ;;
  configure)   panel_configure ;;
  "")          ui_require_tty; panel_menu ;;
  *)           die "unknown panel action: $1" ;;
esac
