# Language Support (Highlighting + LSP) — Design

Date: 2026-10-06
Status: approved in chat, awaiting spec review

## Intent

Agents write most code; the user reviews it and sometimes fixes it by hand.
TreX should highlight the languages the user works in and, through language
servers, show errors/warnings in agent code and make it fast to navigate.

Success: open a `.ts`/`.rs`/`.go` file → colors, red squiggles on type errors
within seconds, F12 jumps to the definition, shift+F12 lists references,
hover shows the type. Missing server → one click installs it.

Languages: web (TS, TSX, JSX, JSON, SCSS), systems (Rust, Go, Zig),
scripting/config (Shell, YAML, TOML, Dockerfile, Makefile, SQL, .env, diff).

Out of scope (later): autocomplete, signature help, rename, format, code
actions/quick fix, inlay hints, semantic tokens, diagnostics inside the
commit review tab, incremental sync.

## Highlighting

- Vendor from `lite-xl/lite-xl-plugins` (MIT): `language_ts`, `language_tsx`,
  `language_jsx`, `language_json`, `language_rust`, `language_go`,
  `language_zig`, `language_sh`, `language_yaml`, `language_toml`,
  `language_make`, `language_diff`, `language_env`. Header changed from
  `mod-version:3` to `mod-version:4` (the 3→4 change is the project API;
  syntax plugins don't use it). Upstream license kept in `licenses/`.
- Written here (small, `syntax.add` only): `language_scss`, `language_sql`,
  `language_dockerfile`.

## Architecture

New plugin directory `data/plugins/lsp/`:

| File | Role |
|---|---|
| `json.lua` | rxi json.lua, vendored (MIT). |
| `rpc.lua` | Starts a process; `Content-Length` JSON-RPC framing over stdio; request ids, callbacks, notifications, 10 s timeout. No UI. |
| `servers.lua` | Table: server name → languages (syntax names), command, root markers, install recipe. |
| `client.lua` | One client per (server, root). initialize/initialized, didOpen/didChange/didSave/didClose, request helpers, diagnostics store per URI. No drawing. |
| `views.lua` | Problems and References tabs (row model like `plugins.scm.views.Text`). |
| `install.lua` | Install recipes runner. |
| `init.lua` | Editor glue: Doc hooks, DocView squiggles/gutter/tooltip, status bar items, commands, keymap. |

### Servers

| Server | Files | Command | Root markers | Install |
|---|---|---|---|---|
| typescript | ts, tsx, js, jsx, mjs, cjs | `typescript-language-server --stdio` | tsconfig.json, jsconfig.json, package.json | npm `typescript-language-server typescript` |
| json | json, jsonc | `vscode-json-language-server --stdio` | package.json | npm `vscode-langservers-extracted` |
| rust | rs | `rust-analyzer` | Cargo.toml | `rustup component add rust-analyzer` |
| go | go | `gopls` | go.mod, go.work | `GOBIN=<dir>/bin go install golang.org/x/tools/gopls@latest` |
| zig | zig | `zls` | build.zig | `brew install zls` (global; confirm says so) |
| bash | sh, bash, zsh | `bash-language-server start` | — | npm `bash-language-server` |
| yaml | yaml, yml | `yaml-language-server --stdio` | — | npm `yaml-language-server` |
| toml | toml | `taplo lsp stdio` | — | npm `@taplo/cli` |
| docker | Dockerfile | `docker-langserver --stdio` | — | npm `dockerfile-language-server-nodejs` |

Install dir: `~/.local/share/trex/lsp/` (npm `--prefix` there → binaries in
`node_modules/.bin`; Go → `bin/`). Lookup order: install dir, then `PATH`
(plus `/opt/homebrew/bin`, `/usr/local/bin`, `~/.cargo/bin` on macOS, since
GUI apps get a short PATH).

### Data flow

1. Doc opened (or its syntax set) → file extension picks a server.
2. Root = nearest ancestor containing a root marker, else `.git` ancestor,
   else the project folder containing the file.
3. No client for (server, root) → start one; queue the doc until initialized.
4. `didOpen` with full text. Edits → `didChange` with full text, debounced
   300 ms. Save → `didSave`. Doc closed → `didClose`.
5. `textDocument/publishDiagnostics` → store `[uri] = diagnostics` → redraw.
6. Last doc of a client closed → `shutdown` + `exit` after 5 min idle. Quit →
   shut all down.

Full-text sync is a deliberate simplification: every server supports it;
cost is resending large files, upgrade to incremental if that shows up.

## UI

Keys follow the VS Code bindings TreX already uses.

### Diagnostics

- Wavy underline under the range: error red, warning yellow, info/hint dim.
- Gutter dot on lines with diagnostics, color of the most severe.
- Mouse resting 500 ms on an underlined range → tooltip: message +
  source/code (`ts(2322): Type 'string' is not assignable…`).
- Status bar: error and warning counts for the active file, drawn as small
  colored rect marks + numbers (the UI font has no ✖/⚠). Click → Problems.
- Problems tab `cmd+shift+m` (`ctrl+shift+m`): grouped by file, errors
  first; click a row → open file at the line; live updates.
- `F8` / `shift+F8`: next/previous diagnostic in the file.

### Navigation

- Go to definition: `F12` or cmd+click (ctrl+click). One result → open and
  select the range; several → picker.
- Find references: `shift+F12` → References tab (file, line, line text);
  click jumps.
- Hover: mouse resting 500 ms on a symbol → tooltip with type/docs
  (markdown shown as plain text, code blocks kept). `cmd+k cmd+i` for the
  symbol at the caret.
- Document symbols: `cmd+shift+o` → picker, jump on submit.
- Workspace symbols: `cmd+t` → query picker.

### Server status

- Status bar item per active server: `ts…` starting, `ts` ready,
  red `ts ✕` crashed; click a crashed item → restart.
- Commands `lsp:restart`, `lsp:show-log` (last 500 stderr lines of the
  active file's server).

## Installer

- Opening a file whose server is missing → nag: `TypeScript language server
  not found. [Install] [Not now]`. "Not now" remembered for the session.
- Install runs in the background with a status-bar note; on success the
  server starts for open docs; on failure `core.error` with the output tail.
- zls: no local recipe; the prompt shows `brew install zls` and says it
  installs globally before running it.

## Errors

- Start failure or crash: marked crashed; auto-restart at most 3 times per
  60 s, then only manual restart.
- Request timeout 10 s: callback receives an error; navigation shows
  "Server busy". Nothing blocks the UI: reads happen in a thread.
- Server→client requests (`workspace/configuration`, `client/registerCapability`,
  `window/workDoneProgress/create`) get a null/empty result;
  `window/showMessage` → `core.log`. Unknown notifications ignored.
- Malformed frame → logged to the server log, the stream resyncs on the next
  `Content-Length` header.

## Testing

1. Native runner (`scripts/tests/ide.lua`): json round-trip; RPC frame
   parser on split chunks, merged chunks and multi-byte UTF-8 bodies; root
   detection; server lookup by filename; diagnostics sort order.
2. Fake server `scripts/tests/fake-lsp.lua`, run with the test runner binary:
   answers initialize, publishes one diagnostic on didOpen, answers
   definition, references, hover, documentSymbol; exits on `exit`.
3. UI runtime (`scripts/tests/ui-runtime.lua`), with the fake server
   registered for `.ts`: open file → diagnostic stored, squiggle drawn,
   status counts; Problems lists it; F12 opens target with selection;
   shift+F12 opens References; hover text received; kill server → crashed →
   restart works.
4. Real-server smoke (skipped when absent): rust-analyzer on a crate with a
   type error, diagnostic within 20 s.
5. Screenshot of squiggle + tooltip and of Problems tab; docs section in
   `docs/ide-features.md`.
