# menubar-timer

A countdown timer for the macOS menu bar, built as a [SwiftBar](https://github.com/swiftbar/SwiftBar) plugin. When the timer ends, it **loops an alarm sound** and **opens a dialog in front of every other window**, which stays up until you click Stop or Snooze.

This is a modern rewrite of [fferri/bitbar-countdown-timer](https://github.com/fferri/bitbar-countdown-timer). That plugin depended on Python 2, which macOS no longer includes. This version is a single bash script that only uses tools already on every Mac (`bash`, `osascript`, `afplay`), so there's nothing to install.

## Features

- A live countdown in the menu bar (`Tea 4:59`) that turns orange in the last minute and red in the last 10 seconds
- One-click presets (1, 5, 10, 15, 20, 25, 30 or 45 min, or 1 hr) and a **Custom…** option
- **Pause/Resume**, **+1 min**, **+5 min** and **Cancel**
- When it ends:
  - the sound loops
  - an alert pops up in front of your other windows with **Snooze 5 min** and **Stop** buttons
  - a notification is sent and the menu bar icon turns red
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
PRESETS="1 5 10 15 20 25 30 45 60"              # minutes, shown in the menu
SOUND="/System/Library/Sounds/Glass.aiff"       # any .aiff in /System/Library/Sounds
SNOOZE_MIN=5                                    # length of the "Snooze" button
RING_FOR=300                                    # seconds to keep ringing if ignored
CHECK_UPDATES=1                                 # 0 = never look for a newer version on GitHub
```

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
./timer.1s.sh add 60             # add a minute
./timer.1s.sh stop               # cancel the timer, or silence a ringing alarm
./timer.1s.sh check-update       # look for a newer version now
./timer.1s.sh update             # install the newest version from GitHub
```

The timer's state is stored in `~/Library/Application Support/menubar-timer/`.
