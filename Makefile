# The readers, writers and test suite depend on nothing but pandoc. Everything
# below that needs LuaRocks is optional tooling; `make test` never touches it.

ROCKS_TREE   := .luarocks
ANNOTATIONS  := https://raw.githubusercontent.com/jrnold/pandoc-annotations/pandoc-3.11-fixes/pandoc-annotations-0.0.1-2.rockspec
LIBRARY      := $(ROCKS_TREE)/lib/luarocks/rocks-5.5/pandoc-annotations/0.0.1-2/library

.PHONY: test lint typecheck check deps clean-deps

## test: run the suite (pandoc only -- no other dependencies)
test:
	pandoc lua tests/run.lua

## lint: luacheck over the whole repo
lint:
	luacheck .

## typecheck: LuaCATS/LuaLS check using the annotations from `make deps`
typecheck: $(LIBRARY)
	lua-language-server --check . --checklevel=Warning

## check: everything
check: test lint typecheck

## deps: install the optional dev tooling into a project-local rocks tree
deps: $(LIBRARY)

$(LIBRARY):
	luarocks install --tree $(ROCKS_TREE) $(ANNOTATIONS)

## clean-deps: remove the project-local rocks tree
clean-deps:
	rm -rf $(ROCKS_TREE)
