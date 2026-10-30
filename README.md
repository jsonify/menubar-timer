# menubar-timer

A countdown timer for the macOS menu bar, built as a [SwiftBar](https://github.com/swiftbar/SwiftBar) plugin. When the timer ends, it **loops an alarm sound** and **opens an alarm window in front of every other window**, which stays up until you click Stop or Snooze.

This is a modern rewrite of [fferri/bitbar-countdown-timer](https://github.com/fferri/bitbar-countdown-timer). That plugin depended on Python 2, which macOS no longer includes. This version is a single bash script that only uses tools already on every Mac (`bash`, `osascript`, `afplay`), so there's nothing to install.

## Features

- A live countdown in the menu bar (`◕ Tea 4:59`). The pie fills as time runs out, and the color goes from teal to amber in the last 20% and to red in the last 10 seconds.
- The menu opens on a large countdown with a progress bar (`▰▰▰▰▰▰▱▱▱▱  of 15:00`) and the time it ends.
- Your five most recent timers at the top of the menu, so the ones you actually use are one click away, followed by named presets (**🍅 Pomodoro · 25 min**, **🧠 Deep work · 50 min**) and **Custom…**, which you can also open from any app with **⌘⌥T**
- **Pause/Resume**, **Add 1 minute**, **Add 5 minutes** and **Cancel**. Hold **⌥** to change the Add items to **Subtract**.
- A **Settings** menu where you choose the alarm sound (each one plays when you pick it), the snooze length, and what the menu bar shows: label and time, time only, or icon only
- Click the timer in the menu bar to drop down a **panel** with a retro hardware look (see [Panel](#panel)): a green seven-segment LCD, chunky keys, and knobs you drag or scroll to set a timer. Right-click it for the standard menu.
- When it ends:
  - the sound loops
  - an alarm window in the same retro style as the [panel](#panel) opens in front of your other windows, on every Space and over full-screen apps. Its LCD flashes **00:00** with the backlight pulsing and counts how long it has been ringing. It has **Again** (run the same timer again), **Snooze** and **Stop** keys, and shows when it will stop ringing by itself. On the keyboard, Return, Space or Esc stops it, S snoozes and R restarts.
  - a notification is sent and the menu bar icon turns red
  - the menu has a **Restart** item that runs the same timer again
- The timer keeps running if SwiftBar restarts, because its state is stored on disk.
- It checks GitHub for a newer version once a day and offers a one-click update.

## Install

1. Install SwiftBar (`brew install swiftbar`, or download it from its GitHub releases) and choose a plugin folder.
2. Copy `timer.1s.sh` into that folder and make it executable:
   ```sh
   cp timer.1s.sh ~/path/to/SwiftBar/Plugins/
   chmod +x ~/path/to/SwiftBar/Plugins/timer.1s.sh
   ```
3. Choose **Refresh All** from SwiftBar's menu. A ⏱ icon appears in the menu bar.

The `1s` in the filename tells SwiftBar to refresh the plugin every second.

### If the alarm window can't open

If the styled alarm window can't open, the plugin falls back to a plain dialog with **Snooze** and **Stop** buttons. That dialog comes to the front by asking **System Events** to show it. The first time this happens, macOS asks: *"SwiftBar wants to control System Events"*. Click **OK**. If you click Don't Allow, the alarm still rings, but the dialog may open behind your current window. To change the setting later, go to **System Settings → Privacy & Security → Automation → SwiftBar**.

Also make sure notifications are allowed for SwiftBar under **System Settings → Notifications**.

## Panel

Click the timer in the menu bar and a panel styled like a piece of desk hardware drops down below it. Like a menu, it goes away when you click anywhere else, click the timer again, or click **Close** in the panel.

The standard menu is still there: **right-click** the timer (or ⌥-click it). It also has **Open panel** and **Close panel**. If you'd rather a left-click open the menu, choose **Settings → Clicking the timer opens → This menu**, or set `CLICK="menu"`. Opening the panel with a click needs a recent version of SwiftBar. Older versions open the menu on every click, so use **Open panel** in the menu instead.

- **LCD**: the countdown in seven-segment digits, the timer's label, when it ends, a progress strip, and whether it's running, paused or ringing. The **Run / Pause / Ring** lights at the top match.
- **Keys**:
  - **Reset** cancels the timer.
  - The orange key is **Start**, **Pause**, **Resume** or **Stop**, depending on the state.
  - **+1 Min** adds a minute, and becomes **Snooze** while the alarm rings.
  - **Edit** opens **Custom…**.
- **Knobs**: **Hours**, **Minutes** and **Seconds** set the length that **Start** uses. **Snooze** sets the snooze length. Drag a knob up or down, or scroll over it, and double-click it to reset it.
- **Recent**: your recent timers as buttons. Click one to run it again.
- **Settings**: what the menu bar shows, and the alarm sound. Use the arrows to step through the sounds, and click the name to hear it.
- **Keyboard**: Space is the orange key, Esc is Reset, `+` adds a minute, Return is Edit and ⌘W closes the panel.

The panel, and the alarm window that opens when a timer ends, are a web page in a WebKit window run by `osascript`, and it's built into `timer.1s.sh`, so there's still nothing to install. It reads the timer from `timer.1s.sh status` twice a second and sends clicks back as the commands listed under [Command line](#command-line), so the panel, the menu and the terminal always agree.

If the panel or the alarm window doesn't open, the reason is written to `~/Library/Application Support/menubar-timer/window.log`.

## Custom times

**Custom…** accepts any of these formats. Any text after the time becomes the timer's label.

| You type         | Timer             |
|------------------|-------------------|
| `25`             | 25 minutes (a bare number means minutes) |
| `25m`, `25 min`  | 25 minutes        |
| `90s`            | 90 seconds        |
| `1h30m`, `1h 30m`| 1 hour 30 minutes |
| `10:00`          | 10 minutes (mm:ss) |
| `1:30:00`        | 1 hour 30 minutes (h:mm:ss) |
| `15 Tea is ready`| 15 minutes, labeled "Tea is ready" |

## Settings

Edit the variables at the top of `timer.1s.sh`:

```sh
# Presets are "Group: Name=time, Name=time; Group: ...". A time is anything
# Custom… accepts (a bare number is minutes); the name becomes the label.
# Your five most recent timers are listed above these; "" shows recents only.
PRESETS="Focus: 🍅 Pomodoro=25, 🧠 Deep work=50"
SOUND="/System/Library/Sounds/Glass.aiff"       # default alarm; Settings → Alarm sound overrides it
SNOOZE_MIN=5                                    # snooze length; Settings → Snooze length overrides it
RING_FOR=300                                    # seconds to keep ringing if ignored
FONT="Menlo"                                    # monospaced so the clock doesn't jiggle
SHOW="label"                                    # menu bar: label (◕ Tea 4:59), time (◕ 4:59) or icon (◕)
CLICK="panel"                                   # clicking the timer opens: panel (right-click for the menu) or menu
HOTKEY="CMD+OPTION+T"                           # opens Custom… from any app; "" to turn off
CHECK_UPDATES=1                                 # 0 = never look for a newer version on GitHub
```

### Presets

Separate groups with `;` and the presets in a group with `,`. A group can start with a heading such as `Focus:`, which is shown in small capitals. Each preset is `Name=time`, and the time can be written in any format **Custom…** accepts, so `Bread=1h30m` and `Eggs=7:30` both work. The name becomes the timer's label, and a preset with no name (just `15`) shows its length. A plain list of minutes like `"5 10 15"` still works.

Presets are listed under **Recent**, which holds the last five timers you started (from a preset, a recent, **Custom…**, **Restart** or the command line; snoozes aren't counted). Set `PRESETS=""` to show only your recents. **Settings → Clear recent timers** empties the list.

If you never changed `PRESETS`, you get the current default automatically when you update. In v3.1 that means the old Quick group (Tea, Soft eggs, Pasta) is removed, since your recents now fill that role.

Choices you make in the **Settings** menu or the panel (alarm sound, snooze length, menu bar display and what clicking the timer opens) are saved in `~/Library/Application Support/menubar-timer/prefs` and take priority over `SOUND`, `SNOOZE_MIN`, `SHOW` and `CLICK`.

Other built-in sounds you can use for `SOUND`: `Ping`, `Hero`, `Sosumi`, `Submarine`, `Funk`, `Glass` and `Purr`. Run `ls /System/Library/Sounds` to see all of them.

## Updates

Once a day, the plugin downloads the copy of `timer.1s.sh` on this repo's `main` branch and compares its `<xbar.version>` with its own. If the one on GitHub is newer, you get a notification and the menu shows **Update to vX.Y**. Clicking it downloads the new script and swaps it in. The values you set in the Settings block are copied into the new version, so your changes are kept. If the download fails or the file looks broken, your current version is left as it is.

To turn this off, set `CHECK_UPDATES=0`.

**Releasing a new version:** bump `<xbar.version>` in `timer.1s.sh` and merge to `main`. Anyone running an older version is offered the update within a day.

## Command line

You can control the timer from a terminal or a Shortcut, as well as from the menu:

```sh
./timer.1s.sh start 300 "Eggs"   # start a 5-minute timer labeled "Eggs" (added to Recent)
./timer.1s.sh pause
./timer.1s.sh resume
./timer.1s.sh add 60             # add a minute (add -60 takes one away)
./timer.1s.sh snooze "Eggs"      # start a snooze-length timer without adding it to Recent
./timer.1s.sh stop               # cancel the timer, or silence a ringing alarm
./timer.1s.sh set-snooze 10      # make Snooze 10 minutes
./timer.1s.sh set-click menu     # clicking the timer opens the menu (set-click panel opens the panel)
./timer.1s.sh panel              # open the panel, or close it if it's open
./timer.1s.sh status             # the timer and settings as one line of JSON
./timer.1s.sh check-update       # look for a newer version now
./timer.1s.sh update             # install the newest version from GitHub
```

The timer's state is stored in `~/Library/Application Support/menubar-timer/`.
