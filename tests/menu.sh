#!/usr/bin/env bash
#
# The menu redraws itself in place. That only works if it moves the cursor back
# by exactly as many lines as it printed.
#
#   tests/menu.sh
#
# Get it wrong by one and nothing errors: the menu simply walks up the screen,
# one line per keypress, eating the title and then whatever the installer said
# before it. Six arrow presses and the terminal is a mess of overlapping text.
# That is what a customer reported, and no assertion we had could have seen it —
# the bytes are all still in the stream, and it is only wrong once a terminal
# has interpreted them.
#
# So this interprets them. The model below is about thirty lines and handles
# only what ui_menu emits: newline, carriage return, cursor-up, erase-line and
# erase-screen. It is not a terminal emulator; it is enough of one to see the
# bug.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for tool in docker python3; do
  command -v "${tool}" >/dev/null 2>&1 || { printf '\n  SKIPPED: %s is not installed\n\n' "${tool}"; exit 0; }
done

printf '\nmenu redraw\n\n'

python3 - "${ROOT}" <<'PY'
import os, pty, re, subprocess, sys, time

root = sys.argv[1]

# ── a screen, not a byte stream ──────────────────────────────────────────────
class Screen:
    def __init__(self): self.rows, self.r, self.c = [""], 0, 0
    def _fit(self, n):
        while len(self.rows) <= n: self.rows.append("")
    def write(self, text):
        i = 0
        while i < len(text):
            ch = text[i]
            if ch == "\x1b":
                m = re.match(r"\x1b\[([0-9;?]*)([a-zA-Z])", text[i:])
                if not m: i += 1; continue
                arg, cmd = m.group(1), m.group(2)
                n = int(arg) if arg.isdigit() else 1
                if cmd == "A": self.r = max(0, self.r - n)
                elif cmd == "B": self.r += n; self._fit(self.r)
                elif cmd == "K": self.rows[self.r] = self.rows[self.r][: self.c]
                elif cmd == "J": self.rows, self.r, self.c = [""], 0, 0
                elif cmd == "H": self.r = self.c = 0
                i += m.end(); continue
            if ch == "\n": self.r += 1; self._fit(self.r); self.c = 0
            elif ch == "\r": self.c = 0
            else:
                line = self.rows[self.r]
                if len(line) < self.c: line += " " * (self.c - len(line))
                self.rows[self.r] = line[: self.c] + ch + line[self.c + 1 :]
                self.c += 1
            i += 1
    def text(self): return "\n".join(self.rows)

# ── drive the menu ───────────────────────────────────────────────────────────
script = r'''
. scripts/lib.sh
. scripts/ui.sh
printf 'BEFORE-THE-MENU\n'
ui_menu "Where will TaskSense run?" "Docker Compose|one VM, the usual answer" "Kubernetes|an existing cluster" "OpenShift|the same chart plus an overlay" "Nomad|for the sake of a fourth"
printf 'CHOSE=%s\n' "$UI_CHOICE"
'''
cmd = ["docker", "run", "--rm", "-i", "-t", "-v", f"{root}:/w", "-w", "/w",
       "-e", "TERM=xterm", "bash:5", "bash", "-c", script]

primary, secondary = pty.openpty()
proc = subprocess.Popen(cmd, stdin=secondary, stdout=secondary, stderr=secondary, close_fds=True)
os.close(secondary)
os.set_blocking(primary, False)

raw = bytearray()
def drain(idle=0.7, limit=40):
    last, end = time.time(), time.time() + limit
    while time.time() - last < idle and time.time() < end:
        try:
            chunk = os.read(primary, 65536)
            if chunk: raw.extend(chunk); last = time.time(); continue
        except (BlockingIOError, OSError): pass
        if proc.poll() is not None: break
        time.sleep(0.05)

drain()
# Six down-arrows on a four-item menu: lands on the third, and redraws six times.
for _ in range(6):
    os.write(primary, b"\x1b[B"); drain(0.35)
os.write(primary, b"\r"); drain(1.0)
proc.wait(timeout=30)

screen = Screen(); screen.write(raw.decode(errors="replace"))
visible = screen.text()
plain = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", visible)

failures = []
def check(name, ok, detail=""):
    if ok: print(f"  \033[32m✓\033[0m {name}")
    else:
        print(f"  \033[31m✗\033[0m {name}"); print(f"      {detail}"); failures.append(name)

# What the drift destroys, in the order it destroys it.
check("the line printed before the menu survives six keypresses",
      "BEFORE-THE-MENU" in plain,
      "the menu walked up over it — cursor-up exceeds the lines printed")
check("the menu's own title survives",
      "Where will TaskSense run?" in plain,
      "the first thing the drift eats")
check("every option is still readable",
      all(o in plain for o in ("Docker Compose", "Kubernetes", "OpenShift", "Nomad")),
      "options overwrote each other")
check("no option appears twice on the screen",
      plain.count("Nomad") == 1,
      f"'Nomad' appears {plain.count('Nomad')} times — stale rows were left behind")
check("six downs from the first item select the third",
      "CHOSE=3" in plain,
      f"got {re.findall(r'CHOSE=[0-9]*', plain)}")

# The arithmetic itself, so a failure says which number is wrong.
ups = sorted({int(n) for n in re.findall(r"\x1b\[(\d+)A", raw.decode(errors='replace'))})
check("cursor-up matches the four options plus the hint line",
      ups == [5], f"moved up {ups}, expected [5] for a 4-item menu")

print(f"\n  {6 - len(failures)} passed, {len(failures)} failed\n")
sys.exit(1 if failures else 0)
PY
