// VS Code client for the MC language server (tools/lsp/mc-lsp.py).
//
// Syntax highlighting works without this file (it is pure TextMate grammar). This client adds
// diagnostics, hover, go-to-definition, find-references, document-highlight, rename, document
// formatting, document symbols, and semantic tokens by launching `python3 mc-lsp.py` and
// speaking LSP over stdio. The server itself drives the `mcc` CLI; the `MCC` environment
// variable (from the `mc.mcc.path` setting) selects the compiler binary.

const { workspace, window } = require("vscode");
const { LanguageClient, TransportKind } = require("vscode-languageclient/node");

let client;

function resolve(value) {
  const folder = workspace.workspaceFolders && workspace.workspaceFolders[0];
  return folder ? value.replace(/\$\{workspaceFolder\}/g, folder.uri.fsPath) : value;
}

function activate() {
  const config = workspace.getConfiguration("mc");
  if (!config.get("server.enable", true)) {
    return;
  }

  const python = resolve(config.get("python.path", "python3"));
  const server = resolve(config.get("server.path", "${workspaceFolder}/tools/lsp/mc-lsp.py"));
  const mcc = resolve(config.get("mcc.path", "${workspaceFolder}/zig-out/bin/mcc"));

  // The server is `python3 mc-lsp.py`, with MCC pointing at the compiler binary.
  const exec = {
    command: python,
    args: [server],
    transport: TransportKind.stdio,
    options: { env: { ...process.env, MCC: mcc } },
  };
  const serverOptions = { run: exec, debug: exec };

  const clientOptions = {
    documentSelector: [{ scheme: "file", language: "mc" }],
    synchronize: {
      fileEvents: workspace.createFileSystemWatcher("**/*.mc"),
    },
  };

  client = new LanguageClient("mc", "MC Language Server", serverOptions, clientOptions);
  client.start().catch((error) => {
    window.showErrorMessage(
      `MC language server failed to start (${python} ${server}): ${error.message}. ` +
        `Build the compiler with \`zig build\` and check the "mc.server.path" / "mc.mcc.path" settings.`
    );
  });
}

function deactivate() {
  return client ? client.stop() : undefined;
}

module.exports = { activate, deactivate };
