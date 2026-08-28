local M = {}

-- Escaped outside code blocks, per the NFM spec.
M.SPECIAL = { "\\", "*", "~", "`", "$", "[", "]", "<", ">", "{", "}", "|", "^" }

local set = {}
for _, c in ipairs(M.SPECIAL) do set[c] = true end

function M.is_special(c) return set[c] == true end

function M.escape(s)
  return (s:gsub(".", function(c)
    if set[c] then return "\\" .. c end
    return nil          -- nil leaves the character untouched
  end))
end

function M.unescape(s)
  return (s:gsub("\\(.)", function(c)
    if set[c] then return c end
    return nil          -- not a special character: keep the backslash
  end))
end

return M
