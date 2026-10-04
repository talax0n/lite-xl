local M = {}
local function fields(record, count)
  local result, pos = {}, 1
  for i = 1, count do
    local stop = record:find(" ", pos, true)
    if not stop then return nil end
    result[i], pos = record:sub(pos, stop - 1), stop + 1
  end
  return result, record:sub(pos)
end
function M.status(output)
  local status = {branch = "", ahead = 0, behind = 0, staged = {}, changes = {}, conflicts = {}}
  local pos, count = 1, 0
  local function next_record()
    local stop = output:find("\0", pos, true)
    if not stop then return nil end
    local record = output:sub(pos, stop - 1); pos = stop + 1
    return record
  end
  while true do
    local record = next_record()
    if not record then break end
    if count >= 10000 then status.limited = true; break end
    if record:sub(1, 1) ~= "#" then count = count + 1 end
    if record:sub(1, 2) == "# " then
      local key, value = record:match("^# (%S+) (.*)$")
      if key == "branch.head" then status.branch = value
      elseif key == "branch.oid" then status.head = value
      elseif key == "branch.upstream" then status.upstream = value
      elseif key == "branch.ab" then status.ahead, status.behind = value:match("%+(%d+) %-(%d+)"); status.ahead, status.behind = tonumber(status.ahead) or 0, tonumber(status.behind) or 0 end
    elseif record:sub(1, 2) == "? " then
      status.changes[#status.changes + 1] = {path = record:sub(3), status = "?", untracked = true}
    else
      local kind = record:sub(1, 1)
      local values, path = fields(record, kind == "1" and 8 or kind == "2" and 9 or 10)
      if values and (kind == "1" or kind == "2" or kind == "u") then
        local entry = {path = path, xy = values[2], submodule = values[3] ~= "N..."}
        if kind == "2" then entry.original = next_record() end
        if kind == "u" then entry.status = "!"; status.conflicts[#status.conflicts + 1] = entry
        else
          if entry.xy:sub(1, 1) ~= "." then
            local staged = {}; for k, v in pairs(entry) do staged[k] = v end
            staged.status, staged.staged = entry.xy:sub(1, 1), true
            status.staged[#status.staged + 1] = staged
          end
          if entry.xy:sub(2, 2) ~= "." then entry.status = entry.xy:sub(2, 2); status.changes[#status.changes + 1] = entry end
        end
      end
    end
  end
  return status
end
function M.log(output)
  local fields_, result = {}, {}
  for value in output:gmatch("([^\0]*)\0") do fields_[#fields_ + 1] = value end
  for i = 1, #fields_ - 5, 6 do
    local hash = fields_[i]:gsub("^\n+", "")
    if hash:match("^[%da-f]+$") then
      local parents = {}; for p in fields_[i + 1]:gmatch("%S+") do parents[#parents + 1] = p end
      result[#result + 1] = {hash = hash, parents = parents, author = fields_[i + 2], date = fields_[i + 3], refs = fields_[i + 4], subject = fields_[i + 5]}
    end
  end
  return result
end
function M.graph(commits)
  local lanes = {}
  for _, commit in ipairs(commits) do
    local lane
    for i, hash in ipairs(lanes) do if hash == commit.hash then lane = i; break end end
    commit.incoming = lane ~= nil
    if not lane then
      if #lanes >= 32 then table.remove(lanes); commit.graph_limited = true end
      lane = #lanes + 1; lanes[lane] = commit.hash
    end
    local before = {}; for i, hash in ipairs(lanes) do before[i] = hash end
    table.remove(lanes, lane)
    for i, parent in ipairs(commit.parents) do
      local exists = false; for _, hash in ipairs(lanes) do if hash == parent then exists = true; break end end
      if not exists then
        if #lanes < 32 then table.insert(lanes, math.min(lane + i - 1, #lanes + 1), parent)
        else commit.graph_limited = true end
      end
    end
    commit.lane, commit.edges, commit.lanes = lane, {}, math.max(#before, #lanes)
    for from, hash in ipairs(before) do
      if from ~= lane then
        for to, next_hash in ipairs(lanes) do if next_hash == hash then commit.edges[#commit.edges + 1] = {from, to, false}; break end end
      end
    end
    for _, parent in ipairs(commit.parents) do
      for to, hash in ipairs(lanes) do if hash == parent then commit.edges[#commit.edges + 1] = {lane, to, true}; break end end
    end
  end
end
function M.hunks(diff)
  local result, header, current = {}, {}, nil
  for line in (diff .. "\n"):gmatch("([^\n]*)\n") do
    if line:match("^@@ ") then
      current = {lines = {line}, start = line}; result[#result + 1] = current
    elseif current then current.lines[#current.lines + 1] = line
    else header[#header + 1] = line end
  end
  for _, hunk in ipairs(result) do
    while hunk.lines[#hunk.lines] == "" do table.remove(hunk.lines) end
    hunk.patch = table.concat(header, "\n") .. "\n" .. table.concat(hunk.lines, "\n") .. "\n"
  end
  return result
end
return M
