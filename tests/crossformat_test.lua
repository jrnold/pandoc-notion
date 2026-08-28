local t   = require "support.assert"
local nfm = require "support.nfm"

local READER = nfm.ROOT .. "/notion-markdown-reader.lua"

-- Columns adopt pandoc's own convention, so they must survive into reveal.js
-- as a real two-column slide. This protects interoperability we got for free.
local columns = table.concat({
  "<columns>", "\t<column>", "\t\tLeft", "\t</column>",
  "\t<column>", "\t\tRight", "\t</column>", "</columns>", "" }, "\n")

local html = pandoc.pipe("pandoc", { "-f", READER, "-t", "revealjs" }, columns)
t.truthy(html:find('class="columns"', 1, true) ~= nil, "columns class survives to reveal.js")
t.truthy(html:find('class="column"', 1, true) ~= nil, "column class survives to reveal.js")

-- Conversion to common formats must not crash and must keep the content.
for _, fmt in ipairs({ "html", "gfm", "org", "latex", "plain" }) do
  local ok, out = pcall(pandoc.pipe, "pandoc", { "-f", READER, "-t", fmt }, columns)
  t.truthy(ok, "converts to " .. fmt .. " without error")
  if ok then
    t.truthy(out:find("Left", 1, true) ~= nil, "content survives conversion to " .. fmt)
  end
end

-- A callout's content must remain visible in other formats, which is the whole
-- reason the convention is structural rather than raw.
local callout = '<callout icon="X" color="blue_bg">\n\tVisible text\n</callout>\n'
local as_html = pandoc.pipe("pandoc", { "-f", READER, "-t", "html" }, callout)
t.truthy(as_html:find("Visible text", 1, true) ~= nil, "callout content survives to HTML")
t.truthy(as_html:find("callout", 1, true) ~= nil, "callout class survives to HTML")
