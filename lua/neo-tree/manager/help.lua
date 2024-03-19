local NuiLine = require("nui.line")
local Popup = require("nui.popup")
local hls = require("neo-tree.ui.highlights")
local popups = require("neo-tree.ui.popups")

local M = {}

---@alias NeotreeHelpAlign
---|"left"
---|"right"
---|"center"
---@class NeotreeHelpColumn
---@field text string
---@field hl string|nil
---@field align NeotreeHelpAlign
---@field expand boolean|nil
---@field __calculated_index integer|nil

---@param text string
---@param highlight string|nil
---@param align NeotreeHelpAlign
---@param expand boolean|nil
---@return NeotreeHelpColumn
local function one_col(text, highlight, align, expand)
  return {
    text = text,
    hl = highlight,
    align = align,
    expand = not not expand,
  }
end

---@param text string
---@param align NeotreeHelpAlign
---@param width integer
local function align_text(text, align, width)
  local text_length = vim.api.nvim_strwidth(text)
  if align == "right" then
    return string.rep(" ", width - text_length) .. text
  elseif align == "center" then
    local half = (width - text_length) / 2
    return string.rep(" ", math.floor(half)) .. text .. string.rep(" ", math.ceil(half))
  else
    return text .. string.rep(" ", width - text_length)
  end
end

---Resolve table and return NuiLines
---@param rows (NeotreeHelpColumn[])[]
---@param default_hl string|nil # Default highlight used for columns unspecified.
---@param separator string|nil # Character used for separator between columns.
---@param separator_hl string|nil # Highlight used for separator between columns.
---@param padding integer|{ left: integer, right: integer }|nil
---@return NuiLine[] lines
---@return integer table_width
local function resolve_table(rows, default_hl, separator, separator_hl, padding)
  separator = separator or ""
  if type(padding) ~= "table" then
    padding = { left = padding or 0, right = padding or 0 }
  end
  local table_width = 0
  local num_columns = 0
  ---@type integer[]
  local row_no_expands_widths = {}
  ---@type integer[]
  local col_max_widths = {}
  for irow, row in ipairs(rows) do
    local row_required_width = 0
    local found_expanded_col = false
    for icol, col in ipairs(row) do
      local col_width = vim.api.nvim_strwidth(col.text)
      if col.expand then
        found_expanded_col = true
      else
        local _icol = found_expanded_col and (icol - #row) or icol
        col_max_widths[_icol] = math.max(col_max_widths[_icol] or 0, col_width)
        col.__calculated_index = _icol
        row_no_expands_widths[irow] = (row_no_expands_widths[irow] or 0) + col_width
      end
      row_required_width = row_required_width + col_width
    end
    num_columns = math.max(num_columns, #row)
    table_width = math.max(table_width, row_required_width)
  end
  -- resolve negative indecies
  for index, _ in pairs(col_max_widths) do
    if index <= 0 then
      local width = math.max(col_max_widths[num_columns + index] or 0, col_max_widths[index])
      col_max_widths[index] = width
      col_max_widths[num_columns + index] = width
    end
  end
  -- generate rows
  ---@type NuiLine[]
  local lines = {}
  for irow, row in ipairs(rows) do
    local num_expanded = #vim.tbl_filter(function(col)
      return col.expand
    end, row)
    local found_expanded_col = false
    local line = NuiLine()
    line:append(string.rep(" ", padding.left))
    for icol, col in ipairs(row) do
      if icol > 0 then
        line:append(separator, separator_hl)
      end
      local col_width = col_max_widths[col.__calculated_index] or 0
      if col.expand then
        local space_for_expands = table_width - (row_no_expands_widths[irow] or 0)
        col_width = math.floor(space_for_expands / num_expanded)
          + (found_expanded_col and space_for_expands % num_expanded or 0) -- add remainders to the first expanded col
        found_expanded_col = true
      end
      assert(
        col_width >= #col.text,
        string.format("(%s, %s) col width exceeded: %s", irow, icol, vim.inspect(col))
      )
      line:append(align_text(col.text, col.align, col_width), col.hl or default_hl)
    end
    line:append(string.rep(" ", padding.right))
    table.insert(lines, line)
  end
  return lines, table_width + (num_columns - 1) * #separator + padding.left + padding.right
end

---Get the list of registered mappings that start with `prefix_key`.
---@param mappings NeotreeConfig.mappings
---@param prefix_key string|nil # If nil, returns all keymaps.
local function get_sub_keys(mappings, prefix_key)
  ---@type NeotreeConfig.mappings
  local result = {}
  for key, rhs in pairs(mappings) do
    if not prefix_key then
      result[key] = rhs
    elseif #key > #prefix_key and key:sub(1, #prefix_key) == prefix_key then
      result[key:sub(#prefix_key + 1)] = rhs
    end
  end
  return result
end

---Show a help popup.
---@param state NeotreeState
---@param title string|nil # Content to be displayed on the title bar. Default: "Neotree Help"
---@param prefix_key string|nil # Prefix key to show help for.
---@param close_keys string|string[]|nil # Additional keymap to close the popup.
M.show = function(state, title, prefix_key, close_keys)
  local parent_winid = state.winid
  if not parent_winid then
    return
  end
  if type(close_keys) ~= "table" then
    close_keys = { close_keys }
  end
  table.insert(close_keys, "<esc>")
  close_keys = vim.tbl_map(function(e)
    return string.lower(e)
  end, close_keys)
  local close_keys_are = table.concat(close_keys, ", ")
  local content_table = {
    {},
    { one_col("Press the corresponding key to execute the command.", "Comment", "center", true) },
    { one_col(string.format("Press %s to cancel.", close_keys_are), "Comment", "center", true) },
    {},
    {
      one_col("KEY(S)", hls.ROOT_NAME, "right"),
      one_col("", nil, "left"),
      one_col("COMMAND", hls.ROOT_NAME, "left"),
      one_col("VISUAL MODE", hls.ROOT_NAME, "left"),
    },
  }
  local sub_keys = get_sub_keys(state.config.window.mappings, prefix_key)
  for key, rhs in pairs(sub_keys) do
    local row = {
      one_col(key, hls.FILTER_TERM, "right"),
      one_col("->", hls.DIM_TEXT, "left"),
      one_col(rhs.text or rhs.desc or "<lua-function>", hls.NORMAL, "left"),
      one_col(rhs.vfunc and "✓" or "-", rhs.vfunc and hls.VISUAL or hls.DIM_TEXT, "center"),
    }
    table.insert(content_table, row)
  end
  local lines, width = resolve_table(content_table, nil, " ", nil, 1)
  -- make popup
  local col = state.current_position == "right" and (-width - 1)
    or (vim.api.nvim_win_get_width(parent_winid) + 1)
  local height = math.min(vim.o.lines - 5, vim.api.nvim_win_get_height(parent_winid) - 5, #lines)
  local options = {
    position = { row = 2, col = col },
    relative = { type = "win", winid = parent_winid },
    size = { width = width, height = height },
    enter = true,
    focusable = true,
    zindex = 50,
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
      winhighlight = require("neo-tree.manager.wm").get_highlight_string(),
    },
  }
  local _ = popups.popup_options(title or "Neotree Help", width, options)
  local popup = Popup(popups.popup_options(title or "Neotree Help", width, options))
  popup:mount()
  local content = vim.tbl_map(function(value)
    return value:content()
  end, lines)
  vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, content)
  -- set popup keybinds
  for key, _ in pairs(sub_keys) do
    popup:map("n", key, function()
      popup:unmount()
      vim.api.nvim_set_current_win(parent_winid)
      vim.api.nvim_set_current_win(parent_winid)
      local _key = vim.api.nvim_replace_termcodes((prefix_key or "") .. key, true, false, true)
      vim.api.nvim_feedkeys(_key, "m", true)
    end, {})
  end
  for _, close_key in ipairs(close_keys) do
    popup:map("n", close_key, function()
      popup:unmount()
    end, { noremap = true }, true)
  end
  popup:on("WinLeave", function()
    popup:unmount()
  end, { once = true })
  return popup
end

return M
