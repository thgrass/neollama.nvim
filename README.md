# neollama.nvim
# EARLY DEVELOPMENT VERSION/PLAYGROUND. USE AT OWN RISK!!

A minimal Neovim plugin (Lua) to chat with a local **Ollama** instance in a dedicated chat tab, send visual selections, entire buffers, or a set of added buffers to the model, and keep read-only chat history in that tab.

## Features
- `:OllamaChat [model]` — open a new chat **tab** with a read-only chat buffer.
- `:OllamaAsk {text}` — send a one-off prompt to the current chat session.
- `:OllamaChatClose` — close the chat tab and destroy its buffer.
- `:OllamaSendSelection` — send the current **visual selection** as context/prompt.
- `:OllamaSendBuffer` — send the **entire current buffer** content.
- `:OllamaAddBuffer` — add the **current buffer** to the session's context list.
- `:OllamaClearAddedBuffers` — clear the context buffer list for the session.
- `:OllamaSendAddedBuffers` — send the **concatenated contents** of all added buffers.
- `:OllamaModel [model]` — set/get model name for the **current chat**.
- `:OllamaSetServer {url}` — change the server URL (default: `http://127.0.0.1:11434`).

> The chat buffer is **read-only**; you interact using commands. History remains visible within the tab.  
> This plugin uses external `curl` to call Ollama's HTTP API (`/api/generate`) either buffered/streamed to neovim,
> or not (set in config with stream=true|false).

## Requirements
- Neovim 0.8+
- A running Ollama server (default: `http://127.0.0.1:11434`)
- `curl` available on your system

## Installation

### Lazy.nvim
```lua
{
  "thgrass/neollama.nvim",
  config = function()
    require("ollama_chat").setup({
      server_url = "http://127.0.0.1:11434",
      model = "llama3.1",
      stream = true,
    })
  end,
}
```

### Packer.nvim
```lua
use({
  "thgrass/neollama.nvim",
  config = function()
    require("ollama_chat").setup({})
  end,
})
```

Or install manually by copying this folder into your neovim `runtimepath`.

## Usage

- Start a chat tab:
  ```vim
  :OllamaChat          " start with default model
  :OllamaChat mistral  " start with model mistral
  ```

- Ask something directly:
  ```vim
  :OllamaAsk What is the time complexity of quicksort?
  ```

- From another buffer, send the current **visual** selection:
  - Select text in Visual mode, then:
    ```vim
    :OllamaSendSelection
    ```

- Send the **entire buffer**:
  ```vim
  :OllamaSendBuffer
  ```

- Build a multi-file context:
  ```vim
  :OllamaAddBuffer           " run in buffers you want to add
  :OllamaSendAddedBuffers    " send all added buffers together
  :OllamaClearAddedBuffers   " clear the list
  ```

- Change model for the current chat:
  ```vim
  :OllamaModel mistral      " set model to mistral  
  :OllamaModel              " prints current model
  ```

- Change server URL:
  ```vim
  :OllamaSetServer http://localhost:11434
  ```

- Close Chat Tab & Destroy Chat Buffer:
  ```vim
  :OllamaChatClose
  ```

## TODO
- Add chat history to model context.
- Add support for model prompts and other variables.
- Improve support for programming tasks.
- ...

## License
MIT
