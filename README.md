# menubar-timer

A countdown timer for the macOS menu bar, built as a [SwiftBar](https://github.com/swiftbar/SwiftBar) plugin. When the timer ends, it **loops an alarm sound** and **opens a dialog in front of every other window**, which stays up until you click Stop or Snooze.

This is a modern rewrite of [fferri/bitbar-countdown-timer](https://github.com/fferri/bitbar-countdown-timer). That plugin depended on Python 2, which macOS no longer includes. This version is a single bash script that only uses tools already on every Mac (`bash`, `osascript`, `afplay`), so there's nothing to install.

## Features

- A live countdown in the menu bar (`◕ Tea 4:59`). The pie fills as time runs out, and the color goes from teal to amber in the last 20% and to red in the last 10 seconds.
- The menu opens on a large countdown with a progress bar (`▰▰▰▰▰▰▱▱▱▱  of 15:00`) and the time it ends.
- Named, grouped presets (**☕ Tea · 4 min**, **🍅 Pomodoro · 25 min**…), your five most recent custom timers, and **Custom…**, which you can also open from any app with **⌘⌥T**
- **Pause/Resume**, **Add 1 minute**, **Add 5 minutes** and **Cancel**. Hold **⌥** to change the Add items to **Subtract**.
- A **Settings** menu where you choose the alarm sound (each one plays when you pick it) and what the menu bar shows: label and time, time only, or icon only
- When it ends:
  - the sound loops
  - an alert pops up in front of your other windows with **Snooze 5 min** and **Stop** buttons
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

### First alarm: allow SwiftBar to control System Events

The alert comes to the front by asking **System Events** to show it. The first time this happens, macOS asks: *"SwiftBar wants to control System Events"*. Click **OK**. If you click Don't Allow, the alarm still rings, but the dialog may open behind your current window. To change the setting later, go to **System Settings → Privacy & Security → Automation → SwiftBar**.

Also make sure notifications are allowed for SwiftBar under **System Settings → Notifications**.

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
PRESETS="Quick: ☕ Tea=4, 🥚 Soft eggs=7, 🍝 Pasta=10; Focus: 🍅 Pomodoro=25, 🧠 Deep work=50"
SOUND="/System/Library/Sounds/Glass.aiff"       # default alarm; Settings → Alarm sound overrides it
SNOOZE_MIN=5                                    # length of the "Snooze" button
RING_FOR=300                                    # seconds to keep ringing if ignored
SHOW="label"                                    # menu bar: label (◕ Tea 4:59), time (◕ 4:59) or icon (◕)
HOTKEY="CMD+OPTION+T"                           # opens Custom… from any app; "" to turn off
CHECK_UPDATES=1                                 # 0 = never look for a newer version on GitHub
```

### Presets

Separate groups with `;` and the presets in a group with `,`. A group can start with a heading such as `Quick:`, which is shown in small capitals. Each preset is `Name=time`, and the time can be written in any format **Custom…** accepts, so `Bread=1h30m` and `Eggs=7:30` both work. The name becomes the timer's label, and a preset with no name (just `15`) shows its length. A plain list of minutes like `"5 10 15"` still works.

If you never changed `PRESETS` in v2, you get the new named presets automatically when you update.

Choices you make in the **Settings** menu (alarm sound and menu bar display) are saved in `~/Library/Application Support/menubar-timer/prefs` and take priority over `SOUND` and `SHOW`.

Other built-in sounds you can use for `SOUND`: `Ping`, `Hero`, `Sosumi`, `Submarine`, `Funk`, `Glass` and `Purr`. Run `ls /System/Library/Sounds` to see all of them.

## Updates

Once a day, the plugin downloads the copy of `timer.1s.sh` on this repo's `main` branch and compares its `<xbar.version>` with its own. If the one on GitHub is newer, you get a notification and the menu shows **Update to vX.Y**. Clicking it downloads the new script and swaps it in. The values you set in the Settings block are copied into the new version, so your changes are kept. If the download fails or the file looks broken, your current version is left as it is.

To turn this off, set `CHECK_UPDATES=0`.

**Releasing a new version:** bump `<xbar.version>` in `timer.1s.sh` and merge to `main`. Anyone running an older version is offered the update within a day.

## Command line

You can control the timer from a terminal or a Shortcut, as well as from the menu:

```sh
./timer.1s.sh start 300 "Eggs"   # start a 5-minute timer labeled "Eggs"
./timer.1s.sh pause
./timer.1s.sh resume
./timer.1s.sh add 60             # add a minute (add -60 takes one away)
./timer.1s.sh stop               # cancel the timer, or silence a ringing alarm
./timer.1s.sh check-update       # look for a newer version now
./timer.1s.sh update             # install the newest version from GitHub
```

The timer's state is stored in `~/Library/Application Support/menubar-timer/`.
