-- Luacheck configuration.
--
-- pandoc does not lint its own Lua -- it ships no .luacheckrc -- so this is
-- derived from the globals pandoc actually installs, enumerated from the
-- interpreter rather than from memory:
--
--   $ pandoc lua -e 'for k in pairs(_G) do print(k) end'
--   PANDOC_API_VERSION  PANDOC_STATE  PANDOC_VERSION  lpeg  pandoc  re
--
-- and, additionally inside a custom reader or writer, PANDOC_SCRIPT_FILE.
-- PANDOC_READER_OPTIONS, PANDOC_WRITER_OPTIONS and FORMAT are pandoc globals
-- too but exist only in filters; they are listed so a future filter in this
-- repo does not have to rediscover them.

std = "lua54"          -- the interpreter pandoc bundles

-- Everything pandoc provides is read-only: assigning to any of these is a bug.
read_globals = {
  "pandoc",
  "lpeg",
  "re",
  "PANDOC_VERSION",
  "PANDOC_API_VERSION",
  "PANDOC_STATE",
  "PANDOC_SCRIPT_FILE",
  "PANDOC_READER_OPTIONS",
  "PANDOC_WRITER_OPTIONS",
  "FORMAT",
}

-- The entry points define exactly one global each -- that is pandoc's calling
-- convention for a custom reader/writer, not an accident. Scoped per file so a
-- stray global anywhere else is still reported.
files["notion-markdown-reader.lua"] = { globals = { "Reader" } }
files["notion-block-reader.lua"]    = { globals = { "Reader" } }
files["notion-markdown-writer.lua"] = { globals = { "Writer" } }
files["notion-block-writer.lua"]    = { globals = { "Writer" } }

-- Test suites are flat scripts run in one shared interpreter, so they read
-- `arg` to locate themselves.
--
-- `pandoc` is writable here, unlike everywhere else: several suites swap
-- pandoc.read, pandoc.log.info or pandoc.log.warn for a counting stub and
-- restore it afterwards. That is how the batching tests isolate the reader
-- from the real parser, and how the degradation tests assert that a silent
-- fallback logs nothing -- a requirement the spec states as strictly as the
-- output itself. Forbidding it would mean testing a mock instead.
files["tests/**/*.lua"] = {
  read_globals = { "arg" },
  globals = { "pandoc" },
  -- Shadowing checks (411/421/431/432) are off HERE ONLY. These suites are
  -- flat top-to-bottom scripts where each case declares its own `src`, `out`
  -- or `log`; reusing the name per case is the idiom, not an accident, and the
  -- warning fires on every one. They stay ON for production code, where
  -- shadowing genuinely hides bugs -- renaming a shadowed `text` in
  -- notion/reader/tree.lua is what surfaced a latent one while adding this
  -- config.
  ignore = { "411", "421", "431", "432" },
}

-- types/ holds LuaLS definition stubs (---@meta): comments only, never
-- loaded at runtime, and they intentionally assign to pandoc globals.
-- .luarocks/ is the project-local rocks tree from `make deps`: third-party
-- LuaCATS definition files, which are comments only and not ours to lint.
exclude_files = { ".superpowers/**", ".luarocks/**" }
