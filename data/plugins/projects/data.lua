-- Projects column: pure folder listing and status counting, no editor.
-- row = {name, path, git = bool, count = nil|number}
local M = {}

function M.list(root)
  local rows = {}
  for _, name in ipairs(system.list_dir(root) or {}) do
    local path = root .. PATHSEP .. name
    local info = name:sub(1, 1) ~= "." and name ~= "node_modules" and system.get_file_info(path)
    if info and info.type == "dir" then
      rows[#rows + 1] = {name = name, path = path, git = system.get_file_info(path .. PATHSEP .. ".git") ~= nil}
    end
  end
  table.sort(rows, function(a, b)
    local x, y = a.name:lower(), b.name:lower()
    if x == y then return a.name < b.name end
    return x < y
  end)
  return rows
end

-- Number of entries in `git status --porcelain` output.
function M.count(porcelain)
  local n = 0
  for _ in porcelain:gmatch("[^\r\n]+") do n = n + 1 end
  return n
end

return M
