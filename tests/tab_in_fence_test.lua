local t   = require "support.assert"
local nfm = require "support.nfm"

-- Pinned limitation: pandoc expands tabs to spaces (tab-stop 4) in the raw
-- input text before handing it to ANY custom Lua reader's Reader() function.
-- This happens upstream of notion-markdown-reader.lua -- for every pandoc
-- input format except t2t/man/tsv, which pandoc hardcodes as exemptions. A
-- literal tab used as ordinary NFM structural indentation survives this fine
-- (the reader turns any indent width into a nesting depth, and the writer
-- re-emits canonical tab characters on output regardless), but a literal tab
-- that is significant CONTENT inside a fenced code block -- e.g. a Makefile
-- recipe line, which requires a literal tab -- does not: it comes back as
-- four spaces. `--preserve-tabs` avoids the expansion and round-trips it
-- byte-identically; the default CLI experience (what tests/support/nfm.lua's
-- to_nfm uses, and what tests/roundtrip_test.lua exercises) does not.

local path = nfm.ROOT .. "/tests/corpus/adversarial/tab-in-fence.nfm"
local src  = nfm.read_file(path):gsub("\n$", "")

local default = nfm.to_nfm(src):gsub("\n$", "")
t.truthy(default:find("\t") == nil,
  "without --preserve-tabs, the fence's literal tab does not survive")
t.truthy(default:find("    command") ~= nil,
  "without --preserve-tabs, the tab comes back as 4 spaces (pandoc's tab-stop)")

local preserved = nfm.to_nfm_preserve_tabs(src):gsub("\n$", "")
t.eq(preserved, src, "with --preserve-tabs, the fixture round-trips byte-identically")
