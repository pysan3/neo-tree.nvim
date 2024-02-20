local utils = require("neo-tree.utils")
local renderer = require("neo-tree.ui.renderer")
local e = require("neo-tree.types.enums")
local mapping_helper = require("neo-tree.setup.mapping-helper")
local events = require("neo-tree.events")
local log = require("neo-tree.log")
local popups = require("neo-tree.ui.popups")
local file_nesting = require("neo-tree.sources.common.file-nesting")
local highlights = require("neo-tree.ui.highlights")
local manager = require("neo-tree.sources.manager")
local netrw = require("neo-tree.setup.netrw")
local hijack_cursor = require("neo-tree.sources.common.hijack_cursor")
local nio = require("neo-tree.utils.nio_wrapper")
local wm = require("neo-tree.manager.wm")
local Path = require("pathlib")

local locals = {} -- Functions exported for test purposes

---@alias NeotreeFixedPosition NeotreeWindowPosition # Special type name to suggest position ~= "current".
---@alias NeotreeCurrentWinId integer
---@alias NeotreeWindowPosId NeotreeFixedPosition|NeotreeCurrentWinId

---@class NeotreeWindowBeforeJump
---@field prev_winid integer|nil
---@field prev_bufnr integer|nil

---@class NeotreeManager
---@field tabid integer
---@field previous_source NeotreeSourceName # Previous source name rendered with this manager.
---@field previous_position table<NeotreeSourceName, NeotreeFixedPosition|nil> # Last position the state was rendered.
---@field position_state table<NeotreeWindowPosId, NeotreeStateId|nil> # What state occupies each position.
---@field window_lookup table<NeotreeWindowPosId, NuiSplit|NuiPopup|NeotreeCurrentWin|nil> # NuiSplit or NuiPopup that is assigned to each window.
---@field before_jump_info table<NeotreeWindowPosId, NeotreeWindowBeforeJump|nil>
---@field __timer_start number|nil # Calculate how much time has elapsed.
local Manager = setmetatable({
  -- Attributes defined here will be shared across all instances of Manager
  -- Think it as a class attribute, and put caches, const values here.

  ---@type NeotreeConfig # Store user config.
  config = {},
  ---@type table<integer, NeotreeManager> # One manager per tab. Configure via `config.share_state_among_tabs`.
  cache = {},
  ---@type table<integer, table<NeotreeStateId, NeotreeState>> # Table with values returned by `source.setup()`.
  states_lookup = {},
  ---@type table<NeotreeSourceName, NeotreeManager.source_info> # calculated with `search_sources`.
  source_lookup = {},
  ---@type table<NeotreeWindowPosition, NeotreeStateId|nil> # Global storage to remember what state occupies each position.
  global_position_state = {},
  ---@type nio.tasks.Task[]|{ index: integer, done: integer }
  global_tasks = { index = 0, done = 0 },
  default_source = "",
  setup_is_done = false,
}, {
  __call = function(cls, ...)
    return cls.new(cls, ...)
  end,
})
Manager.__index = Manager

---Create new manager instance or return cache if already created.
---@param global_config NeotreeConfig
---@param tabid integer
function Manager.new(global_config, tabid)
  if not Manager.setup_is_done then
    Manager.setup(global_config)
  end
  Manager.wait_all_tasks()
  if Manager.cache[tabid] then
    return Manager.cache[tabid]
  end
  local self = setmetatable({
    tabid = tabid,
    previous_source = Manager.default_source,
    previous_position = {},
    position_state = {},
    window_lookup = {},
    before_jump_info = {},
  }, Manager)
  Manager.cache[tabid] = self
  events.subscribe({
    id = "__neo_tree_internal_tab_enter_" .. self.tabid,
    event = events.VIM_TAB_ENTER,
    handler = function()
      self:on_tab_enter()
    end,
  })
  events.subscribe({
    id = "__neo_tree_internal_win_closed" .. self.tabid,
    event = events.VIM_WIN_CLOSED,
    handler = function(args)
      self:on_win_closed(args)
    end,
  })
  return self
end

---Get the manager associated a tabpage.
---@param tabid integer
function Manager.get(tabid)
  if not Manager.setup_is_done then
    return nil
  end
  Manager.wait_all_tasks()
  return Manager.cache[tabid]
end

---Get the manager associated to current tabpage.
function Manager.get_current()
  return Manager.get(vim.api.nvim_get_current_tabpage())
end

---Generate key to lookup in `self.window_lookup`.
---@param position NeotreeWindowPosition
---@param winid integer|nil # Specify winid to use when position == "current". Defaults to `nvim_get_current_win`.
---@return NeotreeFixedPosition|NeotreeCurrentWinId
function locals.get_posid(position, winid)
  if position == "current" then
    return winid or vim.api.nvim_get_current_win()
  else
    return position
  end
end

---Generate WindowPosition from output of `get_posid`.
---@param posid NeotreeWindowPosId
---@return NeotreeWindowPosition
function locals.get_position(posid)
  local position = locals.pos_is_fixed(posid) and posid or e.valid_window_positions.CURRENT
  ---@cast position NeotreeWindowPosition
  return position
end

---Checks if given `posid` points to a fixed (split or float) window.
---@param posid NeotreeWindowPosId
function locals.pos_is_fixed(posid)
  return type(posid) == "string" and posid ~= "current"
end

---Redraw the tree without relaoding from the source.
---@param state NeotreeState
---@param curpos NeotreeCursorPos|nil # Set cursor position. (row, col)
function Manager:redraw(state, curpos)
  self.__timer_start = os.clock()
  if state.bufnr and vim.api.nvim_buf_is_loaded(state.bufnr) then
    vim.api.nvim_create_autocmd("CursorMoved", {
      once = true,
      desc = "Neo-tree: monitor cursor movement from user.",
      buffer = state.bufnr,
      callback = function()
        if vim.api.nvim_get_current_buf() == state.bufnr then
          state.cursor_update_by_user = true
        end
      end,
    })
    nio.run(function()
      state:redraw(self, nil, curpos)
    end)
  end
end

---Navigate to appropriate source with correct window
---@param args NeotreeManagerNavigateArgs
function Manager:navigate(args)
  if args.action == "toggleall" then
    return self:toggle_all()
  elseif args.action == "closeall" then
    return self:close_all()
  end
  args.action = args.action or "focus"
  if not args.source or args.source == "last" then
    args.source = self.previous_source
  end
  if not args.position then
    args.position = self.previous_position[args.source] or e.valid_window_positions.FLOAT
  end
  if not args.scope then
    args.scope = locals.calculate_default_scope(args.position)
  end
  local state = self:search_state(args.source, {
    id = args.id,
    dir = args.dir,
    position = args.position,
    scope = args.scope,
    reveal_file = args.reveal_file,
  })
  state.current_position = args.position
  state.scope = args.scope
  local posid = locals.get_posid(args.position)
  if args.action == "close" or (args.toggle and self.window_lookup[posid]) then
    return self:close_win(posid)
  end
  self:open_state(state, args.position, Path(args.dir), args.reveal_file and Path(args.reveal_file))
end

function locals.calculate_default_scope(position)
  if vim.tbl_contains(e.valid_phantom_window_positions, position) then
    return e.state_scopes.WINDOW
  else
    return e.state_scopes.TABPAGE
  end
end

---Navigate to state (calls state:navigate).
---@param state NeotreeState
---@param position NeotreeWindowPosition
---@param dir PathlibPath|nil # If nil, uses `state.dir`.
---@param reveal_file PathlibPath|nil # Passed to state:navigate.
function Manager:open_state(state, position, dir, reveal_file)
  self.__timer_start = os.clock() -- Start timeit.
  local jump_before = self:generate_jump_before_info()
  if not state.bufnr or not vim.api.nvim_buf_is_loaded(state.bufnr) then
    state.bufnr = vim.api.nvim_create_buf(false, false)
  end
  if jump_before and jump_before.prev_winid then
    vim.api.nvim_set_current_win(jump_before.prev_winid)
  end
  local window = self:create_win(position, position, state, nil, "TODO", true)
  local new_posid = locals.get_posid(position, window.winid)
  self.window_lookup[new_posid] = window
  self.before_jump_info[new_posid] = jump_before
  local window_width = {
    width = vim.api.nvim_win_get_width(window.winid),
    strict = position ~= "left" and position ~= "right",
  }
  nio.run(function()
    return state:navigate(dir or state.dir, reveal_file, window_width, self, {})
  end)
end

---Function called if state:navigate is finished successfully.
---@param state NeotreeState
---@param requested_window_width integer|nil
---@param requested_curpos NeotreeCursorPos|nil
function Manager:done(state, requested_window_width, requested_curpos)
  nio.elapsed("inside manager:done", self.__timer_start)
  local position = state.current_position
  if position ~= "left" and position ~= "right" then
    requested_window_width = nil
  end
  vim.schedule(function()
    nio.elapsed("inside schedule", self.__timer_start)
    for pos, state_id in pairs(self.position_state) do
      if state_id == state.id and pos ~= position then
        self:close_win(pos)
      end
    end
    nio.elapsed("after close all other wins", self.__timer_start)
    self.previous_source = state.name
    self.previous_position[state.name] = position
    local posid = locals.get_posid(position)
    nio.elapsed("get posid", self.__timer_start)
    local jump_before = self:generate_jump_before_info()
    nio.elapsed("after generate_jump_before_info", self.__timer_start)
    local window = self:create_win(posid, position, state, requested_window_width, "TODO", false)
    nio.elapsed("after create_win", self.__timer_start)
    local new_posid = locals.get_posid(position, window.winid)
    nio.elapsed("get new posid", self.__timer_start)
    self.before_jump_info[new_posid] = jump_before
    self.position_state[new_posid] = state.id
    if state.scope == e.state_scopes.GLOBAL and locals.pos_is_fixed(new_posid) then -- Also register state to global position table.
      self.global_position_state[position] = state.id
    elseif self.global_position_state[position] == state.id then -- State used to be a global state but not anymore.
      self.global_position_state[position] = nil
    end
    nio.elapsed("position before: " .. vim.inspect(state.position), self.__timer_start)
    renderer.position.save(state)
    nio.elapsed("position saved: " .. vim.inspect(state.position), self.__timer_start)
    state.position = vim.tbl_extend("force", state.position, requested_curpos or {})
    if state.cursor_update_by_user then
      renderer.position.clear(state)
      nio.elapsed("clear curpos done", self.__timer_start)
    else
      nio.elapsed("restore curpos start: " .. vim.inspect(state.position), self.__timer_start)
      -- TODO: This is a very nasty workaround
      -- refactor all renderer.postiion related code later
      state.winid = window.winid ---@diagnostic disable-line
      renderer.position.restore(state)
      state.winid = nil ---@diagnostic disable-line
      nio.elapsed("restore curpos done", self.__timer_start)
    end
    state.cursor_update_by_user = nil -- reset monitor
    for lhs, opts in pairs(state.config.window.mappings) do
      local func = opts.func
      local vfunc = opts.vfunc
      local config = opts.config or {}
      for key, value in pairs(config) do
        if type(value) == "table" then
          state.config[key] = vim.tbl_deep_extend("force", state.config[key] or {}, value)
        else
          state.config[key] = value
        end
      end
      opts = locals.normalize_keymap_opts(opts)
      window:map("n", lhs, function()
        return func and nio.run(function()
          return func(state)
        end)
      end, opts)
      if vfunc then
        window:map(
          "v",
          lhs,
          nio.wrap(function()
            local ESC_KEY = vim.api.nvim_replace_termcodes("<ESC>", true, false, true)
            vim.api.nvim_feedkeys(ESC_KEY, "i", true)
            vim.schedule(function()
              local selected_nodes = locals.get_selected_nodes(state)
              if selected_nodes and #selected_nodes > 0 then
                nio.run(function()
                  vfunc(state, selected_nodes)
                end)
              end
            end)
          end),
          opts
        )
      end
    end
    nio.elapsed("set keymap done", self.__timer_start)
    log.info(
      string.format(
        "%s %s %.3f sec, nio: %s",
        state.name,
        position,
        os.clock() - self.__timer_start,
        nio.check_nio_install() and "on" or "off"
      )
    )
  end)
end

function locals.get_selected_nodes(state)
  if state.winid ~= vim.api.nvim_get_current_win() then
    return nil
  end
  local start_pos = vim.fn.getpos("'<")[2]
  local end_pos = vim.fn.getpos("'>")[2]
  if end_pos < start_pos then
    -- I'm not sure if this could actually happen, but just in case
    start_pos, end_pos = end_pos, start_pos
  end
  local selected_nodes = {}
  while start_pos <= end_pos do
    local node = state.tree:get_node(start_pos)
    if node then
      table.insert(selected_nodes, node)
    end
    start_pos = start_pos + 1
  end
  return selected_nodes
end

function locals.normalize_keymap_opts(opts)
  local valid_keys = {
    "nowait",
    "silent",
    "script",
    "expr",
    "unique",
    "noremap",
    "desc",
    "callback",
    "replace_keycodes",
  }
  local res = {}
  for _, key in ipairs(valid_keys) do
    res[key] = opts[key]
  end
  return res
end

function Manager:generate_jump_before_info()
  local cur_winid = vim.api.nvim_get_current_win()
  local nt_window = self:search_win_by_winid(cur_winid)
  if nt_window then
    return self.before_jump_info[nt_window]
  else
    return {
      prev_winid = cur_winid,
      prev_bufnr = vim.api.nvim_get_current_buf(),
    }
  end
end

---Function called if state fails to render with given args.
---@param reason string # Give me a reason of the fail that might be reported to the user.
---@param new_state_id NeotreeStateId|nil # A possible alternative state id that can handle the request.
---@param old_state NeotreeState
---@param dir PathlibPath # Param passed to `state:navigate`
---@param path_to_reveal PathlibPath|nil # Param passed to `state:navigate`
---@param window_width { width: integer, strict: boolean } # Default window width.
---@param args table # Optional args that may be passed from a different state on fail.
function Manager:fail(reason, new_state_id, old_state, dir, path_to_reveal, window_width, args)
  if not new_state_id then
    log.error("Cannot find new state. " .. reason)
    return false
  end
  local source_name = old_state.name
  local new_state = self:search_state(source_name, {
    id = new_state_id,
    dir = dir:tostring(),
    position = old_state.current_position,
  })
  if not new_state or new_state.id == old_state.id then
    log.error("Same state is returned. Bail out because: " .. reason)
    return false
  end
  return new_state:navigate(dir, path_to_reveal, window_width, self, args)
end

---Fetch appropriate state based on args and tabid.
---@param source_name NeotreeSourceName
---@param args NeotreeManagerSearchArgs
---@param tabid integer|nil # Defaults to `nvim_get_current_tabpage`.
function Manager:search_state(source_name, args, tabid)
  if not self.source_lookup[source_name] or not self.source_lookup[source_name].setup_is_done then
    self.wait_all_tasks()
    return self:search_state(source_name, args, tabid)
  end
  if args.dir == "." then
    args.dir = nil -- use getcwd instead to get absolute path
  end
  args.dir = args.dir or vim.fn.getcwd(0, self:get_tabid(tabid))
  local info = self.source_lookup[source_name]
  local mod = require(self.source_lookup[source_name].module_path)
  local mod_id = mod.calculate_state_id(args)
  if mod_id == nil then
    args.scope = "global"
    mod_id = "__internal_global"
  end
  local id = source_name .. mod_id
  if args.scope == "window" then
    id = "TODO: RANDOM"
  end
  local state = self:get_state(id, tabid)
    or self:set_state(mod.new(info.source_config, id, args.dir), tabid) -- register `mod.new`
  return state
end

---Normalize tabid or 0 when `self.config.share_state_among_tabs`.
---@param state_id NeotreeStateId
---@param tabid integer|nil
function Manager:get_state(state_id, tabid)
  local _tabid = self:get_tabid(tabid)
  if not self.states_lookup[_tabid] then
    self.states_lookup[_tabid] = {}
  end
  return self.states_lookup[_tabid][state_id]
end

---Normalize tabid or 0 when `self.config.share_state_among_tabs` and set state to appropriate place.
---@param state NeotreeState
---@param tabid integer|nil
function Manager:set_state(state, tabid)
  local _tabid = self:get_tabid(tabid)
  if not self.states_lookup[_tabid] then
    self.states_lookup[_tabid] = {}
  end
  self.states_lookup[_tabid][state.id] = state
  return state
end

---Normalize tabid or 0 when `self.config.share_state_among_tabs`.
---@param tabid integer|nil
---@return integer
function Manager:get_tabid(tabid)
  return self.config.share_state_among_tabs and 0
    or tabid
    or self.tabid
    or vim.api.nvim_get_current_tabpage()
end

-- ╭─────────────────────────────────────────────────────────╮
-- │                    Window Management                    │
-- ╰─────────────────────────────────────────────────────────╯

---Focus window of `position`. Create one if does not exist.
---@param posid NeotreeWindowPosId # Posid to look for. Returns already created window if exists.
---@param position NeotreeWindowPosition|nil # Position to create new window. If nil calculates from `posid`.
---@param state NeotreeState
---@param requested_width integer|nil
---@param name string # Window name
---@param focus boolean|nil # If true, calls nvim_set_current_win.
function Manager:create_win(posid, position, state, requested_width, name, focus)
  local window = self.window_lookup[posid]
  if not window then
    position = position or locals.get_position(posid)
    window = wm.create_win(position, state.window, requested_width, name, state.bufnr)
    window.bufnr = state.bufnr
  end
  window:update_layout({ relative = locals.pos_is_fixed(posid) and "editor" or "win" }) ---@diagnostic disable-line
  window:show() ---@diagnostic disable-line -- lua_ls cannot correctly detect interfaces.
  if not window.winid or not vim.api.nvim_win_is_valid(window.winid) then
    -- purge and retry
    self.window_lookup[posid]:unmount() ---@diagnostic disable-line -- lua_ls cannot correctly detect interfaces.
    self.window_lookup[posid] = nil
    return self:create_win(posid, position, state, requested_width, name, focus)
  end
  if requested_width and vim.api.nvim_win_get_width(window.winid) < requested_width then
    vim.api.nvim_win_set_width(window.winid, requested_width)
  end
  if focus then
    vim.api.nvim_set_current_win(window.winid)
  end
  window:on("BufWinLeave", function(args)
    vim.print(string.format([[BufDelete args: %s]], vim.inspect(args)))
    vim.print(
      string.format(
        [[vim.api.nvim_get_current_buf(): %s]],
        vim.inspect(vim.api.nvim_get_current_buf())
      )
    )
    vim.print(
      string.format(
        [[vim.api.nvim_get_current_win(): %s]],
        vim.inspect(vim.api.nvim_get_current_win())
      )
    )
    renderer.position.save(state)
    vim.print(string.format([[state.position: %s]], vim.inspect(state.position)))
  end, { once = true })
  return window
end

---Close window in position. Calls `window:unmount()`
---@param posid NeotreeWindowPosId
function Manager:close_win(posid)
  local window = posid and self.window_lookup[posid]
  if window then
    local state_id = self.position_state[posid]
    self.position_state[posid] = nil
    if self.global_position_state[posid] == state_id then
      self.global_position_state[posid] = nil
    end
    window:hide() ---@diagnostic disable-line -- lua_ls cannot correctly detect interfaces.
    local prev_winid = self.before_jump_info[posid].prev_winid
    if prev_winid and vim.api.nvim_win_is_valid(prev_winid) then
      vim.api.nvim_set_current_win(prev_winid)
    end
  end
end

---@param winid integer|nil
function Manager:search_win_by_winid(winid)
  if not winid then
    return nil
  end
  for pos, window in pairs(self.window_lookup) do
    if window.winid == winid then
      return pos
    end
  end
end

---@param state_id NeotreeStateId
function Manager:search_win_by_state_id(state_id)
  if not state_id then
    return nil
  end
  for pos, id in pairs(self.position_state) do
    if id == state_id then
      return pos
    end
  end
end

---Check if there exists a window for state.
---@param state_id NeotreeStateId
function Manager:window_exists(state_id)
  local pos = self:search_win_by_state_id(state_id)
  vim.print(string.format([[state_id: %s]], vim.inspect(state_id)))
  vim.print(string.format([[pos: %s]], vim.inspect(pos)))
  local window = pos and self.window_lookup[pos]
  if window then
    vim.print(string.format([[window.winid: %s]], vim.inspect(window.winid)))
    vim.print(
      string.format(
        [[vim.api.nvim_win_is_valid(window.winid): %s]],
        vim.inspect(vim.api.nvim_win_is_valid(window.winid))
      )
    )
  end
  if window and window.winid and vim.api.nvim_win_is_valid(window.winid) then
    return window.winid
  end
end

---Run callback on state's window if exists.
---@generic T
---@param state_id NeotreeStateId
---@param cb fun(...: any): T
---@return T|nil
function Manager:nvim_win_call(state_id, cb)
  local winid = self:window_exists(state_id)
  return winid and vim.api.nvim_win_call(winid, cb)
end

function Manager:close_all()
  for pos, _ in pairs(self.window_lookup) do
    self:close_win(pos)
  end
end

function Manager:toggle_all()
  local function valid(window)
    return not not window.winid
  end
  local has_active = #vim.tbl_filter(valid, self.window_lookup) > 0
  if has_active then
    return self:close_all()
  else
    for pos, state_id in pairs(self.position_state) do
      local state = self:get_state(state_id)
      if state then
        if not locals.pos_is_fixed(pos) then
          ---@cast pos integer
          vim.api.nvim_set_current_win(pos)
          pos = e.valid_window_positions.CURRENT
        end
        self:open_state(state, pos --[[@as NeotreeWindowPosition]], state.dir)
      end
    end
  end
end

-- ╭─────────────────────────────────────────────────────────╮
-- │                 Instance Initialization                 │
-- ╰─────────────────────────────────────────────────────────╯

function Manager.sync_user_config(user_config, default_config)
  local sync_recursive = {
    "git_status_async_options",
    "open_files_do_not_replace_types",
    "source_selector",
  }
  Manager.config = vim.tbl_extend("force", default_config, Manager.config, user_config)
  for _, key in ipairs(sync_recursive) do
    Manager.config[key] = vim.tbl_deep_extend(
      "force",
      default_config[key],
      Manager.config[key] or {},
      user_config[key] or {}
    )
  end
end

---Create new manager instance or return cache if already created.
---@param user_config NeotreeConfig
---@return NeotreeSourceName[]
function Manager.setup(user_config)
  Manager.wait_all_tasks()
  local default_config = require("neo-tree.defaults")
  Manager.sync_user_config(user_config, default_config)
  local sources = user_config.sources or Manager.config.sources or {}
  -- TODO: Remove me on real release.
  if sources[1] ~= "filetree" or #sources ~= 1 then
    log.warn("TESTING BRANCH. You've only got one source option: filetree.")
    local index = 1
    for _, source in ipairs(sources) do
      if string.find(source, ".", nil, true) then -- External sources, I accept you.
        index = index + 1
        sources[index] = source
      end
    end
    sources[1] = "filetree"
  end
  Manager.set_sources(sources)
  Manager.default_source = locals.name_from_source(sources[1])
  for source_name, info in pairs(Manager.source_lookup) do
    Manager.global_tasks.index = Manager.global_tasks.index + 1
    Manager.global_tasks[Manager.global_tasks.index] = nio.run(function()
      if info.setup_is_done then
        return -- NOTE: only run once per source
      end
      local mod = require(info.module_path)
      ---@type NeotreeConfig.source_config
      local user_source_config = user_config[source_name] or {}
      ---@type NeotreeConfig.source_config
      local default_source_config = default_config[source_name] or {} ---@diagnostic disable-line
      info.source_config = {
        name = mod.name,
        display_name = user_source_config.display_name or mod.display_name,
      }
      info.source_config.commands = vim.tbl_extend(
        "force",
        default_source_config.commands or {},
        mod.commands or {},
        user_source_config.commands or {}
      )
      user_source_config.window = user_source_config.window or {}
      info.source_config.window = vim.tbl_deep_extend(
        "force",
        default_source_config.window or {},
        mod.window or {},
        user_source_config.window
      )
      if Manager.config.use_default_mappings == false then
        default_config.window.mappings = {}
        default_source_config.window.mappings = {}
      end
      local default_mapping_options = vim.tbl_extend(
        "force",
        { noremap = true },
        default_config.window.mapping_options,
        user_source_config.window.mapping_options or {}
      )
      info.source_config.window.mappings = locals.fix_and_merge_mappings(
        info.source_config.commands,
        default_mapping_options,
        default_config.window.mappings or {},
        default_source_config.window.mappings or {},
        user_source_config.window.mappings or {}
      )
      info.source_config.components = locals.merge_components(
        default_config.default_component_configs or {},
        -- ISSUE: let sources define their default component configs?
        -- mod.default_component_configs or {},
        user_config.default_component_configs or {},
        user_source_config.components or {}
      )
      info.source_config.renderers = locals.merge_renderers(
        info.source_config.components,
        default_config.renderers or {},
        -- ISSUE: let sources define their default renderers?
        -- mod.renderers or {},
        user_config.renderers or {},
        user_source_config.renderers or {}
      )
      -- copy remaining config values
      for key, value in pairs(default_source_config) do
        ---@cast value any
        if not info.source_config[key] then
          if type(value) == "table" then
            info.source_config[key] =
              vim.tbl_deep_extend("force", value, user_source_config[key] or {})
          else
            info.source_config[key] = user_source_config[key] or value
          end
        end
      end
      user_config[source_name] = info.source_config
      Manager.config[source_name] = "You shouldn't be accessing this value."
      mod.setup(info.source_config, vim.tbl_deep_extend("force", default_config, user_config))
      info.setup_is_done = true
    end)
  end
  if not Manager.setup_is_done then
    -- Only run this section once.
    -- Others can be run multiple times to update user config.
    events.subscribe({
      event = events.VIM_TAB_NEW_ENTERED,
      handler = function()
        Manager.global_tasks.index = Manager.global_tasks.index + 1
        Manager.global_tasks[Manager.global_tasks.index] = nio.run(function()
          local self = Manager.new(user_config, vim.api.nvim_get_current_tabpage())
          self:on_tab_enter()
        end)
      end,
    })
    events.subscribe({
      event = events.VIM_TAB_CLOSED,
      handler = function(args)
        if Manager.cache[args.afile] then
          Manager.cache[args.afile]:shutdown()
        end
      end,
    })
  end
  Manager.setup_is_done = true
  return vim.tbl_keys(Manager.source_lookup)
end

function Manager:on_tab_enter()
  if vim.api.nvim_get_current_tabpage() == self.tabid then
    for pos, state_id in pairs(self.global_position_state) do
      local state = self:get_state(state_id, self.tabid)
      if state then
        self:open_state(state, pos)
      end
    end
  end
end

function Manager:on_win_closed(args)
  local closed_winid = args.afile
  local new_info = self:generate_jump_before_info()
  for _, info in pairs(self.before_jump_info) do
    if info.prev_winid == closed_winid then
      info.prev_winid = new_info and new_info.prev_winid
    end
  end
end

function Manager:shutdown()
  events.unsubscribe({
    id = "__neo_tree_internal_tab_enter_" .. self.tabid,
  })
  events.unsubscribe({
    id = "__neo_tree_internal_win_closed" .. self.tabid,
  })
  self.cache[self.tabid] = nil
end

---Check if external module is a valid neo-tree source
---@param module_path string # path to require
function locals.check_is_valid_source(module_path)
  ---@type boolean, NeotreeState
  local suc, mod = pcall(require, module_path)
  return suc and mod and mod.i_am_a_valid_source and mod:i_am_a_valid_source()
end

---Registered name will be the last portion of the source name
---@param source string
function locals.name_from_source(source)
  local splits = vim.split(source, ".", { plain = true, trimempty = true })
  return splits[#splits]
end

---used to either limit the sources that are loaded, or add extra external sources
---@param sources string[]
function Manager.set_sources(sources)
  for _, source in ipairs(sources) do
    local name = locals.name_from_source(source)
    local internal_mod_name = "neo-tree.sources." .. source
    if Manager.source_lookup[name] then
      -- skip
    elseif pcall(require, internal_mod_name) then
      Manager.source_lookup[name] = {
        is_internal = true,
        module_path = internal_mod_name,
        setup_is_done = false,
        after_setup = {},
      }
    elseif pcall(require, source) and locals.check_is_valid_source(source) then
      Manager.source_lookup[name] = {
        is_internal = false,
        module_path = source,
        setup_is_done = false,
        after_setup = {},
      }
    else
      log.error("Source module not found", source)
    end
  end
  log.debug("Sources to load: ", vim.tbl_keys(Manager.source_lookup))
  return Manager.source_lookup
end

---Merge render component definition.
---Values in later arguments are more prioritized, just like `vim.tbl_expand("force")`.
---@param default NeotreeConfig.components
---@param ... NeotreeConfig.components
---@return NeotreeConfig.components
function locals.merge_components(default, ...)
  local components = vim.tbl_deep_extend("force", default, ...)
  for key, _ in pairs(components) do
    if not default[key] then
      components[key] = nil
    end
  end
  return components
end

---Merge renderers from config and insert default keys for each component
---Values in later arguments are more prioritized, just like `vim.tbl_expand("force")`.
---@param components NeotreeConfig.components
---@param default NeotreeConfig.renderers
---@param ... NeotreeConfig.renderers
function locals.merge_renderers(components, default, ...)
  ---@param array NeotreeComponentBase[]
  local function merge_renderer_to_components(array)
    ---@type NeotreeComponentBase[]
    local res = {}
    for _, component in ipairs(array) do
      local name = component[1]
      if not components[name] then
        components[name] = {}
      end
      local merged = vim.tbl_extend("force", components[name], component)
      if name == "indent" then -- insert indent as the first value in array
        table.insert(res, 1, merged)
      elseif name == "container" then -- `container.content` contains recursive components
        merged.content = merge_renderer_to_components(merged.content)
        table.insert(res, merged)
      else
        table.insert(res, merged)
      end
    end
    return res
  end
  local renderers = vim.tbl_extend("force", default, ...)
  for r, array in pairs(renderers) do
    renderers[r] = merge_renderer_to_components(array)
  end
  return renderers
end

---Merge keybind settings.
---Values in later arguments are more prioritized, just like `vim.tbl_expand("force")`.
---@param commands NeotreeConfig.command_table
---@param default_map_opts NeotreeConfig.mapping_options
---@param default NeotreeConfig.mappings
---@param ... NeotreeConfig.mappings
function locals.fix_and_merge_mappings(commands, default_map_opts, default, ...)
  ---@type NeotreeConfig.mappings
  local mappings = vim.tbl_extend("force", default, ...)
  ---@type NeotreeConfig.resolved_mappings
  local resolved_mappings = {}
  for key, rhs in pairs(mappings) do
    local normalized_key = require("neo-tree.setup.mapping-helper").normalize_map_key(key)
    local rhs_type = type(rhs)
    ---@type NeotreeConfig.mapping_table
    local opts = vim.tbl_deep_extend("force", default_map_opts, rhs_type == "table" and rhs or {})
    if rhs_type == "nil" then
    elseif rhs_type == "string" and locals.skip_this_mapping[rhs] then
    else
      if rhs_type == "string" then
        opts.command = rhs
      elseif rhs_type == "function" then
        opts.func = rhs
        opts.desc = "<function>"
      end
      opts.command = opts.command or opts[1]
      opts.func = opts.func or commands[opts.command]
      opts.vfunc = opts.vfunc or commands[opts.command .. "_visual"]
      opts.desc = opts.desc or opts.command
      opts.text = opts.desc or opts.command
      if normalized_key and opts.func then
        resolved_mappings[normalized_key] = opts
      else
        local cmd = normalized_key or key
        resolved_mappings[cmd] = "<invalid>"
        log.warn("Invalid mapping for ", cmd, ": ", opts.desc)
      end
    end
  end
  return resolved_mappings
end

locals.skip_this_mapping = {
  ["none"] = true,
  ["nop"] = true,
  ["noop"] = true,
}

function Manager.wait_all_tasks()
  -- Block exec until other setups is completed
  local done = nio.wait_all(Manager.global_tasks, Manager.global_tasks.done + 1)
  if done > Manager.global_tasks.done then
    Manager.global_tasks.done = done
  end
end

return Manager, locals
