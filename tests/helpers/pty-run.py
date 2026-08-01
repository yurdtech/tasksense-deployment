"""Run ensure_registry_login in a container, through a real terminal.

    pty-run.py <repo-root> <config-has-ghcr: yes|no> <answer>

Prints what the operator would have seen, with the escape sequences removed.

A pty rather than a pipe because the code under test refuses a pipe deliberately
— a question asked into one is a question nobody can answer, and waiting on it
reads as a hang rather than as a mistake. Feeding it through a terminal is the
only way to exercise the branch a person actually takes.
"""

import os
import pty
import re
import subprocess
import sys
import time

root, has, answer = sys.argv[1], sys.argv[2], sys.argv[3]

# A docker that answers the way a real one does at this point: logout always
# works, and login succeeds — which is the whole point of the bug being tested.
INNER = r"""
set -uo pipefail
export HOME=/tmp/home
mkdir -p "${HOME}/.docker" /tmp/bin

{
  echo '#!/usr/bin/env bash'
  # Recorded rather than printed: the installer sends `docker logout` to
  # /dev/null on purpose — it is noise to an operator — so asserting on the
  # transcript would be asserting on something deliberately hidden. The call
  # itself is the thing under test.
  echo 'echo "$*" >> /tmp/docker-calls'
  echo 'case "$1" in'
  echo '  compose) [ "$2" = version ] && exit 0 ;;'
  echo '  logout)  echo "Removing login credentials"; exit 0 ;;'
  echo '  login)   echo "Login Succeeded"; exit 0 ;;'
  echo 'esac'
  echo 'exit 0'
} > /tmp/bin/docker
chmod +x /tmp/bin/docker
export PATH=/tmp/bin:$PATH
: > /tmp/docker-calls

if [ "${HAS}" = "yes" ]; then
  printf '{"auths":{"ghcr.io":{"auth":"c3R1Yg=="}}}' > "${HOME}/.docker/config.json"
else
  printf '{"auths":{}}' > "${HOME}/.docker/config.json"
fi

. scripts/lib.sh
detect_runtime
ensure_registry_login
printf '\n--- docker calls ---\n'
cat /tmp/docker-calls
"""

cmd = [
    "docker", "run", "--rm", "-i", "-t",
    "-v", f"{root}:/w:ro", "-w", "/w",
    "-e", f"HAS={has}",
    "bash:5", "bash", "-c", INNER,
]

primary, secondary = pty.openpty()
proc = subprocess.Popen(cmd, stdin=secondary, stdout=secondary, stderr=secondary, close_fds=True)
os.close(secondary)
os.set_blocking(primary, False)

buf = bytearray()


def drain(idle: float = 0.6, limit: float = 40) -> None:
    """Read until it stops printing, i.e. until it is waiting for an answer."""
    last, end = time.time(), time.time() + limit
    while time.time() - last < idle and time.time() < end:
        try:
            chunk = os.read(primary, 65536)
            if chunk:
                buf.extend(chunk)
                last = time.time()
                continue
        except (BlockingIOError, OSError):
            pass
        if proc.poll() is not None:
            break
        time.sleep(0.05)


# The replace-it answer, then a username (Enter takes the default) and a token.
# Enough answers for the longest path. A shorter one exits early and the pty
# goes away mid-write; that is the run ending, not a failure, so it is caught
# rather than allowed to abort before the transcript is printed.
for line in (f"{answer}\n", "\n", "some-token\n"):
    if proc.poll() is not None:
        break
    drain()
    try:
        os.write(primary, line.encode())
    except OSError:
        break
drain(idle=1.2)

try:
    proc.wait(timeout=20)
except subprocess.TimeoutExpired:
    proc.kill()

print(re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", buf.decode(errors="replace")))
