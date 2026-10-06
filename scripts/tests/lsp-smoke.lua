-- Manual smoke test against a real server: rust-analyzer must report a type
-- error in a fresh crate. Usage: build/src/ide-test-runner scripts/tests/lsp-smoke.lua
package.path = './data/?.lua;./data/?/init.lua;' .. package.path
PLATFORM, PATHSEP = 'Mac OS X', '/'
local threads = {}
package.loaded.core = {add_thread = function(fn) threads[#threads + 1] = coroutine.create(fn) end,
  error = function(...) print(string.format(...)) end, log = function() end}
package.loaded['core.config'], package.loaded['core.common'] = {fps = 60}, {}
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
  for _, d in ipairs(client.diagnostics_for(doc.abs_filename) or {}) do
    if d.severity == 1 and d.line1 == 2 then print('PASS: rust-analyzer reported: ' .. d.message); os.execute("rm -rf '" .. dir .. "'"); os.exit(0) end
  end
  system.sleep(20)
end
print('FAIL: no diagnostic within 90 s; state=' .. c.state .. '\n' .. table.concat(c.log, '\n'))
os.exit(1)
