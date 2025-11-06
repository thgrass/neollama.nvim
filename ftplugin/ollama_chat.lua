-- ftplugin/ollama_chat.lua
-- This runs for every buffer with :set filetype=ollama_chat

-- Syntax highlighting on
vim.cmd("syntax on")

-- fold level, style for think block
vim.opt_local.foldmethod = "syntax"
vim.opt_local.foldenable = true
vim.opt_local.foldlevel = 0

--  Define syntax rules
vim.cmd([[
  " languages for syntax highlighting in fenced markdown blocks in messages
  syntax include @OllamaCode syntax/python.vim
  syntax include @OllamaCode syntax/r.vim
  syntax include @OllamaCode syntax/lua.vim
  syntax include @OllamaCode syntax/sh.vim
  syntax include @OllamaCode syntax/bash.vim
  syntax include @OllamaCode syntax/vim.vim
  syntax include @OllamaCode syntax/julia.vim
  syntax include @OllamaCode syntax/c.vim
  syntax include @OllamaCode syntax/cpp.vim
  syntax include @OllamaCode syntax/rust.vim
  syntax include @OllamaCode syntax/javascript.vim
  syntax include @OllamaCode syntax/typescript.vim
  syntax include @OllamaCode syntax/html.vim
  syntax include @OllamaCode syntax/xml.vim
  syntax include @OllamaCode syntax/asm.vim

  " Triple-backtick fenced code block, language is ignored textually
  " but the code inside is highlighted by whatever syntax matches.
  syntax region OllamaCodeBlock
        \ matchgroup=OllamaCodeFence
        \ start='^\s*```.*$'
        \ end='^\s*```\s*$'
        \ keepend
        \ contains=@OllamaCode

  " Heading lines:
  syntax match OllamaHeading /^# .*$/

  " Model line: "Model: .."
  syntax match OllamaModel /^Model: .*$/

  " <think> ... </think> block (multi-line)
  syntax region OllamaThinkBlock
        \ start=+<think>+
        \ end=+</think>+
	\ fold
        \ keepend

  " USER BLOCK:
  " from a line starting with "**User:**" up to the next **User:** or **Ollama:** or EOF
  syntax region OllamaUser
        \ start=/^\*\*User:\*\*/
        \ end=/^\*\*User:\*\*\|^\*\*Ollama:\*\*\|\%$/
        \ keepend

  " OLLAMA BLOCK:
  " from a line starting with "**Ollama:**" up to the next **User:** or **Ollama:** or EOF
  syntax region OllamaAssistant
        \ start=/^\*\*Ollama:\*\*/
        \ end=/^\*\*User:\*\*\|^\*\*Ollama:\*\*\|\%$/
        \ keepend
        \ contains=OllamaThinkBlock,OllamaCodeBlock
]])

-- Theme-friendly highlighting: link to existing groups + modifiers

vim.api.nvim_set_hl(0, "OllamaUser", { link = "Identifier" })

vim.api.nvim_set_hl(0, "OllamaAssistant", { link = "Statement" })

vim.api.nvim_set_hl(0, "OllamaModel", { link = "Comment" })

vim.api.nvim_set_hl(0, "OllamaThinkBlock", { link = "Comment" })

vim.api.nvim_set_hl(0, "OllamaHeading", { link = "Special" })

vim.api.nvim_set_hl(0, "OllamaCodeFence", { link = "Special" })
