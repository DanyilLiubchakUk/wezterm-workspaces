local M = {}

local function append_list(config, field, items)
  local existing = config[field] or {}
  for _, item in ipairs(items) do
    table.insert(existing, item)
  end
  config[field] = existing
end

local function merge_options(opts)
  opts = opts or {}
  return {
    sidebar_default_cells = tonumber(opts.sidebar_default_cells) or 28,
    sidebar_min_cells = tonumber(opts.sidebar_min_cells) or 16,
    sidebar_max_cells = tonumber(opts.sidebar_max_cells) or 68,
    startup_workspace = opts.startup_workspace or "default",
    sidebar_script = opts.sidebar_script,
    enable_keys = opts.enable_keys ~= false,
    enable_mouse_bindings = opts.enable_mouse_bindings ~= false,
    manage_startup = opts.manage_startup ~= false,
    format_tab_title = opts.format_tab_title == true,
    show_pane_status = opts.show_pane_status == true,
    status_update_interval = opts.status_update_interval == false and false
      or tonumber(opts.status_update_interval)
      or 1000,
  }
end

function M.apply_to_config(wezterm, config, user_opts, plugin_dir)
  local options = merge_options(user_opts)

  if options.status_update_interval then
    local current = tonumber(config.status_update_interval)
    if not current or current > options.status_update_interval then
      config.status_update_interval = options.status_update_interval
    end
  end

  local workspace_sidebar_script = options.sidebar_script
    or (plugin_dir .. "/bin/wezterm-workspace-sidebar.sh")
  local workspace_sidebar_default_cells = options.sidebar_default_cells
  local workspace_sidebar_min_cells = options.sidebar_min_cells
  local workspace_sidebar_max_cells = options.sidebar_max_cells
  local workspace_sidebar_width_file = wezterm.config_dir .. "/workspace_sidebar_width.txt"
  local workspace_sidebar_state_file = wezterm.config_dir .. "/workspace_sidebar_state.txt"
  local workspace_sidebar_help_state_file = wezterm.config_dir .. "/workspace_sidebar_help_state.txt"
  local workspace_sidebar_data_file = wezterm.config_dir .. "/workspace_sidebar.tsv"
  local workspace_rail_state_file = wezterm.config_dir .. "/workspace_rail_state.txt"
  local workspace_store_file = wezterm.config_dir .. "/workspaces.json"
  local workspace_sidebar_split_pending = false
  local workspace_sidebar_sync_pending = false
  local workspace_sidebar_pane_by_tab = {}
  local workspace_sidebar_prewarm_pending_by_tab = {}
  local workspace_sidebar_selected_by_pane = {}
  local workspace_rail_visible = true
  local last_content_pane_by_workspace = {}
  local last_content_pane_by_tab = {}

  local startup_workspace_name = options.startup_workspace
  local last_workspace_store_content = nil

local function json_escape(s)
  return tostring(s or ""):gsub("\\", "\\\\"):gsub('"', '\\"')
end

local function title_case(text)
  text = tostring(text or ""):gsub("[-_]+", " ")
  return text:gsub("(%S)(%S*)", function(first, rest)
    return first:upper() .. rest:lower()
  end)
end

local function normalize_workspace_record(record, index)
  if type(record) ~= "table" then return nil end

  local name = tostring(record.name or ""):match("^%s*(.-)%s*$")
  if name == "" then return nil end

  local label = tostring(record.label or name)
  local title = tostring(record.title or label)
  return {
    key = tostring(record.key or (index <= 9 and tostring(index) or "")),
    name = name,
    label = label,
    title = title,
    desc = tostring(record.desc or "workspace"),
    note = tostring(record.note or "custom workspace"),
    path = tostring(record.path or "active session"),
  }
end

local function encode_workspace_store(list)
  if wezterm.json_encode then return wezterm.json_encode(list) end

  local rows = {}
  for _, workspace in ipairs(list) do
    table.insert(rows, string.format(
      '{"key":"%s","name":"%s","label":"%s","title":"%s","desc":"%s","note":"%s","path":"%s"}',
      json_escape(workspace.key),
      json_escape(workspace.name),
      json_escape(workspace.label),
      json_escape(workspace.title),
      json_escape(workspace.desc),
      json_escape(workspace.note),
      json_escape(workspace.path)
    ))
  end

  return "[" .. table.concat(rows, ",") .. "]"
end

local function write_workspace_store(list)
  local f = io.open(workspace_store_file, "w")
  if not f then return end

  f:write(encode_workspace_store(list))
  f:write("\n")
  f:close()
end

local function read_workspace_store()
  local f = io.open(workspace_store_file, "r")
  if not f then return nil end

  local content = f:read("*a")
  f:close()
  last_workspace_store_content = content

  if wezterm.json_parse then
    local ok, parsed = pcall(wezterm.json_parse, content)
    if ok and type(parsed) == "table" then return parsed end
  end

  return nil
end

local function configured_workspaces()
  local raw = read_workspace_store()
  local source = type(raw) == "table" and raw or {}
  local store_text = tostring(last_workspace_store_content or ""):match("^%s*(.-)%s*$")
  local list = {}
  local seen = {}

  for _, record in ipairs(source) do
    local workspace = normalize_workspace_record(record, #list + 1)
    if workspace and not seen[workspace.name] then
      seen[workspace.name] = true
      workspace.key = tostring(#list + 1 <= 9 and #list + 1 or "")
      table.insert(list, workspace)
    end
  end

  if type(raw) ~= "table" or store_text:sub(1, 1) ~= "[" then
    write_workspace_store(list)
  end

  return list
end

local function persist_workspace_record(record)
  local list = configured_workspaces()
  local normalized = normalize_workspace_record(record, #list + 1)
  if not normalized then return end

  for index, workspace in ipairs(list) do
    if workspace.name == normalized.name then
      list[index] = normalized
      write_workspace_store(list)
      return
    end
  end

  table.insert(list, normalized)
  write_workspace_store(list)
end

local function rename_workspace_record(old_name, new_name)
  local list = configured_workspaces()
  local found = false

  for index, workspace in ipairs(list) do
    if workspace.name == old_name then
      workspace.name = new_name
      if workspace.label == old_name or workspace.label == title_case(old_name) then
        workspace.label = title_case(new_name)
      end
      if workspace.title == old_name or workspace.title == title_case(old_name) then
        workspace.title = title_case(new_name)
      end
      workspace.key = tostring(index <= 9 and index or "")
      found = true
      break
    end
  end

  if not found then
    table.insert(list, normalize_workspace_record({ name = new_name }, #list + 1))
  end

  write_workspace_store(list)
end

local function delete_workspace_record(name)
  local list = configured_workspaces()
  local updated = {}
  local removed = false

  for _, workspace in ipairs(list) do
    if workspace.name == name then
      removed = true
    else
      table.insert(updated, workspace)
    end
  end

  if not removed then return false, list end

  for index, workspace in ipairs(updated) do
    workspace.key = tostring(index <= 9 and index or "")
  end

  write_workspace_store(updated)
  return true, updated
end

if options.manage_startup then
  wezterm.on("mux-startup", function()
  pcall(function()
    local workspaces = configured_workspaces()
    local workspace = workspaces[1] and workspaces[1].name or startup_workspace_name
    wezterm.mux.spawn_window { workspace = workspace }
    wezterm.mux.set_active_workspace(workspace)
  end)
  end)
end


-- =========================
-- Editable Pane Titles
-- =========================
local pane_titles = {}

local function pane_id(pane)
  local ok, value = pcall(function() return pane.pane_id end)
  if ok and type(value) == "function" then return pane:pane_id() end
  if ok and value ~= nil then return value end
  return tostring(pane)
end

local function fallback_pane_title(pane)
  local ok, title = pcall(function() return pane.title end)
  if ok and title and title ~= "" then return title end

  ok, title = pcall(function()
    if type(pane.get_title) == "function" then return pane:get_title() end
    return nil
  end)
  if ok and title and title ~= "" then return title end

  return "pane " .. tostring(pane_id(pane))
end

local function pane_title(pane)
  return pane_titles[pane_id(pane)] or fallback_pane_title(pane)
end

local function truncate_right(s, max_len)
  if #s <= max_len then return s end
  return s:sub(1, math.max(1, max_len - 1)) .. "."
end

local function clamp_number(value, min_value, max_value)
  local number = tonumber(value)
  if not number then return min_value end
  if number < min_value then return min_value end
  if number > max_value then return max_value end
  return number
end

local function read_workspace_sidebar_cells()
  local f = io.open(workspace_sidebar_width_file, "r")
  if not f then return workspace_sidebar_default_cells end

  local value = f:read("*l")
  f:close()

  return clamp_number(
    value,
    workspace_sidebar_min_cells,
    workspace_sidebar_max_cells
  )
end

local function write_workspace_sidebar_cells(cells)
  local clamped = clamp_number(
    cells,
    workspace_sidebar_min_cells,
    workspace_sidebar_max_cells
  )

  local f = io.open(workspace_sidebar_width_file, "w")
  if not f then return clamped end

  f:write(tostring(clamped))
  f:write("\n")
  f:close()

  return clamped
end

local function read_workspace_sidebar_visible()
  local f = io.open(workspace_sidebar_state_file, "r")
  if not f then return false end

  local value = f:read("*l")
  f:close()

  return value == "open"
end

local function write_workspace_sidebar_visible(visible)
  local f = io.open(workspace_sidebar_state_file, "w")
  if not f then return end

  f:write(visible and "open" or "closed")
  f:write("\n")
  f:close()
end

local function read_workspace_sidebar_help_visible()
  local f = io.open(workspace_sidebar_help_state_file, "r")
  if not f then return true end

  local value = f:read("*l")
  f:close()

  return value ~= "hidden"
end

local function write_workspace_sidebar_help_visible(visible)
  local f = io.open(workspace_sidebar_help_state_file, "w")
  if not f then return end

  f:write(visible and "open" or "hidden")
  f:write("\n")
  f:close()
end

local function read_workspace_rail_visible()
  local f = io.open(workspace_rail_state_file, "r")
  if not f then return workspace_rail_visible end

  local value = f:read("*l")
  f:close()

  if value == "hidden" then return false end
  if value == "visible" then return true end
  return workspace_rail_visible
end

local function write_workspace_rail_visible(visible)
  workspace_rail_visible = visible and true or false

  local f = io.open(workspace_rail_state_file, "w")
  if not f then return end

  f:write(workspace_rail_visible and "visible" or "hidden")
  f:write("\n")
  f:close()
end

local function stop_all_workspace_sidebar_helpers()
  if type(wezterm.run_child_process) ~= "function" then return end

  pcall(function()
    wezterm.run_child_process {
      "/usr/bin/pkill",
      "-f",
      "wezterm-workspace-sidebar.sh",
    }
  end)
end

local function clean_status_text(s)
  if not s or s == "" then return "" end
  local cleaned = s:gsub("[%c]", " ")
  cleaned = cleaned:gsub("%s+", " ")
  cleaned = cleaned:match("^%s*(.-)%s*$") or cleaned
  return cleaned
end

local function workspace_by_name(name)
  for _, workspace in ipairs(configured_workspaces()) do
    if workspace.name == name then return workspace end
  end
  return nil
end

local is_workspace_sidebar_pane
local find_workspace_sidebar
local find_workspace_sidebar_info
local first_content_pane
local last_content_pane
local open_workspace_sidebar
local close_workspace_sidebar
local remember_workspace_sidebar_cells
local enforce_workspace_sidebar_min_cells
local remember_content_pane
local activate_last_content_pane
local close_tab_if_closing_last_content_pane
local sync_workspace_sidebar_later
local prewarm_workspace_sidebar
local write_workspace_sidebar_data
local open_workspace_switcher
local rename_workspace
local create_workspace
local delete_workspace
local mux_window_tabs
local mux_tab_panes
local mux_window_for_workspace
local active_tab_info_for_mux_window
local tab_first_content_pane_info
local kill_pane_by_id

local function normalize_workspace_name(name)
  local normalized = tostring(name or ""):match("^%s*(.-)%s*$")
  if normalized == "" then return startup_workspace_name end
  return normalized
end

local function toggle_workspace_sidebar_help(window, pane)
  if type(is_workspace_sidebar_pane) == "function"
    and is_workspace_sidebar_pane(pane)
  then
    window:perform_action(wezterm.action.SendString("\027/"), pane)
    return
  end

  write_workspace_sidebar_help_visible(not read_workspace_sidebar_help_visible())

  if read_workspace_sidebar_visible()
    and type(sync_workspace_sidebar_later) == "function"
  then
    sync_workspace_sidebar_later(window, 0.02, false)
  end
end

local function window_workspace_name(window)
  if not window then return nil end

  local ok, name = pcall(function()
    return window:active_workspace()
  end)
  if ok and name and name ~= "" then
    return normalize_workspace_name(name)
  end

  return nil
end

local function mux_active_workspace_name()
  local ok, name = pcall(function()
    return wezterm.mux.get_active_workspace()
  end)
  if ok and name and name ~= "" then
    return normalize_workspace_name(name)
  end

  return nil
end

local function active_workspace_name(window)
  return window_workspace_name(window)
    or mux_active_workspace_name()
    or startup_workspace_name
end

local function switch_to_workspace(window, pane, name)
  if not name or name == "" then return end

  if type(remember_workspace_sidebar_cells) == "function" then
    remember_workspace_sidebar_cells(window)
  end

  local source_content_pane = pane
  if type(is_workspace_sidebar_pane) == "function"
    and is_workspace_sidebar_pane(pane)
  then
    source_content_pane = type(last_content_pane) == "function"
      and last_content_pane(window)
      or (type(first_content_pane) == "function" and first_content_pane(window) or nil)
  end

  if read_workspace_sidebar_visible() then
    if type(write_workspace_sidebar_data) == "function" then
      write_workspace_sidebar_data(window, name)
    end

    if type(prewarm_workspace_sidebar) == "function" then
      prewarm_workspace_sidebar(name, false)
    end
  end

  local target = source_content_pane or pane
  remember_content_pane(window, target)

  window:perform_action(wezterm.action.SwitchToWorkspace { name = name }, target)

  if type(activate_last_content_pane) == "function" then
    if wezterm.time and wezterm.time.call_after then
      wezterm.time.call_after(0.08, function()
        activate_last_content_pane(window)
      end)
    else
      activate_last_content_pane(window)
    end
  end

  if read_workspace_sidebar_visible()
    and type(sync_workspace_sidebar_later) == "function"
  then
    sync_workspace_sidebar_later(window, 0.12, false)
    if wezterm.time and wezterm.time.call_after
      and type(prewarm_workspace_sidebar) == "function"
    then
      wezterm.time.call_after(0.2, function()
        prewarm_workspace_sidebar(name, false)
      end)
      wezterm.time.call_after(0.28, function()
        if type(activate_last_content_pane) == "function" then
          activate_last_content_pane(window)
        end
      end)
    end
  end
end

local function workspace_names()
  local names = {}

  for _, workspace in ipairs(configured_workspaces()) do
    table.insert(names, workspace.name)
  end

  return names
end

local function workspace_meta(name, index)
  local workspace = workspace_by_name(name)
  if workspace then return workspace end

  local label = title_case(name)
  if label == "" then label = "Workspace " .. tostring(index) end

  return {
    key = index <= 9 and tostring(index) or "",
    name = name,
    label = label,
    title = label,
    desc = "workspace",
    note = "custom workspace",
    path = "active session",
  }
end

local function workspace_at_index(index)
  local names = workspace_names()
  return names[index]
end

local function osc8_link(uri, text)
  return "\027]8;;" .. uri .. "\027\\" .. text .. "\027]8;;\027\\"
end

local function tab_key(tab)
  local ok, id = pcall(function()
    if type(tab.tab_id) == "function" then return tab:tab_id() end
    return tab.tab_id
  end)

  if ok and id then return tostring(id) end
  return tostring(tab)
end

local function active_tab_key_for_window(window)
  local ok, tab = pcall(function() return window:active_tab() end)
  if ok and tab then return tab_key(tab) end
  return nil
end

local function pane_matches_id(pane, id)
  return id and pane and tostring(pane_id(pane)) == tostring(id)
end

local function remember_sidebar_for_tab(tab_id, pane)
  if tab_id and pane then
    workspace_sidebar_pane_by_tab[tab_id] = tostring(pane_id(pane))
  end
end

local function choose_sidebar_info_for_tab(tab_id, sidebars)
  if not sidebars or #sidebars == 0 then return nil end

  local cached_id = tab_id and workspace_sidebar_pane_by_tab[tab_id] or nil
  if cached_id then
    for _, info in ipairs(sidebars) do
      if pane_matches_id(info.pane, cached_id) then
        return info
      end
    end
  end

  remember_sidebar_for_tab(tab_id, sidebars[1].pane)
  return sidebars[1]
end

local function uri_escape(text)
  return tostring(text or ""):gsub("([^%w%-%._~])", function(char)
    return string.format("%%%02X", string.byte(char))
  end)
end

local function uri_unescape(text)
  return tostring(text or ""):gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end)
end

local function workspace_rail(window)
  local active = active_workspace_name(window)
  local items = {
    { Background = { Color = "#171b23" } },
    { Foreground = { Color = "#7dd3fc" } },
    { Attribute = { Intensity = "Bold" } },
    { Text = osc8_link("wezterm-workspaces://toggle", " WS ") },
  }

  if not read_workspace_rail_visible() then
    return wezterm.format(items)
  end

  for index, name in ipairs(workspace_names()) do
    local workspace = workspace_meta(name, index)
    local is_active = workspace.name == active
    table.insert(items, { Background = { Color = is_active and "#2563eb" or "#252b36" } })
    table.insert(items, { Foreground = { Color = is_active and "#ffffff" or "#aab1bf" } })
    table.insert(items, { Attribute = { Intensity = is_active and "Bold" or "Normal" } })
    table.insert(items, {
      Text = osc8_link(
        "wezterm-workspace://" .. uri_escape(workspace.name),
        " " .. tostring(index) .. ":" .. workspace.label .. " "
      ),
    })
    table.insert(items, { Background = { Color = "#171b23" } })
    table.insert(items, { Text = " " })
  end

  return wezterm.format(items)
end

local function top_workspace_status(window)
  return workspace_rail(window)
end

local function toggle_workspace_rail(window)
  write_workspace_rail_visible(not read_workspace_rail_visible())
  window:set_left_status(top_workspace_status(window))
end

local function active_pane_info(tab)
  local ok, active = pcall(function() return tab.active_pane end)
  if ok and active then return active end

  for _, pane in ipairs(tab.panes) do
    if pane.is_active then return pane end
  end
  return tab.panes[1]
end

is_workspace_sidebar_pane = function(pane)
  if not pane then return false end

  if fallback_pane_title(pane) == "workspace-sidebar" then return true end

  local ok, proc = pcall(function()
    if type(pane.get_foreground_process_name) == "function" then
      return pane:get_foreground_process_name()
    end
    return pane.foreground_process_name
  end)
  if ok and proc then
    proc = tostring(proc):lower()
    if proc:find("wezterm%-workspace%-sidebar", 1, false) then return true end
  end

  return false
end

remember_content_pane = function(window, pane)
  if not pane or is_workspace_sidebar_pane(pane) then return end

  local id = pane_id(pane)
  last_content_pane_by_workspace[active_workspace_name(window)] = id

  local ok, tab = pcall(function() return window:active_tab() end)
  if ok and tab then
    last_content_pane_by_tab[tab_key(tab)] = id
  end
end

local function is_workspace_sidebar_pane_for_action(pane)
  if is_workspace_sidebar_pane(pane) then return true end

  local ok, text = pcall(function()
    if type(pane.get_lines_as_text) == "function" then
      return pane:get_lines_as_text(20)
    end
    return nil
  end)
  if not ok or not text then return false end

  text = tostring(text)
  return text:find("WORKSPACES", 1, true)
    and (
      text:find("↑↓", 1, true)
      or text:find("[1-9]/↵", 1, true)
      or text:find("hide shortcuts", 1, true)
      or text:find("show shortcuts", 1, true)
    )
end

local function active_content_pane_info(tab)
  local active = active_pane_info(tab)
  if active and not is_workspace_sidebar_pane(active) then return active end

  for _, pane in ipairs(tab.panes or {}) do
    if not is_workspace_sidebar_pane(pane) then return pane end
  end

  return active
end

local function content_pane_count(tab)
  local count = 0
  for _, pane in ipairs(tab.panes or {}) do
    if not is_workspace_sidebar_pane(pane) then
      count = count + 1
    end
  end

  if count == 0 then return #(tab.panes or {}) end
  return count
end

local function tab_base_title(tab)
  if tab.tab_title and tab.tab_title ~= "" then return tab.tab_title end
  local active = active_content_pane_info(tab)
  if active then return pane_title(active) end
  return "Tab"
end

local function tab_description(tab)
  local count = content_pane_count(tab)
  local active = active_content_pane_info(tab)
  local active_title = active and pane_title(active) or "pane"
  local has_sidebar = #(tab.panes or {}) > count
  local suffix = has_sidebar and " + rail" or ""

  if count == 1 then return active_title .. suffix end
  return tostring(count) .. " panes / " .. active_title .. suffix
end

local function simple_tab_title(tab)
  local title = clean_status_text(tab_base_title(tab))
  if title == "" or title == "zsh" or title == "workspace-sidebar" then
    title = "Tab"
  end
  return title
end

local function sidebar_field(value)
  local text = clean_status_text(tostring(value or ""))
  text = text:gsub("\t", " ")
  text = text:gsub("|", " ")
  return text
end

local function strip_ansi(text)
  text = tostring(text or "")
  text = text:gsub("\27%[[0-?]*[ -/]*[@-~]", "")
  text = text:gsub("\27%][^\7]*(\7)", "")
  return text
end

local function pane_last_visible_line(pane)
  if not pane then return "" end

  local ok, text = pcall(function()
    if type(pane.get_lines_as_text) == "function" then
      return pane:get_lines_as_text(12)
    end
    return nil
  end)
  if not ok or not text then return "" end

  local last = ""
  for line in tostring(text):gmatch("[^\r\n]+") do
    local cleaned = clean_status_text(strip_ansi(line))
    if cleaned ~= "" then last = cleaned end
  end

  return last
end

local function content_pane_for_workspace(window, name)
  if window and name == active_workspace_name(window) then
    if type(last_content_pane) == "function" then
      local pane = last_content_pane(window)
      if pane then return pane end
    end
    if type(first_content_pane) == "function" then
      return first_content_pane(window)
    end
  end

  if type(mux_window_for_workspace) ~= "function"
    or type(active_tab_info_for_mux_window) ~= "function"
    or type(tab_first_content_pane_info) ~= "function"
  then
    return nil
  end

  local mux_window = mux_window_for_workspace(name)
  local tab_info = mux_window and active_tab_info_for_mux_window(mux_window) or nil
  local tab = tab_info and tab_info.tab or nil
  local pane_info = tab and tab_first_content_pane_info(tab) or nil
  return pane_info and pane_info.pane or nil
end

local function workspace_live_line(window, name)
  local line = pane_last_visible_line(content_pane_for_workspace(window, name))
  if line ~= "" then return line end
  return ""
end

function write_workspace_sidebar_data(window, active_override)
  local active = active_override or active_workspace_name(window)
  local rows = {}
  for index, name in ipairs(workspace_names()) do
    local meta = workspace_meta(name, index)
    local fields = {
      tostring(index),
      sidebar_field(meta.key or (index <= 9 and tostring(index) or "")),
      sidebar_field(name),
      sidebar_field(meta.label),
      sidebar_field(meta.title or meta.label),
      sidebar_field(meta.desc),
      sidebar_field(workspace_live_line(window, name)),
      sidebar_field(meta.note),
      "",
      name == active and "1" or "0",
    }

    table.insert(rows, table.concat(fields, "|"))
  end

  local content = table.concat(rows, "\n")
  if content ~= "" then content = content .. "\n" end

  local existing_file = io.open(workspace_sidebar_data_file, "r")
  if existing_file then
    local existing = existing_file:read("*a")
    existing_file:close()
    if existing == content then return end
  end

  local f = io.open(workspace_sidebar_data_file, "w")
  if not f then return end
  f:write(content)
  f:close()
end


  if options.format_tab_title then
  wezterm.on("format-tab-title", function(tab, _tabs, _panes, _config, _hover, max_width)
    local title = simple_tab_title(tab)
    local index = tostring((tab.tab_index or 0) + 1)
    local text = " " .. index .. " " .. title .. " "
  
    local bg = "#20242c"
    local fg = "#aab1bf"
    local accent = "#6b7280"
  
    if tab.is_active then
      bg = "#dbeafe"
      fg = "#111827"
      accent = "#1d4ed8"
    elseif _hover then
      bg = "#303642"
      fg = "#f3f4f6"
      accent = "#9ca3af"
    end
  
    return {
      { Background = { Color = bg } },
      { Foreground = { Color = accent } },
      { Text = " " },
      { Foreground = { Color = fg } },
      { Attribute = { Intensity = tab.is_active and "Bold" or "Normal" } },
      { Text = truncate_right(text, math.max(6, max_width)) },
    }
  end)
  
  
  end

wezterm.on("open-uri", function(window, pane, uri)
  local workspace = uri:match("^wezterm%-workspace://(.+)$")
  if workspace then
    switch_to_workspace(window, pane, uri_unescape(workspace))
    return false
  end

  if uri == "wezterm-workspaces://toggle" then
    toggle_workspace_rail(window)
    return false
  end
end)

local function update_status(window, pane)
  remember_content_pane(window, pane)

  local status_pane = pane
  if is_workspace_sidebar_pane(pane) and type(first_content_pane) == "function" then
    status_pane = first_content_pane(window) or pane
  end

  window:set_left_status(top_workspace_status(window))
  if options.show_pane_status then
    window:set_right_status("pane: " .. pane_title(status_pane) .. " ")
  end

  if read_workspace_sidebar_visible()
    and type(write_workspace_sidebar_data) == "function"
  then
    if type(enforce_workspace_sidebar_min_cells) == "function" then
      enforce_workspace_sidebar_min_cells(window)
    end
    write_workspace_sidebar_data(window)
  end
end

wezterm.on("update-status", update_status)

wezterm.on("window-resized", function(window, _pane)
  if type(enforce_workspace_sidebar_min_cells) == "function" then
    enforce_workspace_sidebar_min_cells(window)
  else
    remember_workspace_sidebar_cells(window)
  end
end)

wezterm.on("user-var-changed", function(window, pane, name, value)
  if name == "wezterm_workspace" then
    local target = tostring(value or ""):match("^([^\t]+)")
    switch_to_workspace(window, pane, target)
  elseif name == "wezterm_workspace_create" and type(create_workspace) == "function" then
    create_workspace(window, pane)
  elseif name == "wezterm_workspace_rename" and type(rename_workspace) == "function" then
    rename_workspace(window, pane)
  elseif name == "wezterm_workspace_delete" and type(delete_workspace) == "function" then
    local target = tostring(value or ""):match("^([^\t]+)")
    delete_workspace(window, pane, target)
  elseif name == "wezterm_workspace_selected" then
    local target = tostring(value or ""):match("^([^\t]+)")
    if target and target ~= "" then
      workspace_sidebar_selected_by_pane[tostring(pane_id(pane))] = target
    end
  elseif name == "wezterm_workspace_switcher" and type(open_workspace_switcher) == "function" then
    open_workspace_switcher(window, pane)
  elseif name == "wezterm_content_exited"
    and type(close_tab_if_closing_last_content_pane) == "function"
  then
    close_tab_if_closing_last_content_pane(window, pane)
  end
end)


-- =========================
-- Tab Navigation
-- =========================
local function tabs_with_info(window)
  local ok, tabs = pcall(function()
    return window:mux_window():tabs_with_info()
  end)

  if ok and type(tabs) == "table" then return tabs end
  return {}
end

local function active_tab_index(window)
  for _, tab in ipairs(tabs_with_info(window)) do
    if tab.is_active then return tab.index end
  end
  return 0
end

local function activate_or_create_tab(window, pane, target_index)
  local count = #tabs_with_info(window)

  if target_index < count then
    window:perform_action(wezterm.action.ActivateTab(target_index), pane)
  elseif target_index == count then
    window:perform_action(wezterm.action.SpawnTab("CurrentPaneDomain"), pane)
  end

  if read_workspace_sidebar_visible()
    and type(sync_workspace_sidebar_later) == "function"
  then
    sync_workspace_sidebar_later(window, 0.12, false)
  end
end

local function activate_or_create_numbered_tab(number)
  return wezterm.action_callback(function(window, pane)
    activate_or_create_tab(window, pane, number - 1)
  end)
end

local function activate_previous_tab(window, pane)
  local current = active_tab_index(window)
  if current > 0 then
    window:perform_action(wezterm.action.ActivateTab(current - 1), pane)
  end

  if read_workspace_sidebar_visible()
    and type(sync_workspace_sidebar_later) == "function"
  then
    sync_workspace_sidebar_later(window, 0.12, false)
  end
end

local function activate_next_or_create_tab(window, pane)
  activate_or_create_tab(window, pane, active_tab_index(window) + 1)
end

local function rename_tab(window, pane)
  window:perform_action(
    wezterm.action.PromptInputLine {
      description = "Tab title:",
      action = wezterm.action_callback(function(win, _pane, line)
        if line == nil then return end

        local title = line:match("^%s*(.-)%s*$")
        win:active_tab():set_title(title)
      end),
    },
    pane
  )
end

local function switch_numbered_workspace(number)
  return wezterm.action_callback(function(window, pane)
    local name = workspace_at_index(number)
    if name then
      switch_to_workspace(window, pane, name)
      return
    end

    if number == #workspace_names() + 1 then
      create_workspace(window, pane)
    end
  end)
end

local function switch_sidebar_or_send_number(number)
  local key = tostring(number)

  return wezterm.action_callback(function(window, pane)
    if is_workspace_sidebar_pane(pane) then
      local name = workspace_at_index(number)
      if name then switch_to_workspace(window, pane, name) end
    else
      window:perform_action(wezterm.action.SendKey { key = key }, pane)
    end
  end)
end

local function switch_workspace_relative(delta, create_after_last)
  return wezterm.action_callback(function(window, pane)
    local names = workspace_names()
    if #names == 0 then
      if create_after_last then create_workspace(window, pane) end
      return
    end

    local current = active_workspace_name(window)
    local index = 1
    for i, name in ipairs(names) do
      if name == current then
        index = i
        break
      end
    end

    local target = index + delta

    if create_after_last and delta > 0 and target > #names then
      create_workspace(window, pane)
      return
    end

    if target < 1 then target = #names end
    if target > #names then target = 1 end

    switch_to_workspace(window, pane, names[target])
  end)
end

function open_workspace_switcher(window, pane)
  local choices = {}

  for index, name in ipairs(workspace_names()) do
    local meta = workspace_meta(name, index)
    table.insert(choices, {
      id = name,
      label = tostring(index) .. ". " .. meta.label .. " - " .. meta.desc,
    })
  end

  window:perform_action(
    wezterm.action.InputSelector {
      title = "Switch Workspace",
      choices = choices,
      fuzzy = true,
      action = wezterm.action_callback(function(win, p, id, _label)
        if id then switch_to_workspace(win, p, id) end
      end),
    },
    pane
  )
end

function create_workspace(window, pane)
  window:perform_action(
    wezterm.action.PromptInputLine {
      description = "New workspace name:",
      action = wezterm.action_callback(function(win, p, line)
        if line == nil then return end

        local name = line:match("^%s*(.-)%s*$")
        if name == "" then return end

        local title = title_case(name)
        persist_workspace_record {
          name = name,
          label = title,
          title = title,
          desc = "workspace",
          note = "workspace",
          path = "live pane line",
        }
        switch_to_workspace(win, p, name)
        write_workspace_sidebar_data(win, name)
      end),
    },
    pane
  )
end

function rename_workspace(window, pane)
  local current = active_workspace_name(window)

  window:perform_action(
    wezterm.action.PromptInputLine {
      description = "Workspace name:",
      initial_value = current,
      action = wezterm.action_callback(function(_win, _pane, line)
        if line == nil then return end

        local name = line:match("^%s*(.-)%s*$")
        if name == "" or name == current then return end

        pcall(function()
          wezterm.mux.rename_workspace(current, name)
        end)
        rename_workspace_record(current, name)
      end),
    },
    pane
  )
end

local function active_tab_panes_with_info(window)
  local ok, tab = pcall(function() return window:active_tab() end)
  if not ok or not tab then return {} end

  local panes
  ok, panes = pcall(function() return tab:panes_with_info() end)
  if not ok or type(panes) ~= "table" then return {} end

  return panes
end

local function pane_info_cells(info)
  if info and tonumber(info.width) then return tonumber(info.width) end
  if not (info and info.pane) then return nil end

  local ok, dimensions = pcall(function()
    if type(info.pane.get_dimensions) == "function" then
      return info.pane:get_dimensions()
    end
    return nil
  end)
  if ok and type(dimensions) == "table" and tonumber(dimensions.cols) then
    return tonumber(dimensions.cols)
  end

  return nil
end

local function active_tab_total_cells(window)
  local total = 0
  for _, info in ipairs(active_tab_panes_with_info(window)) do
    total = total + (pane_info_cells(info) or 0)
  end
  return total
end

local function workspace_sidebar_cells_for_total(total)
  local desired = read_workspace_sidebar_cells()

  if total > 0 and total <= workspace_sidebar_min_cells + 8 then
    return math.max(1, math.min(desired, total - 8))
  end

  return desired
end

local function workspace_sidebar_cells_for_window(window)
  return workspace_sidebar_cells_for_total(
    window and active_tab_total_cells(window) or 0
  )
end

local function pane_info_rows(info)
  if info and tonumber(info.height) then return tonumber(info.height) end
  if not (info and info.pane) then return nil end

  local ok, dimensions = pcall(function()
    if type(info.pane.get_dimensions) == "function" then
      return info.pane:get_dimensions()
    end
    return nil
  end)
  if ok and type(dimensions) == "table" then
    if tonumber(dimensions.viewport_rows) then
      return tonumber(dimensions.viewport_rows)
    end
    if tonumber(dimensions.rows) then
      return tonumber(dimensions.rows)
    end
  end

  return nil
end

local function workspace_sidebar_infos(window, for_action)
  local sidebars = {}
  local allow_slow_detection = for_action ~= false

  for _, info in ipairs(active_tab_panes_with_info(window)) do
    local candidate = info.pane
    local is_sidebar = allow_slow_detection
      and is_workspace_sidebar_pane_for_action(candidate)
      or is_workspace_sidebar_pane(candidate)
    if is_sidebar then
      table.insert(sidebars, info)
    end
  end

  return sidebars
end

local function all_mux_windows()
  local ok, windows = pcall(function()
    return wezterm.mux.all_windows()
  end)

  if ok and type(windows) == "table" then return windows end
  return {}
end

mux_window_tabs = function(mux_window)
  local ok, tabs = pcall(function()
    return mux_window:tabs()
  end)

  if ok and type(tabs) == "table" then return tabs end
  return {}
end

mux_tab_panes = function(tab)
  local ok, panes = pcall(function()
    return tab:panes()
  end)

  if ok and type(panes) == "table" then return panes end
  return {}
end

local function mux_window_workspace_name(mux_window)
  local ok, name = pcall(function()
    if type(mux_window.get_workspace) == "function" then
      return mux_window:get_workspace()
    end
    return nil
  end)

  if ok and name and name ~= "" then
    return normalize_workspace_name(name)
  end

  return nil
end

mux_window_for_workspace = function(name)
  local target = normalize_workspace_name(name)

  for _, mux_window in ipairs(all_mux_windows()) do
    if mux_window_workspace_name(mux_window) == target then
      return mux_window
    end
  end

  return nil
end

active_tab_info_for_mux_window = function(mux_window)
  local ok, tabs = pcall(function()
    return mux_window:tabs_with_info()
  end)
  if not ok or type(tabs) ~= "table" then return nil end

  for _, info in ipairs(tabs) do
    if info.is_active then return info end
  end

  return tabs[1]
end

local function tab_panes_with_info(tab)
  local ok, panes = pcall(function()
    return tab:panes_with_info()
  end)
  if ok and type(panes) == "table" then return panes end
  return {}
end

local function tab_sidebar_infos(tab)
  local sidebars = {}

  for _, info in ipairs(tab_panes_with_info(tab)) do
    if is_workspace_sidebar_pane(info.pane) then
      table.insert(sidebars, info)
    end
  end

  return sidebars
end

kill_pane_by_id = function(pane)
  if not pane then return end
  local ok, kill_method = pcall(function() return pane.kill end)
  if ok and type(kill_method) == "function" then
    pcall(function() pane:kill() end)
    return
  end

  if type(wezterm.run_child_process) ~= "function" then return end

  local id = tostring(pane_id(pane))
  local bins = {
    "/opt/homebrew/bin/wezterm",
    "/Applications/WezTerm.app/Contents/MacOS/wezterm",
  }

  for _, bin in ipairs(bins) do
    local f = io.open(bin, "r")
    if f then
      f:close()
      pcall(function()
        wezterm.run_child_process {
          bin,
          "cli",
          "kill-pane",
          "--pane-id",
          id,
        }
      end)
      return
	  end
	end
end

local function kill_sidebar_mux_pane(pane)
  if not pane or not is_workspace_sidebar_pane(pane) then return end
  kill_pane_by_id(pane)
end

local function dedupe_tab_sidebars(tab)
  local sidebars = tab_sidebar_infos(tab)
  if #sidebars == 0 then return nil end

  local tab_id = tab_key(tab)
  local keep = choose_sidebar_info_for_tab(tab_id, sidebars)
  local keep_id = keep and tostring(pane_id(keep.pane)) or nil

  for _, info in ipairs(sidebars) do
    local sidebar = info.pane
    if tostring(pane_id(sidebar)) ~= keep_id then
      kill_sidebar_mux_pane(sidebar)
    end
  end

  if keep then remember_sidebar_for_tab(tab_id, keep.pane) end
  return keep
end

tab_first_content_pane_info = function(tab)
  for _, info in ipairs(tab_panes_with_info(tab)) do
    if not is_workspace_sidebar_pane(info.pane) then
      return info
    end
  end

  return nil
end

local function kill_workspace_mux(name)
  local mux_window = mux_window_for_workspace(name)
  if not mux_window then return end

  for _, tab in ipairs(mux_window_tabs(mux_window)) do
    for _, pane in ipairs(mux_tab_panes(tab)) do
      kill_pane_by_id(pane)
    end
  end
end

delete_workspace = function(window, pane, name)
  local target = normalize_workspace_name(name)
  if target == "" or target == startup_workspace_name then return end

  local removed, remaining = delete_workspace_record(target)
  if not removed then return end

  last_content_pane_by_workspace[target] = nil

  local active = active_workspace_name(window)
  local fallback = remaining[1] and remaining[1].name or startup_workspace_name
  local deleting_active = target == active

  if deleting_active then
    window:perform_action(wezterm.action.SwitchToWorkspace { name = fallback }, pane)
  end

  local function finish_delete()
    kill_workspace_mux(target)
    write_workspace_sidebar_data(window, deleting_active and fallback or nil)

    if read_workspace_sidebar_visible()
      and type(sync_workspace_sidebar_later) == "function"
    then
      sync_workspace_sidebar_later(window, 0.12, false)
    end
  end

  if deleting_active and wezterm.time and wezterm.time.call_after then
    wezterm.time.call_after(0.18, finish_delete)
  else
    finish_delete()
  end
end

prewarm_workspace_sidebar = function(name, focus_sidebar)
  if not read_workspace_sidebar_visible() then return false end

  local mux_window = mux_window_for_workspace(name)
  if not mux_window then return false end

  local tab_info = active_tab_info_for_mux_window(mux_window)
  local tab = tab_info and tab_info.tab or nil
  if not tab then return false end

  local tab_id = tab_key(tab)
  local existing = dedupe_tab_sidebars(tab)
  if existing then
    if focus_sidebar then
      pcall(function() existing.pane:activate() end)
    else
      local content_info = tab_first_content_pane_info(tab)
      local content = content_info and content_info.pane or nil
      if content then pcall(function() content:activate() end) end
    end
    return true
  end

  if workspace_sidebar_prewarm_pending_by_tab[tab_id] then
    return true
  end

  local content_info = tab_first_content_pane_info(tab)
  local content = content_info and content_info.pane or nil
  if not content then return false end

  workspace_sidebar_prewarm_pending_by_tab[tab_id] = true
  write_workspace_sidebar_data(nil, normalize_workspace_name(name))

  local cells = workspace_sidebar_cells_for_total(pane_info_cells(content_info) or 0)
  local rows = pane_info_rows(content_info) or 36
  local sidebar = nil
  local ok = pcall(function()
    sidebar = content:split {
      direction = "Left",
      top_level = true,
      size = cells,
      args = {
        "/bin/zsh",
        workspace_sidebar_script,
        normalize_workspace_name(name),
        workspace_sidebar_data_file,
        tostring(rows),
        tostring(cells),
      },
    }
  end)

  if ok and sidebar then
    remember_sidebar_for_tab(tab_id, sidebar)
    if focus_sidebar then
      pcall(function() sidebar:activate() end)
    else
      pcall(function() content:activate() end)
    end
  else
    workspace_sidebar_prewarm_pending_by_tab[tab_id] = nil
  end

  if wezterm.time and wezterm.time.call_after then
    wezterm.time.call_after(0.7, function()
      workspace_sidebar_prewarm_pending_by_tab[tab_id] = nil
      dedupe_tab_sidebars(tab)
    end)
  else
    workspace_sidebar_prewarm_pending_by_tab[tab_id] = nil
  end

  return ok
end

local function any_workspace_sidebar()
  for _, mux_window in ipairs(all_mux_windows()) do
    for _, tab in ipairs(mux_window_tabs(mux_window)) do
      for _, pane in ipairs(mux_tab_panes(tab)) do
        if is_workspace_sidebar_pane(pane) then return true end
      end
    end
  end

  return false
end

function find_workspace_sidebar(window, for_action)
  local info = find_workspace_sidebar_info(window, for_action)
  return info and info.pane or nil
end

function find_workspace_sidebar_info(window, for_action)
  local sidebars = workspace_sidebar_infos(window, for_action)
  return choose_sidebar_info_for_tab(active_tab_key_for_window(window), sidebars)
end

local function dedupe_workspace_sidebars(window, for_action)
  local sidebars = workspace_sidebar_infos(window, for_action)
  if #sidebars == 0 then return nil end

  local tab_id = active_tab_key_for_window(window)
  local keep = choose_sidebar_info_for_tab(tab_id, sidebars)
  local keep_id = keep and tostring(pane_id(keep.pane)) or nil

  for _, info in ipairs(sidebars) do
    local sidebar = info.pane
    if tostring(pane_id(sidebar)) ~= keep_id then
      pcall(function() sidebar:activate() end)
      window:perform_action(
        wezterm.action.CloseCurrentPane { confirm = false },
        sidebar
      )
    end
  end

  if keep then remember_sidebar_for_tab(tab_id, keep.pane) end
  return keep
end

local function first_content_pane_info(window, for_action)
  for _, info in ipairs(active_tab_panes_with_info(window)) do
    local candidate = info.pane
    local is_sidebar = for_action
      and is_workspace_sidebar_pane_for_action(candidate)
      or is_workspace_sidebar_pane(candidate)
    if not is_sidebar then
      return info
    end
  end

  return nil
end

function first_content_pane(window)
  local info = first_content_pane_info(window, true)
  return info and info.pane or nil
end

last_content_pane = function(window)
  local ok, tab = pcall(function() return window:active_tab() end)
  local tab_id = ok and tab and tab_key(tab) or nil
  local preferred_ids = {
    tab_id and last_content_pane_by_tab[tab_id] or nil,
    last_content_pane_by_workspace[active_workspace_name(window)],
  }

  for _, preferred_id in ipairs(preferred_ids) do
    for _, info in ipairs(active_tab_panes_with_info(window)) do
      local candidate = info.pane
      if not is_workspace_sidebar_pane(candidate)
        and pane_matches_id(candidate, preferred_id)
      then
        return candidate
      end
    end
  end

  return first_content_pane(window)
end

activate_last_content_pane = function(window, fallback)
  local target = last_content_pane(window) or fallback
  if target and not is_workspace_sidebar_pane(target) then
    pcall(function() target:activate() end)
  end
  return target
end

function remember_workspace_sidebar_cells(window)
  local info = find_workspace_sidebar_info(window, false)
  local cells = pane_info_cells(info)
  if cells then write_workspace_sidebar_cells(cells) end
end

enforce_workspace_sidebar_min_cells = function(window)
  local info = find_workspace_sidebar_info(window, false)
  local cells = pane_info_cells(info)
  if not cells then return end

  if cells >= workspace_sidebar_min_cells then
    write_workspace_sidebar_cells(cells)
    return
  end

  local total = active_tab_total_cells(window)
  if total > workspace_sidebar_min_cells + 8 then
    local delta = workspace_sidebar_min_cells - cells
    window:perform_action(
      wezterm.action.AdjustPaneSize { "Right", delta },
      info.pane
    )
    write_workspace_sidebar_cells(workspace_sidebar_min_cells)
  else
    write_workspace_sidebar_cells(cells)
  end
end

local function active_tab_pane_counts(window)
  local content = 0
  local sidebars = 0

  for _, info in ipairs(active_tab_panes_with_info(window)) do
    if is_workspace_sidebar_pane(info.pane) then
      sidebars = sidebars + 1
    else
      content = content + 1
    end
  end

  return content, sidebars
end

local function close_current_tab(window, pane)
  remember_workspace_sidebar_cells(window)
  window:perform_action(
    wezterm.action.CloseCurrentTab { confirm = false },
    pane
  )
end

close_tab_if_closing_last_content_pane = function(window, pane)
  local content_count = active_tab_pane_counts(window)
  if content_count <= 1 then
    close_current_tab(window, pane)
    return true
  end

  return false
end

local function active_tab_rows(window)
  local info = first_content_pane_info(window, true)
  local rows = pane_info_rows(info)
  if rows then return rows end

  for _, candidate in ipairs(active_tab_panes_with_info(window)) do
    rows = pane_info_rows(candidate)
    if rows then return rows end
  end

  return 36
end

local function activate_content_from_sidebar(window, target)
  if not (wezterm.time and wezterm.time.call_after) then
    activate_last_content_pane(window, target)
    return
  end

  wezterm.time.call_after(0.12, function()
    local sidebar = find_workspace_sidebar(window)

    if sidebar then
      pcall(function()
        window:perform_action(
          wezterm.action.ActivatePaneDirection("Right"),
          sidebar
        )
      end)
    end

    activate_last_content_pane(window, target)
  end)
end

local function activate_sidebar_from_content(window)
  if not (wezterm.time and wezterm.time.call_after) then
    local sidebar = find_workspace_sidebar(window)
    if sidebar then pcall(function() sidebar:activate() end) end
    return
  end

  wezterm.time.call_after(0.12, function()
    local sidebar = find_workspace_sidebar(window)
    if sidebar then pcall(function() sidebar:activate() end) end
  end)
end

function close_workspace_sidebar(window, pane, keep_visible_state)
  remember_workspace_sidebar_cells(window)
  local tab_id = active_tab_key_for_window(window)

  if not keep_visible_state then
    write_workspace_sidebar_visible(false)
  end

  local sidebars = workspace_sidebar_infos(window)
  if #sidebars == 0 then return end

  local target = first_content_pane(window)
  for _, info in ipairs(sidebars) do
    local sidebar = info.pane
    pcall(function() sidebar:activate() end)
    window:perform_action(
      wezterm.action.CloseCurrentPane { confirm = false },
      sidebar
    )
  end
  if tab_id then
    workspace_sidebar_pane_by_tab[tab_id] = nil
    workspace_sidebar_prewarm_pending_by_tab[tab_id] = nil
  end

  if target then
    pcall(function() target:activate() end)
  end
end

function open_workspace_sidebar(window, pane, focus_sidebar)
  if workspace_sidebar_split_pending then return end

  if type(write_workspace_sidebar_data) == "function" then
    write_workspace_sidebar_data(window)
  end

  local existing_info = dedupe_workspace_sidebars(window, false)
  local existing = existing_info and existing_info.pane or nil
  if existing then
    write_workspace_sidebar_visible(true)
    remember_sidebar_for_tab(active_tab_key_for_window(window), existing)
    local target = first_content_pane(window)
    if focus_sidebar then
      pcall(function() existing:activate() end)
    elseif target then
      activate_content_from_sidebar(window, target)
    end
    return
  end

  local target = first_content_pane(window) or pane

  workspace_sidebar_split_pending = true
  local tab_id = active_tab_key_for_window(window)
  if tab_id then workspace_sidebar_prewarm_pending_by_tab[tab_id] = true end
  write_workspace_sidebar_visible(true)
  window:perform_action(
    wezterm.action.SplitPane {
      direction = "Left",
      top_level = true,
      size = { Cells = workspace_sidebar_cells_for_window(window) },
      command = {
        args = {
          "/bin/zsh",
          workspace_sidebar_script,
          active_workspace_name(window),
          workspace_sidebar_data_file,
          tostring(active_tab_rows(window)),
          tostring(workspace_sidebar_cells_for_window(window)),
        },
      },
    },
    target
  )

  if focus_sidebar then
    activate_sidebar_from_content(window)
  else
    activate_content_from_sidebar(window, target)
  end

  if wezterm.time and wezterm.time.call_after then
    wezterm.time.call_after(0.5, function()
      workspace_sidebar_split_pending = false
      if tab_id then workspace_sidebar_prewarm_pending_by_tab[tab_id] = nil end
      dedupe_workspace_sidebars(window, false)
    end)
  else
    workspace_sidebar_split_pending = false
    if tab_id then workspace_sidebar_prewarm_pending_by_tab[tab_id] = nil end
  end
end

local function sync_workspace_sidebar(window, focus_sidebar)
  if not read_workspace_sidebar_visible() then return end

  local ok, active_pane = pcall(function()
    return window:active_pane()
  end)
  if not ok or not active_pane then return end

  if type(write_workspace_sidebar_data) == "function" then
    write_workspace_sidebar_data(window)
  end

  dedupe_workspace_sidebars(window, false)

  open_workspace_sidebar(window, active_pane, focus_sidebar)
end

sync_workspace_sidebar_later = function(window, delay, focus_sidebar)
  if workspace_sidebar_sync_pending then return end
  workspace_sidebar_sync_pending = true

  local function run()
    workspace_sidebar_sync_pending = false
    pcall(function()
      sync_workspace_sidebar(window, focus_sidebar)
    end)
  end

  if wezterm.time and wezterm.time.call_after then
    wezterm.time.call_after(delay or 0.12, run)
  else
    run()
  end
end

local function toggle_workspace_sidebar(window, pane)
  if read_workspace_sidebar_visible() then
    write_workspace_sidebar_visible(false)
    close_workspace_sidebar(window, pane, true)
    stop_all_workspace_sidebar_helpers()
  else
    stop_all_workspace_sidebar_helpers()
    write_workspace_sidebar_visible(true)
    if wezterm.time and wezterm.time.call_after then
      wezterm.time.call_after(0.12, function()
        open_workspace_sidebar(window, pane, true)
      end)
    else
      open_workspace_sidebar(window, pane, true)
    end
  end
end

local function action_on_content_pane(action)
  return wezterm.action_callback(function(window, pane)
    local target = pane
    if is_workspace_sidebar_pane(pane) then
      target = first_content_pane(window) or pane
    end

    window:perform_action(action, target)
    if read_workspace_sidebar_visible()
      and type(sync_workspace_sidebar_later) == "function"
    then
      sync_workspace_sidebar_later(window, 0.12, false)
    end
  end)
end

local function close_sidebar_or_current_pane(window, pane)
  if is_workspace_sidebar_pane(pane) then
    close_workspace_sidebar(window, pane)
  elseif close_tab_if_closing_last_content_pane(window, pane) then
    return
  else
    window:perform_action(wezterm.action.CloseCurrentPane { confirm = false }, pane)
  end
end

local function sidebar_create_or_send_key(key, mods)
  return wezterm.action_callback(function(window, pane)
    create_workspace(window, pane)
  end)
end

local function selected_workspace_from_sidebar_text(pane)
  local ok, text = pcall(function()
    if type(pane.get_lines_as_text) == "function" then
      return pane:get_lines_as_text(80)
    end
    return nil
  end)
  if not ok or not text then return nil end

  for line in tostring(text):gmatch("[^\r\n]+") do
    local cleaned = clean_status_text(line)
    local index = tonumber(cleaned:match("^%s*[%*>]%s+(%d+)"))
    local name = index and workspace_at_index(index) or nil
    if name and name ~= "" then
      return name
    end
  end

  return nil
end

local function sidebar_delete_or_send_backspace(window, pane)
  if is_workspace_sidebar_pane_for_action(pane) then
    local target = workspace_sidebar_selected_by_pane[tostring(pane_id(pane))]
      or selected_workspace_from_sidebar_text(pane)
    if target and target ~= "" then
      delete_workspace(window, pane, target)
    end
    return
  end

  window:perform_action(wezterm.action.SendString("\x17"), pane)
end


  if options.enable_keys then
    local keys = {
      { key = "w", mods = "CMD", action = wezterm.action_callback(close_sidebar_or_current_pane) },
      { key = "Backspace", mods = "ALT", action = wezterm.action_callback(sidebar_delete_or_send_backspace) },
      { key = "n", mods = "ALT", action = sidebar_create_or_send_key("n", "ALT") },
      { key = "N", mods = "ALT|SHIFT", action = sidebar_create_or_send_key("N", "ALT|SHIFT") },
      { key = "LeftArrow", mods = "ALT", action = wezterm.action_callback(activate_previous_tab) },
      { key = "RightArrow", mods = "ALT", action = wezterm.action_callback(activate_next_or_create_tab) },
      { key = "R", mods = "ALT", action = wezterm.action_callback(rename_tab) },
      { key = "r", mods = "ALT", action = wezterm.action_callback(rename_tab) },
      { key = "W", mods = "ALT", action = wezterm.action_callback(open_workspace_switcher) },
      { key = "w", mods = "ALT", action = wezterm.action_callback(open_workspace_switcher) },
      { key = "D", mods = "CMD", action = wezterm.action_callback(toggle_workspace_rail) },
      { key = "d", mods = "CMD", action = wezterm.action_callback(toggle_workspace_rail) },
      { key = "D", mods = "CMD|SHIFT", action = wezterm.action_callback(toggle_workspace_rail) },
      { key = "/", mods = "ALT", action = wezterm.action_callback(toggle_workspace_sidebar_help) },
      { key = "phys:B", mods = "CMD", action = wezterm.action_callback(toggle_workspace_sidebar) },
      { key = "phys:B", mods = "CMD|SHIFT", action = wezterm.action_callback(toggle_workspace_sidebar) },
      { key = "B", mods = "CMD|SHIFT", action = wezterm.action_callback(toggle_workspace_sidebar) },
      { key = "b", mods = "CMD", action = wezterm.action_callback(toggle_workspace_sidebar) },
      { key = "R", mods = "ALT|SHIFT", action = wezterm.action_callback(rename_workspace) },
      { key = "r", mods = "ALT|SHIFT", action = wezterm.action_callback(rename_workspace) },
      { key = "LeftArrow", mods = "ALT|SHIFT", action = switch_workspace_relative(-1) },
      { key = "RightArrow", mods = "ALT|SHIFT", action = switch_workspace_relative(1) },
      { key = "\\", mods = "ALT", action = action_on_content_pane(wezterm.action.SplitPane { direction = "Right", size = { Percent = 50 } }) },
      { key = "\\", mods = "ALT|SHIFT", action = action_on_content_pane(wezterm.action.SplitPane { direction = "Left", size = { Percent = 50 } }) },
      { key = "|", mods = "ALT|SHIFT", action = action_on_content_pane(wezterm.action.SplitPane { direction = "Left", size = { Percent = 50 } }) },
      { key = "-", mods = "ALT", action = action_on_content_pane(wezterm.action.SplitPane { direction = "Down", size = { Percent = 50 } }) },
      { key = "_", mods = "ALT|SHIFT", action = action_on_content_pane(wezterm.action.SplitPane { direction = "Up", size = { Percent = 50 } }) },
      { key = "-", mods = "ALT|SHIFT", action = action_on_content_pane(wezterm.action.SplitPane { direction = "Up", size = { Percent = 50 } }) },
      { key = "UpArrow", mods = "ALT", action = switch_workspace_relative(-1, false) },
      { key = "DownArrow", mods = "ALT", action = switch_workspace_relative(1, true) },
    }

    for number = 1, 9 do
      table.insert(keys, { key = tostring(number), mods = "NONE", action = switch_sidebar_or_send_number(number) })
      table.insert(keys, { key = tostring(number), mods = "ALT", action = activate_or_create_numbered_tab(number) })
      table.insert(keys, { key = tostring(number), mods = "ALT|CMD", action = switch_numbered_workspace(number) })
    end

    append_list(config, "keys", keys)
  end

  if options.enable_mouse_bindings then
    append_list(config, "mouse_bindings", {
      {
        event = { Up = { streak = 1, button = "Left" } },
        mods = "NONE",
        action = wezterm.action.OpenLinkAtMouseCursor,
      },
    })
  end
end

return M
