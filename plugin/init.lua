local M = {}

local function find_plugin_dir(wezterm, opts)
  if opts and opts.plugin_dir then
    return tostring(opts.plugin_dir):match("^(.-)/?$") .. "/plugin"
  end

  for _, plugin in ipairs(wezterm.plugin.list() or {}) do
    local url = tostring(plugin.url or "")
    local dir = tostring(plugin.plugin_dir or "")

    if url:find("wezterm%-workspaces", 1, false)
      or dir:find("wezterm%-workspaces", 1, false)
    then
      return dir .. "/plugin"
    end
  end

  return nil
end

function M.apply_to_config(config, opts)
  local wezterm = require("wezterm")
  local plugin_dir = find_plugin_dir(wezterm, opts)
  if not plugin_dir then
    wezterm.log_error("wezterm-workspaces: unable to find plugin checkout")
    return
  end

  local workspace = dofile(plugin_dir .. "/workspace.lua")
  workspace.apply_to_config(wezterm, config, opts or {}, plugin_dir)
end

return M
