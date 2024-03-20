local highlights = require("neo-tree.ui.highlights")
local utils = require("neo-tree.utils")
local file_nesting = require("neo-tree.sources.common.file-nesting")
local container = require("neo-tree.sources.common.container")
local log = require("neo-tree.log")

---This file contains the built-in components. Each componment is a function
---that takes the following arguments:
---    config:       A table containing the configuration provided by the user
---                  when declaring this component in their renderer config.
---    node:         A NuiNode object for the currently focused node.
---    state:        The current state of the source providing the items.
---    window_width: integer Allocated width
---
---The function should return either a table, or a list of tables, each of which
---contains the following keys:
---    text:      The text to display for this item.
---    highlight: The highlight group to apply to this text.
---It also may return `wanted_width` to render the component.
---This value might be ignored anyways and not guarantied to be allocated.
---@type table<string, NeotreeComponentFunc>
local M = {}
---@alias NeotreeComponentFunc fun(config: NeotreeComponentBase, node: NuiTreeNode|NeotreeSourceItem, state: NeotreeState): NeotreeComponentResult|NeotreeComponentResult[], integer|nil
---@alias NeotreeComponentResult { text: string, highlight: NeotreeHighlightGroupName, no_padding: boolean|nil, no_next_padding: boolean|nil }

local make_two_char = function(symbol)
  if vim.fn.strchars(symbol) == 1 then
    return symbol .. " "
  else
    return symbol
  end
end
-- only works in the buffers component, but it's here so we don't have to defined
-- multple renderers.
M.bufnr = function(config, node, state)
  local highlight = config.highlight or highlights.BUFFER_NUMBER
  local bufnr = node.extra and node.extra.bufnr
  if not bufnr then
    return {}
  end
  return {
    text = string.format("#%s", bufnr),
    highlight = highlight,
  }
end

M.clipboard = function(config, node, state)
  local clipboard = state.clipboard or {}
  local clipboard_state = clipboard[node:get_id()]
  if not clipboard_state then
    return {}
  end
  return {
    text = " (" .. clipboard_state.action .. ")",
    highlight = config.highlight or highlights.DIM_TEXT,
  }
end

M.container = container.render

M.current_filter = function(config, node, state)
  local filter = node.search_pattern or ""
  if filter == "" then
    return {}
  end
  return {
    {
      text = "Find",
      highlight = highlights.DIM_TEXT,
    },
    {
      text = string.format('"%s"', filter),
      highlight = config.highlight or highlights.FILTER_TERM,
    },
    {
      text = "in",
      highlight = highlights.DIM_TEXT,
    },
  }
end

---`sign_getdefined` based wrapper with compatibility
---@param severity string
---@return vim.fn.sign_getdefined.ret.item
local function get_defined_sign(severity)
  local defined
  if vim.fn.has("nvim-0.10") > 0 then
    local signs_config = vim.diagnostic.config().signs
    if type(signs_config) == "table" then
      local identifier = severity:sub(1, 1)
      if identifier == "H" then
        identifier = "N"
      end
      defined = {
        text = (signs_config.text or {})[vim.diagnostic.severity[identifier]],
        texthl = "DiagnosticSign" .. severity,
      }
    end
  else -- before 0.10
    defined = vim.fn.sign_getdefined("DiagnosticSign" .. severity)
    if vim.tbl_isempty(defined) then
      -- backwards compatibility...
      local old_severity = severity
      if severity == "Warning" then
        old_severity = "Warn"
      elseif severity == "Information" then
        old_severity = "Info"
      end
      defined = vim.fn.sign_getdefined("LspDiagnosticsSign" .. old_severity)
    end
    defined = defined and defined[1]
  end
  if type(defined) ~= "table" then
    defined = {}
  end
  return defined
end

---@param config NeotreeComponent.diagnostics
M.diagnostics = function(config, node, state)
  local diag = state.diagnostics_lookup or {}
  local diag_state = diag[node:get_id()]
  if config.hide_when_expanded and node.type == "directory" and node:is_expanded() then
    return {}
  end
  if not diag_state then
    return {}
  end
  if config.errors_only and diag_state.severity_number > 1 then
    return {}
  end
  local severity = diag_state.severity_string
  local defined = get_defined_sign(severity)
  -- check for overrides in the component config
  local severity_lower = severity:lower()
  if config.symbols and config.symbols[severity_lower] then
    defined.texthl = defined.texthl or ("Diagnostic" .. severity)
    defined.text = config.symbols[severity_lower]
  end
  if config.highlights and config.highlights[severity_lower] then
    defined.text = defined.text or severity:sub(1, 1)
    defined.texthl = config.highlights[severity_lower]
  end
  if defined.text and defined.texthl then
    return {
      text = make_two_char(defined.text),
      highlight = defined.texthl,
    }
  else
    return {
      text = severity:sub(1, 1),
      highlight = "Diagnostic" .. severity,
    }
  end
end

---@param config NeotreeComponent.git_status
M.git_status2 = function(config, node, state)
  local git_status_lookup = state.git_status_lookup
  if config.hide_when_expanded and node.type == "directory" and node:is_expanded() then
    return {}
  end
  if not git_status_lookup then
    return {}
  end
  local git_status = git_status_lookup[node.path]
  if not git_status then
    if node.filtered_by and node.filtered_by.gitignored then
      git_status = "!!"
    else
      return {}
    end
  end
  local symbols = config.symbols or {}
  local change_symbol
  local change_highlt = highlights.FILE_NAME
  local status_symbol = symbols.staged
  local status_highlt = highlights.GIT_STAGED
  if node.type == "directory" and git_status:len() == 1 then
    status_symbol = nil
  end
  if git_status:sub(1, 1) == " " then
    status_symbol = symbols.unstaged
    status_highlt = highlights.GIT_UNSTAGED
  end
  if git_status:match("?$") then
    status_symbol = nil
    status_highlt = highlights.GIT_UNTRACKED
    change_symbol = symbols.untracked
    change_highlt = highlights.GIT_UNTRACKED
    -- all variations of merge conflicts
  elseif git_status == "DD" then
    status_symbol = symbols.conflict
    status_highlt = highlights.GIT_CONFLICT
    change_symbol = symbols.deleted
    change_highlt = highlights.GIT_CONFLICT
  elseif git_status == "UU" then
    status_symbol = symbols.conflict
    status_highlt = highlights.GIT_CONFLICT
    change_symbol = symbols.modified
    change_highlt = highlights.GIT_CONFLICT
  elseif git_status == "AA" then
    status_symbol = symbols.conflict
    status_highlt = highlights.GIT_CONFLICT
    change_symbol = symbols.added
    change_highlt = highlights.GIT_CONFLICT
  elseif git_status:match("U") then
    status_symbol = symbols.conflict
    status_highlt = highlights.GIT_CONFLICT
    if git_status:match("A") then
      change_symbol = symbols.added
    elseif git_status:match("D") then
      change_symbol = symbols.deleted
    end
    change_highlt = highlights.GIT_CONFLICT
    -- end merge conflict section
  elseif git_status:match("M") then
    change_symbol = symbols.modified
    change_highlt = highlights.GIT_MODIFIED
  elseif git_status:match("R") then
    change_symbol = symbols.renamed
    change_highlt = highlights.GIT_RENAMED
  elseif git_status:match("[ACT]") then
    change_symbol = symbols.added
    change_highlt = highlights.GIT_ADDED
  elseif git_status:match("!") then
    status_symbol = nil
    change_symbol = symbols.ignored
    change_highlt = highlights.GIT_IGNORED
  elseif git_status:match("D") then
    change_symbol = symbols.deleted
    change_highlt = highlights.GIT_DELETED
  end
  if change_symbol or status_symbol then
    local components = {}
    if type(change_symbol) == "string" and #change_symbol > 0 then
      table.insert(components, {
        text = make_two_char(change_symbol),
        highlight = change_highlt,
      })
    end
    if type(status_symbol) == "string" and #status_symbol > 0 then
      table.insert(components, {
        text = make_two_char(status_symbol),
        highlight = status_highlt,
      })
    end
    return components
  else
    return {
      text = "[" .. git_status .. "]",
      highlight = config.highlight or change_highlt,
    }
  end
end

local pathlib_git_status = require("pathlib.const").git_status
local git_symbols_map = {
  [pathlib_git_status.UNMODIFIED] = "unmodified",
  [pathlib_git_status.MODIFIED] = "modified",
  [pathlib_git_status.FILE_TYPE_CHANGED] = "file_type_changed",
  [pathlib_git_status.ADDED] = "added",
  [pathlib_git_status.DELETED] = "deleted",
  [pathlib_git_status.RENAMED] = "renamed",
  [pathlib_git_status.COPIED] = "copied",
  [pathlib_git_status.UPDATED_BUT_UNMERGED] = "updated_but_unmerged",
  [pathlib_git_status.UNTRACKED] = "untracked",
  [pathlib_git_status.UNSTAGED] = "unstaged",
  [pathlib_git_status.STAGED] = "staged",
  [pathlib_git_status.CONFLICT] = "conflict",
  [pathlib_git_status.IGNORED] = "ignored",
}
local git_highlights_map = {
  [pathlib_git_status.UNMODIFIED] = highlights.GIT_UNMODIFIED,
  [pathlib_git_status.MODIFIED] = highlights.GIT_MODIFIED,
  [pathlib_git_status.FILE_TYPE_CHANGED] = highlights.GIT_FILE_TYPE_CHANGED,
  [pathlib_git_status.ADDED] = highlights.GIT_ADDED,
  [pathlib_git_status.DELETED] = highlights.GIT_DELETED,
  [pathlib_git_status.RENAMED] = highlights.GIT_RENAMED,
  [pathlib_git_status.COPIED] = highlights.GIT_COPIED,
  [pathlib_git_status.UPDATED_BUT_UNMERGED] = highlights.GIT_UPDATED_BUT_UNMERGED,
  [pathlib_git_status.UNTRACKED] = highlights.GIT_UNTRACKED,
  [pathlib_git_status.UNSTAGED] = highlights.GIT_UNSTAGED,
  [pathlib_git_status.STAGED] = highlights.GIT_STAGED,
  [pathlib_git_status.CONFLICT] = highlights.GIT_CONFLICT,
  [pathlib_git_status.IGNORED] = highlights.GIT_IGNORED,
}

---@param config NeotreeComponent.git_status
M.git_status = function(config, node, state)
  -- local git_status_lookup = state.git_status_lookup
  if config.hide_when_expanded and node.type == "directory" and node:is_expanded() then
    return {}
  end
  -- if not git_status_lookup then
  --   return {}
  -- end
  local git_state = node.pathlib.git_state
  if not git_state or not git_state.is_ready then
    if node.filtered_by and node.filtered_by.gitignored then
      git_status = "!!"
    else
      return {}
    end
  end
  if not git_state.is_ready.is_set() then
    return {}
  end
  local git_status = git_state.state or {}
  local symbols = config.symbols or {}
  local change_symbol = symbols[git_symbols_map[git_status.change or ""] or ""]
  local change_highlt = git_highlights_map[git_status.change or ""]
  local status_symbol = symbols[git_symbols_map[git_status.status or ""] or ""]
  local status_highlt = git_highlights_map[git_status.status or ""]
  -- if node.type == "directory" and git_status:len() == 1 then
  --   status_symbol = nil
  -- end
  -- if git_status:sub(1, 1) == " " then
  --   status_symbol = symbols.unstaged
  --   status_highlt = highlights.GIT_UNSTAGED
  -- end
  if change_symbol or status_symbol then
    local components = {}
    if type(change_symbol) == "string" and #change_symbol > 0 then
      table.insert(components, {
        text = make_two_char(change_symbol),
        highlight = change_highlt,
      })
    end
    if type(status_symbol) == "string" and #status_symbol > 0 then
      table.insert(components, {
        text = make_two_char(status_symbol),
        highlight = status_highlt,
      })
    end
    return components
  elseif git_status.change then
    return {
      text = "[" .. (git_status.change or pathlib_git_status.UNMODIFIED) .. "]",
      highlight = config.highlight or change_highlt,
    }
  end
end

M.filtered_by = function(config, node, state)
  local result = {}
  if type(node.filtered_by) == "table" then
    local fby = node.filtered_by
    if fby.name then
      result = {
        text = "(hide by name)",
        highlight = highlights.HIDDEN_BY_NAME,
      }
    elseif fby.pattern then
      result = {
        text = "(hide by pattern)",
        highlight = highlights.HIDDEN_BY_NAME,
      }
    elseif fby.gitignored then
      result = {
        text = "(gitignored)",
        highlight = highlights.GIT_IGNORED,
      }
    elseif fby.dotfiles then
      result = {
        text = "(dotfile)",
        highlight = highlights.DOTFILE,
      }
    elseif fby.hidden then
      result = {
        text = "(hidden)",
        highlight = highlights.WINDOWS_HIDDEN,
      }
    end
    fby = nil
  end
  return result
end

---@param config NeotreeComponent.icon
M.icon = function(config, node, state)
  local icon = config.default or " "
  local highlight = config.highlight or highlights.FILE_ICON
  if node.type == "directory" then
    highlight = highlights.DIRECTORY_ICON
    if node.loaded and not node:has_children() then
      icon = not node.empty_expanded and config.folder_empty or config.folder_empty_open or icon
    elseif node:is_expanded() then
      icon = config.folder_open or "-"
    else
      icon = config.folder_closed or "+"
    end
  elseif node.type == "file" or node.type == "terminal" then
    local success, web_devicons = pcall(require, "nvim-web-devicons")
    local name = node.type == "terminal" and "terminal" or node.name
    if success then
      local devicon, hl = web_devicons.get_icon(name)
      icon = devicon or icon
      highlight = hl or highlight
    end
  end
  local filtered_by = M.filtered_by(config, node, state)
  return {
    text = icon .. " ",
    highlight = filtered_by.highlight or highlight,
  }
end

---@param config NeotreeComponent.modified
M.modified = function(config, node, state)
  local opened_buffers = state.opened_buffers or {}
  local buf_info = opened_buffers[node.path]
  if buf_info and buf_info.modified then
    return {
      text = (make_two_char(config.symbol) or "[+]"),
      highlight = config.highlight or highlights.MODIFIED,
    }
  else
    return {}
  end
end

---@param config NeotreeComponent.name
M.name = function(config, node, state)
  local highlight = config.highlight or highlights.FILE_NAME
  local text = node.name
  local parent_id = node:get_parent_id()
  local skipped_parents = parent_id and state.render_context.skipped_nodes[parent_id]
  if parent_id and skipped_parents then
    text = skipped_parents .. text
    state.render_context.skipped_nodes[parent_id] = nil
  end
  if node.type == "directory" then
    highlight = highlights.DIRECTORY_NAME
    if config.trailing_slash and text ~= "/" then
      text = text .. "/"
    end
  end
  if node:get_depth() == 1 and node.type ~= "message" then
    highlight = highlights.ROOT_NAME
  else
    local filtered_by = M.filtered_by(config, node, state)
    highlight = filtered_by.highlight or highlight
    if config.use_git_status_colors then
      local git_status = state.components.git_status({}, node, state)
      if git_status and git_status.highlight then
        highlight = git_status.highlight
      end
    end
  end
  local hl_opened = config.highlight_opened_files
  if hl_opened then
    local opened_buffers = state.opened_buffers or {}
    if
      (hl_opened == "all" and opened_buffers[node.path])
      or (opened_buffers[node.path] and opened_buffers[node.path].loaded)
    then
      highlight = highlights.FILE_NAME_OPENED
    end
  end
  if type(config.right_padding) == "number" then
    if config.right_padding > 0 then
      text = text .. string.rep(" ", config.right_padding)
    end
  else
    text = text
  end
  return {
    text = text,
    highlight = highlight,
  }
end

---@param config NeotreeComponent.indent
---@param node NuiTreeNode|NeotreeSourceItem
---@param state NeotreeState
M.indent = function(config, node, state)
  if not state.skip_marker_at_level then
    state.skip_marker_at_level = {}
  end
  local strlen = vim.fn.strdisplaywidth
  local skip_marker = state.skip_marker_at_level
  local indent_size = config.indent_size or 2
  local padding = config.padding or 0
  local level = state.render_context.visual_depth[node:get_id()] - 1
  local with_markers = config.with_markers
  local with_expanders = config.with_expanders == nil and file_nesting.is_enabled()
    or config.with_expanders
  local marker_highlight = config.highlight or highlights.INDENT_MARKER
  local expander_highlight = config.expander_highlight or config.highlight or highlights.EXPANDER
  local function get_expander()
    if with_expanders and utils.is_expandable(node) then
      return node:is_expanded() and (config.expander_expanded or "")
        or (config.expander_collapsed or "")
    end
  end
  if indent_size == 0 or level < 2 or not with_markers then
    local len = indent_size * level + padding
    local expander = get_expander()
    if level == 0 or not expander then
      return {
        text = string.rep(" ", len),
      }
    end
    return {
      text = string.rep(" ", len - strlen(expander) - 1) .. expander .. " ",
      highlight = expander_highlight,
    }
  end
  local indent_marker = config.indent_marker or "│"
  local last_indent_marker = config.last_indent_marker or "└"
  skip_marker[level] = node.is_last_child
  local indent = {}
  if padding > 0 then
    table.insert(indent, { text = string.rep(" ", padding) })
  end
  for i = 1, level do
    local char = ""
    local spaces_count = indent_size
    local highlight = nil
    if i > 1 and not skip_marker[i] or i == level then
      spaces_count = spaces_count - 1
      char = indent_marker
      highlight = marker_highlight
      if i == level then
        local expander = get_expander()
        if expander then
          char = expander
          highlight = expander_highlight
        elseif node.is_last_child then
          char = last_indent_marker
          spaces_count = spaces_count - (vim.api.nvim_strwidth(last_indent_marker) - 1)
        end
      end
    end
    table.insert(indent, {
      text = char .. string.rep(" ", spaces_count),
      highlight = highlight,
      no_next_padding = true,
    })
  end
  return indent
end

local get_header = function(state, label, size)
  if state.sort and state.sort.label == label then
    local icon = state.sort.direction == 1 and "▲" or "▼"
    size = size - 2
    return string.format("%" .. size .. "s %s  ", label, icon)
  end
  return string.format("%" .. size .. "s  ", label)
end

M.file_size = function(config, node, state)
  -- Root node gets column labels
  if node:get_depth() == 1 then
    return {
      text = get_header(state, "Size", 12),
      highlight = highlights.FILE_STATS_HEADER,
    }
  end
  local text = "-"
  if node.type == "file" then
    local stat = utils.get_stat(node)
    local size = stat and stat.size or nil
    if size then
      local success, human = pcall(utils.human_size, size)
      if success then
        text = human or text
      end
    end
  end
  return {
    text = string.format("%12s  ", text),
    highlight = config.highlight or highlights.FILE_STATS,
  }
end

local file_time = function(config, node, state, stat_field)
  -- Root node gets column labels
  if node:get_depth() == 1 then
    local label = stat_field
    if stat_field == "mtime" then
      label = "Last Modified"
    elseif stat_field == "birthtime" then
      label = "Created"
    end
    return {
      text = get_header(state, label, 20),
      highlight = highlights.FILE_STATS_HEADER,
    }
  end
  local stat = utils.get_stat(node)
  local value = stat and stat[stat_field]
  local seconds = value and value.sec or nil
  local display = seconds and os.date("%Y-%m-%d %I:%M %p", seconds) or "-"
  return {
    text = string.format("%20s  ", display),
    highlight = config.highlight or highlights.FILE_STATS,
  }
end

M.last_modified = function(config, node, state)
  return file_time(config, node, state, "mtime")
end

M.created = function(config, node, state)
  return file_time(config, node, state, "birthtime")
end

M.symlink_target = function(config, node, state)
  if node.is_link then
    return {
      text = string.format(" ➛ %s", node.link_to),
      highlight = config.highlight or highlights.SYMBOLIC_LINK_TARGET,
    }
  else
    return {}
  end
end

M.type = function(config, node, state)
  local text = node.ext or node.type
  -- Root node gets column labels
  if node:get_depth() == 1 then
    return {
      text = get_header(state, "Type", 10),
      highlight = highlights.FILE_STATS_HEADER,
    }
  end
  return {
    text = string.format("%10s  ", text),
    highlight = highlights.FILE_STATS,
  }
end

return M
