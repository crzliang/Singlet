#!/usr/bin/env bash
# Dry-run: generate the same AppleScript shape HelperInstaller uses and
# verify `osascript` can *parse* it (compile check). Does NOT prompt for password
# when using -c / syntax-only via a no-op script path that never runs with admin
# if we only compile — here we use `osascript -e` with a compile-friendly form.
set -euo pipefail

TMP="$(mktemp -t singlet-helper-dry.XXXXXX).sh"
trap 'rm -f "$TMP"' EXIT
cat >"$TMP" <<'EOF'
#!/bin/bash
echo dry-run-ok
EOF
chmod 700 "$TMP"

# Mirror HelperInstaller.buildAdminAppleScript:
#   do shell script "/bin/bash " & quoted form of "<path>" with administrator privileges
AS="do shell script \"/bin/bash \" & quoted form of \"${TMP}\" with administrator privileges"

echo "=== Generated AppleScript ==="
echo "$AS"
echo

echo "=== Parse / compile check (osascript -c via temporary .applescript) ==="
ASFILE="$(mktemp -t singlet-helper-as.XXXXXX).applescript"
trap 'rm -f "$TMP" "$ASFILE"' EXIT
printf '%s\n' "$AS" >"$ASFILE"

# `osascript -c` isn't universal; use Language Syntax check via osacompile -c equivalent:
# Compiling to /dev/null validates syntax without executing.
if ! osacompile -o /tmp/singlet-helper-dry.scpt "$ASFILE" 2>/tmp/singlet-helper-dry.err; then
  echo "COMPILE FAILED:" >&2
  cat /tmp/singlet-helper-dry.err >&2
  exit 1
fi
rm -f /tmp/singlet-helper-dry.scpt /tmp/singlet-helper-dry.err
echo "AppleScript syntax OK"

echo
echo "=== OLD broken form (bash single quotes) — expect syntax error ==="
BAD="do shell script '${TMP}' with administrator privileges"
BADFILE="$(mktemp -t singlet-helper-bad.XXXXXX).applescript"
printf '%s\n' "$BAD" >"$BADFILE"
if osacompile -o /tmp/singlet-helper-bad.scpt "$BADFILE" 2>/tmp/singlet-helper-bad.err; then
  echo "unexpected: bad form compiled" >&2
  exit 2
fi
echo "As expected, bad form fails:"
cat /tmp/singlet-helper-bad.err
rm -f /tmp/singlet-helper-bad.scpt /tmp/singlet-helper-bad.err "$BADFILE"
echo
echo "Dry-run passed."
