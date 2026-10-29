# menubar-timer

A SwiftBar countdown-timer plugin: everything lives in `timer.1s.sh` (pure bash 3.2 + `osascript`, no dependencies). `README.md` is the user-facing documentation.

## Always update the README

Every feature change, behavior change, new setting or new command must update `README.md` in the same change. Before finishing, check each section the change touches:

- **Features**: the bullet list describing what the menu shows and does
- **Settings**: the copy of the Settings block, which must match the top of `timer.1s.sh` exactly (values and comments)
- **Presets** / **Custom times**: if parsing or preset behavior changed
- **Command line**: every `case "$1"` command meant for users should be listed
- **Updates**: if the update mechanism changed

## Releasing

Bump `<xbar.version>` in `timer.1s.sh` for any user-visible change. Installed copies check `main` daily and offer the update.

The updater keeps each user's Settings values, so changing a default in the Settings block doesn't reach existing users. If they should get the new default, add a migration that replaces the old default value (see the `PRESETS` migration near the top of the script).

## Testing

There's no test suite. Run `bash -n timer.1s.sh`, then run the script with `HOME` pointed at a scratch directory and `CHECK_UPDATES=0` to check the menu output (`./timer.1s.sh`) and commands (`start`, `stop`, `parse "1h30m Tea"`). Keep it compatible with macOS's bash 3.2: no associative arrays, `mapfile` or `${var,,}`, and no heredocs inside `$( )`.
