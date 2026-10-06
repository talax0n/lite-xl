# Language Support (Highlighting + LSP) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Highlight TS/TSX/JSX/JSON/SCSS/Rust/Go/Zig/Shell/YAML/TOML/Dockerfile/Make/SQL/.env/diff, and run language servers for errors, warnings and navigation (definition, references, hover, symbols), with one-click server install.

**Architecture:** Syntax files are vendored from `lite-xl/lite-xl-plugins` with the header bumped to mod-version 4. The LSP follows the `scm` layout: plugin file `data/plugins/lsp.lua` (editor glue: hooks, drawing, commands, install) plus modules in `data/plugins/lsp/`:
- `json.lua` (vendored rxi json with null support)
- `util.lua` (pure helpers)
- `servers.lua` (server table)
- `rpc.lua` (stdio JSON-RPC)
- `client.lua` (one client per server and root, plus the diagnostics store)
- `views.lua` (Problems and References lists)

A fake server, `scripts/tests/fake-lsp.lua`, drives the tests.

**Tech Stack:** Lua 5.4 on lite-xl (mod-version 4, SDL3). `core.process` for server processes, `plugins.scm.git.exec` for installs. Tests: native runner `build/src/ide-test-runner scripts/tests/ide.lua` (currently 76 checks), UI runtime `./scripts/test-ide.sh build`.

**Spec:** `docs/superpowers/specs/2026-10-06-language-support-design.md`

**Spec deviations (rulings; spec is the authority for everything else):**
- Layout `lsp.lua` + `lsp/` modules matches `scm.lua` + `scm/`. Install logic lives in `lsp.lua` (about 20 lines), so there's no `install.lua`.
- One status-bar item shows the active file's server state (not one per running server). Crashed and missing states show the words `crashed` and `not installed`, because the UI font has no ✕ glyph.
- Workspace symbols take two steps: type a query and submit, then pick a result. `CommandView` suggestions are synchronous.
- Hover at the caret is `cmd+i` (mac) / `ctrl+shift+i`, because lite-xl keymaps have no `cmd+k cmd+i` chords.
- Cmd+click (mac) / ctrl+click is bound through the keymap as `lsp:goto-definition-at-mouse`; on files without a server it falls through to the old binding.
- Language-server shutdown on quit relies on stdin EOF (servers exit when the editor's pipes close); there's no explicit quit hook.
- `language_sass` covers `.scss` and `language_psql` covers `.sql`, so only `language_dockerfile` is written here. `language_env`'s syntax name is renamed from `language_env` to `.env`.
- Real-server smoke runs as a manual script (`scripts/tests/lsp-smoke.lua`, Task 6). rust-analyzer can take longer than the meson test timeout.

## Global Constraints

- Plugin header: `-- mod-version:4` on every plugin file in `data/plugins/`.
- Install dir: `~/.local/share/trex/lsp/`, npm `--prefix` there, Go `GOBIN=<dir>/bin`. Lookup order: install dir, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.cargo/bin`, `~/go/bin`, then `PATH`.
- Server processes and installs get `PATH` = that list (GUI apps start with a short PATH; npm-based servers need `node`).
- didChange is full text, debounced 300 ms; a request flushes pending changes first.
- Request timeout 10 s. Auto-restart at most 3 times per 60 s. Idle client shutdown after 5 min with no open docs.
- Diagnostic colors: severity 1 `style.error`, 2 `style.warn`, 3/4 `style.dim`.
- Hover delay 500 ms.
- Keys: `f12`, `shift+f12`, `f8`, `shift+f8`, `cmd+i`/`ctrl+shift+i`, `cmd+shift+o`/`ctrl+shift+o`, `cmd+t`/`ctrl+t`, `cmd+shift+m`/`ctrl+shift+m`, `cmd+1lclick`/`ctrl+1lclick`.
- Never commit `subprojects/.wraplock`. Conventional Commits.

## Review Focus

1. **Non-ASCII text before a diagnostic** (`é`, emoji): LSP columns are UTF-16 units, but lite-xl uses byte columns. Squiggles must sit under the right characters. Covered in Task 2 (`UTF-16 columns`, diagnostics on `é = 1`).
2. **Paths with spaces or non-ASCII characters** (`/a b/é.ts`): they must round-trip through `file://` URIs. Covered in Task 2.
3. **A server that dies or never starts** (crash, missing binary, failed initialize): no UI freeze, no restart loop, and the doc must reopen after a restart. Covered in Task 2 (limiter) and Task 3 / Task 4 (kill → restart).
4. **Frames split across reads or merged in one read**, multi-byte bodies, and junk headers. Covered in Task 2.
5. **Typing fast in a big file**: one didChange per 300 ms of quiet, never one per keystroke, and requests see the latest text. Covered by the flush in Task 4 / Task 5 code. The UI test edits and then requests.

---

### Task 1: Syntax highlighting for the new languages

**Files:**
- Create (vendored): `data/plugins/language_{ts,tsx,jsx,json,rust,go,zig,sh,yaml,toml,make,diff,env,sass,psql}.lua`
- Create: `data/plugins/language_dockerfile.lua`
- Modify: `licenses/licenses.md` (append the lite-xl-plugins MIT notice)
- Test: `scripts/tests/ui-runtime.lua`

**Interfaces:**
- Consumes: nothing.
- Produces: `syntax.get(path).name` gives `TypeScript`, `TypeScript with JSX`, `JSX`, `JSON`, `Rust`, `Go`, `Zig`, `Shell script`, `YAML`, `TOML`, `Makefile`, `Diff`, `.env`, `Sass`, `PostgreSQL`, `Dockerfile`.

- [ ] **Step 1: Write the failing test**

In `scripts/tests/ui-runtime.lua`, insert before `    for _, item in ipairs(core.log_items) do`:

```lua
    local syntax = require 'core.syntax'
    for file, name in pairs({['a.ts'] = 'TypeScript', ['a.tsx'] = 'TypeScript with JSX', ['a.jsx'] = 'JSX', ['a.json'] = 'JSON',
      ['a.rs'] = 'Rust', ['a.go'] = 'Go', ['a.zig'] = 'Zig', ['a.sh'] = 'Shell script', ['a.yaml'] = 'YAML', ['a.toml'] = 'TOML',
      ['Makefile'] = 'Makefile', ['a.diff'] = 'Diff', ['.env'] = '.env', ['a.scss'] = 'Sass', ['a.sql'] = 'PostgreSQL',
      ['Dockerfile'] = 'Dockerfile'}) do
      local got = syntax.get(workspace .. '/' .. file).name
      assert(got == name, file .. ' highlighted as ' .. tostring(got))
    end
```

- [ ] **Step 2: Run it and watch it fail**

Run: `cd /Users/theo/Documents/PROJECT/lite-xl && PATH=/tmp/lite-xl-build-tools/bin:$PATH ./scripts/test-ide.sh build 2>&1 | tail -1`
Expected: FAIL `a.ts highlighted as Plain Text` (or another missing file; pairs order varies).

- [ ] **Step 3: Vendor the upstream syntax files**

```bash
cd /Users/theo/Documents/PROJECT/lite-xl
rm -rf /tmp/lxl-plugins && git clone -q --depth 1 https://github.com/lite-xl/lite-xl-plugins /tmp/lxl-plugins
for n in ts tsx jsx json rust go zig sh yaml toml make diff env sass psql; do
  sed '1s/mod-version:3/mod-version:4/' /tmp/lxl-plugins/plugins/language_$n.lua > data/plugins/language_$n.lua
done
sed -i '' 's/name = "language_env"/name = ".env"/' data/plugins/language_env.lua
head -1 data/plugins/language_*.lua | grep -c 'mod-version:4'
git -C /tmp/lxl-plugins rev-parse HEAD
```

Expected: the count equals the number of `language_*.lua` files (24), and the commit sha is printed for the license note.

- [ ] **Step 4: Write the Dockerfile syntax**

Create `data/plugins/language_dockerfile.lua`:

```lua
-- mod-version:4
local syntax = require "core.syntax"

syntax.add {
  name = "Dockerfile",
  files = { PATHSEP .. "[Dd]ockerfile[^" .. PATHSEP .. "]*$", "%.dockerfile$", PATHSEP .. "Containerfile$" },
  comment = "#",
  patterns = {
    { pattern = "#.*",                    type = "comment"  },
    { pattern = { '"', '"', '\\' },       type = "string"   },
    { pattern = { "'", "'", '\\' },       type = "string"   },
    { pattern = "%$%{[^}]*%}",            type = "keyword2" },
    { pattern = "%$[%w_]+",               type = "keyword2" },
    { pattern = "^%s*%u+%f[%s]",          type = "keyword"  },
    { pattern = "%-%-[%w%-]+",            type = "function" },
    { pattern = "%d+",                    type = "number"   },
    { pattern = "[%w_%-%.]+",             type = "normal"   },
  },
  symbols = {},
}
```

- [ ] **Step 5: Add the license note**

Append to `licenses/licenses.md`:

```markdown

## lite-xl-plugins (syntax files `language_*.lua` from lite-xl/lite-xl-plugins)

MIT License. Copyright (c) 2020-present Lite XL Team and contributors.
Source: https://github.com/lite-xl/lite-xl-plugins

## json.lua (`data/plugins/lsp/json.lua`, via lite-xl/lite-xl-lsp)

MIT License. Copyright (c) 2020 rxi. Source: https://github.com/rxi/json.lua
```

- [ ] **Step 6: Run the tests and watch them pass**

Run: `cd /Users/theo/Documents/PROJECT/lite-xl && PATH=/tmp/lite-xl-build-tools/bin:$PATH ./scripts/test-ide.sh build 2>&1 | tail -1`
Expected: `PASS: nested workspace repositories, ...`. Also check that the log has no `stack traceback` from loading the new plugins (the runtime asserts this).

- [ ] **Step 7: Commit**

```bash
git add data/plugins/language_*.lua licenses/licenses.md scripts/tests/ui-runtime.lua
git commit -m "feat(syntax): highlight TypeScript, Rust, Go, Zig, shell, YAML, TOML and more"
```

---

### Task 2: JSON, pure helpers, server table and frame parser

**Files:**
- Create: `data/plugins/lsp/json.lua` (vendored), `data/plugins/lsp/util.lua`, `data/plugins/lsp/servers.lua`, `data/plugins/lsp/rpc.lua` (the parser and frame part; Task 3 adds the process part)
- Test: `scripts/tests/ide.lua` (block before the final `assert(os.execute('rm -rf ' .. tmp))`)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `json.encode(v)`, `json.decode(s) -> value | false`, `json.null`. Empty tables encode as `{}`.
  - `util.path_to_uri(path)`, `util.uri_to_path(uri)`
  - `util.byte_col(text, character) -> col`, `util.utf16_col(text, col) -> character`
  - `util.find_root(path, markers, fallback)`
  - `util.diagnostics(list, lines|nil)`, which returns sorted `{line1, col1, line2, col2, severity, message, source, code}`
  - `util.describe(d)`, `util.hover_text(contents)`
  - `util.locations(result)`, which returns `{{uri, line, character, end_line, end_character}}` (0-based)
  - `util.symbols(result, uri)`, which returns `{{name, detail, kind, uri, line, character}}`
  - `util.may_restart(times, now)`, `util.problems(store)`, which returns `{{path, items}}`
  - `servers.list`, `servers.dir`, `servers.find(path)`, `servers.language_id(spec, path)`, `servers.path()`, `servers.resolve(spec)`, `servers.install_argv(spec)`, `servers.install_text(spec)`
  - `rpc.parser()`, which returns `feed(chunk) -> {body...}`, and `rpc.frame(msg)`
  - A spec is `{name, label, short, files = {pattern...}, id, ids = {[ext] = id}|nil, cmd = {exe, args...}, roots = {...}, env = {...}|nil, install = {npm = {...}} | {go = "pkg"} | {cmd = {...}, global = bool}}`.

- [ ] **Step 1: Write the failing test**

In `scripts/tests/ide.lua`, insert before the final `assert(os.execute('rm -rf ' .. tmp))`:

```lua
-- Language servers: JSON, framing, columns, URIs, roots, server table, diagnostics.
system.get_file_info = system.get_file_info or function(path)
  local f = io.open(path, 'rb'); if f then f:close(); return {type = 'file'} end
end
do
  local json = require 'plugins.lsp.json'
  local util = require 'plugins.lsp.util'
  local rpc = require 'plugins.lsp.rpc'
  local servers = require 'plugins.lsp.servers'
  local t = json.decode(json.encode({a = {1, 2}, s = 'é "q"\n', n = json.null, e = {}}))
  check(t.a[2] == 2 and t.s == 'é "q"\n' and t.n == nil and next(t.e) == nil, 'JSON round-trip')
  local feed = rpc.parser()
  local frame = rpc.frame({id = 1, result = 'héllo'})
  check(#feed(frame:sub(1, 10)) == 0, 'Partial frame waits')
  local got = feed(frame:sub(11) .. frame .. 'Content-Length: 7\r\n\r\n{"a"')
  check(#got == 2 and json.decode(got[2]).result == 'héllo', 'Split and merged frames, byte lengths')
  got = feed(':1}')
  check(#got == 1 and json.decode(got[1]).a == 1, 'Frame completed by a later chunk')
  check(#feed('X-Junk: 1\r\n\r\n' .. rpc.frame({id = 2})) == 1, 'Malformed header resyncs')
  check(util.byte_col('a😀b', 3) == 6 and util.utf16_col('a😀b', 6) == 3 and util.byte_col('é', 1) == 3, 'UTF-16 columns')
  check(util.uri_to_path(util.path_to_uri('/a b/é.ts')) == '/a b/é.ts' and util.path_to_uri('/a b') == 'file:///a%20b', 'File URIs')
  local tsx = servers.find('/x/app.tsx')
  check(tsx.name == 'typescript' and servers.language_id(tsx, '/x/app.tsx') == 'typescriptreact'
    and servers.find('/x/Dockerfile').name == 'docker' and servers.find('/x/a.txt') == nil, 'Server lookup by file name')
  local d = util.diagnostics({
    {range = {start = {line = 2, character = 1}, ['end'] = {line = 2, character = 3}}, severity = 2, message = 'w'},
    {range = {start = {line = 0, character = 2}, ['end'] = {line = 0, character = 4}}, message = 'e', source = 'ts', code = 2322},
  }, {'é = 1\n', '\n', 'xyz\n'})
  check(d[1].line1 == 1 and d[1].col1 == 4 and d[1].severity == 1 and util.describe(d[1]) == 'ts(2322): e' and d[2].line1 == 3, 'Diagnostics normalised and ordered')
  check(util.hover_text({kind = 'markdown', value = '```ts\nconst x: number\n```\n\nDocs'}) == 'const x: number\n\nDocs', 'Hover markdown to text')
  local times = {}
  check(util.may_restart(times, 0) and util.may_restart(times, 1) and util.may_restart(times, 2)
    and not util.may_restart(times, 3) and util.may_restart(times, 61), 'Crash restarts limited per minute')
  local root = tmp .. '/lsp-root'
  assert(os.execute("mkdir -p '" .. root .. "/pkg/src'"))
  io.open(root .. '/pkg/package.json', 'w'):close()
  check(util.find_root(root .. '/pkg/src/a.ts', {'package.json'}) == root .. '/pkg', 'Root marker found')
  check(util.find_root(root .. '/x.ts', {'nope.json'}, '/fallback') == '/fallback', 'Root falls back')
  local problems = util.problems({['/b'] = {{severity = 2, line1 = 1}, {severity = 1, line1 = 9}}, ['/a'] = {{severity = 1, line1 = 3}}, ['/c'] = {}})
  check(#problems == 2 and problems[1].path == '/a' and problems[2].items[1].line1 == 9, 'Problems grouped, errors first')
  local locs = util.locations({{targetUri = 'file:///a', targetSelectionRange = {start = {line = 1, character = 2}, ['end'] = {line = 1, character = 5}}}})
  local syms = util.symbols({{name = 'A', range = {}, selectionRange = {start = {line = 3, character = 0}, ['end'] = {line = 3, character = 1}},
    children = {{name = 'b', selectionRange = {start = {line = 4, character = 2}, ['end'] = {line = 4, character = 3}}}}}}, 'file:///s')
  check(locs[1].uri == 'file:///a' and locs[1].end_character == 5 and syms[2].name == 'A.b' and syms[2].line == 4 and syms[2].uri == 'file:///s', 'Locations and symbols flattened')
end
```

- [ ] **Step 2: Run it and watch it fail**

Run: `cd /Users/theo/Documents/PROJECT/lite-xl && build/src/ide-test-runner scripts/tests/ide.lua 2>&1 | tail -2`
Expected: FAIL `module 'plugins.lsp.json' not found`.

- [ ] **Step 3: Vendor json.lua**

```bash
cd /Users/theo/Documents/PROJECT/lite-xl && mkdir -p data/plugins/lsp
rm -rf /tmp/lxl-lsp && git clone -q --depth 1 https://github.com/lite-xl/lite-xl-lsp /tmp/lxl-lsp
cp /tmp/lxl-lsp/json.lua data/plugins/lsp/json.lua
grep -n 'require' data/plugins/lsp/json.lua || echo "no requires"
```

Expected: `no requires`. The file keeps rxi's MIT header.

- [ ] **Step 4: Write util.lua**

Create `data/plugins/lsp/util.lua`:

```lua
-- Pure helpers for the language server client: URIs, UTF-16 columns,
-- project roots and normalising server results. No UI, no processes.
local M = {}

function M.path_to_uri(path)
  return "file://" .. path:gsub("[^%w%-%._~/]", function(c) return string.format("%%%02X", c:byte()) end)
end

function M.uri_to_path(uri)
  local path = uri:gsub("^file://", "")
  return (path:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function char_len(byte) return byte < 0x80 and 1 or byte < 0xE0 and 2 or byte < 0xF0 and 3 or 4 end

-- LSP columns are 0-based UTF-16 code units; lite-xl columns are 1-based bytes.
function M.byte_col(text, character)
  local i, units = 1, 0
  while i <= #text and units < character do
    local n = char_len(text:byte(i))
    units, i = units + (n == 4 and 2 or 1), i + n
  end
  return i
end

function M.utf16_col(text, col)
  local i, units = 1, 0
  while i < col and i <= #text do
    local n = char_len(text:byte(i))
    units, i = units + (n == 4 and 2 or 1), i + n
  end
  return units
end

local function parent(path) return path:match("^(.+)/[^/]+$") end

-- Nearest ancestor holding a root marker; a git repository bounds the search.
function M.find_root(path, markers, fallback)
  local dir = parent(path)
  while dir do
    for _, name in ipairs(markers) do
      if system.get_file_info(dir .. "/" .. name) then return dir end
    end
    if system.get_file_info(dir .. "/.git") then return dir end
    dir = parent(dir)
  end
  return fallback or parent(path)
end

local function col(lines, line, character)
  local text = lines and lines[line]
  return text and M.byte_col(text, character) or character + 1
end

function M.diagnostics(list, lines)
  local out = {}
  for _, d in ipairs(list or {}) do
    local s, e = d.range.start, d.range["end"]
    out[#out + 1] = {line1 = s.line + 1, col1 = col(lines, s.line + 1, s.character), line2 = e.line + 1,
      col2 = col(lines, e.line + 1, e.character), severity = d.severity or 1, message = d.message or "",
      source = d.source, code = d.code and tostring(d.code)}
  end
  table.sort(out, function(a, b)
    if a.line1 ~= b.line1 then return a.line1 < b.line1 end
    if a.col1 ~= b.col1 then return a.col1 < b.col1 end
    return a.severity < b.severity
  end)
  return out
end

function M.describe(d)
  local tag = d.source and (d.source .. (d.code and "(" .. d.code .. ")" or "")) or d.code
  return tag and (tag .. ": " .. d.message) or d.message
end

-- Hover contents (string, MarkupContent, MarkedString or a list) as plain text.
function M.hover_text(contents)
  if type(contents) ~= "table" then return contents or "" end
  if contents.value then
    if contents.language then return contents.value end
    return (contents.value:gsub("```[%w_%-]*\n?", ""):gsub("\n\n\n+", "\n\n"):gsub("^%s+", ""):gsub("%s+$", ""))
  end
  local parts = {}
  for _, c in ipairs(contents) do
    local text = M.hover_text(c)
    if text ~= "" then parts[#parts + 1] = text end
  end
  return table.concat(parts, "\n\n")
end

function M.locations(result)
  if type(result) ~= "table" then return {} end
  if result.uri or result.targetUri then result = {result} end
  local out = {}
  for _, l in ipairs(result) do
    local range = l.targetSelectionRange or l.range
    if range then
      out[#out + 1] = {uri = l.targetUri or l.uri, line = range.start.line, character = range.start.character,
        end_line = range["end"].line, end_character = range["end"].character}
    end
  end
  return out
end

-- DocumentSymbol trees and SymbolInformation lists, flattened.
function M.symbols(result, uri)
  local out = {}
  local function walk(list, prefix)
    for _, s in ipairs(list) do
      local range = s.selectionRange or (s.location and s.location.range) or s.range
      out[#out + 1] = {name = prefix .. s.name, detail = s.containerName or s.detail, kind = s.kind,
        uri = s.location and s.location.uri or uri, line = range.start.line, character = range.start.character}
      if s.children then walk(s.children, prefix .. s.name .. ".") end
    end
  end
  walk(type(result) == "table" and result or {}, "")
  return out
end

-- At most 3 automatic restarts per minute; records `now` when allowed.
function M.may_restart(times, now)
  for i = #times, 1, -1 do if now - times[i] > 60 then table.remove(times, i) end end
  if #times >= 3 then return false end
  times[#times + 1] = now
  return true
end

-- Problems tab order: by path, errors first, then by line.
function M.problems(store)
  local paths = {}
  for path, list in pairs(store) do if #list > 0 then paths[#paths + 1] = path end end
  table.sort(paths)
  local out = {}
  for _, path in ipairs(paths) do
    local items = {table.unpack(store[path])}
    table.sort(items, function(a, b)
      if a.severity ~= b.severity then return a.severity < b.severity end
      return a.line1 < b.line1
    end)
    out[#out + 1] = {path = path, items = items}
  end
  return out
end

return M
```

- [ ] **Step 5: Write servers.lua**

Create `data/plugins/lsp/servers.lua`:

```lua
-- Language servers TreX knows: which files they handle, how to start and
-- install them, and which files mark their project root.
local M = {}
local HOME = os.getenv("HOME") or ""
M.dir = HOME .. "/.local/share/trex/lsp"

M.list = {
  {name = "typescript", label = "TypeScript", short = "ts", files = {"%.[cm]?[jt]sx?$"}, id = "javascript",
    ids = {ts = "typescript", mts = "typescript", cts = "typescript", tsx = "typescriptreact", jsx = "javascriptreact"},
    cmd = {"typescript-language-server", "--stdio"}, roots = {"tsconfig.json", "jsconfig.json", "package.json"},
    install = {npm = {"typescript-language-server", "typescript"}}},
  {name = "json", label = "JSON", short = "json", files = {"%.jsonc?$"}, id = "json", ids = {jsonc = "jsonc"},
    cmd = {"vscode-json-language-server", "--stdio"}, roots = {"package.json"}, install = {npm = {"vscode-langservers-extracted"}}},
  {name = "rust", label = "Rust", short = "rs", files = {"%.rs$"}, id = "rust",
    cmd = {"rust-analyzer"}, roots = {"Cargo.toml"}, install = {cmd = {"rustup", "component", "add", "rust-analyzer"}}},
  {name = "go", label = "Go", short = "go", files = {"%.go$"}, id = "go",
    cmd = {"gopls"}, roots = {"go.work", "go.mod"}, install = {go = "golang.org/x/tools/gopls@latest"}},
  {name = "zig", label = "Zig", short = "zig", files = {"%.zig$"}, id = "zig",
    cmd = {"zls"}, roots = {"build.zig"}, install = {cmd = {"brew", "install", "zls"}, global = true}},
  {name = "bash", label = "Bash", short = "sh", files = {"%.sh$", "%.bash$", "%.zsh$"}, id = "shellscript",
    cmd = {"bash-language-server", "start"}, roots = {}, install = {npm = {"bash-language-server"}}},
  {name = "yaml", label = "YAML", short = "yaml", files = {"%.ya?ml$"}, id = "yaml",
    cmd = {"yaml-language-server", "--stdio"}, roots = {}, install = {npm = {"yaml-language-server"}}},
  {name = "toml", label = "TOML", short = "toml", files = {"%.toml$"}, id = "toml",
    cmd = {"taplo", "lsp", "stdio"}, roots = {}, install = {npm = {"@taplo/cli"}}},
  {name = "docker", label = "Dockerfile", short = "docker", files = {"/[Dd]ockerfile[^/]*$", "%.dockerfile$"}, id = "dockerfile",
    cmd = {"docker-langserver", "--stdio"}, roots = {}, install = {npm = {"dockerfile-language-server-nodejs"}}},
}

function M.find(path)
  for _, spec in ipairs(M.list) do
    for _, pattern in ipairs(spec.files) do if path:find(pattern) then return spec end end
  end
end

function M.language_id(spec, path)
  return spec.ids and spec.ids[path:match("%.(%w+)$") or ""] or spec.id
end

-- Install dir first, then tool locations a GUI app's PATH lacks.
function M.path()
  return table.concat({M.dir .. "/node_modules/.bin", M.dir .. "/bin", "/opt/homebrew/bin", "/usr/local/bin",
    HOME .. "/.cargo/bin", HOME .. "/go/bin", os.getenv("PATH") or "/usr/bin:/bin"}, ":")
end

function M.resolve(spec)
  local exe = spec.cmd[1]
  if exe:find("/", 1, true) then return system.get_file_info(exe) and exe or nil end
  for dir in M.path():gmatch("[^:]+") do
    local info = system.get_file_info(dir .. "/" .. exe)
    if info and info.type ~= "dir" then return dir .. "/" .. exe end
  end
end

-- Arguments for /usr/bin/env, so installs see the same PATH as servers.
function M.install_argv(spec)
  local r, argv = spec.install, {"PATH=" .. M.path()}
  local function add(list) for _, a in ipairs(list) do argv[#argv + 1] = a end end
  if r.npm then add({"npm", "install", "--prefix", M.dir, "--no-audit", "--no-fund"}); add(r.npm)
  elseif r.go then add({"GOBIN=" .. M.dir .. "/bin", "go", "install", r.go})
  else add(r.cmd) end
  return argv
end

function M.install_text(spec)
  local argv = M.install_argv(spec)
  return table.concat(argv, " ", 2)
end

return M
```

- [ ] **Step 6: Write rpc.lua (framing only)**

Create `data/plugins/lsp/rpc.lua`:

```lua
-- JSON-RPC over a language server's stdio. `parser` and `frame` are pure;
-- `start` (Task 3) runs the process in a thread so the UI never blocks.
local json = require "plugins.lsp.json"
local M = {timeout = 10}

-- Feeds raw stdout chunks; returns the message bodies completed so far.
function M.parser()
  local buf = ""
  return function(chunk)
    buf = buf .. chunk
    local bodies = {}
    while true do
      local hs, he = buf:find("\r\n\r\n", 1, true)
      if not hs then break end
      local len = tonumber(buf:sub(1, hs - 1):match("[Cc]ontent%-[Ll]ength:%s*(%d+)"))
      if not len then buf = buf:sub(he + 1) -- junk header: drop it, resync on the next one
      elseif #buf - he < len then break
      else bodies[#bodies + 1] = buf:sub(he + 1, he + len); buf = buf:sub(he + len + 1) end
    end
    return bodies
  end
end

function M.frame(msg)
  local body = json.encode(msg)
  return "Content-Length: " .. #body .. "\r\n\r\n" .. body
end

return M
```

- [ ] **Step 7: Run it and watch it pass**

Run: `cd /Users/theo/Documents/PROJECT/lite-xl && build/src/ide-test-runner scripts/tests/ide.lua 2>&1 | tail -1`
Expected: `PASS: 91 checks against real Git repositories and a native PTY` (76 + 15).

- [ ] **Step 8: Commit**

```bash
git add data/plugins/lsp scripts/tests/ide.lua
git commit -m "feat(lsp): add JSON, framing, server table and pure helpers"
```

---

### Task 3: Server process, client and fake server

**Files:**
- Modify: `data/plugins/lsp/rpc.lua` (add the process part)
- Create: `data/plugins/lsp/client.lua`, `scripts/tests/fake-lsp.lua`
- Test: `scripts/tests/ide.lua`

**Interfaces:**
- Consumes: Task 2.
- Produces:
  - `rpc.start(argv, {cwd, env, notify(method, params), request(method, params) -> result, stderr(text), exit(code)}) -> r | nil, err`
  - `r:request(method, params, cb(result, err))`, `r:notify(method, params)`, `r:kill()`, `r.alive`
  - `client.clients` (keyed `name .. "\0" .. root`), `client.diagnostics` (`[abs path] = list`), `client.generation`
  - client `c = {key, spec, root, state = "starting"|"ready"|"crashed"|"missing", caps, docs = {[doc] = {version, uri}}, log = {line...}, crashes = {time...}, rpc}`
  - `client.get(spec, root)`, `client.open(c, doc)`, `client.change(c, doc)`, `client.save(c, doc)`, `client.close(c, doc)`
  - `client.request(c, method, params, cb)`, `client.supports(c, capability)`, `client.restart(c)`, `client.stop(c)`, `client.tick(now)`
  - A doc only needs `abs_filename` and `lines` (each line ends with `\n`).

- [ ] **Step 1: Write the fake server**

Create `scripts/tests/fake-lsp.lua`:

```lua
-- Language server for tests: fixed answers to the requests TreX sends and
-- one diagnostic per opened or changed document. Run with ide-test-runner.
package.path = (os.getenv('TREX_DATA') or './data') .. '/?.lua;' .. package.path
local json = require 'plugins.lsp.json'
local function send(msg)
  local body = json.encode(msg)
  io.write('Content-Length: ' .. #body .. '\r\n\r\n' .. body); io.flush()
end
local function range(l1, c1, l2, c2) return {start = {line = l1, character = c1}, ['end'] = {line = l2, character = c2}} end
local handlers = {
  initialize = function() return {capabilities = {textDocumentSync = 1, hoverProvider = true, definitionProvider = true,
    referencesProvider = true, documentSymbolProvider = true, workspaceSymbolProvider = true}} end,
  ['textDocument/hover'] = function() return {contents = {kind = 'markdown', value = '```ts\nconst answer: number\n```'}} end,
  ['textDocument/definition'] = function(p) return {uri = p.textDocument.uri, range = range(2, 6, 2, 13)} end,
  ['textDocument/references'] = function(p)
    return {{uri = p.textDocument.uri, range = range(0, 6, 0, 12)}, {uri = p.textDocument.uri, range = range(2, 16, 2, 22)}}
  end,
  ['textDocument/documentSymbol'] = function()
    return {{name = 'answer', kind = 13, range = range(0, 0, 0, 17), selectionRange = range(0, 6, 0, 12)}}
  end,
  ['workspace/symbol'] = function() return {{name = 'answer', kind = 13, location = {uri = 'file:///nowhere.ts', range = range(0, 6, 0, 12)}}} end,
  shutdown = function() return json.null end,
}
while true do
  local len
  repeat
    local line = io.read('l')
    if not line then os.exit(0) end
    len = tonumber(line:match('Content%-Length: (%d+)')) or len
  until line:gsub('\r$', '') == ''
  local msg = json.decode(io.read(len))
  if msg.method == 'exit' then os.exit(0) end
  if msg.method == 'initialized' then
    send({jsonrpc = '2.0', id = 'cfg', method = 'workspace/configuration', params = {items = {{section = 'fake'}}}})
  elseif msg.id == 'cfg' and msg.method == nil then
    send({jsonrpc = '2.0', method = 'window/logMessage', params = {type = 3, message = 'configured ' .. #msg.result}})
  elseif msg.method == 'textDocument/didOpen' or msg.method == 'textDocument/didChange' then
    send({jsonrpc = '2.0', method = 'textDocument/publishDiagnostics', params = {uri = msg.params.textDocument.uri,
      diagnostics = {{range = range(0, 6, 0, 12), severity = 1, source = 'fake', code = 7, message = 'answer is not a question'}}}})
  end
  if msg.id ~= nil and msg.method and handlers[msg.method] then
    send({jsonrpc = '2.0', id = msg.id, result = handlers[msg.method](msg.params)})
  end
end
```

- [ ] **Step 2: Write the failing test**

In `scripts/tests/ide.lua`, directly after the Task 2 `do ... end` block:

```lua
-- Language server client against the fake server.
do
  local client = require 'plugins.lsp.client'
  local util = require 'plugins.lsp.util'
  core.log = core.log or function() end
  local function wait(cond, what)
    local limit = system.get_time() + 15
    while not cond() do
      for _, co in ipairs(threads) do
        if coroutine.status(co) == 'suspended' then local ok, err = coroutine.resume(co); assert(ok, err) end
      end
      assert(system.get_time() < limit, what)
      system.sleep(5)
    end
  end
  local spec = {name = 'fake', label = 'Fake', short = 'fake', files = {'%.ts$'}, id = 'typescript', roots = {},
    cmd = {system.absolute_path(os.getenv('IDE_TEST_RUNNER') or 'build/src/ide-test-runner'), system.absolute_path('scripts/tests/fake-lsp.lua')},
    env = {TREX_DATA = system.absolute_path('data')}}
  local root = tmp .. '/lsp-root/pkg'
  local doc = {abs_filename = root .. '/src/a é.ts', lines = {'const answer = 42\n', '\n', 'const answer2 = answer\n'}}
  local c = client.get(spec, root)
  client.open(c, doc)
  wait(function() return c.state == 'ready' and client.diagnostics[doc.abs_filename] end, 'Fake server ready with diagnostics')
  local d = client.diagnostics[doc.abs_filename][1]
  check(d.line1 == 1 and d.col1 == 7 and d.col2 == 13 and d.message == 'answer is not a question', 'Diagnostics from server')
  wait(function() for _, l in ipairs(c.log) do if l == 'configured 1' then return true end end end, 'Server request not answered')
  check(true, 'Server request answered')
  local hover
  client.request(c, 'textDocument/hover', {textDocument = {uri = util.path_to_uri(doc.abs_filename)}, position = {line = 0, character = 7}},
    function(r) hover = r end)
  wait(function() return hover end, 'Hover not answered')
  check(util.hover_text(hover.contents) == 'const answer: number', 'Hover result')
  local old = c.rpc
  client.diagnostics[doc.abs_filename] = nil
  old:kill()
  wait(function() return c.state == 'ready' and c.rpc ~= old and client.diagnostics[doc.abs_filename] end, 'Not restarted after crash')
  check(#c.crashes == 1, 'Crash restart reopens documents')
  client.close(c, doc); client.stop(c)
  wait(function() return c.rpc == nil end, 'Server not shut down')
  check(client.clients[c.key] == nil, 'Stopped client forgotten')
end
```

- [ ] **Step 3: Run it and watch it fail**

Run: `cd /Users/theo/Documents/PROJECT/lite-xl && build/src/ide-test-runner scripts/tests/ide.lua 2>&1 | tail -2`
Expected: FAIL `module 'plugins.lsp.client' not found`.

- [ ] **Step 4: Add the process part to rpc.lua**

In `data/plugins/lsp/rpc.lua`, add `local core = require "core"` and `local process = require "core.process"` under the json require. Then insert before `return M`:

```lua
local RPC = {}
RPC.__index = RPC

local function call(fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok then core.error("LSP: %s", tostring(err)) end
end

function RPC:send(msg) self.out[#self.out + 1] = M.frame(msg) end
function RPC:notify(method, params) self:send({jsonrpc = "2.0", method = method, params = params}) end
function RPC:request(method, params, cb)
  if not self.alive then return cb(nil, "server not running") end
  self.next_id = self.next_id + 1
  self.pending[self.next_id] = {cb = cb, method = method, deadline = system.get_time() + M.timeout}
  self:send({jsonrpc = "2.0", id = self.next_id, method = method, params = params})
end
function RPC:kill() if self.alive then self.proc:kill() end end

function RPC:dispatch(body)
  local msg = json.decode(body)
  if type(msg) ~= "table" then return call(self.on.stderr, "unreadable message: " .. body:sub(1, 200) .. "\n") end
  if msg.method and msg.id ~= nil then
    local ok, result = pcall(self.on.request, msg.method, msg.params)
    self:send({jsonrpc = "2.0", id = msg.id, result = ok and result ~= nil and result or json.null})
  elseif msg.method then
    call(self.on.notify, msg.method, msg.params)
  else
    local p = self.pending[msg.id]
    if p then self.pending[msg.id] = nil; call(p.cb, msg.result, msg.error and msg.error.message) end
  end
end

-- Writes queued frames as far as the pipe accepts them.
function RPC:flush()
  while #self.out > 0 do
    local data = self.out[1]
    local n = self.proc:write(data)
    if not n or n == 0 then return end
    if n < #data then self.out[1] = data:sub(n + 1); return end
    table.remove(self.out, 1)
  end
end

function RPC:expire(now)
  local late = {}
  for id, p in pairs(self.pending) do if now > p.deadline then late[#late + 1] = id end end
  for _, id in ipairs(late) do
    local p = self.pending[id]; self.pending[id] = nil
    call(p.cb, nil, p.method .. " timed out")
  end
end

function M.start(argv, on)
  local ok, proc = pcall(process.start, argv, {cwd = on.cwd, env = on.env})
  if not ok or not proc or not proc.process then return nil, not ok and tostring(proc) or "cannot start " .. argv[1] end
  local self = setmetatable({proc = proc, on = on, out = {}, pending = {}, next_id = 0, alive = true}, RPC)
  local feed = M.parser()
  core.add_thread(function()
    while true do
      self:flush()
      local busy = false
      local out = proc:read(process.STREAM_STDOUT, 65536)
      if out and #out > 0 then busy = true; for _, body in ipairs(feed(out)) do self:dispatch(body) end end
      local err = proc:read(process.STREAM_STDERR, 65536)
      if err and #err > 0 then busy = true; call(self.on.stderr, err) end
      self:expire(system.get_time())
      if not busy and not proc:running() then break end
      coroutine.yield(busy and 0 or 0.02)
    end
    self.alive = false
    self:expire(math.huge)
    call(self.on.exit, proc:returncode())
  end)
  return self
end
```

Note: `self:expire(math.huge)` fails every request still pending once the process has exited.

- [ ] **Step 5: Write client.lua**

Create `data/plugins/lsp/client.lua`:

```lua
-- One language server per (server, project root): starts it, keeps open
-- docs in sync, stores diagnostics and restarts it after a crash. No drawing.
local core = require "core"
local json = require "plugins.lsp.json"
local rpc = require "plugins.lsp.rpc"
local servers = require "plugins.lsp.servers"
local util = require "plugins.lsp.util"
local M = {clients = {}, diagnostics = {}, generation = 0, idle_timeout = 300}

local function changed() M.generation = M.generation + 1; core.redraw = true end

local function log(c, text)
  for line in text:gmatch("[^\r\n]+") do
    c.log[#c.log + 1] = line
    if #c.log > 500 then table.remove(c.log, 1) end
  end
end

local function send_open(c, doc)
  local entry = c.docs[doc]
  c.rpc:notify("textDocument/didOpen", {textDocument = {uri = entry.uri,
    languageId = servers.language_id(c.spec, doc.abs_filename), version = entry.version, text = table.concat(doc.lines)}})
end

local function lines_for(path)
  for _, c in pairs(M.clients) do
    for doc in pairs(c.docs) do if doc.abs_filename == path then return doc.lines end end
  end
end

local function on_notify(c, method, params)
  if method == "textDocument/publishDiagnostics" then
    local path = util.uri_to_path(params.uri)
    M.diagnostics[path] = util.diagnostics(params.diagnostics, lines_for(path))
    changed()
  elseif method == "window/showMessage" or method == "window/logMessage" then
    log(c, params.message or "")
    if method == "window/showMessage" and (params.type or 4) <= 2 then core.log("%s: %s", c.spec.label, params.message) end
  end
end

local function on_request(c, method, params)
  if method == "workspace/configuration" then
    local out = {}
    for i = 1, #(params and params.items or {}) do out[i] = json.null end
    return out
  elseif method == "workspace/workspaceFolders" then
    return {{uri = util.path_to_uri(c.root), name = c.root:match("[^/]+$") or c.root}}
  end
end

local start

local function on_exit(c, r, code)
  if c.rpc ~= r then return end
  c.rpc = nil
  if c.stopping then return end
  log(c, "server exited with code " .. tostring(code))
  c.state = "crashed"; changed()
  if util.may_restart(c.crashes, system.get_time()) then
    core.add_thread(function() coroutine.yield(1); if c.state == "crashed" and not c.stopping then start(c) end end)
  end
end

function start(c)
  local exe = servers.resolve(c.spec)
  if not exe then c.state = "missing"; changed(); return end
  local argv = {exe, table.unpack(c.spec.cmd, 2)}
  local env = {PATH = servers.path()}
  for k, v in pairs(c.spec.env or {}) do env[k] = v end
  c.state, c.caps = "starting", nil
  local r
  r = rpc.start(argv, {cwd = c.root, env = env,
    notify = function(m, p) on_notify(c, m, p) end, request = function(m, p) return on_request(c, m, p) end,
    stderr = function(text) log(c, text) end, exit = function(code) on_exit(c, r, code) end})
  if not r then log(c, "cannot start " .. exe); c.state = "crashed"; changed(); return end
  c.rpc = r
  changed()
  local root_uri = util.path_to_uri(c.root)
  r:request("initialize", {processId = json.null, rootUri = root_uri, rootPath = c.root, clientInfo = {name = "TreX"},
    workspaceFolders = {{uri = root_uri, name = c.root:match("[^/]+$") or c.root}},
    capabilities = {
      textDocument = {synchronization = {didSave = true}, publishDiagnostics = {relatedInformation = false},
        hover = {contentFormat = {"markdown", "plaintext"}}, definition = {linkSupport = true},
        references = {dynamicRegistration = false}, documentSymbol = {hierarchicalDocumentSymbolSupport = true}},
      workspace = {workspaceFolders = true, configuration = true, symbol = {dynamicRegistration = false}},
    }}, function(result, err)
      if c.rpc ~= r then return end
      if not result then log(c, "initialize failed: " .. tostring(err)); r:kill(); return end
      c.caps, c.state = result.capabilities or {}, "ready"
      r:notify("initialized", {})
      for doc in pairs(c.docs) do send_open(c, doc) end
      changed()
    end)
end

function M.get(spec, root)
  local key = spec.name .. "\0" .. root
  local c = M.clients[key]
  if not c then
    c = {key = key, spec = spec, root = root, docs = {}, log = {}, crashes = {}, state = "missing"}
    M.clients[key] = c
    start(c)
  end
  return c
end

function M.open(c, doc)
  if c.docs[doc] then return M.change(c, doc) end
  c.docs[doc], c.idle_since = {version = 0, uri = util.path_to_uri(doc.abs_filename)}, nil
  if c.state == "ready" then send_open(c, doc) end
end

function M.change(c, doc)
  local entry = c.docs[doc]
  if not entry then return end
  entry.version = entry.version + 1
  if c.state ~= "ready" then return end
  c.rpc:notify("textDocument/didChange", {textDocument = {uri = entry.uri, version = entry.version},
    contentChanges = {{text = table.concat(doc.lines)}}})
end

function M.save(c, doc)
  if c.state == "ready" and c.docs[doc] then c.rpc:notify("textDocument/didSave", {textDocument = {uri = c.docs[doc].uri}}) end
end

function M.close(c, doc)
  local entry = c.docs[doc]
  if not entry then return end
  if c.state == "ready" then c.rpc:notify("textDocument/didClose", {textDocument = {uri = entry.uri}}) end
  c.docs[doc] = nil
  if next(c.docs) == nil then c.idle_since = system.get_time() end
end

function M.request(c, method, params, cb)
  if c.state ~= "ready" then return cb(nil, c.spec.label .. " language server is not ready") end
  c.rpc:request(method, params, cb)
end

function M.supports(c, capability) return c.state == "ready" and c.caps[capability] ~= nil and c.caps[capability] ~= false end

function M.restart(c)
  local old = c.rpc
  c.rpc, c.crashes, c.stopping = nil, {}, nil
  if old then old:kill() end
  start(c)
end

function M.stop(c)
  c.stopping = true
  M.clients[c.key] = nil
  local r = c.rpc
  if r then
    r:request("shutdown", nil, function()
      r:notify("exit")
      core.add_thread(function() coroutine.yield(2); r:kill() end)
    end)
  end
end

function M.tick(now)
  for _, c in pairs(M.clients) do
    if c.idle_since and now - c.idle_since > M.idle_timeout then M.stop(c) end
  end
end

return M
```

`restart` nils `c.rpc` before killing, so `on_exit`'s `c.rpc ~= r` guard ignores the old process's exit. `stop` keeps `c.rpc` until the process actually exits, and `on_exit` then clears it.

- [ ] **Step 6: Run it and watch it pass**

Run: `cd /Users/theo/Documents/PROJECT/lite-xl && build/src/ide-test-runner scripts/tests/ide.lua 2>&1 | tail -1`
Expected: `PASS: 96 checks ...` (91 + 5).

- [ ] **Step 7: Commit**

```bash
git add data/plugins/lsp/rpc.lua data/plugins/lsp/client.lua scripts/tests/fake-lsp.lua scripts/tests/ide.lua
git commit -m "feat(lsp): run language servers and keep documents in sync"
```

---

### Task 4: Editor glue: sync, diagnostics drawing, Problems, status, install

**Files:**
- Create: `data/plugins/lsp.lua`, `data/plugins/lsp/views.lua`
- Modify: `scripts/test-ide.sh` (pass `TREX_SOURCE` and `TREX_RUNNER`)
- Test: `scripts/tests/ui-runtime.lua`

**Interfaces:**
- Consumes: Tasks 2-3.
- Produces (Task 5 uses these):
  - `lsp.client`, `lsp.servers`, `lsp.views`, `lsp.line_diagnostics(doc, line) -> {d...}`
  - `lsp.install(spec)`, `lsp.flush(doc)`, `lsp.project_root(path)`, `lsp.rel(path)`
  - `lsp.jump(target)`, where `target = {path, line (1-based), col (byte) | character (UTF-16), end_character|nil}`
  - `lsp.hover_state()`, which returns the current hover table `{view, x, y, t, asked, text}`
  - `lsp.set_hover(h)`
  - `lsp.draw_tooltip(dv, text, x, y)`
  - `views.List(name, build, live|nil, on_pick)`; rows are `{target|nil, indent|nil, mark|nil, {color, text}...}`
  - `views.show(list) -> list`
  - `doc.lsp`, the client attached to a doc

- [ ] **Step 1: Pass the source and runner paths to the UI test**

In `scripts/test-ide.sh`, replace:

```sh
    SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software LITE_PREFIX="$test_dir" \
```

with:

```sh
    TREX_SOURCE="$project_dir" TREX_RUNNER="$(cd "$build_dir" && pwd)/src/ide-test-runner" \
    SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software LITE_PREFIX="$test_dir" \
```

- [ ] **Step 2: Write the failing test**

In `scripts/tests/ui-runtime.lua`, insert before `    for _, item in ipairs(core.log_items) do`. This uses the `write` and `wait` helpers from the review block; they are in scope there.

```lua
    -- Language servers, using the fake server for .ts files.
    local lsp = require 'plugins.lsp'
    local src = assert(os.getenv('TREX_SOURCE'), 'TREX_SOURCE not set')
    table.insert(lsp.servers.list, 1, {name = 'fake', label = 'Fake', short = 'fake', files = {'%.ts$'}, id = 'typescript', roots = {},
      cmd = {assert(os.getenv('TREX_RUNNER'), 'TREX_RUNNER not set'), src .. '/scripts/tests/fake-lsp.lua'}, env = {TREX_DATA = src .. '/data'}})
    local ts = workspace .. '/app.ts'
    write(ts, 'const answer = 42\n\nconst answer2 = answer\n')
    local tdv = core.root_view:open_doc(core.open_doc(ts))
    wait(function() return tdv.doc.lsp and tdv.doc.lsp.state == 'ready' and #lsp.line_diagnostics(tdv.doc, 1) == 1 end, 'Diagnostics not shown', 15)
    local version = tdv.doc.lsp.docs[tdv.doc].version
    tdv.doc:insert(2, 1, '-- typed\n')
    wait(function() return tdv.doc.lsp.docs[tdv.doc].version == version + 1 end, 'Edit not synced')
    tdv.doc:remove(2, 1, 3, 1)
    coroutine.yield(0.5)
    command.perform('lsp:problems')
    local pv = core.active_view
    assert(pv.name == 'Problems' and #pv.rows == 2 and pv.rows[2].target.line == 1, 'Problems tab missing the diagnostic')
    core.set_active_view(tdv)
    local c = tdv.doc.lsp
    local old = c.rpc
    old:kill()
    wait(function() return c.state == 'ready' and c.rpc ~= old and #lsp.line_diagnostics(tdv.doc, 1) == 1 end, 'Server not restarted after crash', 15)
```

- [ ] **Step 3: Run it and watch it fail**

Run: `cd /Users/theo/Documents/PROJECT/lite-xl && PATH=/tmp/lite-xl-build-tools/bin:$PATH ./scripts/test-ide.sh build 2>&1 | tail -1`
Expected: FAIL `module 'plugins.lsp' not found` (in the runtime error line).

- [ ] **Step 4: Write views.lua**

Create `data/plugins/lsp/views.lua`:

```lua
-- Problems and References tabs: file header rows and location rows.
local core = require "core"
local common = require "core.common"
local style = require "core.style"
local View = require "core.view"
local M = {}

local List = View:extend()
M.List = List

-- build() -> rows; live() -> a value that changes when rows must be rebuilt.
function List:new(name, build, live, on_pick)
  List.super.new(self)
  self.name, self.build, self.live, self.on_pick, self.scrollable = name, build, live, on_pick, true
  self.gen, self.rows = live and live(), build()
end
function List:get_name() return self.name end

local function lh() return style.font:get_height() + style.padding.y end
function List:get_scrollable_size() return #self.rows * lh() + style.padding.y end

function List:update()
  if self.live and self.live() ~= self.gen then self.gen, self.rows = self.live(), self.build() end
  List.super.update(self)
end

function List:row_at(y)
  local _, oy = self:get_content_offset()
  local i = math.floor((y - oy - style.padding.y / 2) / lh()) + 1
  return self.rows[i] and i
end

function List:draw()
  self:draw_background(style.background)
  local h, mark = lh(), math.floor(8 * SCALE)
  local ox, oy = self:get_content_offset()
  core.push_clip_rect(self.position.x, self.position.y, self.size.x, self.size.y)
  for i = math.max(1, (self:row_at(self.position.y) or 1)), #self.rows do
    local y = oy + style.padding.y / 2 + (i - 1) * h
    if y > self.position.y + self.size.y then break end
    local row, x = self.rows[i], ox + style.padding.x + (self.rows[i].indent or 0)
    if i == self.hovered_row and row.target then renderer.draw_rect(self.position.x, y, self.size.x, h, style.line_highlight) end
    if row.mark then
      renderer.draw_rect(x, y + (h - mark) / 2, mark, mark, row.mark)
      x = x + mark + style.padding.x / 2
    end
    for _, part in ipairs(row) do x = common.draw_text(style.font, part[1], part[2], nil, x, y, 0, h) + style.padding.x / 2 end
  end
  core.pop_clip_rect()
  self:draw_scrollbar()
end

function List:on_mouse_moved(x, y, ...)
  List.super.on_mouse_moved(self, x, y, ...)
  self.hovered_row = self:row_at(y)
end

function List:on_mouse_pressed(button, x, y, clicks)
  if List.super.on_mouse_pressed(self, button, x, y, clicks) then return true end
  local i = self:row_at(y)
  if i and self.rows[i].target then self.on_pick(self.rows[i].target) end
  return true
end

-- One tab per name: an open one takes the new content and is focused.
function M.show(list)
  for _, v in ipairs(core.root_view.root_node:get_children()) do
    if v:is(List) and v.name == list.name then
      v.build, v.live, v.on_pick, v.gen, v.rows = list.build, list.live, list.on_pick, list.gen, list.rows
      core.root_view.root_node:get_node_for_view(v):set_active_view(v)
      return v
    end
  end
  core.root_view:get_active_node_default():add_view(list)
  return list
end

return M
```

- [ ] **Step 5: Write lsp.lua**

Create `data/plugins/lsp.lua`:

```lua
-- mod-version:4
-- Language servers: errors and warnings (squiggles, gutter, Problems tab,
-- status bar) and, below, navigation. Servers come from plugins.lsp.servers
-- and start per project root when a matching file opens.
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local Doc = require "core.doc"
local DocView = require "core.docview"
local git = require "plugins.scm.git"
local client = require "plugins.lsp.client"
local servers = require "plugins.lsp.servers"
local util = require "plugins.lsp.util"
local views = require "plugins.lsp.views"

local M = {client = client, servers = servers, views = views}
local pending, offered, installing = {}, {}, {}

function M.project_root(path)
  for _, p in ipairs(core.projects) do
    if common.path_belongs_to(path, p.path) then return p.path end
  end
end

function M.rel(path)
  local root = M.project_root(path)
  return root and path:sub(#root + 2) or common.home_encode(path)
end

function M.install(spec)
  installing[spec.name] = true; core.redraw = true
  core.add_thread(function()
    common.mkdirp(servers.dir)
    local out, err = git.exec(servers.dir, "/usr/bin/env", servers.install_argv(spec), nil, 900)
    installing[spec.name] = nil
    if not out then
      core.error("Installing the %s language server failed: %s", spec.label, (err or "unknown error"):sub(-400))
      return
    end
    core.log("Installed the %s language server", spec.label)
    for _, c in pairs(client.clients) do if c.spec == spec then client.restart(c) end end
  end)
end

local function offer_install(spec)
  if offered[spec.name] or installing[spec.name] or not spec.install then return end
  offered[spec.name] = true
  core.nag_view:show("Language server missing",
    spec.label .. " language server not found. Install it with: " .. servers.install_text(spec)
      .. (spec.install.global and " (a global Homebrew install)" or ""),
    {{text = "Install", default_yes = true}, {text = "Not now", default_no = true}},
    function(item) if item.text == "Install" then M.install(spec) end end)
end

local function attach(doc)
  local path = doc.abs_filename
  local spec = path and servers.find(path)
  if not spec then return end
  local c = client.get(spec, util.find_root(path, spec.roots, M.project_root(path)))
  if doc.lsp and doc.lsp ~= c then client.close(doc.lsp, doc) end
  doc.lsp = c
  client.open(c, doc)
  if c.state == "missing" then offer_install(spec) end
end

function M.flush(doc)
  if pending[doc] and doc.lsp then pending[doc] = nil; client.change(doc.lsp, doc) end
end

local doc_load, doc_save, doc_close, doc_change = Doc.load, Doc.save, Doc.on_close, Doc.on_text_change
function Doc:load(...)
  local result = doc_load(self, ...)
  attach(self)
  return result
end
function Doc:save(...)
  local result = doc_save(self, ...)
  pending[self] = nil
  attach(self) -- save-as can change the server or the root
  if self.lsp then client.save(self.lsp, self) end
  return result
end
function Doc:on_close(...)
  if self.lsp then client.close(self.lsp, self); self.lsp = nil end
  pending[self] = nil
  return doc_close(self, ...)
end
function Doc:on_text_change(...)
  if self.lsp then pending[self] = system.get_time() end
  return doc_change(self, ...)
end

core.add_thread(function()
  while true do
    local now = system.get_time()
    for doc, t in pairs(pending) do if now - t >= 0.3 then M.flush(doc) end end
    client.tick(now)
    coroutine.yield(0.1)
  end
end)

-- Diagnostics of `doc` touching `line`, indexed once per store change.
local index = setmetatable({}, {__mode = "k"})
function M.line_diagnostics(doc, line)
  local cached = index[doc]
  if not cached or cached.gen ~= client.generation or cached.path ~= doc.abs_filename then
    cached = {gen = client.generation, path = doc.abs_filename, lines = {}}
    for _, d in ipairs(doc.abs_filename and client.diagnostics[doc.abs_filename] or {}) do
      for l = d.line1, math.min(d.line2, d.line1 + 200) do
        cached.lines[l] = cached.lines[l] or {}
        table.insert(cached.lines[l], d)
      end
    end
    index[doc] = cached
  end
  return cached.lines[line] or {}
end

local function severity_color(s) return s == 1 and style.error or s == 2 and style.warn or style.dim end

local function squiggle(x1, x2, y, color)
  local s = math.max(1, math.floor(SCALE))
  local i = 0
  for x = x1, x2 - s, 2 * s do
    renderer.draw_rect(x, y + (i % 2) * s, 2 * s, s, color)
    i = i + 1
  end
end

local draw_line_text, draw_line_gutter = DocView.draw_line_text, DocView.draw_line_gutter
function DocView:draw_line_text(line, x, y)
  local lh = draw_line_text(self, line, x, y)
  local text = self.doc.lines[line]
  for _, d in ipairs(M.line_diagnostics(self.doc, line)) do
    local x1 = x + self:get_col_x_offset(line, d.line1 == line and d.col1 or 1)
    local x2 = x + self:get_col_x_offset(line, d.line2 == line and d.col2 or #text)
    squiggle(x1, math.max(x2, x1 + 6 * SCALE), y + lh - 3 * math.max(1, math.floor(SCALE)), severity_color(d.severity))
  end
  return lh
end
function DocView:draw_line_gutter(line, x, y, width)
  local lh = draw_line_gutter(self, line, x, y, width)
  local worst
  for _, d in ipairs(M.line_diagnostics(self.doc, line)) do worst = math.min(worst or 4, d.severity) end
  if worst then
    local s = math.floor(6 * SCALE)
    renderer.draw_rect(x + (style.padding.x - s) / 2, y + (self:get_line_height() - s) / 2, s, s, severity_color(worst))
  end
  return lh
end

-- Hover tooltips: diagnostics under the mouse plus the server's hover text.
local hover = {}
function M.hover_state() return hover end
function M.set_hover(h) hover = h; core.redraw = true end

local function diagnostics_at(doc, line, col)
  local out = {}
  for _, d in ipairs(M.line_diagnostics(doc, line)) do
    if (line > d.line1 or col >= d.col1) and (line < d.line2 or col <= math.max(d.col2, d.col1 + 1)) then
      out[#out + 1] = util.describe(d)
    end
  end
  return out
end

function M.position(doc, line, col)
  return {textDocument = {uri = util.path_to_uri(doc.abs_filename)},
    position = {line = line - 1, character = util.utf16_col(doc.lines[line] or "", col)}}
end

function M.hover(doc, line, col, cb)
  local parts = diagnostics_at(doc, line, col)
  if not (doc.lsp and client.supports(doc.lsp, "hoverProvider")) then return cb(table.concat(parts, "\n")) end
  M.flush(doc)
  client.request(doc.lsp, "textDocument/hover", M.position(doc, line, col), function(result)
    local text = result and util.hover_text(result.contents) or ""
    if text ~= "" then parts[#parts + 1] = text end
    cb(table.concat(parts, "\n\n"))
  end)
end

local function wrap(text, width)
  local out = {}
  for para in (text .. "\n"):gmatch("([^\n]*)\n") do
    while #para > width do
      local cut = para:sub(1, width):match(".*()%s")
      if not cut or cut < width / 3 then cut = width + 1 end
      out[#out + 1] = para:sub(1, cut - 1)
      para = para:sub(cut):gsub("^%s+", "")
    end
    out[#out + 1] = para
  end
  return out
end

function M.draw_tooltip(dv, text, x, y)
  local font, pad = dv:get_font(), style.padding.x / 2
  local lines = wrap(text, 90)
  if #lines > 20 then lines = {table.unpack(lines, 1, 20)}; lines[20] = "..." end
  local lh, w = font:get_height(), 0
  for _, l in ipairs(lines) do w = math.max(w, font:get_width(l)) end
  w = w + pad * 2
  local h = #lines * lh + pad * 2
  x = math.max(dv.position.x, math.min(x, dv.position.x + dv.size.x - w))
  if y + h > dv.position.y + dv.size.y then y = y - h - dv:get_line_height() * 2 end
  renderer.draw_rect(x - 1, y - 1, w + 2, h + 2, style.divider)
  renderer.draw_rect(x, y, w, h, style.background3)
  for i, l in ipairs(lines) do renderer.draw_text(font, l, x + pad, y + pad + (i - 1) * lh, style.text) end
end

local dv_moved, dv_released, dv_update, dv_overlay = DocView.on_mouse_moved, DocView.on_mouse_released, DocView.update, DocView.draw_overlay
function DocView:on_mouse_moved(x, y, ...)
  if hover.view ~= self or hover.x ~= x or hover.y ~= y then
    if hover.text then core.redraw = true end
    hover = {view = self, x = x, y = y, t = system.get_time()}
  end
  return dv_moved(self, x, y, ...)
end
function DocView:on_mouse_released(...)
  if hover.text then hover = {}; core.redraw = true end
  return dv_released(self, ...)
end
function DocView:update(...)
  local h = hover
  if h.view == self and not h.asked and self.doc.lsp and system.get_time() - h.t > 0.5 then
    h.asked = true
    if h.x > self.position.x + self:get_gutter_width() and h.y >= self.position.y and h.y < self.position.y + self.size.y then
      local line, col = self:resolve_screen_position(h.x, h.y)
      local text = self.doc.lines[line] or ""
      if col < #text and (text:sub(col, col):match("%S") or #diagnostics_at(self.doc, line, col) > 0) then
        M.hover(self.doc, line, col, function(t)
          if hover == h and t ~= "" then h.text = t; core.redraw = true end
        end)
      end
    end
  end
  return dv_update(self, ...)
end
function DocView:draw_overlay(...)
  dv_overlay(self, ...)
  if hover.view == self and hover.text then
    M.draw_tooltip(self, hover.text, hover.x, hover.y + self:get_line_height())
  end
end

-- Opens a location; `col` is a byte column, `character` an LSP UTF-16 one.
function M.jump(t)
  local ok, doc = pcall(core.open_doc, t.path)
  if not ok then core.error("Cannot open %s", t.path); return end
  local dv = core.root_view:open_doc(doc)
  local line = common.clamp(t.line, 1, #doc.lines)
  local text = doc.lines[line]
  local c1 = t.col or util.byte_col(text, t.character or 0)
  local c2 = t.end_character and util.byte_col(text, t.end_character) or c1
  doc:set_selection(line, c2, line, c1)
  dv:scroll_to_line(line, true, true)
  return dv
end

local function problem_rows()
  local rows = {}
  for _, group in ipairs(util.problems(client.diagnostics)) do
    rows[#rows + 1] = {{style.accent, M.rel(group.path)}, {style.dim, tostring(#group.items)}}
    for _, d in ipairs(group.items) do
      rows[#rows + 1] = {target = {path = group.path, line = d.line1, col = d.col1}, indent = style.padding.x,
        mark = severity_color(d.severity), {style.dim, d.line1 .. ":" .. d.col1}, {style.text, util.describe(d)}}
    end
  end
  if #rows == 0 then rows[1] = {{style.dim, "No problems"}} end
  return rows
end

function M.problems()
  return views.show(views.List("Problems", problem_rows, function() return client.generation end, M.jump))
end

local function active_doc()
  local v = core.active_view
  return v and v:is(DocView) and v.doc.lsp and v.doc or nil
end

local counts_item = core.status_view:add_item({
  name = "lsp:diagnostics", alignment = core.status_view.Item.LEFT, command = "lsp:problems",
  predicate = function() return active_doc() ~= nil end, get_item = function() return {} end,
})
counts_item.on_draw = function(x, y, h, hovered, calc_only)
  local errors, warnings = 0, 0
  for _, d in ipairs(client.diagnostics[active_doc().abs_filename] or {}) do
    if d.severity == 1 then errors = errors + 1 elseif d.severity == 2 then warnings = warnings + 1 end
  end
  local s, gap = math.floor(8 * SCALE), style.padding.x / 2
  local parts = {{style.error, tostring(errors)}, {style.warn, tostring(warnings)}}
  local width = 0
  for _, p in ipairs(parts) do width = width + s + gap + style.font:get_width(p[2]) + style.padding.x end
  if calc_only then return width end
  for _, p in ipairs(parts) do
    renderer.draw_rect(x, y + (h - s) / 2, s, s, p[1])
    x = common.draw_text(style.font, hovered and style.accent or style.text, p[2], nil, x + s + gap, y, 0, h) + style.padding.x
  end
  return width
end

core.status_view:add_item({
  name = "lsp:server", alignment = core.status_view.Item.RIGHT, command = "lsp:server-action",
  predicate = function() return active_doc() ~= nil end,
  get_item = function()
    local c = active_doc().lsp
    local s = c.spec.short
    if installing[c.spec.name] then return {style.dim, s .. " installing..."} end
    if c.state == "ready" then return {style.text, s} end
    if c.state == "starting" then return {style.dim, s .. "..."} end
    if c.state == "missing" then return {style.dim, s .. " not installed"} end
    return {style.error, s .. " crashed"}
  end,
})

local function show_log(c)
  local doc = core.open_doc()
  doc:insert(1, 1, (#c.log > 0 and table.concat(c.log, "\n") or "(empty)") .. "\n")
  doc:clean()
  core.root_view:open_doc(doc)
end

command.add(nil, {
  ["lsp:problems"] = function() M.problems() end,
})
command.add(function() local d = active_doc(); return d ~= nil, d end, {
  ["lsp:restart"] = function(doc) client.restart(doc.lsp) end,
  ["lsp:show-log"] = function(doc) show_log(doc.lsp) end,
  ["lsp:server-action"] = function(doc)
    local c = doc.lsp
    if c.state == "crashed" then client.restart(c)
    elseif c.state == "missing" then offered[c.spec.name] = nil; offer_install(c.spec)
    else show_log(c) end
  end,
})
keymap.add({[PLATFORM == "Mac OS X" and "cmd+shift+m" or "ctrl+shift+m"] = "lsp:problems"})

return M
```

- [ ] **Step 6: Run the tests and watch them pass**

Run: `cd /Users/theo/Documents/PROJECT/lite-xl && build/src/ide-test-runner scripts/tests/ide.lua | tail -1 && PATH=/tmp/lite-xl-build-tools/bin:$PATH ./scripts/test-ide.sh build 2>&1 | tail -1`
Expected: `PASS: 96 checks ...` and `PASS: nested workspace repositories, ...`.

- [ ] **Step 7: Commit**

```bash
git add data/plugins/lsp.lua data/plugins/lsp/views.lua scripts/test-ide.sh scripts/tests/ui-runtime.lua
git commit -m "feat(lsp): show errors and warnings with a Problems tab and server status"
```

---

### Task 5: Navigation: definition, references, hover, symbols, next problem

**Files:**
- Modify: `data/plugins/lsp.lua` (insert before `return M`)
- Test: `scripts/tests/ui-runtime.lua`

**Interfaces:**
- Consumes: Task 4 (`M.jump`, `M.flush`, `M.position`, `M.rel`, `M.hover`, `M.set_hover`, `views`).
- Produces:
  - `lsp.definition(doc, line, col)`, `lsp.references(doc, line, col)`
  - `lsp.document_symbols(doc)`, `lsp.workspace_symbols()`
  - `lsp.next_problem(dv, dir)` (`dir` is `1` or `-1`)
  - Commands: `lsp:goto-definition`, `lsp:goto-definition-at-mouse`, `lsp:find-references`, `lsp:hover`, `lsp:document-symbols`, `lsp:workspace-symbols`, `lsp:next-problem`, `lsp:previous-problem`

- [ ] **Step 1: Write the failing test**

In `scripts/tests/ui-runtime.lua`, append after the Task 4 lines (after the `'Server not restarted after crash'` wait):

```lua
    tdv.doc:set_selection(1, 8)
    lsp.definition(tdv.doc, 1, 8)
    wait(function() local l, c1 = tdv.doc:get_selection(true); return core.active_view == tdv and l == 3 and c1 == 7 end, 'Definition not opened')
    lsp.references(tdv.doc, 1, 8)
    wait(function() return core.active_view.name == 'References' and #core.active_view.rows == 3 end, 'References tab missing')
    assert(core.active_view.rows[3].target.line == 3, 'Reference row target wrong')
    core.set_active_view(tdv)
    local text
    lsp.hover(tdv.doc, 1, 8, function(t) text = t end)
    wait(function() return text end, 'Hover not answered')
    assert(text:find('answer is not a question', 1, true) and text:find('const answer: number', 1, true), 'Hover text: ' .. text)
    tdv.doc:set_selection(3, 1)
    lsp.next_problem(tdv, 1)
    assert(select(1, tdv.doc:get_selection()) == 1 and lsp.hover_state().text:find('fake(7)', 1, true), 'Next problem did not wrap to line 1')
    for _, name in ipairs({'lsp:goto-definition', 'lsp:goto-definition-at-mouse', 'lsp:find-references', 'lsp:hover',
      'lsp:document-symbols', 'lsp:workspace-symbols', 'lsp:next-problem', 'lsp:previous-problem'}) do
      assert(command.map[name], name .. ' missing')
    end
```

- [ ] **Step 2: Run it and watch it fail**

Run: `cd /Users/theo/Documents/PROJECT/lite-xl && PATH=/tmp/lite-xl-build-tools/bin:$PATH ./scripts/test-ide.sh build 2>&1 | tail -1`
Expected: FAIL `attempt to call a nil value (field 'definition')`.

- [ ] **Step 3: Write the implementation**

In `data/plugins/lsp.lua`, insert before `return M`:

```lua
-- Navigation.
local function target(loc)
  return {path = util.uri_to_path(loc.uri), line = loc.line + 1, character = loc.character,
    end_character = loc.end_line == loc.line and loc.end_character or nil}
end

local function pick(title, items, fn)
  core.command_view:enter(title, {
    submit = function(_, item) if item then fn(item) end end,
    suggest = function(text)
      local out = {}
      for _, item in ipairs(items) do if item.text:lower():find(text:lower(), 1, true) then out[#out + 1] = item end end
      return out
    end,
  })
end

local function request(doc, method, params, fn)
  if not doc.lsp then return end
  M.flush(doc)
  client.request(doc.lsp, method, params, function(result, err)
    if err then core.log("%s: %s", doc.lsp.spec.label, err) else fn(result) end
  end)
end

function M.definition(doc, line, col)
  request(doc, "textDocument/definition", M.position(doc, line, col), function(result)
    local locs = util.locations(result)
    if #locs == 0 then return core.log("No definition found") end
    if #locs == 1 then return M.jump(target(locs[1])) end
    local items = {}
    for _, l in ipairs(locs) do
      local t = target(l)
      items[#items + 1] = {text = M.rel(t.path) .. ":" .. t.line, target = t}
    end
    pick("Definition", items, function(item) M.jump(item.target) end)
  end)
end

local function file_lines(path)
  for _, d in ipairs(core.docs) do if d.abs_filename == path then return d.lines end end
  local lines, fp = {}, io.open(path, "rb")
  if fp then for l in fp:lines() do lines[#lines + 1] = l end; fp:close() end
  return lines
end

function M.references(doc, line, col)
  local params = M.position(doc, line, col)
  params.context = {includeDeclaration = true}
  request(doc, "textDocument/references", params, function(result)
    local locs = util.locations(result)
    if #locs == 0 then return core.log("No references found") end
    local rows, last = {}, nil
    for _, l in ipairs(locs) do
      local t = target(l)
      if t.path ~= last then
        last = t.path
        rows[#rows + 1] = {{style.accent, M.rel(t.path)}}
      end
      local text = (file_lines(t.path)[t.line] or ""):gsub("^%s+", ""):gsub("%s+$", "")
      rows[#rows + 1] = {target = t, indent = style.padding.x, {style.dim, tostring(t.line)}, {style.text, text}}
    end
    views.show(views.List("References", function() return rows end, nil, M.jump))
  end)
end

function M.document_symbols(doc)
  local uri = util.path_to_uri(doc.abs_filename)
  request(doc, "textDocument/documentSymbol", {textDocument = {uri = uri}}, function(result)
    local items = {}
    for _, s in ipairs(util.symbols(result, uri)) do
      items[#items + 1] = {text = s.name, info = s.detail, target = target({uri = s.uri, line = s.line, character = s.character})}
    end
    if #items == 0 then return core.log("No symbols in this file") end
    pick("Symbol in file", items, function(item) M.jump(item.target) end)
  end)
end

local function any_client()
  local d = active_doc()
  if d then return d.lsp end
  for _, c in pairs(client.clients) do if c.state == "ready" then return c end end
end

function M.workspace_symbols()
  local c = any_client()
  if not c then return end
  core.command_view:enter("Symbol in project", {submit = function(query)
    client.request(c, "workspace/symbol", {query = query}, function(result, err)
      if err then return core.log("%s: %s", c.spec.label, err) end
      local items = {}
      for _, s in ipairs(util.symbols(result)) do
        local t = target({uri = s.uri, line = s.line, character = s.character})
        items[#items + 1] = {text = s.name, info = M.rel(t.path) .. ":" .. t.line, target = t}
      end
      if #items == 0 then return core.log("No symbols match %q", query) end
      pick("Symbol in project", items, function(item) M.jump(item.target) end)
    end)
  end})
end

function M.next_problem(dv, dir)
  local list = client.diagnostics[dv.doc.abs_filename] or {}
  if #list == 0 then return end
  local line, col = dv.doc:get_selection()
  local found
  if dir > 0 then
    for _, d in ipairs(list) do if d.line1 > line or (d.line1 == line and d.col1 > col) then found = d; break end end
    found = found or list[1]
  else
    for i = #list, 1, -1 do
      local d = list[i]
      if d.line1 < line or (d.line1 == line and d.col1 < col) then found = d; break end
    end
    found = found or list[#list]
  end
  dv.doc:set_selection(found.line1, found.col1)
  dv:scroll_to_line(found.line1, true, true)
  local x, y = dv:get_line_screen_position(found.line1, found.col1)
  M.set_hover({view = dv, x = x, y = y, t = 0, asked = true, text = util.describe(found)})
end

local function caret_hover(dv)
  local line, col = dv.doc:get_selection()
  local x, y = dv:get_line_screen_position(line, col)
  local h = {view = dv, x = x, y = y, t = 0, asked = true}
  M.set_hover(h)
  M.hover(dv.doc, line, col, function(text) if M.hover_state() == h and text ~= "" then h.text = text; core.redraw = true end end)
end

command.add(function(...) local v = core.active_view; return v:is(DocView) and v.doc.lsp ~= nil, v, ... end, {
  ["lsp:goto-definition"] = function(dv) M.definition(dv.doc, dv.doc:get_selection()) end,
  ["lsp:goto-definition-at-mouse"] = function(dv, x, y)
    local line, col = dv:resolve_screen_position(x, y)
    dv.doc:set_selection(line, col)
    M.definition(dv.doc, line, col)
  end,
  ["lsp:find-references"] = function(dv) M.references(dv.doc, dv.doc:get_selection()) end,
  ["lsp:hover"] = caret_hover,
  ["lsp:document-symbols"] = function(dv) M.document_symbols(dv.doc) end,
  ["lsp:next-problem"] = function(dv) M.next_problem(dv, 1) end,
  ["lsp:previous-problem"] = function(dv) M.next_problem(dv, -1) end,
})
command.add(function() return any_client() ~= nil end, {
  ["lsp:workspace-symbols"] = function() M.workspace_symbols() end,
})

local mac = PLATFORM == "Mac OS X"
keymap.add({
  ["f12"] = "lsp:goto-definition",
  ["shift+f12"] = "lsp:find-references",
  ["f8"] = "lsp:next-problem",
  ["shift+f8"] = "lsp:previous-problem",
  [mac and "cmd+i" or "ctrl+shift+i"] = "lsp:hover",
  [mac and "cmd+shift+o" or "ctrl+shift+o"] = "lsp:document-symbols",
  [mac and "cmd+t" or "ctrl+t"] = "lsp:workspace-symbols",
  [mac and "cmd+1lclick" or "ctrl+1lclick"] = "lsp:goto-definition-at-mouse",
})
```

Notes:
- `M.definition(dv.doc, dv.doc:get_selection())` passes `line1, col1` and drops the remaining return values. `get_selection` returns four values, and `M.definition` takes only the first two after `doc`.
- `M.references` is called the same way.

- [ ] **Step 4: Run the tests and watch them pass**

Run: `cd /Users/theo/Documents/PROJECT/lite-xl && build/src/ide-test-runner scripts/tests/ide.lua | tail -1 && PATH=/tmp/lite-xl-build-tools/bin:$PATH ./scripts/test-ide.sh build 2>&1 | tail -1`
Expected: `PASS: 96 checks ...` and `PASS: nested workspace repositories, ...`.

- [ ] **Step 5: Commit**

```bash
git add data/plugins/lsp.lua scripts/tests/ui-runtime.lua
git commit -m "feat(lsp): go to definition, references, hover, symbols and next problem"
```

---

### Task 6: Real-server smoke, visual check, docs, install

**Files:**
- Create: `scripts/tests/lsp-smoke.lua`
- Modify: `docs/ide-features.md`

- [ ] **Step 1: Write the rust-analyzer smoke script**

Create `scripts/tests/lsp-smoke.lua` (run with the native runner from the repo root):

```lua
-- Manual smoke test against a real server: rust-analyzer must report a type
-- error in a fresh crate. Usage: build/src/ide-test-runner scripts/tests/lsp-smoke.lua
package.path = './data/?.lua;./data/?/init.lua;' .. package.path
PLATFORM, PATHSEP = 'Mac OS X', '/'
local threads = {}
package.loaded.core = {add_thread = function(fn) threads[#threads + 1] = coroutine.create(fn) end,
  error = function(...) print(string.format(...)) end, log = function() end}
system.get_file_info = function(path) local f = io.open(path, 'rb'); if f then f:close(); return {type = 'file'} end end
local servers = require 'plugins.lsp.servers'
local client = require 'plugins.lsp.client'
local spec = servers.find('/x/main.rs')
if not servers.resolve(spec) then print('SKIP: rust-analyzer not installed'); return end
local dir = os.tmpname(); os.remove(dir)
assert(os.execute("mkdir -p '" .. dir .. "/src'"))
io.open(dir .. '/Cargo.toml', 'w'):write('[package]\nname = "smoke"\nversion = "0.1.0"\nedition = "2021"\n'):close()
local src = 'fn main() {\n    let x: i32 = "nope";\n    println!("{x}");\n}\n'
io.open(dir .. '/src/main.rs', 'w'):write(src):close()
local doc = {abs_filename = dir .. '/src/main.rs', lines = {}}
for l in src:gmatch('[^\n]*\n') do doc.lines[#doc.lines + 1] = l end
local c = client.get(spec, dir)
client.open(c, doc)
local limit = os.time() + 90
while os.time() < limit do
  for _, co in ipairs(threads) do if coroutine.status(co) == 'suspended' then assert(coroutine.resume(co)) end end
  for _, d in ipairs(client.diagnostics[doc.abs_filename] or {}) do
    if d.severity == 1 and d.line1 == 2 then print('PASS: rust-analyzer reported: ' .. d.message); os.execute("rm -rf '" .. dir .. "'"); os.exit(0) end
  end
  system.sleep(20)
end
print('FAIL: no diagnostic within 90 s; state=' .. c.state .. '\n' .. table.concat(c.log, '\n'))
os.exit(1)
```

- [ ] **Step 2: Run it**

Run: `cd /Users/theo/Documents/PROJECT/lite-xl && build/src/ide-test-runner scripts/tests/lsp-smoke.lua`
Expected: `PASS: rust-analyzer reported: mismatched types...`, or `SKIP` if rust-analyzer is absent. The `PASS` line shows the client works against a real server: framing, initialize, and UTF-16 positions all hold.

- [ ] **Step 3: Build, install, screenshot**

```bash
cd /Users/theo/Documents/PROJECT/lite-xl && export PATH=/tmp/lite-xl-build-tools/bin:$PATH
ninja -C build-release && ./scripts/package-custom-macos.sh build-release
osascript -e 'quit app "TreX"' 2>/dev/null; rm -rf /Applications/TreX.app && cp -R build-release/TreX.app /Applications/TreX.app
```

Then use a temporary `LITE_USERDIR` with a `shot.lua` runtime, as was done for the review screenshots:
1. Open a Rust file containing a type error under `/tmp/trex-lsp-demo`.
2. Wait for the diagnostic.
3. Set the hover state with `lsp.next_problem(dv, 1)` and take `screencapture -x /tmp/lsp-squiggle.png`.
4. Run `command.perform('lsp:problems')` and take `screencapture -x /tmp/lsp-problems.png`.
5. Look at both screenshots with the Read tool.

Expected:
- A red wavy underline under `"nope"` and a red gutter dot on line 2.
- A tooltip with the rust-analyzer message.
- The status bar shows a red mark with `1` and the server item `rs`.
- The Problems tab lists the file with one error row.

Fix any clipping or overlap before continuing.

- [ ] **Step 4: Write the docs**

Append to `docs/ide-features.md`:

```markdown
## Languages and language servers

TreX highlights TypeScript/TSX/JSX, JSON, SCSS, Rust, Go, Zig, shell, YAML,
TOML, Dockerfile, Makefile, SQL, `.env` and diffs out of the box.

For TypeScript/JavaScript, JSON, Rust, Go, Zig, shell, YAML, TOML and
Dockerfiles TreX also runs a language server. Errors and warnings appear as
wavy underlines with a gutter dot; rest the mouse on one for the message.
The status bar shows the file's error and warning counts; click it, or press
**Cmd+Shift+M**, for the **Problems** tab. **F8** / **Shift+F8** step
through problems in the file.

Navigation: **F12** or **Cmd+click** goes to the definition, **Shift+F12**
lists references, resting the mouse on a symbol (or **Cmd+I**) shows its
type and docs, **Cmd+Shift+O** jumps to a symbol in the file and **Cmd+T**
searches symbols in the project.

When a server is missing, TreX offers to install it into
`~/.local/share/trex/lsp` (npm or `go install`; Zig's `zls` comes from
Homebrew). The status bar shows the server state; click it to restart a
crashed server or see its log (`lsp:show-log`).
```

- [ ] **Step 5: Run every test one last time**

Run: `cd /Users/theo/Documents/PROJECT/lite-xl && build/src/ide-test-runner scripts/tests/ide.lua | tail -1 && PATH=/tmp/lite-xl-build-tools/bin:$PATH ./scripts/test-ide.sh build 2>&1 | tail -1`
Expected: both print `PASS`.

- [ ] **Step 6: Commit**

```bash
git add scripts/tests/lsp-smoke.lua docs/ide-features.md
git commit -m "docs(lsp): document language support and add a real-server smoke test"
```
