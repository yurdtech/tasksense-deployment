#!/usr/bin/env bash
#
# What the installer looks like on a terminal that is not ours.
#
#   tests/terminal.sh
#
# Containers, `ssh` from a locked-down jump host and serial consoles all arrive
# with no locale set. In that state a box-drawing character is three bytes that
# render as three replacement characters, and — worse, because it is silent —
# bash counts those bytes rather than characters when padding the frame.
#
# A test that asserts on colours would be brittle and worthless. This asserts on
# the two things that are actually wrong when this breaks: replacement
# characters in the output, and a frame whose lines are not the same width.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v docker >/dev/null 2>&1 || { printf '\n  SKIPPED: docker is not installed\n\n'; exit 0; }

printf '\nterminal rendering\n\n'

PASS=0
FAIL=0
check() {
  if [ "$2" = "$3" ]; then printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS + 1))
  else printf '  \033[31m✗\033[0m %s\n      expected: %s\n      actual:   %s\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1)); fi
}

# Draw the banner and a menu, with the locale the host actually has.
render() {  # render <image> <env…>
  local image="$1"; shift
  docker run --rm "$@" -v "${ROOT}:/w:ro" -w /w -e TERM=xterm "${image}" /bin/bash -c '
    . scripts/lib.sh
    . scripts/ui.sh
    ui_banner "not installed on this host"
    ui_text "Tests the answers against your real directory — before installing."
    ok "signed in to ghcr.io"
  ' 2>&1
}

for image in redhat/ubi9-minimal debian:12; do
  printf '\n  %s\n' "${image}"

  # The last case is the ASCII fallback, which no supported host reaches on its
  # own — C.UTF-8 is everywhere since RHEL 8 — so it is forced. Untested
  # fallbacks are the ones that turn out not to work.
  for locale_case in "no locale:" "C locale:LC_ALL=C" "UTF-8:LC_ALL=C.UTF-8" "forced ASCII:TASKSENSE_ASCII=1"; do
    name="${locale_case%%:*}"
    env_setting="${locale_case#*:}"
    if [ -n "${env_setting}" ]; then
      out="$(render "${image}" -e "${env_setting}")"
    else
      out="$(render "${image}")"
    fi

    # U+FFFD, what a terminal prints for a byte it cannot decode.
    replacements="$(printf '%s' "${out}" | grep -c $'\xef\xbf\xbd' || true)"
    check "${name}: no replacement characters" "0" "${replacements}"

    # The frame: every line of the box must be the same width. Byte-counting
    # padding shows up here as a short line, and nowhere else.
    #
    # Counted in Python because the width that matters is characters, and the
    # obvious tools do not agree on that: `awk length()` and `wc -c` count
    # bytes, so a correctly aligned box of three-byte glyphs reads as three
    # different widths. The first version of this test failed for exactly that
    # reason, against output that was already right.
    # shellcheck disable=SC2016  # a Python program, not a shell string
    count="$(printf '%s' "${out}" | python3 -c '
import re, sys
text = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", sys.stdin.read())
# `l[:1] in chars` is True for an empty line — "" is a substring of
# everything — which counted every blank line as a zero-width frame line.
frame = [l for l in text.splitlines() if l and l[0] in "+|\u2502\u250c\u2514"]
print(len({len(l) for l in frame}) if frame else "no-frame")
')"
    check "${name}: frame lines are all one width" "1" "${count}"
  done
done

printf '\n  what it looks like with no locale at all:\n\n'
render redhat/ubi9-minimal | sed 's/\x1b\[[0-9;]*m//g' | sed 's/^/    /'

printf '\n  %s passed, %s failed\n\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
