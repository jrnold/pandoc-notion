local t   = require "support.assert"
local nfm = require "support.nfm"

local READER = nfm.ROOT .. "/notion-markdown-reader.lua"

-- Same wide-columns rationale as tests/regenerate_goldens.lua: pandoc 3.10.2
-- line-wraps Attr-bearing constructors (Header/Div/Span with attributes) in
-- native output at the default column width, which would make the goldens
-- fragile to terminal-width assumptions. nfm.to_native is left untouched
-- since other suites depend on it, so this suite shells out on its own.
local function to_native_wide(text)
  return pandoc.pipe("pandoc", { "--columns=1000", "-f", READER, "-t", "native" }, text)
end

local SUBDIRS = { "blocks", "inlines", "nesting", "adversarial", "official" }
local checked = 0

for _, sub in ipairs(SUBDIRS) do
  for _, path in ipairs(nfm.list(sub)) do
    local name = path:match("([^/]+)%.nfm$")
    local dest = nfm.ROOT .. "/tests/golden/" .. sub .. "/" .. name .. ".native"
    local fh = io.open(dest, "rb")
    if not fh then
      t.truthy(false, "missing golden for " .. sub .. "/" .. name
                      .. " (run: pandoc lua tests/regenerate_goldens.lua)")
    else
      local expected = fh:read("a"); fh:close()
      t.eq(to_native_wide(nfm.read_file(path)), expected,
           "AST matches golden: " .. sub .. "/" .. name)
      checked = checked + 1
    end
  end
end

t.eq(checked, 45, "every fixture has a golden, checked " .. checked)
