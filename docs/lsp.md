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
different working directory. Relative `MCC` paths containing a directory are
normalized when the server starts. Unsaved source is passed to `mcc` over stdin
with the document directory as the compiler working directory, so relative imports
resolve without writing beside the source file. This works with read-only trees.

Compiler requests have a hard timeout controlled by
`MC_LSP_MCC_TIMEOUT_SECONDS` (15 seconds by default). Diagnostics are debounced,
obsolete checks are terminated, imported-file diagnostics retain their source
URI, and stale imported diagnostics are explicitly cleared. Symbol spans include
their source path, so definition, references, and rename operate across the current
import graph. Workspace symbol search also discovers unopened `.mc` files under
the roots supplied by the client, up to the server's 10,000-document safety limit.
