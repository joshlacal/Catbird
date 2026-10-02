#!/usr/bin/env bash
# Isolated encrypted-request presentation validation; never authenticates.
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASK_BUILD="$TASK_ROOT/../.builds/t09-macos"
TASK_APP="$TASK_BUILD/Build/Products/Debug/Catbird.app"
TASK_MODE="${1:---verify}"
case "$TASK_MODE" in run|--verify|--logs|--telemetry|--debug) ;; *) echo "usage: $0 [run|--verify|--logs|--telemetry|--debug]" >&2; exit 2;; esac
# Stop only this isolated build's process, never an installed Catbird instance.
python3 - "$TASK_APP/Contents/MacOS/Catbird" <<'PY'
import os,signal,subprocess,sys
executable=sys.argv[1]
for line in subprocess.check_output(['ps','-axo','pid=,command='],text=True).splitlines():
    fields=line.strip().split(None,1)
    if len(fields)==2 and (fields[1]==executable or fields[1].startswith(executable+' ')):
        os.kill(int(fields[0]),signal.SIGTERM)
PY
export CATBIRD_MLS_LOCAL_INTEGRATION=1
export CATBIRD_MLS_FFI_PATH="$TASK_ROOT/../CatbirdMLSCore/Sources/CatbirdMLSFFI.xcframework"
xcodebuild -project "$TASK_ROOT/Catbird.xcodeproj" -scheme Catbird -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$TASK_BUILD" \
  CODE_SIGNING_ALLOWED=NO build
if [[ "$TASK_MODE" == --debug ]]; then
  exec lldb -- "$TASK_APP/Contents/MacOS/Catbird" --encrypted-request-ui-fixture
fi
open -n "$TASK_APP" --args --encrypted-request-ui-fixture
case "$TASK_MODE" in
  --logs|--telemetry) exec /usr/bin/log stream --info --style compact --predicate 'process == "Catbird" AND subsystem == "blue.catbird"' ;;
  --verify)
    sleep 2
    python3 - "$TASK_APP/Contents/MacOS/Catbird" <<'PY'
import subprocess,sys
expected=sys.argv[1]
commands=subprocess.check_output(['ps','-axo','command='],text=True).splitlines()
if not any(command==expected or command.startswith(expected+' ') for command in commands):
    raise SystemExit('Isolated Catbird fixture did not remain running')
print('Isolated Catbird fixture process is running; capture its window for visual verification.')
PY
    ;;
esac
