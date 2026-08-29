local M = {}

-- Escaped outside code blocks, per the NFM spec.
M.SPECIAL = { "\\", "*", "~", "`", "$", "[", "]", "<", ">", "{", "}", "|", "^" }

local set = {}
for _, c in ipairs(M.SPECIAL) do set[c] = true end

function M.escape(s)
  return (s:gsub(".", function(c)
    if set[c] then return "\\" .. c end
    return nil          -- nil leaves the character untouched
  end))
end

-- Currently unused by production code: the reader hands every line to
-- pandoc.read, whose markdown parser (with all_symbols_escapable) already
-- consumes the backslashes itself, so this is redundant rather than missing.
-- Kept (and unit-tested) as the exact inverse of M.escape.
function M.unescape(s)
  return (s:gsub("\\(.)", function(c)
    if set[c] then return c end
    return nil          -- not a special character: keep the backslash
  end))
end

return M
