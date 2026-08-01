#!/usr/bin/env bash
# Terminal primitives for the guided installer. Sourced after lib.sh, whose
# colours, `step`, `ok`, `warn` and `die` are reused rather than duplicated.
#
# Everything here assumes a real terminal and says so when there is not one.
# The alternative — prompting into a pipe — waits forever, which is how a
# `curl … | bash` reads as a hang rather than a mistake.

# The guided path needs bash 4: associative arrays for the answers, and `read
# -t 0.1` for arrow keys — bash 3.2 rejects a fractional timeout outright.
#
# Every supported host has it (RHEL 8 ships 4.4, Ubuntu 20.04 ships 5.0). macOS
# does not, which is the case worth naming: /bin/bash there is 3.2 from 2007.
# The plain scripts stay bash 3 compatible, so an operator on a Mac is never
# stuck — they just take the documented route.
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
  printf '\nerror: this needs bash 4 or newer (found %s)\n' "${BASH_VERSION:-unknown}" >&2
  printf '       Every supported Linux host has it. On macOS: brew install bash\n' >&2
  printf '       Or use the non-interactive path, which runs on bash 3:\n' >&2
  # shellcheck disable=SC2016  # $EDITOR is for the reader to substitute, not us
  printf '         cp compose/.env.example compose/.env && $EDITOR compose/.env\n' >&2
  printf '         ./scripts/install.sh\n\n' >&2
  exit 1
fi

# Extra colours the plain scripts do not need.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]; then
  C_CYAN=$'\033[36m'; C_BLUE=$'\033[34m'; C_INV=$'\033[7m'; C_GREY=$'\033[90m'
else
  C_CYAN=""; C_BLUE=""; C_INV=""; C_GREY=""
fi

# Box drawing, in whichever alphabet this terminal can actually render. lib.sh
# has already adopted a UTF-8 locale if the host has one and set UI_UTF8 to say
# whether it worked.
#
# Two things break without it, and they break differently. The glyphs come out
# as replacement characters — visibly wrong. And `${#text}`, which pads the
# boxes, counts bytes rather than characters, so the frame is silently
# misaligned by two columns for every em dash inside it. The second is the one
# that would have shipped unnoticed.
if [ "${UI_UTF8}" = "1" ]; then
  UI_H="─"; UI_V="│"; UI_TL="┌"; UI_TR="┐"; UI_BL="└"; UI_BR="┘"
  UI_POINT="❯"; UI_ARROWS="↑↓"
  UI_SPIN='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
else
  UI_H="-"; UI_V="|"; UI_TL="+"; UI_TR="+"; UI_BL="+"; UI_BR="+"
  UI_POINT=">"; UI_ARROWS="up/down"
  UI_SPIN='|/-'
fi

UI_WIDTH="$( { tput cols 2>/dev/null || echo 80; } )"
[ "${UI_WIDTH}" -gt 100 ] && UI_WIDTH=100
[ "${UI_WIDTH}" -lt 60 ] && UI_WIDTH=60

# A wizard half-way through an install leaves a hidden cursor and a terminal in
# raw mode. Restore both however we exit.
ui_restore() { printf '\033[?25h'; stty echo 2>/dev/null || true; }
trap ui_restore EXIT INT TERM

ui_require_tty() {
  [ -t 0 ] && [ -t 1 ] && return 0
  die "this needs an interactive terminal" \
      "It asks questions, so it cannot run from a pipe or a CI job." \
      "For automation use the documented path instead:" \
      "  cp compose/.env.example compose/.env && \$EDITOR compose/.env" \
      "  ./scripts/install.sh"
}

# ── output ───────────────────────────────────────────────────────────────────

# Prose, in an alphabet this terminal can render.
#
# The explanatory text is full of em dashes and middle dots. On a terminal
# without UTF-8 each one is three replacement characters dropped into the middle
# of a sentence, which is worse than a hyphen: it reads as corruption, and the
# operator starts wondering what else is broken. iconv transliterates rather
# than mangles, and is on every glibc host.
ui_plain() {
  local text="$*" out
  if [ "${UI_UTF8}" = "1" ]; then printf '%s' "${text}"; return; fi
  out="$(printf '%s' "${text}" | iconv -f UTF-8 -t ASCII//TRANSLIT 2>/dev/null)" || out=""
  printf '%s' "${out:-${text}}"
}

# Cut to a character count, with an ellipsis when something was lost. Counted in
# characters rather than bytes, which the UTF-8 locale settled in lib.sh makes
# true — the same reason the banner pads correctly.
ui_fit() {
  local text="$1" width="$2"
  [ "${width}" -lt 8 ] && width=8
  [ "${#text}" -le "${width}" ] && { printf '%s' "${text}"; return; }
  if [ "${UI_UTF8}" = "1" ]; then printf '%s…' "${text:0:$((width - 1))}"
  else printf '%s...' "${text:0:$((width - 3))}"; fi
}

ui_clear() { [ -t 1 ] || return 0; printf '\033[2J\033[H'; }

ui_banner() {
  printf '\n%s%s%s%s%s\n' "$C_BLUE" "$UI_TL" "$(ui_rule $((UI_WIDTH - 2)))" "$UI_TR" "$C_OFF"
  ui_banner_line "$(ui_plain "TaskSense — on-premise installer")"
  ui_banner_line "$(ui_plain "${1:-}")"
  printf '%s%s%s%s%s\n' "$C_BLUE" "$UI_BL" "$(ui_rule $((UI_WIDTH - 2)))" "$UI_BR" "$C_OFF"
}

ui_banner_line() {
  local text="$1" pad
  pad=$((UI_WIDTH - 4 - ${#text}))
  [ "${pad}" -lt 0 ] && pad=0
  printf '%s%s%s %s%*s %s%s%s\n' "$C_BLUE" "$UI_V" "$C_OFF" "$text" "${pad}" "" "$C_BLUE" "$UI_V" "$C_OFF"
}

# Built by repetition rather than `printf | tr`: GNU tr does not handle
# multibyte characters at all, in any locale, so `tr ' ' '─'` writes one third
# of a box-drawing character per column. It looks right on macOS, whose BSD tr
# does handle them — which is why this survived until it was run on RHEL.
ui_rule() {
  local n="$1" out=""
  while [ "${#out}" -lt "${n}" ]; do out="${out}${UI_H}${UI_H}${UI_H}${UI_H}${UI_H}${UI_H}${UI_H}${UI_H}"; done
  printf '%s' "${out:0:n}"
}

# "Step 4 of 9 — Sign-in", so nobody wonders how much is left.
ui_step() {
  local n="$1" total="$2" title
  title="$(ui_plain "$3")"
  printf '\n%s%s Step %s of %s %s%s  %s%s%s\n' \
    "$C_INV" "$C_BOLD" "$n" "$total" "$C_OFF" "" "$C_BOLD" "$title" "$C_OFF"
  printf '%s%s%s\n' "$C_GREY" "$(ui_rule "$UI_WIDTH")" "$C_OFF"
}

# Wraps explanatory text to the terminal, indented. `fold` is everywhere `fmt`
# is not, and breaks on spaces with -s.
ui_text() {
  printf '%s\n' "$(ui_plain "$*")" | fold -s -w $((UI_WIDTH - 4)) | sed 's/^/  /'
}

ui_hint() {
  printf '%s\n' "$(ui_plain "$*")" | fold -s -w $((UI_WIDTH - 4)) | sed "s/^/  ${C_DIM}/;s/$/${C_OFF}/"
}

# ── menu ─────────────────────────────────────────────────────────────────────

# ui_menu "Title" "Label|description" …
# Sets UI_CHOICE to the 1-based index. Arrow keys move, Enter selects, and a
# number selects directly — not every terminal sends arrows, and over some
# serial consoles none of them do.
# shellcheck disable=SC2034  # read by the wizard scripts that source this
UI_CHOICE=0
ui_menu() {
  ui_require_tty
  local title="$1"; shift
  local options=("$@")
  local count=${#options[@]} selected=0 key rest

  printf '\n  %s%s%s\n\n' "$C_BOLD" "$title" "$C_OFF"
  printf '\033[?25l'

  while true; do
    local i=0
    for entry in "${options[@]}"; do
      local label desc=""
      label="$(ui_plain "${entry%%|*}")"
      [ "${entry}" != "${entry%%|*}" ] && desc="$(ui_plain "${entry#*|}")"
      # A description long enough to wrap would print two rows where the
      # arithmetic below counts one, and the menu would climb the screen exactly
      # as it did when the arithmetic itself was wrong. Truncate instead.
      desc="$(ui_fit "${desc}" $((UI_WIDTH - 32)))"
      # \033[K clears to the end of the line before writing it: a shorter option
      # drawn over a longer one otherwise leaves the tail of the old text behind.
      if [ "${i}" -eq "${selected}" ]; then
        printf '\033[K  %s%s %s %-22s%s %s%s%s\n' "$C_CYAN" "$C_BOLD" "$UI_POINT" "${label}" "$C_OFF" "$C_DIM" "${desc}" "$C_OFF"
      else
        printf '\033[K    %s%-22s%s %s%s%s\n' "$C_GREY" "${label}" "$C_OFF" "$C_DIM" "${desc}" "$C_OFF"
      fi
      i=$((i + 1))
    done
    printf '\033[K\n\033[K  %s%s or 1-%s to choose - Enter to confirm%s' "$C_DIM" "$UI_ARROWS" "${count}" "$C_OFF"

    IFS= read -rsn1 key
    case "${key}" in
      $'\033')
        # An escape sequence, or a bare Esc. Read the rest without blocking so
        # a lone Esc does not hang waiting for characters that never come.
        read -rsn2 -t 0.1 rest || rest=""
        case "${rest}" in
          "[A") selected=$(((selected - 1 + count) % count)) ;;
          "[B") selected=$(((selected + 1) % count)) ;;
        esac
        ;;
      "" ) printf '\033[?25h\n'; UI_CHOICE=$((selected + 1)); return 0 ;;
      [1-9])
        if [ "${key}" -le "${count}" ]; then
          printf '\033[?25h\n'
          # shellcheck disable=SC2034  # read by the wizard scripts that source this
          UI_CHOICE="${key}"
          return 0
        fi
        ;;
      q|Q) printf '\033[?25h\n\n'; info "  cancelled"; exit 0 ;;
    esac
    # Back to the first option, and no further.
    #
    # This printed `count` option rows, then a newline, then the hint — so the
    # cursor is `count + 1` rows below where option one started. Moving up
    # `count + 2`, as this did, put it one row higher every time round: the menu
    # climbed the screen a line per keypress, erasing its own title and then
    # whatever the installer had said above it. Nothing errors when it is wrong,
    # which is why tests/menu.sh interprets the escape sequences rather than
    # searching the bytes for text that is still technically present.
    printf '\033[%sA\r' "$((count + 1))"
  done
}

# ── questions ────────────────────────────────────────────────────────────────

# ui_ask VAR "Label" "default" "explanation" [validator]
#
# The explanation is the point. This is a guided version of
# docs/04-CONFIGURATION.md — somebody installing for the first time should not
# have to read a 190-line file to learn which six values matter.
# shellcheck disable=SC2034  # read by the wizard scripts that source this
UI_VALUE=""
ui_ask() {
  ui_require_tty
  local name="$1" default="$2" explain="$3" validator="${4:-}" answer problem

  while true; do
    printf '\n  %s%s%s\n' "$C_BOLD" "${name}" "$C_OFF"
    [ -n "${explain}" ] && ui_hint "${explain}"
    if [ -n "${default}" ]; then
      printf '\n  %s[%s]%s ' "$C_DIM" "${default}" "$C_OFF"
    else
      printf '\n  > '
    fi

    IFS= read -r answer

    # Trim. `IFS= read` keeps leading and trailing whitespace, and a path or a
    # DN pasted out of a document or an email routinely carries one —
    # invisibly. What that produces is not a validation error but a
    # working-looking value that fails much later: LDAP_TLS_CA=" /certs/ca.pem"
    # is reported as "no such file or directory, open ' /certs/ca.pem'", where
    # the only evidence is a space nobody notices inside a quoted string.
    answer="${answer#"${answer%%[![:space:]]*}"}"
    answer="${answer%"${answer##*[![:space:]]}"}"
    answer="${answer:-${default}}"

    if [ -z "${answer}" ]; then
      warn "this one is required"
      continue
    fi
    if [ -n "${validator}" ] && ! problem="$("${validator}" "${answer}")"; then
      warn "${problem}"
      continue
    fi
    UI_VALUE="${answer}"
    return 0
  done
}

# The generator, on its own so it can be tested without a terminal.
#
# `uri` means hex: nothing in it needs escaping anywhere. 24 bytes is 48
# characters and 192 bits, so nothing is given up for the safety. base64 stays
# for values that never enter a URI, where the shorter string is nicer to handle.
ui_generate_secret() {
  local charset="$1" bytes="$2" value

  # Without this, a host with no openssl generates an empty string and says
  # "generated (0 characters)". The empty password then makes a URI that parses
  # perfectly — `mongodb://tasksense:@mongo:27017/` is valid — so nothing
  # downstream objects until the database refuses the connection, by which point
  # the cause is several steps behind. A test of this generator passed against
  # exactly that, twice, before the assertion below existed.
  command -v openssl >/dev/null 2>&1 || die "openssl is not installed" \
    "It generates the secrets, and there is no safe fallback worth writing." \
    "  RHEL/Rocky:  sudo dnf install openssl" \
    "  Debian/Ubuntu:  sudo apt install openssl"

  if [ "${charset}" = "uri" ]; then
    value="$(openssl rand -hex "${bytes}" | tr -d '\n')"
  else
    value="$(openssl rand -base64 "${bytes}" | tr -d '\n')"
  fi

  [ -n "${value}" ] || die "openssl produced nothing" \
    "Generating a secret is not something to guess at, so this stops here."
  printf '%s' "${value}"
}

# Trims a typed secret, and says so.
#
# Pasting a password out of a password manager or an email brings a trailing
# space or newline more often than not. Keeping it turns into "invalid
# credentials" against a directory, which is the least diagnosable failure we
# have: the password is right, the operator can see that it is right, and it
# does not work. Announcing the trim is the part that matters — a password that
# genuinely ends in a space is rare, and whoever has one is told why their value
# changed rather than left to find out at sign-in.
ui_trim_secret() {
  local raw="$1" trimmed
  trimmed="${raw#"${raw%%[![:space:]]*}"}"
  trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
  [ "${trimmed}" != "${raw}" ] && warn "removed leading or trailing whitespace from what you pasted"
  printf '%s' "${trimmed}"
}

# A secret, with generation offered first — an operator asked to invent a
# 32-character key will reach for something memorable, which is the problem.
# ui_secret NAME "explanation" BYTES [uri]
#
# `uri` generates from hex instead of base64, for a value that ends up inside a
# connection string. base64 emits `+`, `/` and `=`, and a MongoDB URI rejects
# all three in the password position — `mongodb://user:aB3+xY/9zQ==@mongo/`
# fails to parse before a single packet is sent. Two in three generated
# passwords contained one, so most installations died at first boot with
# "MongoParseError: Password contains unescaped characters", which names neither
# the setting nor the fact that we chose the value.
ui_secret() {
  ui_require_tty
  local name="$1" explain="$2" bytes="${3:-32}" charset="${4:-base64}" choice answer problem

  printf '\n  %s%s%s\n' "$C_BOLD" "${name}" "$C_OFF"
  [ -n "${explain}" ] && ui_hint "${explain}"

  # bytes=0 means the value belongs to somebody else — a directory service
  # account, a mail relay, an OIDC client. Offering to generate one would be
  # offering to invent a password that already exists somewhere.
  if [ "${bytes}" -eq 0 ]; then
    printf '\n  > '
    read -rs answer
    printf '\n'
    UI_VALUE="$(ui_trim_secret "${answer}")"
    [ -n "${UI_VALUE}" ] || warn "left empty"
    return 0
  fi

  printf '\n  %s[g]%s generate one for me   %s[t]%s type my own\n  > ' \
    "$C_BOLD" "$C_OFF" "$C_BOLD" "$C_OFF"

  IFS= read -r choice
  case "${choice:-g}" in
    t|T)
      while true; do
        printf '  '
        read -rs answer
        printf '\n'
        answer="$(ui_trim_secret "${answer}")"
        if [ "${charset}" = "uri" ] && ! problem="$(ui_valid_uri_secret "${answer}")"; then
          warn "${problem}"
          continue
        fi
        UI_VALUE="${answer}"
        break
      done
      ;;
    *)
      UI_VALUE="$(ui_generate_secret "${charset}" "${bytes}")"
      ok "generated (${#UI_VALUE} characters)"
      ;;
  esac
}

ui_yesno() {
  ui_require_tty
  local prompt="$1" default="${2:-n}" answer hint
  [ "${default}" = "y" ] && hint="[Y/n]" || hint="[y/N]"
  printf '\n  %s %s%s%s ' "${prompt}" "$C_DIM" "${hint}" "$C_OFF"
  IFS= read -r answer
  answer="${answer:-${default}}"
  case "${answer}" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# ── validators ───────────────────────────────────────────────────────────────
# Each prints why it refused, on stdout, and returns non-zero. Catching these
# here rather than at boot is most of the value: the alternative is a container
# that exits with a message nobody sees until they go looking for logs.

ui_valid_url() {
  case "$1" in
    https://*) return 0 ;;
    http://*)
      warn "plain http — passwords and session cookies would cross the network unencrypted"
      return 0
      ;;
    *) printf 'must start with https:// (or http://)'; return 1 ;;
  esac
}

ui_valid_email() {
  case "$1" in
    ?*@?*.?*) return 0 ;;
    *) printf 'that does not look like an email address'; return 1 ;;
  esac
}

ui_valid_ldap_url() {
  case "$1" in
    ldaps://*) return 0 ;;
    ldap://*) printf 'use ldaps:// — a plain ldap:// bind sends every password in clear text, and on-premise the application refuses it'; return 1 ;;
    *) printf 'must start with ldaps://'; return 1 ;;
  esac
}

ui_valid_port() {
  case "$1" in
    ''|*[!0-9]*) printf 'must be a number' ; return 1 ;;
    *) [ "$1" -ge 1 ] && [ "$1" -le 65535 ] && return 0
       printf 'must be between 1 and 65535'; return 1 ;;
  esac
}

# For anything that ends up in a connection string. The reserved characters are
# not a matter of taste: the URI parser splits on them, so a password containing
# one is read as the end of the password and the beginning of something else.
ui_valid_uri_secret() {
  case "$1" in
    *[/:@?\#%]*|*'['*|*']'*)
      printf 'cannot contain / : @ ? # %% [ or ] — the connection string is a URI and those end the password early. Letters, digits and . _ ~ - are safe'
      return 1
      ;;
  esac
  [ "${#1}" -ge 12 ] && return 0
  printf 'at least 12 characters'
  return 1
}

ui_valid_secret() {
  [ "${#1}" -ge 32 ] && return 0
  printf 'must be at least 32 characters (%s given)' "${#1}"
  return 1
}

# ── progress ─────────────────────────────────────────────────────────────────

# ui_spinner "message" -- command…
# Output goes to a log the caller can show if it fails; a `docker pull` writing
# over a spinner is unreadable.
UI_LAST_LOG=""
ui_spinner() {
  local message="$1"; shift; [ "$1" = "--" ] && shift
  local log; log="$(mktemp)"; UI_LAST_LOG="${log}"

  if [ ! -t 1 ]; then
    printf '  %s … ' "${message}"
    "$@" >"${log}" 2>&1 && { printf 'done\n'; return 0; } || return 1
  fi

  "$@" >"${log}" 2>&1 &
  local pid=$! frames="${UI_SPIN}" i=0
  printf '\033[?25l'
  while kill -0 "${pid}" 2>/dev/null; do
    printf '\r  %s%s%s %s' "$C_CYAN" "${frames:i++%${#frames}:1}" "$C_OFF" "${message}"
    sleep 0.1
  done
  printf '\033[?25h\r\033[K'

  if wait "${pid}"; then
    ok "${message}"
    return 0
  fi
  printf '  %s%s%s %s\n' "$C_RED" "$MARK_BAD" "$C_OFF" "${message}"
  return 1
}

# The tail of the last ui_spinner command, for when it failed.
ui_show_log() {
  [ -f "${UI_LAST_LOG}" ] || return 0
  printf '\n'
  tail -n "${1:-15}" "${UI_LAST_LOG}" | sed "s/^/  ${C_DIM}/;s/$/${C_OFF}/"
  printf '\n'
}

# ── summary ──────────────────────────────────────────────────────────────────

# Collects `label|value` pairs, then draws them. Secrets are masked here rather
# than at the call site, so a new setting cannot leak by being added without
# somebody remembering to hide it.
UI_SUMMARY=()
ui_summary_add() { UI_SUMMARY+=("$1|$2"); }
ui_summary_secret() { UI_SUMMARY+=("$1|••••••••  ${C_DIM}(${#2} characters)${C_OFF}"); }

ui_summary_show() {
  printf '\n  %s%s%s\n' "$C_BOLD" "${1:-Review}" "$C_OFF"
  printf '  %s%s%s\n' "$C_GREY" "$(ui_rule $((UI_WIDTH - 2)))" "$C_OFF"
  local entry
  for entry in "${UI_SUMMARY[@]}"; do
    printf '  %s%-24s%s %s\n' "$C_DIM" "${entry%%|*}" "$C_OFF" "${entry#*|}"
  done
  printf '\n'
}
