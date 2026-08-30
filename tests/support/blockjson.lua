-- Helpers that shell out to pandoc for the block-JSON pair. Mirrors
-- tests/support/nfm.lua, which does the same for the NFM pair.
local M = {}

local ROOT = (arg[0] or ""):match("^(.*)[/\\]tests[/\\]") or "."
M.ROOT = ROOT

M.READER     = ROOT .. "/notion-block-reader.lua"
M.WRITER     = ROOT .. "/notion-block-writer.lua"
M.NFM_READER = ROOT .. "/notion-markdown-reader.lua"
M.NFM_WRITER = ROOT .. "/notion-markdown-writer.lua"

-- --standalone is required: pandoc's native writer emits the `Pandoc Meta …`
-- wrapper ONLY under --standalone. Without it, `-t native` prints the blocks
-- alone and Meta vanishes -- which would leave design doc 4.6 (page properties
-- -> Meta) with no golden coverage in Task 13, even though it is success
-- criterion 6. The cost on a document with no metadata is one short line:
-- `Pandoc Meta { unMeta = fromList [] } [ … ]`.
-- The NFM helper in tests/support/nfm.lua needs no such flag, because NFM has
-- no metadata layer at all.
function M.to_native(text)
  return pandoc.pipe("pandoc",
    { "-f", M.READER, "-t", "native", "--standalone" }, text)
end

function M.to_json(text)
  return pandoc.pipe("pandoc", { "-f", M.READER, "-t", M.WRITER }, text)
end

function M.to_nfm(text)
  return pandoc.pipe("pandoc", { "-f", M.READER, "-t", M.NFM_WRITER }, text)
end

function M.from_nfm(text)
  return pandoc.pipe("pandoc", { "-f", M.NFM_READER, "-t", M.WRITER }, text)
end

function M.nfm_roundtrip(text)
  return pandoc.pipe("pandoc", { "-f", M.NFM_READER, "-t", M.NFM_WRITER }, text)
end

function M.from_markdown(text)
  return pandoc.pipe("pandoc", { "-f", "markdown", "-t", M.WRITER }, text)
end

-- pandoc.pipe cannot split stdout from stderr, and pandoc.log.info is only
-- emitted under --verbose, so log assertions shell out via temp files.
function M.from_markdown_verbose(text)
  local tmp_in, tmp_err = os.tmpname(), os.tmpname()
  local fh = assert(io.open(tmp_in, "wb"))
  fh:write(text)
  fh:close()

  local cmd = string.format("pandoc --verbose -f markdown -t %q %q 2>%q",
                            M.WRITER, tmp_in, tmp_err)
  local out = ""
  local p = io.popen(cmd, "r")
  if p then out = p:read("a"); p:close() end

  local errtext = ""
  local ef = io.open(tmp_err, "rb")
  if ef then errtext = ef:read("a"); ef:close() end

  os.remove(tmp_in)
  os.remove(tmp_err)
  return out, errtext
end

function M.read_file(path)
  local fh = assert(io.open(path, "rb"))
  local data = fh:read("a")
  fh:close()
  return data
end

function M.list(subdir)
  local dir = ROOT .. "/tests/corpus/json/" .. subdir
  local out = {}
  local p = io.popen("ls " .. dir .. "/*.json 2>/dev/null")
  if p then
    for line in p:lines() do out[#out + 1] = line end
    p:close()
  end
  table.sort(out)
  return out
end

return M
