# WezTerm Workspaces

A small WezTerm plugin that adds saved workspaces, a keyboard-driven workspace
sidebar, a clickable top workspace rail, and workspace-aware tab/pane actions.
Inspired by the workspace-first flow of cmux terminal.

This plugin owns only the workspace workflow. It does not set your font, shell,
window opacity, terminal color scheme, inactive-pane styling, or other personal
WezTerm appearance settings.

## Install

Add this to your `~/.config/wezterm/wezterm.lua`:

```lua
local wezterm = require("wezterm")
local config = wezterm.config_builder()

wezterm.plugin.require("https://github.com/DanyilLiubchakUk/wezterm-workspaces")
  .apply_to_config(config)

return config
```

If you already have a config object, only add:

```lua
wezterm.plugin.require("https://github.com/DanyilLiubchakUk/wezterm-workspaces")
  .apply_to_config(config)
```

## What It Adds

- saved workspace records in `~/.config/wezterm/workspaces.json`
- left workspace sidebar toggled with `Command+B`
- top workspace rail toggled with `Command+D`
- clickable workspace names in the top rail
- keyboard workspace switching with `Command+Option+1..9`
- sidebar workspace creation/deletion
- workspace-aware tab navigation and split shortcuts
- live sidebar preview from the active pane's last visible line

## Shortcuts

```text
Command+B            show/hide workspace sidebar
Command+D            show/hide workspace names on top
Option+W             fuzzy workspace switcher
Command+Option+1..9  switch to workspace 1..9, or create the next slot
Command+Up/Down      previous/next workspace; Down creates after the last one
Option+N             same as Command+Down
Option+Shift+R       rename current workspace

Command+Left/Right   previous/next tab
Option+1..9          switch/create tabs in the current workspace
Option+R             rename current tab

Option+-             split down
Option+Shift+-       split up
Option+\             split right
Option+Shift+\       split left
Command+W            close pane/tab with sidebar-aware cleanup
```

Inside the sidebar:

```text
[1-9]/Enter          open selected workspace
Option+N             same as Command+Down
Option+Backspace     delete selected workspace
Up/Down              select workspace
Option+/             hide/show shortcut help
```

The plugin does not bind `Option+Left` or `Option+Right`, so shells and WezTerm
prompts can keep using those keys for word-by-word cursor movement.

## Options

```lua
local workspaces = wezterm.plugin.require(
  "https://github.com/DanyilLiubchakUk/wezterm-workspaces"
)

workspaces.apply_to_config(config, {
  sidebar_default_cells = 28,
  sidebar_min_cells = 16,
  sidebar_max_cells = 68,
  startup_workspace = "default",

  -- Disable if your own config handles these.
  enable_keys = true,
  enable_mouse_bindings = true,
  manage_startup = true,

  -- Off by default so the plugin does not take over your tab styling.
  format_tab_title = false,
  show_pane_status = false,
})
```

## Update

WezTerm caches plugins after the first clone. To pull newer plugin code, run this
from the WezTerm Debug Overlay:

```lua
wezterm.plugin.update_all()
```

Then reload WezTerm.

## Local Development

```lua
wezterm.plugin.require("file:///Users/you/dev/wezterm-workspaces")
  .apply_to_config(config)
```
