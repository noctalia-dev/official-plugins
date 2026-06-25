#!/bin/sh
# Long-lived mpvpaper supervisor. The service launches exactly one of these (via
# noctalia.runStream) and drives it with newline commands written to a FIFO:
#
#   set <connector> <video-path>   start/replace mpvpaper on that output
#   clear <connector>              stop mpvpaper on that output
#   clear-all                      stop every mpvpaper
#
# The supervisor and every mpvpaper it starts share one process group, so when the
# service is reloaded or noctalia exits, the host's SIGTERM to the group tears the
# whole tree down. The EXIT trap is a second line of defence.

FIFO="$1"        # command FIFO path
MPVPAPER_FLAGS="$2" # e.g. "--auto-pause"
MPV_OPTS="$3"    # mpv -o option string, e.g. "loop-file=inf no-audio hwdec=auto"

pids="" # space-separated "connector=pid" entries

kill_for() {
  conn="$1"
  next=""
  for entry in $pids; do
    if [ "${entry%%=*}" = "$conn" ]; then
      kill "${entry##*=}" 2>/dev/null
    else
      next="$next $entry"
    fi
  done
  pids="$next"
}

kill_all() {
  for entry in $pids; do
    kill "${entry##*=}" 2>/dev/null
  done
  pids=""
}

trap 'kill_all; rm -f "$FIFO"; exit 0' INT TERM EXIT

rm -f "$FIFO"
mkfifo "$FIFO" || exit 1

# Hold the FIFO open for writing too, so reads block on an empty pipe instead of
# spinning on EOF between commands.
exec 3<>"$FIFO"

while IFS= read -r line <&3; do
  cmd=${line%% *}
  rest=${line#* }
  case "$cmd" in
    set)
      conn=${rest%% *}
      path=${rest#* }
      [ -n "$conn" ] && [ "$conn" != "$rest" ] && [ -n "$path" ] || continue
      kill_for "$conn"
      # shellcheck disable=SC2086
      mpvpaper $MPVPAPER_FLAGS -o "$MPV_OPTS" "$conn" "$path" <&- >/dev/null 2>&1 &
      pids="$pids $conn=$!"
      ;;
    clear)
      kill_for "$rest"
      ;;
    clear-all)
      kill_all
      ;;
    quit)
      break
      ;;
  esac
done

kill_all
rm -f "$FIFO"
