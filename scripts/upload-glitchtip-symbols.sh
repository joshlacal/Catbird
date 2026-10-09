#!/usr/bin/env bash
# Manual operator tool. Never add this script to an Xcode build phase.
set -euo pipefail
umask 077
refuse() { printf '%s\n' "$1" >&2; exit 2; }
[[ $# == 3 && "$1" == --upload && "${CATBIRD_GLITCHTIP_MANUAL_SYMBOL_UPLOAD:-}" == 1 ]] ||
  refuse 'Manual opt-in required: CATBIRD_GLITCHTIP_MANUAL_SYMBOL_UPLOAD=1 upload-glitchtip-symbols.sh --upload /Release/Catbird.app /matching.dSYM/Contents/Resources/DWARF/Catbird'
[[ -z "${XCODE_VERSION_ACTUAL:-}${XCODE_PRODUCT_BUILD_VERSION:-}${PROJECT_FILE_PATH:-}${TARGET_BUILD_DIR:-}" ]] ||
  refuse 'Refusing an Xcode build environment; symbol upload is a separate manual action.'
: "${SENTRY_URL:?Supply the approved GlitchTip base URL without credentials}"
: "${SENTRY_ORG:?Supply the approved organization slug}"
: "${SENTRY_PROJECT:?Supply the approved project slug}"
: "${SENTRY_AUTH_TOKEN:?Supply a short-lived approved token through the process environment}"
: "${CATBIRD_APPROVED_SENTRY_CLI_VERSION:?Supply the independently reviewed sentry-cli version}"
# GlitchTip v6.2.6 APIToken.generate_token is 32 random bytes encoded as lowercase hex.
# Structured Sentry organization tokens can carry a URL that overrides --url.
python3 - <<'PY'
import os, re
if not re.fullmatch(r'[0-9a-f]{64}', os.environ.get('SENTRY_AUTH_TOKEN', '')):
    raise SystemExit('Only an approved opaque GlitchTip API token is accepted; structured or unknown token formats are prohibited.')
PY
export SENTRY_DISABLE_UPDATE_CHECK=1
app=$2
dwarf=$3
[[ -d "$app" && "$app" == *.app && -f "$dwarf" && "$dwarf" == *.dSYM/Contents/Resources/DWARF/* ]] ||
  refuse 'Supply exactly one app bundle and its matching app DWARF file; archives and source bundles are not accepted.'
command -v sentry-cli >/dev/null || refuse 'The reviewed chunk-capable sentry-cli is not installed.'
[[ "$(sentry-cli --version)" == "sentry-cli $CATBIRD_APPROVED_SENTRY_CLI_VERSION" ]] ||
  refuse 'Installed sentry-cli does not match the explicitly reviewed version.'
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
python3 - "$app" "$dwarf" "$scratch/binary-path" <<'PY'
import ipaddress, os, plistlib, re, sys
from pathlib import Path
from urllib.parse import urlsplit

def require(condition, message):
    if not condition:
        raise SystemExit(message)

app, dwarf, output = map(Path, sys.argv[1:])
info_path = app / 'Contents/Info.plist' if (app / 'Contents/Info.plist').is_file() else app / 'Info.plist'
info = plistlib.loads(info_path.read_bytes())
require(info.get('CATBIRD_TELEMETRY_BACKEND') == 'glitchtip', 'App must explicitly select the own-server backend.')
host = info.get('CATBIRD_GLITCHTIP_ALLOWED_HOST', '')
require(isinstance(host, str) and host == host.strip() and len(host) <= 253, 'Missing or malformed app-approved host.')
host = host.lower()
require(bool(re.fullmatch(r'[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?', host)), 'App-approved host must be an exact hostname.')
require(all(label and len(label) <= 63 and not label.startswith('-') and not label.endswith('-') for label in host.split('.')), 'Invalid hostname label.')
require(not host.endswith('.localhost'), 'Loopback aliases are not approved; use the exact private localhost host.')
numeric_address = all(re.fullmatch(r'(?:[0-9]+|0x[0-9a-f]+)', label) for label in host.split('.'))
try:
    address = ipaddress.IPv4Address(host)
except ipaddress.AddressValueError:
    address = None
require(not numeric_address or address is not None, 'Short, integer, octal and hex IP aliases are prohibited.')
require(not any(host == denied or host.endswith('.' + denied) for denied in ('sentry.io', 'sentry.dev', 'getsentry.com')), 'Hosted Sentry destinations are prohibited.')
raw = os.environ['SENTRY_URL']
require(raw == raw.strip() and '%' not in raw and not any(c.isspace() or ord(c) < 32 for c in raw), 'Invalid upload origin.')
url = urlsplit(raw)
require(url.hostname == host and url.username is None and url.password is None and '?' not in raw and '#' not in raw and url.path in ('', '/'), 'Upload origin must exactly match the app-approved host; credentials and path prefixes are prohibited.')
require(not url.netloc.endswith(':') and (url.port is None or 1 <= url.port <= 65535), 'Invalid upload port.')
loopback = host == 'localhost' or (address is not None and address.is_loopback)
require((not loopback and url.scheme == 'https') or (loopback and url.scheme in ('http', 'https') and os.environ.get('CATBIRD_GLITCHTIP_ALLOW_LOOPBACK_SYMBOL_UPLOAD') == '1'), 'HTTPS is required; a private loopback pilot needs a separate explicit operator opt-in.')
for key in ('SENTRY_ORG', 'SENTRY_PROJECT'):
    require(bool(re.fullmatch(r'[A-Za-z0-9_-]+', os.environ[key])), 'Invalid organization/project slug.')
executable = info.get('CFBundleExecutable')
require(isinstance(executable, str) and executable and Path(executable).name == executable, 'Invalid app executable name.')
binary = app / 'Contents/MacOS' / executable if (app / 'Contents/Info.plist').is_file() else app / executable
require(binary.is_file() and dwarf.name == executable, 'The app executable and selected DWARF basename must match.')
output.write_text(str(binary))
PY
binary=$(cat "$scratch/binary-path")
xcrun dwarfdump --uuid "$binary" > "$scratch/binary"
xcrun dwarfdump --uuid "$dwarf" > "$scratch/symbols"
python3 - "$scratch/binary" "$scratch/symbols" <<'PY'
import re, sys
from pathlib import Path
def identities(path):
    return {(uuid.lower(), arch) for uuid, arch in re.findall(r'UUID: ([0-9A-Fa-f-]+) \(([^)]+)\)', Path(path).read_text())}
binary, symbols = map(identities, sys.argv[1:])
if not binary or binary != symbols:
    raise SystemExit('Binary and dSYM UUID/architecture sets must match exactly.')
PY
# No login, source-context flag, source bundle, app executable, or whole archive upload.
# The validated opaque token cannot carry a URL override; it stays in the environment.
unset SENTRY_DSN
if ! sentry-cli --url "$SENTRY_URL" debug-files upload --org "$SENTRY_ORG" --project "$SENTRY_PROJECT" \
  --type dsym --no-sources --wait "$dwarf" > "$scratch/upload.stdout" 2> "$scratch/upload.stderr"; then
  refuse 'Symbol upload failed. Command output is withheld because it may include sensitive routing details.'
fi
printf '%s\n' 'Upload command returned; server readiness remains UNVERIFIED. Independently confirm assembled UUID, architecture, and artifact identity before triggering any crash. No event was sent by this script.'
# Deliberately nonzero: a successful CLI exit alone must never be treated as qualification.
exit 3
