local M = {}

local ROOT = (arg[0] or ""):match("^(.*)[/\\]tests[/\\]") or "."
M.ROOT = ROOT

local READER = ROOT .. "/notion-markdown-reader.lua"
local WRITER = ROOT .. "/notion-markdown-writer.lua"

function M.to_nfm(text)
  return pandoc.pipe("pandoc", { "-f", READER, "-t", WRITER }, text)
end

function M.to_native(text)
  return pandoc.pipe("pandoc", { "-f", READER, "-t", "native" }, text)
end

-- Same as to_nfm, but with pandoc's default tab-to-spaces expansion turned
-- off. Used only to pin the known --preserve-tabs limitation in
-- tab_in_fence_test.lua -- the default harness above deliberately does not
-- use this flag (see tests/roundtrip_test.lua).
function M.to_nfm_preserve_tabs(text)
  return pandoc.pipe("pandoc", { "--preserve-tabs", "-f", READER, "-t", WRITER }, text)
end

function M.read_file(path)
  local fh = assert(io.open(path, "rb"))
  local data = fh:read("a")
  fh:close()
  return data
end

-- List *.nfm under a corpus subdirectory, sorted for deterministic runs.
function M.list(subdir)
  local dir = ROOT .. "/tests/corpus/" .. subdir
  local out = {}
  local pipe = io.popen("ls " .. dir .. "/*.nfm 2>/dev/null")
  if pipe then
    for line in pipe:lines() do out[#out + 1] = line end
    pipe:close()
  end
  table.sort(out)
  return out
end

return M
