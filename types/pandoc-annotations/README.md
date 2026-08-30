# Vendored pandoc type annotations

LuaCATS/LuaLS type definitions for pandoc's Lua API. Comments only — never
loaded at runtime, so this directory has no effect on `pandoc lua`.

- Upstream: https://github.com/lua-craters/pandoc-annotations (MIT)
- Vendored from: https://github.com/jrnold/pandoc-annotations,
  branch `pandoc-3.11-fixes`

The fork fixes six defects found while checking this project against pandoc
3.11, each verified by running the constructor rather than reading the manual:
`Math` was missing its `text` parameter; `TableBody`'s first two parameters
were the wrong way round; `pandoc.Block` and `pandoc.Inline` were absent from
an `(exact)` class; `DefinitionListItem` was modelled as a record when it is a
positional pair; duplicate `insert` fields meant only one arity resolved; and
`pandoc.List` returned an unparameterised type. It also models pandoc's
argument coercion, since pandoc accepts a plain array, a single element or a
string wherever the manual documents `Blocks`/`Inlines`.

Together those took this workspace from 149 diagnostics to 0.

To update: replace these files from the fork, then re-run

    lua-language-server --check . --checklevel=Warning

Those fixes have not been offered upstream yet.
