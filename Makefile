# The readers, writers and test suite depend on nothing but pandoc. Everything
# below that needs LuaRocks is optional tooling; `make test` never touches it.

ROCKS_TREE   := .luarocks
ANNOTATIONS  := https://raw.githubusercontent.com/jrnold/pandoc-annotations/pandoc-3.11-fixes/pandoc-annotations-0.0.1-2.rockspec
LIBRARY      := $(ROCKS_TREE)/lib/luarocks/rocks-5.5/pandoc-annotations/0.0.1-2/library

.PHONY: test lint typecheck check deps clean-deps fixtures test-py lint-py

## test: run the suite (pandoc only -- no other dependencies)
test:
	pandoc lua tests/run.lua

## lint: luacheck over the whole repo
lint:
	luacheck .

## typecheck: LuaCATS/LuaLS check using the annotations from `make deps`
typecheck: $(LIBRARY)
	lua-language-server --check . --checklevel=Warning

## fixtures: regenerate the Python suite's block JSON fixtures from the corpus
fixtures:
	@mkdir -p notion-upload/tests/fixtures
	@for f in tests/corpus/blocks/*.nfm; do \
		name=$$(basename $$f .nfm); \
		pandoc -f notion-markdown-reader.lua -t notion-block-writer.lua \
			"$$f" -o "notion-upload/tests/fixtures/$$name.json" || exit 1; \
		echo "  $$name.json"; \
	done

## test-py: run the uploader's suite (no pandoc, no network)
test-py:
	cd notion-upload && uv run pytest -q

## lint-py: ruff over the uploader package
lint-py:
	cd notion-upload && uv run ruff check .

## check: everything
check: test lint typecheck test-py lint-py

## deps: install the optional dev tooling into a project-local rocks tree
deps: $(LIBRARY)

$(LIBRARY):
	luarocks install --tree $(ROCKS_TREE) $(ANNOTATIONS)

## clean-deps: remove the project-local rocks tree
clean-deps:
	rm -rf $(ROCKS_TREE)
