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
local default_popup_size = { width = 60, height = "80%" }

local M = {}

function M.get_highlight_string()
  if not M.highlight_string then
    local result = {
      "Normal:NeoTreeNormal",
      "NormalNC:NeoTreeNormalNC",
      "SignColumn:NeoTreeSignColumn",
      "CursorLine:NeoTreeCursorLine",
      "FloatBorder:NeoTreeFloatBorder",
      "StatusLine:NeoTreeStatusLine",
      "StatusLineNC:NeoTreeStatusLineNC",
      "VertSplit:NeoTreeVertSplit",
      "EndOfBuffer:NeoTreeEndOfBuffer",
    }
    if vim.version and vim.version.ge(vim.version(), { 0, 7, 0 }) then
      table.insert(result, "WinSeparator:NeoTreeWinSeparator")
    end
    M.highlight_string = table.concat(result, ",")
  end
  return M.highlight_string
end

M.create_floating_window = function(window_config, default_opts, name)
  -- First get the default options for floating windows.
  local sourceTitle = name:gsub("^%l", string.upper)
  default_opts = popups.popup_options("Neo-tree " .. sourceTitle, 40, default_opts)
  default_opts.win_options = nil
  default_opts.zindex = 40

  -- Then override with source specific options.
  default_opts.size = utils.resolve_config_option(window_config, "popup.size", default_popup_size)
  default_opts.position = utils.resolve_config_option(window_config, "popup.position", "50%")
  default_opts.border =
    utils.resolve_config_option(window_config, "popup.border", default_opts.border or {})

  local win = require("nui.popup")(default_opts)
  win:on("BufUnload", function()
    win:unmount()
  end, { once = true })
  return win
end
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
  local opts = {
    ns_id = highlights.ns_id,
    bufnr = bufnr,
    size = utils.resolve_config_option(size_option, size_option, size_default),
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
      list = false,
      cursorline = true,
      cursorlineopt = "line",
      wrap = false,
      colorcolumn = "",
      signcolumn = "no",
      spell = false,
      number = false,
      relativenumber = false,
      winhighlight = M.get_highlight_string(),
    },
  }
  if vim.tbl_contains(e.valid_split_window_positions, position) then
    return require("nui.split")(opts)
  elseif vim.tbl_contains(e.valid_float_window_positions, position) then
    return M.create_floating_window(window_config, opts, name)
  elseif vim.tbl_contains(e.valid_phantom_window_positions, position) then
    return require("neo-tree.manager.current")(opts)
  end
end

return M, locals
