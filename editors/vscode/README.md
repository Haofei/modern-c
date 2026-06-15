# MC for VS Code

Syntax highlighting and a language server for the MC systems language (`.mc`).

The language server (`tools/lsp/mc-lsp.py`) drives the `mcc` compiler CLI and provides:

- diagnostics (the compiler's own `E_…` codes, plus parse errors)
- hover (type + kind), go-to-definition, find-references, document-highlight, rename
- document symbols (outline) and semantic tokens
- document formatting (`mcc fmt`)

Syntax highlighting (the TextMate grammar in `syntaxes/`) works with no server.

## Setup

1. Build the compiler from the repo root: `zig build` (produces `zig-out/bin/mcc`).
2. Make sure Python 3 is available.
3. Install the extension (for local development, symlink or copy this folder into
   `~/.vscode/extensions/`, then run `npm install` here to fetch `vscode-languageclient`).

## Settings

| Setting | Default | Meaning |
|---|---|---|
| `mc.server.enable` | `true` | Enable the language server. |
| `mc.server.path` | `${workspaceFolder}/tools/lsp/mc-lsp.py` | The `mc-lsp.py` server script. |
| `mc.mcc.path` | `${workspaceFolder}/zig-out/bin/mcc` | The `mcc` binary the server drives (passed as `MCC`). |
| `mc.python.path` | `python3` | Python 3 interpreter for the server. |

The server is started as `python3 mc-lsp.py` with `MCC` set to the compiler path, so it
always uses the same diagnostics and formatting as the CLI.
