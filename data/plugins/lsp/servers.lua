-- Language servers TreX knows: which files they handle, how to start and
-- install them, and which files mark their project root.
local process = require "core.process"
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

-- Runs in a thread on its own process, not git.exec: that one's two slots are
-- shared with source control and an npm install can hold one for minutes.
-- Returns true, or nil and the tail of the output.
function M.install(spec, timeout)
  local ok, proc = pcall(process.start, {"/usr/bin/env", table.unpack(M.install_argv(spec))}, {cwd = M.dir})
  if not ok or not proc or not proc.process then return nil, tostring(proc) end
  proc:close_stream(process.STREAM_STDIN)
  local out, started = "", system.get_time()
  while true do
    local busy = false
    for _, stream in ipairs({process.STREAM_STDOUT, process.STREAM_STDERR}) do
      local data = proc:read(stream, 65536)
      if data and #data > 0 then busy, out = true, (out .. data):sub(-4000) end
    end
    if not busy and not proc:running() then break end
    if system.get_time() - started > (timeout or 900) then proc:kill(); return nil, out .. "\ntimed out" end
    coroutine.yield(busy and 0 or 0.05)
  end
  if proc:returncode() ~= 0 then return nil, out ~= "" and out or "exit code " .. tostring(proc:returncode()) end
  return true
end

function M.install_text(spec)
  local argv = M.install_argv(spec)
  return table.concat(argv, " ", 2)
end

return M
