local M = {}

---@enum NeotreeStateScope
M.state_scopes = {
  GLOBAL = "global",
  TABPAGE = "tabpage",
  WINDOW = "window",
}

---@enum NeotreeBufVar
M.buf_vars = {
  NEO_TREE_POSITION = "neo_tree_position",
  NEO_TREE_SOURCE = "neo_tree_source",
  NEO_TREE_TABID = "neo_tree_tabid",
  NEO_TREE_WINID = "neo_tree_winid",
}

---@enum NeotreeWinVar
M.win_vars = {
  NEO_TREE_SETTINGS_APPLIED = "neo_tree_settings_applied",
}

---@enum NeotreeWindowPosition
M.valid_window_positions = {
  LEFT = "left",
  RIGHT = "right",
  TOP = "top",
  BOTTOM = "bottom",
  FLOAT = "float",
  CURRENT = "current",
}

M.valid_split_window_positions = {
  M.valid_window_positions.LEFT,
  M.valid_window_positions.RIGHT,
  M.valid_window_positions.TOP,
  M.valid_window_positions.BOTTOM,
}

M.valid_float_window_positions = {
  M.valid_window_positions.FLOAT,
}

M.valid_phantom_window_positions = {
  M.valid_window_positions.CURRENT,
}

-- TODO: Test window_positions contains all valid_*_window_positions.

return M
