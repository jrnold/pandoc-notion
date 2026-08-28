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

-- Same as to_nfm, but also returns pandoc's log output (its stderr with
-- --verbose, since pandoc.log.info messages are INFO-level and pandoc
-- suppresses those by default). pandoc.pipe only returns stdout, so this
-- shells out via temp files instead. Used only to pin that a genuinely
-- dropped construct (e.g. colgroup color) actually logs per spec Sec 8,
-- rather than silently disappearing.
function M.to_nfm_with_log(text)
  local in_path, err_path = os.tmpname(), os.tmpname()
  local fh = assert(io.open(in_path, "wb"))
  fh:write(text)
  fh:close()

  local cmd = "pandoc --verbose -f '" .. READER .. "' -t '" .. WRITER
              .. "' '" .. in_path .. "' 2>'" .. err_path .. "'"
  local p = assert(io.popen(cmd, "r"))
  local out = p:read("a")
  p:close()

  local ef = assert(io.open(err_path, "rb"))
  local err = ef:read("a")
  ef:close()

  os.remove(in_path)
  os.remove(err_path)
  return out, err
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

-- Run standard markdown -> NFM through the writer only (source format is
-- pandoc's own `markdown`, not the NFM reader). Used to pin the writer's
-- lossy-input fallbacks -- footnotes, definition lists, line blocks, etc. --
-- constructs the NFM reader itself never produces, so to_nfm can't reach them.
function M.from_markdown(text)
  return pandoc.pipe("pandoc", { "-f", "markdown", "-t", WRITER }, text)
end

-- Same as from_markdown, but run with --verbose and stdout/stderr captured
-- separately, so tests can assert on log level (INFO only on a true drop,
-- nothing at default verbosity). pandoc.pipe cannot split streams, so this
-- shells out via temp files instead.
function M.from_markdown_verbose(text)
  local tmp_in  = os.tmpname()
  local tmp_err = os.tmpname()
  local ok, err = pcall(function()
    local fh = assert(io.open(tmp_in, "wb"))
    fh:write(text)
    fh:close()
  end)
  if not ok then
    os.remove(tmp_in)
    os.remove(tmp_err)
    error(err)
  end

  local cmd = string.format("pandoc --verbose -f markdown -t %q %q 2>%q",
                             WRITER, tmp_in, tmp_err)
  local out = ""
  local out_pipe = io.popen(cmd, "r")
  if out_pipe then
    out = out_pipe:read("a")
    out_pipe:close()
  end

  local errtext = ""
  local err_fh = io.open(tmp_err, "rb")
  if err_fh then
    errtext = err_fh:read("a")
    err_fh:close()
  end

  os.remove(tmp_in)
  os.remove(tmp_err)
  return out, errtext
end

return M
