-- Put this script's own directory on package.path. Pandoc does NOT do this:
-- package.path contains only the system paths and ./?.lua.
local dir = PANDOC_SCRIPT_FILE:match("^(.*)[/\\][^/\\]*$") or "."
package.path = dir .. "/?.lua;" .. dir .. "/?/init.lua;" .. package.path

local tree   = require "notion.reader.tree"
local blocks = require "notion.reader.blocks"

-- pandoc expands tabs to `opts.tab_stop` spaces before ANY custom reader
-- sees the input, unless --preserve-tabs is passed -- confirmed directly:
-- a file containing "Parent\n\tChild\n" arrives as src.text ==
-- "Parent\n    Child\n". NFM's nesting model is strict-tabs-only (see
-- tree.lua), so silently accepting the expanded text would corrupt every
-- tab-nested document. Re-reading the source file's raw bytes from disk
-- sidesteps the expansion entirely, with no change to the parser itself.
--
-- Each element of `input` (a Sources list) exposes `.name` (the source's
-- path, or "" for stdin/non-file sources) and `.text` (pandoc's -- possibly
-- tab-expanded -- decoded text). When `.name` names a file we can open, its
-- raw bytes are used verbatim (tabs intact, regardless of --preserve-tabs);
-- otherwise `.text` is the only text available, and is used as-is.
local function read_source(src)
  local name = src.name
  if type(name) == "string" and name ~= "" then
    local fh = io.open(name, "rb")
    if fh then
      local bytes = fh:read("a")
      fh:close()
      return bytes, false
    end
  end
  return tostring(src.text), true
end

-- A line whose leading whitespace is exactly one tab_stop's worth of spaces
-- is the signature left behind by pandoc's own tab expansion; used only to
-- decide whether a fallen-back-to source is worth warning about.
local function looks_tab_expanded(text, tab_stop)
  if type(tab_stop) ~= "number" or tab_stop <= 0 then return false end
  local indent = string.rep(" ", tab_stop)
  for line in (text .. "\n"):gmatch("(.-)\n") do
    if line:match("^" .. indent .. "[^ ]") then return true end
  end
  return false
end

function Reader(input, opts)
  local parts, warn_worthy = {}, false
  for _, src in ipairs(input) do
    local text, fell_back = read_source(src)
    if text:sub(-1) ~= "\n" then text = text .. "\n" end
    parts[#parts + 1] = text
    if fell_back and looks_tab_expanded(text, opts.tab_stop) then
      warn_worthy = true
    end
  end
  -- Warn once per document, not per line/source, and only when we actually
  -- had to fall back to pandoc's own (possibly already-expanded) text.
  if warn_worthy then
    pandoc.log.warn("Tabs may have been expanded to spaces before reaching " ..
      "the NFM reader; pass --preserve-tabs to keep tab-based nesting intact.")
  end

  return pandoc.Pandoc(blocks.convert(tree.parse(table.concat(parts))))
end
