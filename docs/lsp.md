# MC Language Server

`tools/lsp/mc-lsp.py` is a stdio Language Server Protocol server for `.mc`
files. It drives the `mcc` compiler CLI for diagnostics, formatting, symbols,
rename, references, hover, completion, semantic tokens, and related editor
features.

## Command

Run the server from the repository root:

```sh
MCC=/absolute/path/to/zig-out/bin/mcc python3 tools/lsp/mc-lsp.py
```

The server speaks LSP over stdin/stdout. Configure generic LSP clients with:

| Field | Value |
|---|---|
| Language id | `mc` |
| File extensions | `.mc` |
| Command | `python3` |
| Arguments | `tools/lsp/mc-lsp.py` |
| Environment | `MCC=/absolute/path/to/mcc` |

If `MCC` is unset, the server uses `mcc` from `PATH`. The VS Code extension
sets `MCC` from its `mc.mcc.path` setting.

## Client Examples

Neovim (`nvim-lspconfig` style):

```lua
vim.filetype.add({ extension = { mc = "mc" } })
vim.lsp.config("mc", {
  cmd = { "python3", "tools/lsp/mc-lsp.py" },
  filetypes = { "mc" },
  root_markers = { "build.zig", ".git" },
  cmd_env = { MCC = vim.fn.getcwd() .. "/zig-out/bin/mcc" },
})
vim.lsp.enable("mc")
```

Helix (`languages.toml`):

```toml
[[language]]
name = "mc"
scope = "source.mc"
file-types = ["mc"]
language-servers = ["mc-lsp"]

[language-server.mc-lsp]
command = "python3"
args = ["tools/lsp/mc-lsp.py"]
environment = { MCC = "zig-out/bin/mcc" }
```

Emacs Eglot:

```elisp
(add-to-list 'auto-mode-alist '("\\.mc\\'" . mc-mode))
(add-to-list 'eglot-server-programs
             '(mc-mode . ("python3" "tools/lsp/mc-lsp.py")))
(setenv "MCC" "/absolute/path/to/zig-out/bin/mcc")
```

Use an absolute path for `MCC` when the editor may start the server from a
different working directory. The server creates temporary sibling `.mc` files
beside the edited document so relative imports resolve the same way they do for
the compiler CLI.
