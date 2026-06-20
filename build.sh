#!/bin/bash
# Regenerate pixel.sh from pixel.py.
#
# pixel.sh is the deployed artifact (copied to the MiSTer). It's a thin bash
# wrapper that feeds a VERBATIM copy of pixel.py to python3 on fd 3, so stdin
# stays free for the MiSTer launcher's key prompt. Because the Python source is
# embedded, pixel.sh must be regenerated after every edit to pixel.py.
#
# Usage:  ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -f pixel.py ]; then
  echo "error: pixel.py not found next to build.sh" >&2
  exit 1
fi
# A bare 'PYEOF' line in pixel.py would close the heredoc early and corrupt the
# wrapper — refuse rather than emit a broken pixel.sh.
if grep -qx 'PYEOF' pixel.py; then
  echo "error: pixel.py contains a line 'PYEOF' that would break the heredoc" >&2
  exit 1
fi

{
  # The 9-line bash header (quoted heredoc -> emitted verbatim, no expansion).
  cat <<'HEADER'
#!/bin/bash
# PIXEL - MiSTer FPGA frame capture client
# Usage: ./pixel.sh [-a HOST:PORT] [--restart] [--stop]
# Wraps pixel.py so it can be copy-pasted to the MiSTer and run with no
# separate .py file. The script body is fed to python on fd 3 (not stdin), so
# stdin stays connected to the keyboard for the launcher key prompt. Body below
# is a verbatim copy of pixel.py — regenerate with ./build.sh after editing it.
export PIXEL_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 /dev/fd/3 "$@" 3<< 'PYEOF'
HEADER
  cat pixel.py
  printf 'PYEOF\n'
} > pixel.sh

chmod +x pixel.sh
echo "pixel.sh regenerated from pixel.py ($(wc -l < pixel.sh | tr -d ' ') lines)"