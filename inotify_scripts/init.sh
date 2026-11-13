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

# Sweep only once the database answers; a load before that fails.
i=0
until python3 -c 'import sys, psycopg2; sys.path.insert(0, "/scripts"); import ingest_file_h360tk as m; psycopg2.connect(**m.DB_CONNECTION_PARAMS).close()' >/dev/null 2>&1; do
    i=$((i + 1))
    if [ "$i" -ge 60 ]; then echo "[$(date -Iseconds)] sweep: database still down after 120s, sweeping anyway"; break; fi
    sleep 2
done
[ "$i" -lt 60 ] && echo "[$(date -Iseconds)] sweep: database answered after about $((i * 2))s"

swept=0
for f in "${INOTIFY_TARGET:-/data}"/*; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in .*|'~$'*) continue ;; esac  # hidden and Excel lock files
    echo "[$(date -Iseconds)] sweep: $f was here before the watcher"
    bash "${INOTIFY_SCRIPT:-/scripts/fileproc.sh}" "$(date +%H:%M:%S)" "$(dirname "$f")/" SWEEP "$(basename "$f")"
    swept=$((swept + 1))
done
echo "[$(date -Iseconds)] watcher ready, swept $swept file(s)"

wait "$watcher"
