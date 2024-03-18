local M = {}

---@alias NeotreeSortName
---|"id_alphabet"
---|"id_alphabet_nocase" # Case insensitive alphabet sort.
---|"id_length"
---|"id_int"

M.utils = {}

---@generic T
---@param a T
---@param b T
---@param reverse boolean
---@return boolean
function M.utils.lt(a, b, reverse)
  if reverse then
    return a > b
  else
    return a < b
  end
end

---@type table<NeotreeSortName, NeotreeTypes.sort_function>
M.pre_defined = {}

function M.pre_defined.id_alphabet(a, b, reverse)
  return M.utils.lt(a:get_id(), b:get_id(), reverse)
end

function M.pre_defined.id_alphabet_nocase(a, b, reverse)
  return M.utils.lt(a:get_id():lower(), b:get_id():lower(), reverse)
end

function M.pre_defined.id_length(a, b, reverse)
  return M.utils.lt(tostring(a:get_id()):len(), tostring(b:get_id()):len(), reverse)
end

function M.pre_defined.id_int(a, b, reverse)
  local a_id = a:get_id()
  assert(pcall(tonumber, a_id), string.format([[a:get_id() = '%s' is not an integer.]], a_id))
  local b_id = b:get_id()
  assert(pcall(tonumber, b_id), string.format([[b:get_id() = '%s' is not an integer.]], b_id))
  return M.utils.lt(tonumber(a_id), tonumber(b_id), reverse)
end

---@class NeotreeSortConstructors
M.constructor = {}

---Sort by a property of nodes. `a[property] < b[property]`
---@param property string # Property name (eg "type"). This property must be comparable with `<` (less than.
---@return NeotreeTypes.sort_function
function M.constructor.by_x(property)
  return function(a, b, reverse)
    return M.utils.lt(a[property], b[property], reverse)
  end
end

---Sort by a lookup table and property name.
---
--->>> local dict = {
--->>>   directory = 1,
--->>>   file = 2,
--->>>   ["_"] = 100,
--->>> }
--->>> M.constructor.by_lookuptable(dict, "type") -> node.type == "directory" comes first.
---
---@param lut table<any, integer>
---@param property string|nil # Property name (eg "type") or `:get_id()` if nil. The value must be in `lut` or ["_"] key for default.
---@return NeotreeTypes.sort_function
function M.constructor.by_lookuptable(lut, property)
  local get
  if property then
    get = function(x)
      return x[property] or "_"
    end
  else
    get = function(x)
      return x:get_id()
    end
  end
  return function(a, b, reverse)
    local a_val = lut[get(a)] or lut._
    local b_val = lut[get(b)] or lut._
    if a_val == b_val then
      return not reverse
    elseif not a_val or not b_val then
      return (not not a_val) ~= reverse
    else
      return M.utils.lt(a_val, b_val, reverse)
    end
  end
end

---Sort by a lookup table and property name.
---
--->>> local dict = {
--->>>   ["/path/to/cwd/a"] = 10,
--->>>   ["/path/to/cwd/b"] = 20,
--->>>   ["_"] = 100,
--->>> }
--->>> -- parents will use the lowest values of children.
--->>> -- "/path/to/cwd" will be 100.
--->>> M.constructor.id_lookuptable(dict) -> M.constructor.id_lookuptable
---
---@param lut table<string, integer>
---@param sep string # Separator used to define hiarchy.
---@param use_highest boolean # Prioritize bigger values instead.
---@param property string|nil # Property name (eg "type") or `:get_id()` if nil. The value must be in `lut` or ["_"] key for default.
---@return NeotreeTypes.sort_function
---@return table<string, integer> lut # Modified lut, in case you want to use it afterwards.
function M.constructor.by_lookuptable_backpropagate(lut, sep, use_highest, property)
  use_highest = use_highest and true or false
  local update_fallback = use_highest and math.min or math.max
  for _, key in ipairs(vim.tbl_keys(lut)) do
    if type(lut[key]) == "number" then
      lut._ = update_fallback(lut._ or lut[key], lut[key])
    end
    local i = 1
    while true do
      local sep_idx, sep_end = string.find(key, sep, i, true)
      if not sep_idx then
        break
      end
      local s = string.sub(key, 1, sep_idx - 1)
      if not lut[s] or (lut[s] > lut[key] ~= use_highest) then -- (XOR use_highest) flips the condition
        lut[s] = lut[key]
      end
      i = sep_end + 1
    end
  end
  return M.constructor.by_lookuptable(lut, property), lut
end

return M
