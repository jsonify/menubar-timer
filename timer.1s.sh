#!/bin/bash
# <xbar.title>Menu Bar Timer</xbar.title>
# <xbar.version>v3.1</xbar.version>
# <xbar.author>Jason Rueckert</xbar.author>
# <xbar.author.github>jsonify</xbar.author.github>
# <xbar.desc>Countdown timer that rings and grabs focus when it's done. Inspired by fferri/bitbar-countdown-timer.</xbar.desc>
# <xbar.dependencies>bash,osascript</xbar.dependencies>
# <xbar.abouturl>https://github.com/jsonify/menubar-timer</xbar.abouturl>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
#
# Pure bash 3.2 + osascript, so it runs on a stock macOS with nothing to install.

# ---- Settings -------------------------------------------------------------
# Presets are "Group: Name=time, Name=time; Group: ...". A time is anything
# Custom… accepts (a bare number is minutes); the name becomes the label.
# Your five most recent timers are listed above these; "" shows recents only.
PRESETS="Focus: 🍅 Pomodoro=25, 🧠 Deep work=50"
SOUND="/System/Library/Sounds/Glass.aiff"       # default alarm; Settings → Alarm sound overrides it
SNOOZE_MIN=5                                    # length of the "Snooze" button
RING_FOR=300                                    # seconds to keep ringing if ignored
FONT="Menlo"                                    # monospaced so the clock doesn't jiggle
SHOW="label"                                    # menu bar: label (◕ Tea 4:59), time (◕ 4:59) or icon (◕)
HOTKEY="CMD+OPTION+T"                           # opens Custom… from any app; "" to turn off
CHECK_UPDATES=1                                 # 0 = never look for a newer version on GitHub
# ---------------------------------------------------------------------------

# Old default lists are carried over by the updater; give those users the current default.
case "$PRESETS" in
  "1 5 10 15 20 25 30 45 60"|"Quick: ☕ Tea=4, 🥚 Soft eggs=7, 🍝 Pasta=10; Focus: 🍅 Pomodoro=25, 🧠 Deep work=50")
    PRESETS="Focus: 🍅 Pomodoro=25, 🧠 Deep work=50" ;;
esac

STATE_DIR="$HOME/Library/Application Support/menubar-timer"
STATE="$STATE_DIR/state"        # line 1: running|paused|ringing  line 2: end epoch or secs left  line 3: label  line 4: total secs
PREFS="$STATE_DIR/prefs"        # KEY=value lines saved by the Settings menu (SOUND, SHOW)
RECENT="$STATE_DIR/recent"      # secs|label lines, newest first, at most 5
ALARM_PID="$STATE_DIR/alarm.pid"
UPDATE_FILE="$STATE_DIR/update" # line 1: epoch of last check  line 2: newest version on GitHub
UPDATE_URL="https://raw.githubusercontent.com/jsonify/menubar-timer/main/timer.1s.sh"
CHECK_EVERY=86400               # seconds between update checks
SELF="$0"
DONE_TEXT="Time's up!"
mkdir -p "$STATE_DIR"

# Choices made in the Settings menu win over the defaults above.
load_prefs() {
  local k v
  [ -f "$PREFS" ] || return 0
  while IFS='=' read -r k v; do
    case "$k" in
      SOUND) SOUND=$v ;;
      SHOW)  SHOW=$v ;;
    esac
  done < "$PREFS"
}

set_pref() {  # key value
  { [ -f "$PREFS" ] && grep -v "^$1=" "$PREFS"; printf '%s=%s\n' "$1" "$2"; } > "$PREFS.tmp" && mv -f "$PREFS.tmp" "$PREFS"
}

load_prefs

now() { date +%s; }

fmt() {   # seconds -> M:SS or H:MM:SS
  local t=$1 h m s
  h=$((t / 3600)); m=$((t % 3600 / 60)); s=$((t % 60))
  if [ "$h" -gt 0 ]; then printf '%d:%02d:%02d' "$h" "$m" "$s"; else printf '%d:%02d' "$m" "$s"; fi
}

clock() {  # epoch -> local wall-clock time (BSD date first, GNU fallback for testing)
  date -r "$1" '+%-I:%M %p' 2>/dev/null || date -d "@$1" '+%-I:%M %p'
}

dur_text() {  # seconds -> "4 min", "1 hr 30 min", "1 min 30 sec"
  local t=$1 h m s out=""
  h=$((t / 3600)); m=$((t % 3600 / 60)); s=$((t % 60))
  [ "$h" -gt 0 ] && out="$h hr"
  [ "$m" -gt 0 ] && out="${out:+$out }$m min"
  [ "$s" -gt 0 ] && out="${out:+$out }$s sec"
  printf '%s' "${out:-0 sec}"
}

write_state() { printf '%s\n%s\n%s\n%s\n' "$1" "$2" "$3" "$4" > "$STATE"; }

read_state() {
  MODE=""; VALUE=""; LABEL=""; TOTAL=""
  [ -f "$STATE" ] || return 1
  { read -r MODE; read -r VALUE; read -r LABEL; read -r TOTAL; } < "$STATE"
  case "$TOTAL" in ''|*[!0-9]*) TOTAL=0 ;; esac   # state files from v2 have no total
  [ -n "$MODE" ]
}

# Parse "25", "25m", "1h30m", "90s", "1h 15m", "10:00", "1:30:00" from the
# front of the input. Sets SECS to the duration and REST to whatever text
# follows (used as the label). Bare numbers are minutes.
parse_time() {
  local in rest="" tok n unit total=0 matched=0
  in=$(printf '%s' "$1" | sed -e 's/^[[:space:]]*//')
  if [[ $in =~ ^([0-9]+):([0-9]{1,2})(:([0-9]{1,2}))?([[:space:]]+(.*))?$ ]]; then
    if [ -n "${BASH_REMATCH[4]}" ]; then
      total=$(( 10#${BASH_REMATCH[1]} * 3600 + 10#${BASH_REMATCH[2]} * 60 + 10#${BASH_REMATCH[4]} ))
    else
      total=$(( 10#${BASH_REMATCH[1]} * 60 + 10#${BASH_REMATCH[2]} ))
    fi
    SECS=$total; REST=${BASH_REMATCH[6]}
    [ "$SECS" -gt 0 ]; return
  fi
  while [[ $in =~ ^([0-9]+)[[:space:]]*([A-Za-z]*)([[:space:]]+|$)(.*)$ ]]; do
    n=$((10#${BASH_REMATCH[1]})); unit=$(printf '%s' "${BASH_REMATCH[2]}" | tr 'A-Z' 'a-z')
    rest=${BASH_REMATCH[4]}
    case "$unit" in
      h|hr|hrs|hour|hours)            total=$((total + n * 3600)) ;;
      m|min|mins|minute|minutes|"")   total=$((total + n * 60)) ;;
      s|sec|secs|second|seconds)      total=$((total + n)) ;;
      *) total=$((total + n * 60)); rest="${BASH_REMATCH[2]}${BASH_REMATCH[3]}$rest"; matched=1; in=$rest; break ;;   # "15 Tea" = 15 min, label "Tea"
    esac
    matched=1; in=$rest
  done
  # Also allow glued units like "1h30m"
  if [ $matched -eq 0 ] && [[ $in =~ ^(([0-9]+)h)?(([0-9]+)m)?(([0-9]+)s)?([[:space:]]+(.*))?$ ]] && [ -n "${BASH_REMATCH[1]}${BASH_REMATCH[3]}${BASH_REMATCH[5]}" ]; then
    total=$(( 10#${BASH_REMATCH[2]:-0} * 3600 + 10#${BASH_REMATCH[4]:-0} * 60 + 10#${BASH_REMATCH[6]:-0} ))
    matched=1; in=${BASH_REMATCH[8]}
  fi
  SECS=$total; REST=$in
  [ $matched -eq 1 ] && [ "$SECS" -gt 0 ]
}

clean_label() { printf '%s' "$1" | tr -d '|"\n\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

start_timer() {  # seconds [label]
  stop_alarm
  write_state running $(( $(now) + $1 )) "$(clean_label "$2")" "$1"
  record_recent "$1" "$(clean_label "$2")"
}

record_recent() {  # seconds label
  local line="$1|$2"
  { echo "$line"; [ -f "$RECENT" ] && grep -vxF -- "$line" "$RECENT"; } | head -n 5 > "$RECENT.tmp" && mv -f "$RECENT.tmp" "$RECENT"
}

add_time() {  # seconds (negative subtracts); never leaves less than 1 second
  local left total
  read_state || return 0
  case "$MODE" in
    running) left=$(( VALUE - $(now) + $1 )) ;;
    paused)  left=$(( VALUE + $1 )) ;;
    *)       return 0 ;;
  esac
  [ "$left" -lt 1 ] && left=1
  total=$(( TOTAL + $1 )); [ "$total" -lt "$left" ] && total=$left
  if [ "$MODE" = running ]; then
    write_state running $(( $(now) + left )) "$LABEL" "$total"
  else
    write_state paused "$left" "$LABEL" "$total"
  fi
}

stop_alarm() {
  if [ -f "$ALARM_PID" ]; then
    local pid; pid=$(cat "$ALARM_PID")
    [ -n "$pid" ] && kill "$pid" $(pgrep -P "$pid" 2>/dev/null) 2>/dev/null
    rm -f "$ALARM_PID"
  fi
  pkill -f "afplay $SOUND" 2>/dev/null
}

# AppleScripts are kept in variables (heredocs inside $( ) trip up macOS's bash 3.2).
read -r -d '' ALARM_SCRIPT <<'APPLESCRIPT'
on run argv
  set msg to item 1 of argv
  set snoozeBtn to item 2 of argv
  set waitFor to (item 3 of argv) as integer
  try
    -- Activating System Events pulls the dialog in front of whatever app you're in.
    tell application "System Events"
      activate
      set r to display dialog msg with title "⏰ Timer" buttons {snoozeBtn, "Stop"} default button "Stop" with icon caution giving up after waitFor
    end tell
  on error errMsg number errNum
    -- No Automation permission for System Events yet: fall back to a plain dialog.
    set r to display dialog msg with title "⏰ Timer" buttons {snoozeBtn, "Stop"} default button "Stop" with icon caution giving up after waitFor
  end try
  if gave up of r then return "gaveup"
  return button returned of r
end run
APPLESCRIPT

read -r -d '' ASK_SCRIPT <<'APPLESCRIPT'
tell application "System Events"
  activate
  set r to display dialog "How long? Add a label after the time if you like." & return & return & "Examples:  25m   1h30m   90s   10:00   15 Tea is ready" with title "⏰ New Timer" default answer "25m" buttons {"Cancel", "Start"} default button "Start"
end tell
return text returned of r
APPLESCRIPT

# Runs detached: loops the sound and puts a dialog in front of everything.
ring() {
  local label="${1:-$DONE_TEXT}" sp kids answer
  echo $$ > "$ALARM_PID"
  osascript -e 'display notification "Timer finished" with title "⏰ Timer" sound name "Glass"' >/dev/null 2>&1
  ( while :; do afplay "$SOUND"; sleep 0.3; done ) &
  sp=$!
  answer=$(printf '%s' "$ALARM_SCRIPT" | osascript - "$label" "Snooze $SNOOZE_MIN min" "$RING_FOR" 2>/dev/null)
  kids=$(pgrep -P "$sp" 2>/dev/null)
  kill "$sp" $kids 2>/dev/null
  rm -f "$ALARM_PID"
  case "$answer" in
    Snooze*) read_state; write_state running $(( $(now) + SNOOZE_MIN * 60 )) "$LABEL" $(( SNOOZE_MIN * 60 )) ;;
    *)       rm -f "$STATE" ;;
  esac
}

# ---- Updates ----------------------------------------------------------------
script_version() { sed -n 's/.*<xbar.version>v\{0,1\}\([0-9][0-9.]*\)<\/xbar.version>.*/\1/p' "$1" | head -n 1; }

version_gt() {  # true if dotted version $1 is newer than $2
  local IFS=. i p q
  local -a a=($1) b=($2)
  for ((i = 0; i < ${#a[@]} || i < ${#b[@]}; i++)); do
    p=$((10#${a[i]:-0})); q=$((10#${b[i]:-0}))
    [ "$p" -gt "$q" ] && return 0
    [ "$p" -lt "$q" ] && return 1
  done
  return 1
}

read_update() { LAST_CHECK=0; LATEST=""; [ -f "$UPDATE_FILE" ] && { read -r LAST_CHECK; read -r LATEST; } < "$UPDATE_FILE"; }

check_update() {
  local dl="$STATE_DIR/.check.$$" found prev
  read_update; prev=$LATEST
  curl -fsSL --max-time 15 "$UPDATE_URL" -o "$dl" 2>/dev/null || { rm -f "$dl"; return 1; }
  found=$(script_version "$dl"); rm -f "$dl"
  [ -n "$found" ] || return 1
  printf '%s\n%s\n' "$(now)" "$found" > "$UPDATE_FILE"
  if version_gt "$found" "$(script_version "$SELF")" && [ "$found" != "$prev" ]; then
    osascript -e "display notification \"Version $found is available. Open the timer menu to install it.\" with title \"⏰ Timer\"" >/dev/null 2>&1
  fi
}

# Downloads the newest script and swaps it in place, keeping your Settings block.
install_update() {
  local target="$SELF" link dir dl tmp v
  if [ -L "$target" ]; then   # follow a symlinked plugin to the real file
    link=$(readlink "$target")
    case "$link" in /*) target=$link ;; *) target="$(dirname "$target")/$link" ;; esac
  fi
  dir=$(dirname "$target")
  dl="$STATE_DIR/.download.$$"
  tmp="$dir/.timer-update.$$"   # hidden, so SwiftBar doesn't load it as a plugin
  if ! curl -fsSL --max-time 30 "$UPDATE_URL" -o "$dl" 2>/dev/null; then
    rm -f "$dl"
    osascript -e 'display alert "Couldn'"'"'t download the update" message "Check your internet connection and try again."' >/dev/null 2>&1
    return 1
  fi
  v=$(script_version "$dl")
  if [ "$(head -n 1 "$dl")" != "#!/bin/bash" ] || [ -z "$v" ] || ! bash -n "$dl" 2>/dev/null; then
    rm -f "$dl"
    osascript -e 'display alert "The downloaded update looks broken" message "Your current version was left as it is."' >/dev/null 2>&1
    return 1
  fi
  # Carry over every setting from the current file into the new one.
  awk 'NR == FNR {
         if (/^# ---- Settings/) s = 1
         else if (s && /^# ----/) s = 0
         else if (s && /^[A-Za-z_][A-Za-z_0-9]*=/) { k = $0; sub(/=.*/, "", k); old[k] = $0 }
         next
       }
       /^# ---- Settings/ { t = 1; print; next }
       t && /^# ----/ { t = 0 }
       t && /^[A-Za-z_][A-Za-z_0-9]*=/ { k = $0; sub(/=.*/, "", k); if (k in old) { print old[k]; next } }
       { print }' "$target" "$dl" > "$tmp" && chmod 755 "$tmp" && mv -f "$tmp" "$target"
  local ok=$?
  rm -f "$dl" "$tmp"
  if [ $ok -eq 0 ]; then
    osascript -e "display notification \"Updated to version $v.\" with title \"⏰ Timer\"" >/dev/null 2>&1
  else
    osascript -e 'display alert "Couldn'"'"'t install the update" message "The plugin file could not be replaced."' >/dev/null 2>&1
  fi
  return $ok
}

ask_custom() {
  local reply
  reply=$(printf '%s' "$ASK_SCRIPT" | osascript - 2>/dev/null) || exit 0
  if parse_time "$reply"; then
    start_timer "$SECS" "$REST"
  else
    osascript -e 'display alert "Couldn'"'"'t understand that time" message "Try something like 25m, 1h30m, 90s or 10:00."' >/dev/null 2>&1
  fi
}

# Clicks in the menu run this script again with an argument.
case "$1" in
  start)   case "$2" in ''|*[!0-9]*|0) exit 1 ;; esac; start_timer "$2" "$3"; exit 0 ;;
  snooze)  stop_alarm; write_state running $(( $(now) + SNOOZE_MIN * 60 )) "$(clean_label "$2")" $(( SNOOZE_MIN * 60 )); exit 0 ;;   # not added to recents
  custom)  ask_custom; exit 0 ;;
  ring)    ring "$2"; exit 0 ;;
  stop)    stop_alarm; rm -f "$STATE"; exit 0 ;;
  pause)   read_state && [ "$MODE" = running ] && write_state paused $(( VALUE - $(now) )) "$LABEL" "$TOTAL"; exit 0 ;;
  resume)  read_state && [ "$MODE" = paused ] && write_state running $(( $(now) + VALUE )) "$LABEL" "$TOTAL"; exit 0 ;;
  add)     add_time "$2"; exit 0 ;;
  set-sound) if [ -f "$2" ]; then set_pref SOUND "$2"; nohup afplay "$2" </dev/null >/dev/null 2>&1 & fi; exit 0 ;;   # plays a preview
  set-show)  case "$2" in label|time|icon) set_pref SHOW "$2" ;; esac; exit 0 ;;
  clear-recent) rm -f "$RECENT"; exit 0 ;;
  check-update) check_update; exit $? ;;
  update)  install_update; exit $? ;;
  parse)   parse_time "$2" && echo "$SECS|$REST" || echo "invalid"; exit 0 ;;   # for testing
esac

# ---- Menu bar rendering (runs every second) --------------------------------
action() { printf 'bash="%s" param1=%s' "$SELF" "$1"; shift; local i=2; for p in "$@"; do printf ' param%d="%s"' $i "$p"; i=$((i+1)); done; printf ' terminal=false refresh=true'; }

# Colors are "light menu bar,dark menu bar".
CALM="#0E8F78,#3CCFB0"; SOON="#B86E00,#F2A33A"; LATE="#D93025,#F0605D"
HEADING="size=11 color=gray"

pie() {  # elapsed total -> ○ ◔ ◑ ◕ ●
  local i=0
  [ "$2" -gt 0 ] && i=$(( ($1 * 8 / $2 + 1) / 2 ))
  case $i in 0) printf '○' ;; 1) printf '◔' ;; 2) printf '◑' ;; 3) printf '◕' ;; *) printf '●' ;; esac
}

bar() {  # elapsed total -> ▰▰▰▱▱▱▱▱▱▱
  local n=0 i out=""
  [ "$2" -gt 0 ] && n=$(( $1 * 10 / $2 ))
  for ((i = 0; i < 10; i++)); do if [ $i -lt $n ]; then out="$out▰"; else out="$out▱"; fi; done
  printf '%s' "$out"
}

# Groups split on ";", an optional "Heading:" starts a group, items split on ",".
# A plain "1 5 10" list (the v2 format) still works.
preset_rows() {
  local p="$1" spec=$PRESETS grp head item name first=1
  [[ $spec == *[=,\;:]* ]] || spec=$(printf '%s' "$spec" | sed 's/[[:space:]][[:space:]]*/, /g')
  while IFS= read -r -d ';' grp; do
    head=""
    if [[ $grp =~ ^[[:space:]]*([^:=,]+):(.*)$ ]] && [[ ${BASH_REMATCH[1]} == *[![:digit:][:space:]]* ]]; then
      head=$(clean_label "${BASH_REMATCH[1]}"); grp=${BASH_REMATCH[2]}
    fi
    [ $first -eq 1 ] || echo "${p}---"
    first=0
    [ -n "$head" ] && echo "${p}$(printf '%s' "$head" | tr 'a-z' 'A-Z') | $HEADING"
    while IFS= read -r -d ',' item; do
      name=""
      case "$item" in *=*) name=$(clean_label "${item%%=*}"); item=${item#*=} ;; esac
      parse_time "$item" || continue
      if [ -n "$name" ]; then
        echo "${p}$name · $(dur_text "$SECS") | $(action start "$SECS" "$name")"
      else
        echo "${p}$(dur_text "$SECS") | $(action start "$SECS") sfimage=timer"
      fi
    done <<< "$grp,"
  done <<< "$spec;"
}

launcher() {  # the "start a timer" rows: recents, presets, Custom…
  local p="$1" secs label presets
  if [ -s "$RECENT" ]; then
    echo "${p}RECENT | $HEADING"
    while IFS='|' read -r secs label; do
      case "$secs" in ''|*[!0-9]*) continue ;; esac
      echo "${p}${label:+$label · }$(dur_text "$secs") | $(action start "$secs" "$label") sfimage=arrow.counterclockwise"
    done < "$RECENT"
    echo "${p}---"
  fi
  presets=$(preset_rows "$p")
  [ -n "$presets" ] && { echo "$presets"; echo "${p}---"; }
  echo "${p}Custom… | $(action custom) sfimage=keyboard${HOTKEY:+ shortcut=$HOTKEY}"
}

settings_menu() {
  local f name opt
  echo "Settings | sfimage=gearshape"
  echo "--Alarm sound | sfimage=speaker.wave.2"
  for f in /System/Library/Sounds/*.aiff; do
    [ -e "$f" ] || continue
    name=${f##*/}; name=${name%.aiff}
    echo "----$name | $(action set-sound "$f")$([ "$f" = "$SOUND" ] && printf ' checked=true')"
  done
  echo "--Menu bar shows | sfimage=menubar.rectangle"
  for opt in "label:Label and time" "time:Time only" "icon:Icon only"; do
    echo "----${opt#*:} | $(action set-show "${opt%%:*}")$([ "${opt%%:*}" = "$SHOW" ] && printf ' checked=true')"
  done
  [ -s "$RECENT" ] && echo "--Clear recent timers | $(action clear-recent) sfimage=trash"
}

if read_state; then
  case "$MODE" in
    running)
      left=$(( VALUE - $(now) ))
      if [ "$left" -le 0 ]; then
        write_state ringing 0 "$LABEL" "$TOTAL"
        nohup "$SELF" ring "${LABEL:-$DONE_TEXT}" </dev/null >/dev/null 2>&1 &
        MODE=ringing
      fi ;;
  esac
fi

if [ "$CHECK_UPDATES" = 1 ]; then
  read_update
  if [ $(( $(now) - ${LAST_CHECK:-0} )) -ge "$CHECK_EVERY" ]; then
    printf '%s\n%s\n' "$(now)" "$LATEST" > "$UPDATE_FILE"   # stamp first so we only spawn one check
    nohup "$SELF" check-update </dev/null >/dev/null 2>&1 &
  fi
fi

case "$MODE" in
  running|paused)
    [ "$MODE" = paused ] && left=$VALUE
    [ "$TOTAL" -lt "$left" ] && TOTAL=$left
    elapsed=$(( TOTAL - left ))
    if [ "$MODE" = paused ]; then
      color=gray
    else
      color=$CALM
      [ $(( left * 5 )) -le "$TOTAL" ] && color=$SOON
      [ "$left" -le 10 ] && color=$LATE
    fi
    time=$(fmt "$left")
    case "$SHOW" in
      icon) title="" ;;
      time) title=$time ;;
      *)    title=$time; [ -n "$LABEL" ] && title="$LABEL $time" ;;
    esac
    if [ "$MODE" = paused ]; then
      echo "$title | sfimage=pause.circle font=$FONT color=gray"
    else
      echo "$(pie "$elapsed" "$TOTAL")${title:+ $title} | font=$FONT color=$color"
    fi
    echo "---"
    [ -n "$LABEL" ] && echo "$LABEL | size=12 color=gray"
    echo "$time | font=$FONT size=28 color=$color"
    echo "$(bar "$elapsed" "$TOTAL")  of $(fmt "$TOTAL") | font=$FONT size=12 color=$color"
    if [ "$MODE" = paused ]; then
      echo "Paused | size=12 color=gray"
      echo "---"
      echo "Resume | $(action resume) sfimage=play.fill"
    else
      echo "Ends at $(clock "$VALUE") | size=12 color=gray"
      echo "---"
      echo "Pause | $(action pause) sfimage=pause.fill"
    fi
    # Holding ⌥ swaps each "Add" row for the "Subtract" row after it.
    echo "Add 1 minute | $(action add 60) sfimage=plus"
    echo "Subtract 1 minute | $(action add -60) sfimage=minus alternate=true"
    echo "Add 5 minutes | $(action add 300) sfimage=plus"
    echo "Subtract 5 minutes | $(action add -300) sfimage=minus alternate=true"
    echo "Cancel | $(action stop) sfimage=xmark"
    echo "---"
    echo "New timer | sfimage=timer"
    launcher "--"
    echo "---"
    settings_menu
    ;;
  ringing)
    echo "${LABEL:-$DONE_TEXT} | sfimage=alarm.fill color=$LATE"
    echo "---"
    [ -n "$LABEL" ] && echo "$LABEL | size=12 color=gray"
    echo "$DONE_TEXT | size=20 color=$LATE"
    echo "---"
    echo "Stop alarm | $(action stop) sfimage=stop.fill"
    echo "Snooze $SNOOZE_MIN min | $(action snooze "$LABEL") sfimage=zzz"
    [ "$TOTAL" -gt 0 ] && echo "Restart · $(dur_text "$TOTAL") | $(action start "$TOTAL" "$LABEL") sfimage=arrow.clockwise"
    ;;
  *)
    echo "| sfimage=timer"
    echo "---"
    launcher ""
    echo "---"
    settings_menu
    ;;
esac

if [ "$CHECK_UPDATES" = 1 ] && [ "$MODE" != ringing ] && [ -n "$LATEST" ] && version_gt "$LATEST" "$(script_version "$SELF")"; then
  echo "---"
  echo "Update to v$LATEST | $(action update) sfimage=arrow.down.circle"
fi
