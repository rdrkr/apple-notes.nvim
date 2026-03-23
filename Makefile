# Copyright (c) 2026 apple-notes.nvim by Ronen Druker.

NVIM ?= nvim
PWD := $(shell pwd)
LUA_PATH := $(PWD)/lua/?.lua;$(PWD)/lua/?/init.lua;$(PWD)/tests/?.lua

.PHONY: test test-sanitize lint

test: test-sanitize

test-sanitize:
	@$(NVIM) --headless -u NONE \
		--cmd "set rtp+=$(PWD)" \
		-c "lua package.path = package.path .. ';$(LUA_PATH)'" \
		-c "lua require('test_sanitize')()" \
		-c "qa"

lint:
	@luacheck lua/ --no-unused-args --no-max-line-length 2>/dev/null || true
