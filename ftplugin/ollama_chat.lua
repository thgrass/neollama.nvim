-- ftplugin/ollama_chat.lua
-- This runs for every buffer with :set filetype=ollama_chat

--  Turn off diagnostics for this buffer
--vim.diagnostic.disable(0)

--  Define syntax rules 
vim.cmd([[
  " Lines starting with "You:" are user messages
  syntax match OllamaUser      /^You:.*/

  " Lines starting with "AI:" are assistant messages
  syntax match OllamaAssistant /^AI:.*/

  " Lines starting with "[System]" are system messages
  syntax match OllamaSystem    /^\[System\].*/

  " Everything between <think> and </think>
  syntax region OllamaThinkBlock start=+<think>+ end=+</think>+ keepend

  " Markdown-ish headings
  syntax match OllamaHeading   /^# .*/
]])

--  Define highlight groups (colors/style) 

vim.api.nvim_set_hl(0, "OllamaUser", {
  bold = true,
})

vim.api.nvim_set_hl(0, "OllamaAssistant", {
})

vim.api.nvim_set_hl(0, "OllamaSystem", {
  underline = true,
})

vim.api.nvim_set_hl(0, "OllamaThinkBlock", {
  italic = true,
})

vim.api.nvim_set_hl(0, "OllamaHeading", {
  bold = true,
  underline = true,
})

