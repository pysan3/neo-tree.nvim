local utils = require("neo-tree.utils")
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

local locals = {} -- Functions exported for test purposes

local M = {}

---Return a window for neo-tree in `position`. Returns winid.
---@param position NeotreeWindowPosition
---@param window_config NeotreeConfig.window
---@param window_width integer|nil # If nil, uses default values from user config.
---@param name string
---@param bufnr integer|nil
function M.create_win(position, window_config, window_width, name, bufnr)
  local size_option, size_default = "width", 40
  if position == e.valid_window_positions.TOP or position == e.valid_window_positions.BOTTOM then
    size_option, size_default = "height", 15
  end
  local win_options = {
    ns_id = highlights.ns_id,
    bufnr = bufnr,
    size = window_config[size_option] or size_default, -- TODO: Call function to calculate here.
    -- TODO: Overwrite size with window_width if possible.
    position = position,
    relative = window_config.relative or "editor",
    buf_options = {
      buftype = "nofile",
      modifiable = false,
      swapfile = false,
      filetype = "neo-tree",
      undolevels = -1,
    },
    win_options = {
      colorcolumn = "",
      signcolumn = "no",
    },
  }
  if vim.tbl_contains(e.valid_split_window_positions, position) then
    print("NuiSplit")
    local window = require("nui.split")(win_options)
    return window
  elseif vim.tbl_contains(e.valid_float_window_positions, position) then
    print("NuiPopup")
    local sourceTitle = name:gsub("^%l", string.upper)
    win_options = popups.popup_options("Neo-tree " .. sourceTitle, 40, win_options)
    local window = require("nui.popup")(win_options)
    return window
  elseif vim.tbl_contains(e.valid_phantom_window_positions, position) then
    print("CurrentWin")
    local window = require("neo-tree.manager.current")(win_options)
    return window
  end
end

return M, locals
