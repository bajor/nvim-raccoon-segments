.PHONY: install test test-pure test-neovim test-pipeline test-host lint

PACK_DIR := $(HOME)/.config/nvim/pack/local/start
PLUGIN_NAME := nvim-raccoon-segments
HOST_COMMIT := 785ef2d7b32c6f4f0468f2efb85fbdb7c144b103
PLENARY_COMMIT := b9fd5226c2f76c951fc8ed5923d85e4de065e509
HOST_PATH ?= .deps/nvim-raccoon
PLENARY_PATH ?= .deps/plenary.nvim
NVIM ?= nvim
LUA ?= lua

install:
	@echo "Installing $(PLUGIN_NAME)..."
	@mkdir -p $(PACK_DIR)
	@rm -rf $(PACK_DIR)/$(PLUGIN_NAME)
	@ln -s $(CURDIR) $(PACK_DIR)/$(PLUGIN_NAME)
	@echo "Symlinked $(CURDIR) -> $(PACK_DIR)/$(PLUGIN_NAME)"
	@echo "Done! Restart Neovim to load the plugin."

test: test-pure test-neovim test-pipeline test-host lint

test-pure:
	$(LUA) tests/run.lua

test-neovim:
	$(NVIM) --headless -u NONE -l tests/run_in_ui.lua tests/neovim_spec.lua

test-pipeline:
	$(NVIM) --headless -u tests/minimal_init.lua -l tests/pipeline_spec.lua

$(HOST_PATH)/.git:
	mkdir -p $(dir $(HOST_PATH))
	git clone --no-checkout https://github.com/bajor/nvim-raccoon.git $(HOST_PATH)
	git -C $(HOST_PATH) checkout --detach $(HOST_COMMIT)

$(PLENARY_PATH)/.git:
	mkdir -p $(dir $(PLENARY_PATH))
	git clone --no-checkout https://github.com/nvim-lua/plenary.nvim.git $(PLENARY_PATH)
	git -C $(PLENARY_PATH) checkout --detach $(PLENARY_COMMIT)

test-host: $(HOST_PATH)/.git $(PLENARY_PATH)/.git
	$(NVIM) --headless --clean --cmd "set runtimepath^=$(CURDIR)/$(HOST_PATH)" \
		-c "lua assert(require('raccoon'))" -c qa
	$(NVIM) --headless -u NONE -l tests/run_in_ui.lua tests/host_compat_spec.lua \
		--cmd "set runtimepath^=$(CURDIR)/$(HOST_PATH)" --cmd "set runtimepath^=$(CURDIR)/$(PLENARY_PATH)"

lint:
	luacheck lua plugin tests
	git diff --check
