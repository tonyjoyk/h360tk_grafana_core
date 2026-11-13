#!/bin/bash

# $1 --> timestamp
# $2 --> watched file/directory path
# $3 --> event name(s), or SWEEP when init.sh found the file at start
# $4 --> filename (if a directory is monitored)

echo $1 $2 $3 $4

FULL_PATH="${2}${4}"

if [ ! -f "$FULL_PATH" ]; then
    echo "Info: '$FULL_PATH' is not a regular file or does not exist. Exiting."
    exit 0
fi

# One marker per file name, holding the size and mtime last ingested. A file
# already ingested at the same size and time is skipped, so the start-up sweep
# and repeated modify events do not ingest the same bytes twice.
STATE_DIR="${H360TK_INGEST_STATE:-/grafana_target/.h360_ingested}"
# One load per file at a time: the sweep and an inotify event can fire together.
mkdir -p "$STATE_DIR"
exec 9>"$STATE_DIR/$(basename "$FULL_PATH").lock"
flock 9
SIG="$(stat -c '%s %Y' "$FULL_PATH" 2>/dev/null)"
MARKER="$STATE_DIR/$(basename "$FULL_PATH").done"
if [ -n "$SIG" ] && [ -f "$MARKER" ] && [ "$(cat "$MARKER")" = "$SIG" ]; then
    echo "Info: '$FULL_PATH' already ingested ($SIG). Skipping."
    exit 0
fi

echo "We got a file !! $FULL_PATH"

python3 "${H360TK_DATA_LOAD_SCRIPT}" "$FULL_PATH"
status=$?

# Record the file only if it did not change while it was being read.
if [ "$status" -eq 0 ] && [ -n "$SIG" ] && [ "$(stat -c '%s %Y' "$FULL_PATH" 2>/dev/null)" = "$SIG" ]; then
    echo "$SIG" > "$MARKER"
fi
exit "$status"
