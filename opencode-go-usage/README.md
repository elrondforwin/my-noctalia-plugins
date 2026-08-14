# OpenCode Usage

Shows your OpenCode Go usage as a percent on the bar (rolling / weekly /
monthly), with a detail panel for the full picture. The API key is stored in
the desktop keyring (Secret Service) and never written to plugin settings.

## Plugin

| Field | Value |
| --- | --- |
| ID | `elrond/opencode-go-usage` |
| Entries | Bar widget: `bar`; panel: `panel`; service: `usage` |

## Requirements

- `secret-tool` on `PATH` (generally package `libsecret-tools`) to store and read the
  API key.
- An OpenCode Go API key, stored via the panel's "Set
  key" field. Without it the widget shows "No API key set".

## Usage

Add the `bar` widget to your bar. It shows the usage percent for the selected
window; click it to open the detail panel.

In the panel you can change the stored API key, refresh usage manually, and
(optionally) enable debug mode to drive each window's percent by hand.

Toggle the panel with its IPC command:

```sh
noctalia msg panel-toggle elrond/opencode-go-usage:panel
```

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `label` | `string` | `""` | Text shown before the percent in the bar. Empty shows just the percent. |
| `show_glyph` | `bool` | `true` | Show a glyph before the bar text. |
| `glyph` | `glyph` | `activity` | Glyph shown before the bar text. |
| `metric` | `select` | `monthly` | Which usage window the bar and panel hero show: rolling (24h), weekly, or monthly. |
| `refresh_minutes` | `int` | `15` | How often the plugin re-fetches usage from the API. |
| `warn_threshold` | `int` | `70` | Usage at or above this percent turns yellow. |
| `critical_threshold` | `int` | `90` | Usage at or above this percent turns red. |
| `debug_mode` | `bool` | `false` | Skip the API and control each window's percent from the panel (no API key required). |

## Notes

- The API key is stored in the desktop keyring (Secret Service) via
  `secret-tool`, never in plugin settings or files.
- The plugin makes network requests to the OpenCode Go usage API on every
  refresh (default every 15 minutes) and when "Refresh now" is pressed.
- If the keyring is locked, saving the key fails with a clear error; if
  `secret-tool` is missing, the error suggests installing `libsecret-tools`.
- ~~Debug mode lets you test the bar colors and panel without an API key or
  network access.~~ (currently does not work, gonna be removed :p)
