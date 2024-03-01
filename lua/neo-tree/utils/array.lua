---@class NeotreeArray.push<T> : { pushleft: fun(self: any, value: T), pushright: fun(self: any, value: T) }
---@class NeotreeArray.pop<T> : { popleft: (fun(self: any): T), popright: (fun(self: any): T) }
---@class NeotreeArray.add<T> : { append: fun(self: any, value: T), extend: fun(self: any, ...: T) }
---@class NeotreeArray.extra<T> : { len: (fun(self: any): integer), peek: (fun(self: any, index: integer): T) }
---@class NeotreeArray<T>: { left: integer, right: integer, __data: T[] }

---@class NeotreeArray
local Array = setmetatable({}, {
  __index = function(cls, index)
    if type(index) == "number" then
      return cls:peek(index)
    end
  end,
  __call = function(cls, ...)
    return cls.new(...)
  end,
})
Array.__index = Array

---Create new array object.
function Array.new(...)
  ---@class NeotreeArray<T>
  local self = setmetatable({
    left = 0,
    right = -1,
    __data = {},
  }, Array)
  self:extend(...)
  return self
end

---Prepend a value to the left of the array.
function Array:pushleft(value)
  self.left = self.left - 1 ---@diagnostic disable-line
  self.__data[self.left] = value
end

---Append a value to the right of the array.
function Array:pushright(value)
  self.right = self.right + 1 ---@diagnostic disable-line
  self.__data[self.right] = value
end

---Get the left most value. Use for FIFO queue.
function Array:popleft()
  if self.right < self.left then
    return nil
  end
  local value = self.__data[self.left]
  self.left = self.left + 1 ---@diagnostic disable-line
  return value
end

---Get the right most value. Use for LIFO stack.
function Array:popright()
  if self.right < self.left then
    return nil
  end
  local value = self.__data[self.right]
  self.right = self.right - 1 ---@diagnostic disable-line
  return value
end

---Peek at the `index`-th value in the list (1-index).
---This does not remove the value from the list.
---
---When index > 0, it is counted from the left,
---and when index < 0, it is counted from the right.
---when index == 0, does nothing (returns nil).
function Array:peek(index)
  if index > 0 then
    return self.__data[self.left + index - 1]
  elseif index < 0 then
    return self.__data[self.right + index + 1]
  end
end

---Get the right most value. Use for LIFO stack.
function Array:len()
  return self.right - self.left + 1
end

---Append a value to the right of the array.
function Array:append(value)
  return self:pushright(value)
end

---Append values to the right of the array.
function Array:extend(...)
  for _, value in ipairs({ ... }) do
    self:pushright(value)
  end
end

-- \@generic is not clever enough, so we need to create new type names for each content type
-- to have type annotations work correctly.

---@alias NeotreeArray.integer NeotreeArray<integer>|NeotreeArray.push<integer>|NeotreeArray.pop<integer>|NeotreeArray.add<integer>|NeotreeArray.extra<integer>
---@alias NeotreeArray.string NeotreeArray<string>|NeotreeArray.push<string>|NeotreeArray.pop<string>|NeotreeArray.add<string>|NeotreeArray.extra<string>

return {
  ---@type NeotreeArray.integer|fun(...: integer): NeotreeArray.integer
  integer = Array,
  ---@type NeotreeArray.string|fun(...: string): NeotreeArray.string
  string = Array,
}
