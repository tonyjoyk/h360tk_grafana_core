echo "Doing the init ..."

# Install the ingest dependencies only when they are missing, so a restart
# reaches the watcher in seconds instead of re-installing pandas (R-02).
if ! python3 -c 'import pandas, openpyxl, psycopg2, python_calamine' >/dev/null 2>&1; then
    apk update
    apk upgrade
    apk add python3 py3-pip
    pip install --break-system-packages pandas openpyxl psycopg2-binary python-calamine
fi

# Start the watcher first, then sweep files that were already in the folder
# before it started (R-02: a file copied during the install fired no event).
# fileproc.sh skips a file it has already ingested at the same size and time,
# so a file seen by both the sweep and the watcher is ingested once.
bash /docker-entrypoint.sh inotify-script &
watcher=$!

i=0
while [ "$i" -lt 30 ] && ! pgrep -x inotifywait >/dev/null 2>&1; do
    sleep 1
    i=$((i + 1))
done
sleep 1

swept=0
for f in "${INOTIFY_TARGET:-/data}"/*; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in .*) continue ;; esac
    echo "[$(date -Iseconds)] sweep: $f was here before the watcher"
    bash "${INOTIFY_SCRIPT:-/scripts/fileproc.sh}" "$(date +%H:%M:%S)" "$(dirname "$f")/" SWEEP "$(basename "$f")"
    swept=$((swept + 1))
done
echo "[$(date -Iseconds)] watcher ready, swept $swept file(s)"

wait "$watcher"
