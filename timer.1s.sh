#!/bin/bash
# <xbar.title>Menu Bar Timer</xbar.title>
# <xbar.version>v3.3</xbar.version>
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
SNOOZE_MIN=5                                    # snooze length; Settings → Snooze length overrides it
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
PREFS="$STATE_DIR/prefs"        # KEY=value lines saved by the Settings menu and panel (SOUND, SHOW, SNOOZE_MIN)
RECENT="$STATE_DIR/recent"      # secs|label lines, newest first, at most 5
ALARM_PID="$STATE_DIR/alarm.pid"
PANEL_PID="$STATE_DIR/panel.pid"
WINDOW_LOG="$STATE_DIR/window.log"   # errors from the last panel or alarm window
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
      SNOOZE_MIN) case "$v" in ""|*[!0-9]*) ;; *) SNOOZE_MIN=$v ;; esac ;;
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

# Runs detached: loops the sound and puts the alarm window in front of everything.
ring() {
  local label="${1:-$DONE_TEXT}" sp kids answer
  echo $$ > "$ALARM_PID"
  osascript -e 'display notification "Timer finished" with title "⏰ Timer" sound name "Glass"' >/dev/null 2>&1
  ( while :; do afplay "$SOUND"; sleep 0.3; done ) &
  sp=$!
  read_state
  answer=$(osascript -l JavaScript -e "$PANEL_JS" "$(abs_self)" "$PANEL_HTML" alarm \
    "{\"label\":$(json_str "$LABEL"),\"total\":${TOTAL:-0},\"snooze\":$SNOOZE_MIN,\"ends\":\"$(clock "$(now)")\",\"ringFor\":$RING_FOR}" "$RING_FOR" 2>"$WINDOW_LOG")
  # If the styled window couldn't open, fall back to a plain dialog (unless the alarm was stopped meanwhile).
  [ -z "$answer" ] && [ -f "$ALARM_PID" ] &&
    answer=$(printf '%s' "$ALARM_SCRIPT" | osascript - "$label" "Snooze $SNOOZE_MIN min" "$RING_FOR" 2>/dev/null)
  kids=$(pgrep -P "$sp" 2>/dev/null)
  kill "$sp" $kids 2>/dev/null
  rm -f "$ALARM_PID"
  case "$answer" in
    Snooze*) read_state; write_state running $(( $(now) + SNOOZE_MIN * 60 )) "$LABEL" $(( SNOOZE_MIN * 60 )) ;;
    Restart) read_state; if [ "$TOTAL" -gt 0 ]; then start_timer "$TOTAL" "$LABEL"; else rm -f "$STATE"; fi ;;
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

# ---- Panel and alarm window -------------------------------------------------
# A small window with an LCD, keys and knobs. It's an HTML page in a WebKit view
# hosted by osascript (JavaScript for Automation), so it needs nothing installed.
# The page talks to this script through the "timer" message handler: each
# message is a command line for the case below, and "status" is polled twice a
# second to redraw it. The same page, in "alarm" mode, is the window that rings.
read -r -d '' PANEL_JS <<'JXA'
ObjC.import('Cocoa');
ObjC.import('WebKit');

// argv: script html [alarm init-json ring-for]. As the alarm, it prints the button
// clicked (Stop, Snooze, Restart, or gaveup after ring-for seconds) and exits.
function run(argv) {
  var script = argv[0], html = argv[1], alarm = argv[2] === 'alarm', width = 300;
  var init = argv[3] || '{}', ringFor = Number(argv[4]) || 0, waited = 0, answered = false;
  var app = $.NSApplication.sharedApplication;
  app.setActivationPolicy(1);   // accessory: a window but no Dock icon

  function sh(args, wait) {
    var t = $.NSTask.alloc.init, out = $.NSPipe.pipe;
    t.launchPath = '/bin/bash';
    t.arguments = $([script].concat(args));
    t.standardOutput = wait ? out : $.NSFileHandle.fileHandleWithNullDevice;
    t.standardError = $.NSFileHandle.fileHandleWithNullDevice;
    t.launch;
    if (!wait) return '';
    var data = out.fileHandleForReading.readDataToEndOfFile;
    t.waitUntilExit;
    return $.NSString.alloc.initWithDataEncoding(data, 4).js || '';
  }

  function answer(a) {
    if (answered) return;
    answered = true;
    $.NSFileHandle.fileHandleWithStandardOutput.writeData($(a + '\n').dataUsingEncoding(4));
    app.terminate(null);
  }

  var web, win, last = '';
  function push(force) {
    var s = sh(['status'], true).trim();
    if (!s || (s === last && !force)) return;
    last = s;
    web.evaluateJavaScriptCompletionHandler('MT.render(' + s + ')', null);
  }

  // No "protocols" lists: JXA can only name protocols already loaded in the runtime, and
  // WKScriptMessageHandler isn't. WebKit and NSWindow only check that the methods exist.
  ObjC.registerSubclass({
    name: 'MTBridge',
    methods: {
      'userContentController:didReceiveScriptMessage:': {
        types: ['void', ['id', 'id']],
        implementation: function (ucc, msg) {
          var a = ObjC.deepUnwrap(msg.body) || [], cmd = a[0];
          if (cmd === 'close') { win.close; return; }
          if (cmd === 'answer') { answer(String(a[1])); return; }
          if (cmd === 'status') { push(true); return; }
          if (cmd === 'size') {   // grow or shrink to fit the page, keeping the top edge in place
            var f = win.frame, h = Number(a[1]);
            var dh = win.frameRectForContentRect($.NSMakeRect(0, 0, width, h)).size.height - f.size.height;
            if (Math.abs(dh) >= 1) win.setFrameDisplay($.NSMakeRect(f.origin.x, f.origin.y - dh, f.size.width, f.size.height + dh), true);
            return;
          }
          sh(a, cmd !== 'custom');   // Custom… waits on a dialog, so don't block the window
          push(false);
        }
      }
    }
  });

  ObjC.registerSubclass({
    name: 'MTTicker',
    methods: { 'tick:': { types: ['void', ['id']], implementation: function () {
      if (!alarm) return push(false);
      waited += 0.5;
      if (ringFor && waited >= ringFor) answer('gaveup');
    } } }
  });

  ObjC.registerSubclass({
    name: 'MTWindowDelegate',
    methods: { 'windowWillClose:': { types: ['void', ['id']], implementation: function () { if (alarm) answer('Stop'); else app.terminate(null); } } }
  });

  // titled + closable + miniaturizable + full-size content: the page draws under a clear title bar
  win = $.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer($.NSMakeRect(0, 0, width, 540), 1 | 2 | 4 | (1 << 15), 2, false);
  win.titlebarAppearsTransparent = true;
  win.titleVisibility = 1;
  win.title = 'Menu Timer';
  win.backgroundColor = $.NSColor.colorWithSRGBRedGreenBlueAlpha(0.922, 0.910, 0.882, 1);
  win.standardWindowButton(2).hidden = true;   // no zoom button
  if (alarm) {
    win.standardWindowButton(1).hidden = true;
    win.level = 25;                   // status-window level: above other apps' windows
    win.collectionBehavior = 1 | 256; // on every Space, and over full-screen apps
  }
  win.releasedWhenClosed = false;
  var delegate = $.MTWindowDelegate.alloc.init;
  win.delegate = delegate;

  var conf = $.WKWebViewConfiguration.alloc.init;
  var bridge = $.MTBridge.alloc.init;
  conf.userContentController.addScriptMessageHandlerName(bridge, 'timer');
  conf.userContentController.addUserScript($.WKUserScript.alloc.initWithSourceInjectionTimeForMainFrameOnly(
    'window.MT_MODE = ' + JSON.stringify(alarm ? 'alarm' : 'panel') + '; window.MT_INIT = ' + init + ';', 0, true));
  web = $.WKWebView.alloc.initWithFrameConfiguration(win.contentView.bounds, conf);
  web.autoresizingMask = 2 | 16;   // width + height sizable
  web.setValueForKey($.NSNumber.numberWithBool(false), 'drawsBackground');
  win.contentView = web;
  web.loadHTMLStringBaseURL(html, $.NSURL.URLWithString('https://menubar-timer.local/'));

  win.center;
  if (!alarm) win.setFrameAutosaveName('MenubarTimerPanel');   // reopen where you left it
  win.makeKeyAndOrderFront(null);
  win.orderFrontRegardless;
  app.activateIgnoringOtherApps(true);

  var ticker = $.MTTicker.alloc.init;
  $.NSTimer.scheduledTimerWithTimeIntervalTargetSelectorUserInfoRepeats(0.5, ticker, 'tick:', null, true);
  app.run;
}
JXA

read -r -d '' PANEL_HTML <<'HTML'
<!doctype html>
<html><head><meta charset="utf-8">
<style>
:root {
  --chassis: #ebe8e1; --chassis-hi: #f7f5f0; --chassis-lo: #d3cfc5;
  --ink: #2b2a27; --ink-soft: #8b877d; --ink-faint: #b9b4a9;
  --orange: #ff5c1c; --teal: #1f9e86; --amber: #e6a119; --red: #e0402f;
  --lcd-ink: #1e2318;
  --tiny: 7.5px;
}
* { box-sizing: border-box; margin: 0; padding: 0; }
html, body { background: var(--chassis); height: 100%; overflow: hidden; }
body {
  font: 600 var(--tiny)/1.2 -apple-system, "Helvetica Neue", sans-serif;
  letter-spacing: .14em; text-transform: uppercase; color: var(--ink-soft);
  -webkit-user-select: none; user-select: none; cursor: default;
  -webkit-font-smoothing: antialiased;
}
.device {
  width: 300px; padding: 0 14px 14px;
  background:
    radial-gradient(120% 60% at 50% 0%, rgba(255,255,255,.55), transparent 70%),
    var(--chassis);
}
button { font: inherit; letter-spacing: inherit; text-transform: inherit; color: inherit; background: none; border: 0; cursor: default; }

/* top strip: sits under the transparent title bar, so it doubles as the drag handle */
.bar { height: 30px; display: flex; align-items: center; justify-content: space-between; padding-left: 52px; }
.brand b { color: var(--ink); font-weight: 800; }
.legend { display: flex; gap: 8px; }
.legend span { display: flex; align-items: center; gap: 3px; color: var(--ink-faint); transition: color .2s; }
.legend i { width: 5px; height: 5px; border-radius: 50%; background: currentColor; opacity: .5; }
.legend span.on { color: var(--ink); }
.legend span.on i { opacity: 1; box-shadow: 0 0 4px currentColor; }
.legend .run.on i { background: var(--teal); color: var(--teal); }
.legend .pause.on i { background: var(--amber); color: var(--amber); }
.legend .ring.on i { background: var(--red); color: var(--red); }

/* LCD */
.bezel {
  margin-top: 2px; padding: 5px; border-radius: 10px;
  background: linear-gradient(#d2cec4, #e2ded6);
  box-shadow: inset 0 1px 2px rgba(0,0,0,.18), 0 1px 0 rgba(255,255,255,.9);
}
.lcd {
  position: relative; border-radius: 6px; padding: 7px 9px 6px; color: var(--lcd-ink);
  background: linear-gradient(170deg, #d3d9be 0%, #c3caad 60%, #b9c0a2 100%);
  box-shadow: inset 0 2px 5px rgba(0,0,0,.28), inset 0 0 0 1px rgba(0,0,0,.25);
  overflow: hidden;
}
.lcd::after { /* faint pixel grid and glass sheen */
  content: ""; position: absolute; inset: 0; pointer-events: none;
  background:
    linear-gradient(160deg, rgba(255,255,255,.22), transparent 40%),
    repeating-linear-gradient(0deg, rgba(0,0,0,.025) 0 1px, transparent 1px 2px),
    repeating-linear-gradient(90deg, rgba(0,0,0,.02) 0 1px, transparent 1px 2px);
}
.lcd-row { display: flex; justify-content: space-between; align-items: center; height: 11px; }
.lcd-row b { font-weight: 800; color: var(--lcd-ink); }
.lcd-row span { color: rgba(30,35,24,.7); }
.digits { display: flex; justify-content: center; align-items: center; height: 58px; gap: 3px; transform: skewX(-5deg); }
.digits svg { height: 46px; width: auto; }
.digits svg.colon { width: 6px; }
.digits.long svg { height: 36px; }
.seg { fill: var(--lcd-ink); transition: fill-opacity .08s; }
.seg.off { fill-opacity: .07; }
.prog { display: flex; gap: 1.5px; }
.prog i { width: 4px; height: 5px; background: var(--lcd-ink); opacity: .1; }
.prog i.on { opacity: .85; }
.state { display: flex; align-items: center; gap: 4px; }
.state i { width: 4px; height: 4px; border-radius: 50%; background: var(--lcd-ink); opacity: .15; }
.running .state i { opacity: .9; animation: blink 1s steps(2) infinite; }
@keyframes blink { 50% { opacity: .15; } }
.ringing .digits { animation: flash .5s steps(2) infinite; }
@keyframes flash { 50% { opacity: .2; } }
.lcd.ringing { animation: backlight 1.2s ease-in-out infinite alternate; }   /* the backlight pulses while it rings */
@keyframes backlight {
  to { background: linear-gradient(170deg, #eaf3c4 0%, #d9e6a2 60%, #cddb93 100%); box-shadow: inset 0 2px 5px rgba(0,0,0,.18), inset 0 0 0 1px rgba(0,0,0,.25), inset 0 0 18px rgba(255,250,190,.7); }
}

/* transport keys */
.keys {
  display: grid; grid-template-columns: repeat(4, 1fr); gap: 8px; margin-top: 12px;
  padding: 8px 8px 6px; border-radius: 10px;
  background: linear-gradient(#e2ded6, #e9e6df);
  box-shadow: inset 0 1px 2px rgba(0,0,0,.14), 0 1px 0 rgba(255,255,255,.9);
}
.key-wrap { display: flex; flex-direction: column; align-items: center; gap: 5px; }
.key {
  width: 100%; height: 44px; border-radius: 8px; display: grid; place-items: center; color: var(--ink);
  background: linear-gradient(#fdfcfa, #e8e4dc);
  box-shadow: 0 2px 0 #c7c2b7, 0 3px 6px rgba(0,0,0,.16), inset 0 1px 0 #fff, inset 0 0 0 .5px rgba(0,0,0,.12);
  transition: transform .06s, box-shadow .06s;
}
.key svg { width: 15px; height: 15px; fill: currentColor; }
.key:active, .key.down { transform: translateY(2px); box-shadow: 0 0 0 #c7c2b7, 0 1px 2px rgba(0,0,0,.2), inset 0 1px 0 #fff, inset 0 0 0 .5px rgba(0,0,0,.12); }
.key.orange { color: #fff; background: linear-gradient(#ff8045, #f2520f); box-shadow: 0 2px 0 #b93a07, 0 3px 7px rgba(242,82,15,.35), inset 0 1px 0 rgba(255,255,255,.35); }
.key.orange:active { box-shadow: 0 0 0 #b93a07, 0 1px 2px rgba(0,0,0,.25), inset 0 1px 0 rgba(255,255,255,.35); }
.key.dark { color: #f2efe9; background: linear-gradient(#45433e, #252421); box-shadow: 0 2px 0 #11100f, 0 3px 6px rgba(0,0,0,.3), inset 0 1px 0 rgba(255,255,255,.12); }
.key.dark:active { box-shadow: 0 0 0 #11100f, 0 1px 2px rgba(0,0,0,.3), inset 0 1px 0 rgba(255,255,255,.12); }
.key[disabled] { color: var(--ink-faint); }
.key-wrap label { color: var(--ink-soft); }

/* section rules */
.rule { display: flex; align-items: center; gap: 6px; margin: 14px 0 8px; }
.rule::after { content: ""; flex: 1; height: 1px; background: linear-gradient(90deg, var(--chassis-lo), transparent); box-shadow: 0 1px 0 rgba(255,255,255,.7); }
.rule b { color: var(--ink); font-weight: 800; }

/* knobs */
.knobs { display: grid; grid-template-columns: repeat(4, 1fr); }
.knob-unit { display: flex; flex-direction: column; align-items: center; }
.well { position: relative; width: 60px; height: 60px; touch-action: none; cursor: ns-resize; }
.well svg { position: absolute; inset: 0; }
.tick { stroke: var(--ink-faint); stroke-width: 1; stroke-linecap: round; }
.tick.on { stroke: var(--ink); }
.tick.major { stroke-width: 1.4; }
.knob {
  position: absolute; left: 11px; top: 11px; width: 38px; height: 38px; border-radius: 50%;
  background: repeating-conic-gradient(#d8d4ca 0 5deg, #f4f2ed 5deg 10deg);
  box-shadow: 0 4px 6px rgba(0,0,0,.22), 0 1px 1px rgba(0,0,0,.3), inset 0 0 0 .5px rgba(0,0,0,.2);
  transition: transform .08s ease-out;
}
.cap {
  position: absolute; inset: 4px; border-radius: 50%;
  background: radial-gradient(circle at 38% 30%, #ffffff 0%, #eeebe5 45%, #d5d1c7 100%);
  box-shadow: inset 0 -1px 2px rgba(0,0,0,.14), 0 0 0 .5px rgba(0,0,0,.18), 0 1px 1px rgba(255,255,255,.6);
}
.cap::before { content: ""; position: absolute; left: 50%; top: 2px; width: 2px; height: 8px; margin-left: -1px; border-radius: 1px; background: var(--ink); }
.knob-unit.accent .cap::before { background: var(--orange); }
.val { display: flex; align-items: center; gap: 4px; margin-top: 1px; font: 600 11px/1 "SF Mono", Menlo, monospace; letter-spacing: 0; color: var(--ink); }
.val::before, .val::after { content: ""; width: 5px; height: 1px; background: var(--ink-faint); }
.knob-unit label { margin-top: 3px; color: var(--ink); font-weight: 800; }
.knob-unit small { font-size: 6.5px; color: var(--ink-faint); letter-spacing: .1em; margin-top: 1px; text-transform: lowercase; }

/* recent chips */
.chips { display: flex; flex-wrap: wrap; gap: 5px; min-height: 20px; }
.chip {
  height: 20px; padding: 0 8px; border-radius: 10px; display: flex; align-items: center; gap: 5px; color: var(--ink);
  background: linear-gradient(#fbfaf7, #e7e3db);
  box-shadow: 0 1px 0 #c7c2b7, 0 1px 3px rgba(0,0,0,.12), inset 0 0 0 .5px rgba(0,0,0,.12);
}
.chip:active { transform: translateY(1px); box-shadow: 0 0 0 #c7c2b7, inset 0 0 0 .5px rgba(0,0,0,.15); }
.chip em { font-style: normal; color: var(--ink-soft); font-family: "SF Mono", Menlo, monospace; letter-spacing: .02em; }
.empty { color: var(--ink-faint); line-height: 20px; }

/* settings rows */
.row { display: flex; align-items: center; justify-content: space-between; min-height: 24px; }
.row + .row { margin-top: 6px; }
.row > span { display: flex; align-items: center; gap: 6px; color: var(--ink); font-weight: 800; }
.row > span i { width: 9px; height: 9px; border-radius: 2px; background: var(--orange); box-shadow: inset 0 0 0 .5px rgba(0,0,0,.25), inset 0 1px 0 rgba(255,255,255,.35); }
.seg-ctl {
  display: flex; padding: 2px; gap: 2px; border-radius: 6px;
  background: #dcd8cf; box-shadow: inset 0 1px 2px rgba(0,0,0,.16), 0 1px 0 rgba(255,255,255,.8);
}
.seg-ctl button { height: 18px; padding: 0 7px; border-radius: 4px; color: var(--ink-soft); }
.seg-ctl button.on { color: #f4f1eb; background: linear-gradient(#45433e, #2a2926); box-shadow: 0 1px 2px rgba(0,0,0,.3); }
.stepper { display: flex; align-items: center; gap: 4px; }
.stepper button.arrow {
  width: 18px; height: 18px; border-radius: 50%; display: grid; place-items: center; color: var(--ink);
  background: linear-gradient(#fbfaf7, #e4e0d8); box-shadow: 0 1px 0 #c7c2b7, 0 1px 2px rgba(0,0,0,.15), inset 0 0 0 .5px rgba(0,0,0,.12);
}
.stepper button.arrow:active { transform: translateY(1px); box-shadow: inset 0 0 0 .5px rgba(0,0,0,.15); }
.stepper svg { width: 7px; height: 7px; fill: currentColor; }
.chiplcd {
  min-width: 74px; height: 18px; padding: 0 6px; border-radius: 3px; display: grid; place-items: center;
  font: 700 9px/1 "SF Mono", Menlo, monospace; letter-spacing: .08em; color: var(--lcd-ink);
  background: linear-gradient(#cfd5ba, #bfc6a9); box-shadow: inset 0 1px 2px rgba(0,0,0,.3), inset 0 0 0 .5px rgba(0,0,0,.25);
}

/* footer */
.foot { display: flex; align-items: center; justify-content: space-between; margin-top: 16px; }
.quit { display: flex; align-items: center; gap: 7px; color: var(--ink); font-weight: 800; }
.quit i {
  width: 22px; height: 22px; border-radius: 50%; display: grid; place-items: center;
  background: linear-gradient(#45433e, #22211e); box-shadow: 0 2px 3px rgba(0,0,0,.3), 0 0 0 2px var(--chassis), 0 0 0 3px #cfcabf;
}
.quit i::after { content: ""; width: 6px; height: 6px; border-radius: 50%; background: var(--orange); box-shadow: 0 0 4px var(--orange); }
.quit:active i { transform: translateY(1px); }
.serial { color: var(--ink-faint); text-align: right; line-height: 1.5; }
.grille { display: grid; grid-template-columns: repeat(7, 4px); gap: 3px; }
.grille i { width: 4px; height: 4px; border-radius: 50%; background: radial-gradient(circle at 50% 35%, #8f8a80, #3d3b37); box-shadow: 0 .5px 0 rgba(255,255,255,.8); }
.foot-r { display: flex; align-items: center; gap: 10px; }

/* alarm window: the same page, showing only the LCD and the alarm keys */
body.alarm .panel-only, body:not(.alarm) .alarm-only { display: none; }
.keys.three { grid-template-columns: 1fr 1fr 1.7fr; }
.alarm .legend .ring.on i { animation: blink .6s steps(2) infinite; }
.alarm .serial { text-align: left; }
.alarm .serial b { color: var(--ink); font: 600 10px/1.4 "SF Mono", Menlo, monospace; letter-spacing: 0; }
.grille.buzz i { animation: buzz .09s linear infinite alternate; }
.grille.buzz i:nth-child(2n) { animation-delay: -.045s; }
@keyframes buzz { to { transform: translate(.4px, -.3px); } }
</style></head>
<body>
<div class="device" id="device">
  <header class="bar">
    <div class="brand"><b>MT-1</b> Menu Timer</div>
    <div class="legend">
      <span class="run"><i></i>Run</span><span class="pause"><i></i>Pause</span><span class="ring"><i></i>Ring</span>
    </div>
  </header>

  <div class="bezel"><div class="lcd" id="lcd">
    <div class="lcd-row"><b id="lcdLabel">Ready</b><span id="lcdRight"></span></div>
    <div class="digits" id="digits"></div>
    <div class="lcd-row"><div class="prog" id="prog"></div><span class="state"><i></i><b id="lcdState">Idle</b></span></div>
  </div></div>

  <div class="panel-only">
  <div class="keys">
    <div class="key-wrap"><button class="key" id="kReset" title="Cancel the timer"><svg viewBox="0 0 16 16"><path d="M8 2.5a5.5 5.5 0 1 1-5.2 3.7l1.4.5A4 4 0 1 0 8 4v2L4.5 3.2 8 .5z"/></svg></button><label id="lReset">Reset</label></div>
    <div class="key-wrap"><button class="key orange" id="kPlay"><svg viewBox="0 0 16 16" id="iPlay"></svg></button><label id="lPlay">Start</label></div>
    <div class="key-wrap"><button class="key" id="kAdd"><svg viewBox="0 0 16 16" id="iAdd"></svg></button><label id="lAdd">+1 Min</label></div>
    <div class="key-wrap"><button class="key dark" id="kEdit" title="Type a time and label"><svg viewBox="0 0 16 16"><path d="M11.3 1.6l3.1 3.1-8.6 8.6-3.9.8.8-3.9zM10 4.4l-6 6-.4 1.9 1.9-.4 6-6z"/></svg></button><label>Edit</label></div>
  </div>

  <div class="rule"><b>Timer</b> — drag or scroll a knob</div>
  <div class="knobs" id="knobs"></div>

  <div class="rule"><b>Recent</b></div>
  <div class="chips" id="chips"></div>

  <div class="rule"><b>Settings</b></div>
  <div class="row"><span><i></i>Menu bar</span>
    <div class="seg-ctl" id="show"><button data-v="label">Label</button><button data-v="time">Time</button><button data-v="icon">Icon</button></div>
  </div>
  <div class="row"><span><i></i>Alarm</span>
    <div class="stepper">
      <button class="arrow" id="sPrev"><svg viewBox="0 0 8 8"><path d="M5.5 0v8L1 4z"/></svg></button>
      <div class="chiplcd" id="sound" title="Click to hear it">Glass</div>
      <button class="arrow" id="sNext"><svg viewBox="0 0 8 8"><path d="M2.5 0v8L7 4z"/></svg></button>
    </div>
  </div>

  <div class="foot">
    <button class="quit" id="close"><i></i>Close</button>
    <div class="foot-r">
      <div class="serial" id="serial">Menu bar<br>countdown</div>
      <div class="grille"></div>
    </div>
  </div>
  </div>

  <div class="alarm-only">
    <div class="rule"><b>Time's up</b> — <span id="aSub"></span></div>
    <div class="keys three">
      <div class="key-wrap"><button class="key" id="aRestart" title="Run the same timer again (R)"><svg viewBox="0 0 16 16"><path d="M8 2.5a5.5 5.5 0 1 0 5.2 3.7l-1.4.5A4 4 0 1 1 8 4v2l3.5-2.8L8 .5z"/></svg></button><label id="aRestartL">Restart</label></div>
      <div class="key-wrap"><button class="key" id="aSnooze" title="Snooze (S)"><svg viewBox="0 0 16 16"><path d="M2 3h6v1.5L4.4 9H8v1.5H2V9l3.6-4.5H2zM9 8h5v1.2l-3 3.3h3V14H9v-1.2l3-3.3H9z"/></svg></button><label id="aSnoozeL">Snooze</label></div>
      <div class="key-wrap"><button class="key orange" id="aStop" title="Stop (Return)"><svg viewBox="0 0 16 16"><path d="M3 3h10v10H3z"/></svg></button><label>Stop</label></div>
    </div>
    <div class="foot">
      <div class="serial">Auto-stop in<br><b id="aAuto"></b></div>
      <div class="grille buzz"></div>
    </div>
  </div>
</div>

<script>
(function () {
  var $ = function (id) { return document.getElementById(id); };
  var S = { mode: "idle", left: 0, total: 0, label: "", ends: "", snooze: 5, show: "label", sound: "Glass", sounds: [], recent: [] };
  var ALARM = window.MT_MODE === "alarm";
  if (ALARM) document.body.classList.add("alarm");
  var bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.timer;
  function send() { var a = [].slice.call(arguments).map(String); if (bridge) bridge.postMessage(a); else console.log("send", a.join(" ")); }

  // ---- seven-segment digits ----
  var W = 20, H = 36, T = 3.6, G = 0.7;
  function hseg(cy, x1, x2) { var h = T / 2; return [[x1, cy], [x1 + h, cy - h], [x2 - h, cy - h], [x2, cy], [x2 - h, cy + h], [x1 + h, cy + h]]; }
  function vseg(cx, y1, y2) { var h = T / 2; return [[cx, y1], [cx + h, y1 + h], [cx + h, y2 - h], [cx, y2], [cx - h, y2 - h], [cx - h, y1 + h]]; }
  var l = T / 2, r = W - T / 2, m = H / 2;
  var SEGS = {
    a: hseg(T / 2, l + G, r - G), g: hseg(m, l + G, r - G), d: hseg(H - T / 2, l + G, r - G),
    f: vseg(l, T / 2 + G, m - G), b: vseg(r, T / 2 + G, m - G), e: vseg(l, m + G, H - T / 2 - G), c: vseg(r, m + G, H - T / 2 - G)
  };
  var MAP = { "0": "abcdef", "1": "bc", "2": "abged", "3": "abgcd", "4": "fgbc", "5": "afgcd", "6": "afgedc", "7": "abc", "8": "abcdefg", "9": "abcdfg", "-": "g", " ": "" };
  function digitSvg(ch) {
    var on = MAP[ch] || "", s = '<svg viewBox="-0.5 -0.5 ' + (W + 1) + ' ' + (H + 1) + '">';
    for (var k in SEGS) s += '<polygon class="seg' + (on.indexOf(k) < 0 ? " off" : "") + '" points="' + SEGS[k].map(function (p) { return p.join(","); }).join(" ") + '"/>';
    return s + "</svg>";
  }
  var COLON = '<svg class="colon" viewBox="0 0 6 36"><circle class="seg" cx="3" cy="12" r="2"/><circle class="seg" cx="3" cy="25" r="2"/></svg>';
  var lastDigits = "";
  function showDigits(text) {
    if (text === lastDigits) return; lastDigits = text;
    $("digits").className = "digits" + (text.length > 5 ? " long" : "");
    $("digits").innerHTML = text.split("").map(function (c) { return c === ":" ? COLON : digitSvg(c); }).join("");
  }
  function pad(n) { return (n < 10 ? "0" : "") + n; }
  function clock(t) { var h = Math.floor(t / 3600), m = Math.floor(t % 3600 / 60), s = t % 60; return h ? h + ":" + pad(m) + ":" + pad(s) : pad(m) + ":" + pad(s); }
  function short(t) { var h = Math.floor(t / 3600), m = Math.floor(t % 3600 / 60), s = t % 60, o = []; if (h) o.push(h + "h"); if (m) o.push(m + "m"); if (s) o.push(s + "s"); return o.join(" ") || "0s"; }

  // ---- progress strip ----
  var PROG = 24;
  $("prog").innerHTML = new Array(PROG + 1).join("<i></i>");
  var progCells = $("prog").children;

  // ---- grille ----
  [].forEach.call(document.querySelectorAll(".grille"), function (g) { g.innerHTML = new Array(22).join("<i></i>"); });

  // ---- knobs ----
  var store = {}; try { store = JSON.parse(localStorage.getItem("knobs") || "{}"); } catch (e) {}
  var KNOBS = [
    { k: "h", name: "Hours", unit: "hrs", min: 0, max: 12, v: store.h != null ? store.h : 0 },
    { k: "m", name: "Minutes", unit: "min", min: 0, max: 59, v: store.m != null ? store.m : 25 },
    { k: "s", name: "Seconds", unit: "sec", min: 0, max: 55, step: 5, v: store.s != null ? store.s : 0 },
    { k: "z", name: "Snooze", unit: "min", min: 1, max: 30, v: 5, accent: true }
  ];
  var NT = 11, A0 = -135, A1 = 135;
  KNOBS.forEach(function (K) {
    var u = document.createElement("div"); u.className = "knob-unit" + (K.accent ? " accent" : "");
    var ticks = "";
    for (var i = 0; i < NT; i++) {
      var a = (A0 + (A1 - A0) * i / (NT - 1)) * Math.PI / 180, major = i === 0 || i === NT - 1 || i === (NT - 1) / 2;
      var r1 = major ? 25.5 : 26.5, r2 = 29;
      ticks += '<line class="tick' + (major ? " major" : "") + '" x1="' + (30 + r1 * Math.sin(a)).toFixed(2) + '" y1="' + (30 - r1 * Math.cos(a)).toFixed(2) + '" x2="' + (30 + r2 * Math.sin(a)).toFixed(2) + '" y2="' + (30 - r2 * Math.cos(a)).toFixed(2) + '"/>';
    }
    u.innerHTML = '<div class="well"><svg viewBox="0 0 60 60">' + ticks + '</svg><div class="knob"><div class="cap"></div></div></div><div class="val"></div><label>' + K.name + '</label><small>' + K.unit + '</small>';
    $("knobs").appendChild(u);
    K.el = u; K.knob = u.querySelector(".knob"); K.val = u.querySelector(".val"); K.ticks = u.querySelectorAll(".tick");
    var well = u.querySelector(".well"), y0 = 0, v0 = 0, acc = 0;
    well.addEventListener("pointerdown", function (e) { well.setPointerCapture(e.pointerId); y0 = e.clientY; v0 = K.v; });
    well.addEventListener("pointermove", function (e) { if (!well.hasPointerCapture(e.pointerId)) return; setKnob(K, v0 + Math.round((y0 - e.clientY) / 4) * (K.step || 1)); });
    well.addEventListener("pointerup", function () { commit(K); });
    well.addEventListener("wheel", function (e) {
      e.preventDefault(); acc += e.deltaY;
      if (Math.abs(acc) >= 12) { setKnob(K, K.v + (acc < 0 ? 1 : -1) * (K.step || 1)); acc = 0; clearTimeout(K.t); K.t = setTimeout(function () { commit(K); }, 400); }
    }, { passive: false });
    well.addEventListener("dblclick", function () { setKnob(K, K.k === "m" ? 25 : K.k === "z" ? 5 : 0); commit(K); });
    drawKnob(K);
  });
  function setKnob(K, v) { v = Math.max(K.min, Math.min(K.max, v)); if (v === K.v) return; K.v = v; drawKnob(K); if (S.mode === "idle") renderLcd(); }
  function drawKnob(K) {
    var f = (K.v - K.min) / (K.max - K.min);
    K.knob.style.transform = "rotate(" + (A0 + (A1 - A0) * f) + "deg)";
    K.val.textContent = pad(K.v);
    for (var i = 0; i < K.ticks.length; i++) K.ticks[i].classList.toggle("on", i / (NT - 1) <= f + 1e-9 && f > 0);
  }
  function commit(K) {
    if (K.k === "z") { if (K.v !== S.snooze) send("set-snooze", K.v); return; }
    store = { h: KNOBS[0].v, m: KNOBS[1].v, s: KNOBS[2].v };
    try { localStorage.setItem("knobs", JSON.stringify(store)); } catch (e) {}
  }
  function knobSecs() { return KNOBS[0].v * 3600 + KNOBS[1].v * 60 + KNOBS[2].v; }

  // ---- keys ----
  var ICON = {
    play: '<path d="M4 2.2v11.6L13.5 8z"/>',
    pause: '<path d="M3.5 2h3v12h-3zM9.5 2h3v12h-3z"/>',
    stop: '<path d="M3 3h10v10H3z"/>',
    plus: '<path d="M7 2.5h2v4.5h4.5v2H9v4.5H7V9H2.5V7H7z"/>',
    zzz: '<path d="M2 3h6v1.5L4.4 9H8v1.5H2V9l3.6-4.5H2zM9 8h5v1.2l-3 3.3h3V14H9v-1.2l3-3.3H9z"/>'
  };
  $("kPlay").onclick = function () {
    if (S.mode === "running") send("pause");
    else if (S.mode === "paused") send("resume");
    else if (S.mode === "ringing") send("stop");
    else if (knobSecs() > 0) send("start", knobSecs());
  };
  $("kReset").onclick = function () { if (S.mode !== "idle") send("stop"); };
  $("kAdd").onclick = function () { if (S.mode === "ringing") send("snooze", S.label); else if (S.mode !== "idle") send("add", 60); };
  $("kEdit").onclick = function () { send("custom"); };
  $("close").onclick = function () { send("close"); };
  document.addEventListener("keydown", function (e) {
    if (ALARM) {
      if (e.key === " " || e.key === "Enter" || e.key === "Escape") { e.preventDefault(); press("aStop"); }
      else if (e.key === "s" || e.key === "z") press("aSnooze");
      else if (e.key === "r") press("aRestart");
      return;
    }
    if (e.key === " ") { e.preventDefault(); press("kPlay"); }
    else if (e.key === "Escape") press("kReset");
    else if (e.key === "+" || e.key === "=") press("kAdd");
    else if (e.key === "e" || e.key === "Enter") press("kEdit");
    else if (e.key === "w" && e.metaKey) send("close");
  });
  function press(id) { var k = $(id); k.classList.add("down"); setTimeout(function () { k.classList.remove("down"); }, 120); k.click(); }

  // ---- settings ----
  [].forEach.call($("show").children, function (b) { b.onclick = function () { send("set-show", b.dataset.v); S.show = b.dataset.v; renderSettings(); }; });
  function stepSound(d) {
    if (!S.sounds.length) return;
    var i = (S.sounds.indexOf(S.sound) + d + S.sounds.length) % S.sounds.length;
    S.sound = S.sounds[i]; renderSettings(); send("set-sound", "/System/Library/Sounds/" + S.sound + ".aiff");
  }
  $("sPrev").onclick = function () { stepSound(-1); };
  $("sNext").onclick = function () { stepSound(1); };
  $("sound").onclick = function () { stepSound(0); };

  // ---- render ----
  function renderLcd() {
    var m = S.mode, left = m === "idle" ? knobSecs() : S.left, total = m === "idle" ? 0 : Math.max(S.total, S.left);
    $("lcd").className = "lcd " + m;
    showDigits(m === "ringing" ? "00:00" : clock(left));
    $("lcdLabel").textContent = S.label || (m === "idle" ? "Ready" : m === "ringing" ? "Time's up" : "Timer");
    $("lcdRight").textContent = m === "running" ? "Ends " + S.ends : m === "paused" ? "of " + clock(total) : m === "ringing" ? "Snooze " + S.snooze + " min" : "Set " + short(left);
    $("lcdState").textContent = { idle: "Idle", running: "Running", paused: "Paused", ringing: "Ringing" }[m];
    var lit = m === "ringing" ? PROG : total ? Math.round((total - left) / total * PROG) : 0;
    for (var i = 0; i < PROG; i++) progCells[i].className = i < lit ? "on" : "";
    ["run", "pause", "ring"].forEach(function (c) { document.querySelector(".legend ." + c).classList.toggle("on", { run: "running", pause: "paused", ring: "ringing" }[c] === m); });
  }
  function renderKeys() {
    var m = S.mode;
    $("iPlay").innerHTML = ICON[m === "running" ? "pause" : m === "ringing" ? "stop" : "play"];
    $("lPlay").textContent = { idle: "Start", running: "Pause", paused: "Resume", ringing: "Stop" }[m];
    $("iAdd").innerHTML = ICON[m === "ringing" ? "zzz" : "plus"];
    $("lAdd").textContent = m === "ringing" ? "Snooze" : "+1 Min";
    $("kReset").disabled = m === "idle";
    $("kAdd").disabled = m === "idle";
  }
  function renderChips() {
    var key = JSON.stringify(S.recent);
    if (key === renderChips.last) return; renderChips.last = key;
    var box = $("chips"); box.innerHTML = "";
    if (!S.recent.length) { box.innerHTML = '<span class="empty">Timers you start show up here</span>'; return; }
    S.recent.forEach(function (r) {
      var b = document.createElement("button"); b.className = "chip";
      b.innerHTML = (r[1] ? "<span></span>" : "") + "<em>" + short(r[0]) + "</em>";
      if (r[1]) b.firstChild.textContent = r[1];
      b.onclick = function () { send("start", r[0], r[1]); };
      box.appendChild(b);
    });
  }
  function renderSettings() {
    [].forEach.call($("show").children, function (b) { b.classList.toggle("on", b.dataset.v === S.show); });
    $("sound").textContent = S.sound;
    var z = KNOBS[3]; if (!z.el.querySelector(".well").matches(":active") && z.v !== S.snooze) { z.v = S.snooze; drawKnob(z); }
  }

  // ---- alarm window ----
  // The host passes MT_INIT = {label, total, snooze, ends, ringFor} and waits for one "answer".
  function startAlarm(a) {
    var t0 = Date.now();
    MT.render({ mode: "ringing", label: a.label || "", total: a.total || 0, snooze: a.snooze || 5 });
    $("aSub").textContent = "Ended " + a.ends + (a.total ? " · " + short(a.total) + " timer" : "");
    $("aSnoozeL").textContent = "Snooze " + (a.snooze || 5) + "m";
    $("aRestartL").textContent = a.total ? "Again " + short(a.total).replace(/ .*/, "") : "Restart";
    $("aRestart").disabled = !a.total;
    $("aStop").onclick = function () { send("answer", "Stop"); };
    $("aSnooze").onclick = function () { send("answer", "Snooze"); };
    $("aRestart").onclick = function () { if (a.total) send("answer", "Restart"); };
    function tick() {
      var over = Math.floor((Date.now() - t0) / 1000);
      $("lcdRight").textContent = "+" + clock(over).replace(/^0/, "") + " over";
      $("aAuto").textContent = clock(Math.max(0, (a.ringFor || 300) - over));
    }
    tick(); setInterval(tick, 1000);
  }

  window.MT = {
    render: function (s) {
      for (var k in s) S[k] = s[k];
      renderLcd(); renderKeys(); renderChips(); renderSettings();
    }
  };
  if (ALARM) startAlarm(window.MT_INIT || {}); else { window.MT.render({}); send("status"); }
  send("size", document.getElementById("device").offsetHeight);
})();
</script>
</body></html>
HTML

panel_open() {
  local pid
  [ -f "$PANEL_PID" ] && pid=$(cat "$PANEL_PID") && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null &&
    ps -p "$pid" -o comm= 2>/dev/null | grep -q osascript
}

abs_self() { case "$SELF" in /*) printf '%s' "$SELF" ;; *) printf '%s' "$PWD/$SELF" ;; esac; }

toggle_panel() {  # opens the panel, or closes it if it's already open
  if panel_open; then kill "$(cat "$PANEL_PID")" 2>/dev/null; rm -f "$PANEL_PID"; return; fi
  nohup osascript -l JavaScript -e "$PANEL_JS" "$(abs_self)" "$PANEL_HTML" </dev/null >/dev/null 2>"$WINDOW_LOG" &
  echo $! > "$PANEL_PID"
}

json_str() { printf '"%s"' "$(printf '%s' "$1" | sed 's/[\\"]/\\&/g')"; }

status_json() {  # one line of JSON describing the timer and settings, for the panel
  local mode=idle left=0 total=0 label="" ends="" f n sounds="" recent="" secs l
  if read_state; then
    mode=$MODE; label=$LABEL; total=$TOTAL
    case "$MODE" in
      running) left=$(( VALUE - $(now) )); [ "$left" -lt 0 ] && left=0; ends=$(clock "$VALUE") ;;
      paused)  left=$VALUE ;;
    esac
    [ "$total" -lt "$left" ] && total=$left
  fi
  for f in /System/Library/Sounds/*.aiff; do
    [ -e "$f" ] || continue
    n=${f##*/}; sounds="$sounds${sounds:+,}\"${n%.aiff}\""
  done
  if [ -s "$RECENT" ]; then
    while IFS='|' read -r secs l; do
      case "$secs" in ''|*[!0-9]*) continue ;; esac
      recent="$recent${recent:+,}[$secs,$(json_str "$l")]"
    done < "$RECENT"
  fi
  n=${SOUND##*/}
  printf '{"mode":"%s","left":%d,"total":%d,"label":%s,"ends":"%s","snooze":%d,"show":"%s","sound":%s,"sounds":[%s],"recent":[%s]}\n' \
    "$mode" "$left" "$total" "$(json_str "$label")" "$ends" "$SNOOZE_MIN" "$SHOW" "$(json_str "${n%.aiff}")" "$sounds" "$recent"
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
  set-snooze) case "$2" in ''|*[!0-9]*|0) exit 1 ;; esac; set_pref SNOOZE_MIN "$2"; exit 0 ;;
  panel)   toggle_panel; exit 0 ;;
  status)  status_json; exit 0 ;;
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

panel_item() {
  if panel_open; then echo "Close panel | $(action panel) sfimage=xmark.rectangle"
  else echo "Open panel | $(action panel) sfimage=slider.horizontal.3"; fi
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
  echo "--Snooze length | sfimage=zzz"
  for opt in 1 5 10 15; do
    echo "----$opt min | $(action set-snooze "$opt")$([ "$opt" = "$SNOOZE_MIN" ] && printf ' checked=true')"
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
    panel_item
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
    echo "---"
    panel_item
    ;;
  *)
    echo "| sfimage=timer"
    echo "---"
    launcher ""
    echo "---"
    panel_item
    settings_menu
    ;;
esac

if [ "$CHECK_UPDATES" = 1 ] && [ "$MODE" != ringing ] && [ -n "$LATEST" ] && version_gt "$LATEST" "$(script_version "$SELF")"; then
  echo "---"
  echo "Update to v$LATEST | $(action update) sfimage=arrow.down.circle"
fi
