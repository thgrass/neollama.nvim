-- ftplugin/ollama_chat.lua
-- This runs for every buffer with :set filetype=ollama_chat

local bufnr = vim.api.nvim_get_current_buf()

-- folding for think block, not for code
vim.opt_local.foldmethod = "expr"
vim.opt_local.foldenable = true
vim.opt_local.foldlevel = 0
vim.opt_local.foldexpr = "v:lua.OllamaFold(v:lnum)"

-- Cache fence/think state per line to avoid O(n^2) scans in the foldexpr.
-- Keyed by buffer, invalidated whenever that buffer changes.
local fold_caches = {}

local function compute_states(buf)
	local cache = fold_caches[buf]
	if not cache then
		cache = { seq = -1, states = {}, valid = false }
		fold_caches[buf] = cache
	end
	local seq = vim.api.nvim_buf_get_changedtick(buf)
	if cache.valid and cache.seq == seq then
		return cache.states
	end
	if not vim.api.nvim_buf_is_valid(buf) then
		return {}
	end
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local states = {}
	local fence_open = false
	local think_depth = 0
	for i, line in ipairs(lines) do
		-- a fence marker at line start toggles fence state
		if line:match("^%s*```") then
			fence_open = not fence_open
			states[i] = fence_open and "fence_open" or nil
		elseif fence_open then
			states[i] = "fence_open"
		elseif line:match("^%s*<think>%s*$") then
			think_depth = think_depth + 1
			states[i] = "think_open"
		elseif line:match("^%s*</think>%s*$") and think_depth > 0 then
			think_depth = think_depth - 1
			states[i] = nil
		elseif think_depth > 0 then
			states[i] = "think_open"
		else
			states[i] = nil
		end
	end
	cache.seq = seq
	cache.states = states
	cache.valid = true
	return states
end

local function invalidate_fold_cache(buf)
	local cache = fold_caches[buf]
	if cache then
		cache.valid = false
	end
end

-- Only fold <think>...</think>; never fold inside ``` fenced blocks
_G.OllamaFold = function(lnum)
	local buf = vim.api.nvim_get_current_buf()
	local states = compute_states(buf)
	local state = states[lnum]
	local line = vim.fn.getline(lnum)

	-- Never fold anything inside fenced code blocks
	if state == "fence_open" then
		return 0
	end

	-- Fold only <think>...</think> blocks (level 1)
	if line:match("^%s*<think>%s*$") then
		return ">1" -- start fold at level 1
	end
	if line:match("^%s*</think>%s*$") then
		return "<1" -- end fold
	end
	if state == "think_open" then
		return "=" -- keep previous level (stays at 1 while inside)
		-- Alternatively: return 1
	end

	-- Everything else: no folding
	return 0
end

-- ---------- Alias table: fence tag -> syntax file basename (no .vim) ----------
local OLLAMA_SYNTAX_ALIASES = {
	-- JS/TS/React
	js = "javascript",
	node = "javascript",
	mjs = "javascript",
	cjs = "javascript",
	jsx = "javascript",
	javascriptreact = "javascriptreact",
	ts = "typescript",
	tsx = "typescript",
	typescriptreact = "typescriptreact",

	-- C-family
	["c"] = "c",
	["c++"] = "cpp",
	cpp = "cpp",
	cc = "cpp",
	hpp = "cpp",
	["objective-c"] = "objc",
	["objective-c++"] = "objcpp",
	["obj-c"] = "objc",
	["obj-c++"] = "objcpp",
	csharp = "cs",
	["c#"] = "cs",

	-- Shells
	shell = "sh",
	sh = "sh",
	bash = "bash",
	zsh = "zsh",
	fish = "fish",

	-- Config/markup
	md = "markdown",
	markdown = "markdown",
	yml = "yaml",
	yaml = "yaml",
	json = "json",
	jsonc = "json",
	toml = "toml",
	ini = "dosini",
	conf = "conf",
	xml = "xml",
	html = "html",
	htm = "html",
	css = "css",
	scss = "scss",
	sass = "sass",
	less = "less",

	-- Infra
	docker = "dockerfile",
	dockerfile = "dockerfile",
	nginx = "nginx",
	tf = "terraform",
	terraform = "terraform",
	hcl = "hcl",

	-- Data/query
	sql = "sql",
	graphql = "graphql",
	gql = "graphql",
	proto = "proto",
	protobuf = "proto",
	csv = "csv",

	-- Languages
	lua = "lua",
	python = "python",
	py = "python",
	ruby = "ruby",
	rb = "ruby",
	perl = "perl",
	php = "php",
	go = "go",
	rust = "rust",
	rs = "rust",
	zig = "zig",
	java = "java",
	kotlin = "kotlin",
	kt = "kotlin",
	swift = "swift",
	objc = "objc",
	objcpp = "objcpp",
	r = "r",
	haskell = "haskell",
	hs = "haskell",
	ocaml = "ocaml",
	caml = "ocaml",
	clojure = "clojure",
	scala = "scala",
	julia = "julia",
	dart = "dart",

	-- Scripting/automation
	make = "make",
	makefile = "make",
	cmake = "cmake",
	powershell = "ps1",
	ps = "ps1",
	ps1 = "ps1",

	-- Misc
	vim = "vim",
	vimscript = "vim",
	regex = "regexp",
	regexp = "regexp",
}

-- Escape a string for literal use inside a Vim regex
local function vim_regex_escape(s)
	return (s:gsub("([\\.^$~%[%]*+?(){}|])", "\\%1"))
end

-- Map fence tag -> canonical syntax name (no .vim)
local function resolve_lang(tag)
	if not tag or tag == "" then
		return nil
	end
	tag = tag:lower()
	tag = tag:match("^([%w%+%-%_%.#]+)") or tag
	return OLLAMA_SYNTAX_ALIASES[tag] or tag
end

-- Build/update fenced-code syntax per buffer
local function ollama_update_fenced_syntax()
	-- gather unique canonical languages in this buffer
	local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
	local found, order = {}, {}
	for _, line in ipairs(lines) do
		local raw = line:match("^%s*```%s*([%w%+%-%_%.#]+)")
		if raw then
			local canon = resolve_lang(raw)
			if canon and not found[canon] then
				found[canon] = true
				table.insert(order, canon)
			end
		end
	end

	-- clear previously created regions/clusters
	if type(vim.b.ollama_fence_langs) == "table" then
		for _, old in ipairs(vim.b.ollama_fence_langs) do
			vim.cmd("silent! syntax clear OllamaCodeBlock_" .. old)
			vim.cmd("silent! syntax clear OllamaCode_" .. old)
		end
	end
	vim.cmd("silent! syntax cluster OllamaAllCode contains=NONE")
	vim.cmd("highlight def link OllamaCodeFence Special")

	-- plain (untagged) fenced block: single-line command
	vim.cmd(
		"silent! syntax clear OllamaCodeBlock_plain | "
			.. "syntax region OllamaCodeBlock_plain matchgroup=OllamaCodeFence "
			.. "start='^\\s*```\\s*$' end='^\\s*```\\s*$' keepend containedin=ALL contains=NONE"
	)
	vim.cmd("syntax cluster OllamaAllCode add=OllamaCodeBlock_plain")

	for _, lang in ipairs(order) do
		-- Only include syntax files that exist on the runtimepath; the tag
		-- is also validated against a safe charset above, so this cannot
		-- inject arbitrary ex commands.
		local have_file = #vim.fn.globpath(vim.o.runtimepath, "syntax/" .. lang .. ".vim", true) > 0
		local esc = vim_regex_escape(lang)

		if have_file then
			-- Work around the b:current_syntax guard in syntax files.
			-- Use vim.b directly: script-local (s:) variables are not shared
			-- between separate vim.cmd() calls.
			local prev_syn = vim.b.current_syntax
			vim.b.current_syntax = nil
			vim.cmd("syntax include @OllamaCode_" .. lang .. " syntax/" .. lang .. ".vim")
			if prev_syn then
				vim.b.current_syntax = prev_syn
			else
				vim.b.current_syntax = nil
			end
		end

		-- One-line :syntax region to avoid backslash continuation issues in Lua cmd()
		local start_pat = "^\\s*```\\s*\\%(" .. esc .. "\\)\\%(\\s\\+.*\\)\\=$"
		local end_pat = "^\\s*```\\s*$"
		local contains = have_file and ("@OllamaCode_" .. lang) or "NONE"

		local region_cmd = "syntax region OllamaCodeBlock_"
			.. lang
			.. " matchgroup=OllamaCodeFence"
			.. " start='"
			.. start_pat
			.. "'"
			.. " end='"
			.. end_pat
			.. "'"
			.. " keepend containedin=ALL contains="
			.. contains

		vim.cmd(region_cmd)
		vim.cmd("syntax cluster OllamaAllCode add=OllamaCodeBlock_" .. lang)
	end

	vim.b.ollama_fence_langs = order
end

-- Debounce the (relatively expensive) syntax refresh so streaming
-- responses don't re-run it on every single TextChanged tick.
local refresh_timer = nil
local function schedule_fenced_syntax_refresh()
	if refresh_timer then
		refresh_timer:close()
		refresh_timer = nil
	end
	refresh_timer = vim.defer_fn(function()
		refresh_timer = nil
		if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].filetype == "ollama_chat" then
			ollama_update_fenced_syntax()
		end
	end, 200)
end

-- buffer-local autocommands only for this chat buffer
do
	local grp = vim.api.nvim_create_augroup("OllamaFencedSyntax", { clear = false })
	vim.api.nvim_create_autocmd({ "BufEnter" }, {
		group = grp,
		buffer = bufnr,
		callback = function()
			invalidate_fold_cache(bufnr)
			schedule_fenced_syntax_refresh()
		end,
	})
end

-- Listen for line changes directly: TextChanged does not fire for
-- programmatic writes (which is how streamed responses are appended).
do
	local buf_loaded = false
	local function on_lines()
		if not vim.api.nvim_buf_is_valid(bufnr) then
			return true
		end
		invalidate_fold_cache(bufnr)
		schedule_fenced_syntax_refresh()
	end
	local function on_loaded()
		if buf_loaded then
			return true
		end
		buf_loaded = true
		invalidate_fold_cache(bufnr)
		schedule_fenced_syntax_refresh()
	end
	vim.api.nvim_buf_attach(bufnr, false, {
		on_lines = function()
			on_lines()
		end,
		on_reload = function()
			on_lines()
		end,
		on_detach = function() end,
	})
	vim.api.nvim_create_autocmd({ "BufWinEnter" }, {
		group = vim.api.nvim_create_augroup("OllamaFencedSyntaxLoad", { clear = true }),
		buffer = bufnr,
		callback = function()
			on_loaded()
		end,
	})
end

-- Base syntax: headings, model line, think/user/assistant blocks
vim.cmd([[
  silent! syntax clear OllamaCodeBlock

  syntax match OllamaHeading /^# .*$/
  syntax match OllamaModel   /^Model: .*$/

  syntax region OllamaThinkBlock
        \ start=+<think>+
        \ end=+</think>+
        \ fold
        \ keepend

  syntax region OllamaUser
        \ start=/^\*\*User:\*\*/
        \ end=/^\*\*User:\*\*\|^\*\*Ollama:\*\*\|\%$/
        \ keepend

  syntax region OllamaAssistant
        \ start=/^\*\*Ollama:\*\*/
        \ end=/^\*\*User:\*\*\|^\*\*Ollama:\*\*\|\%$/
        \ keepend
        \ contains=OllamaThinkBlock,@OllamaAllCode
]])

-- Theme-friendly highlights
vim.api.nvim_set_hl(0, "OllamaUser", { link = "Identifier" })
vim.api.nvim_set_hl(0, "OllamaAssistant", { link = "Statement" })
vim.api.nvim_set_hl(0, "OllamaModel", { link = "Comment" })
vim.api.nvim_set_hl(0, "OllamaThinkBlock", { link = "Comment" })
vim.api.nvim_set_hl(0, "OllamaHeading", { link = "Special" })
vim.api.nvim_set_hl(0, "OllamaCodeFence", { link = "Special" })

-- initial syntax build for this buffer
ollama_update_fenced_syntax()
