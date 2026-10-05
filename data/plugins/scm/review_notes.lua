-- Commit review notes: the `.trex/review.md` format, re-anchoring notes to
-- moved code, viewed-file state and `git worktree list --porcelain`.
-- Pure functions: no UI, no git, tested in scripts/tests/ide.lua.
local M = {}

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
local function one_line(s) return (s:gsub("[\r\n]+", " ")) end

function M.location(n)
  if not n.path then return "(general)" end
  return "`" .. n.path .. ":" .. n.from .. ((n.to and n.to ~= n.from) and "-" .. n.to or "") .. "`"
end

function M.parse(text)
  local doc, last = {notes = {}, extra = {}}, nil
  for line in ((text or "") .. "\n"):gmatch("([^\n]*)\n") do
    local mark, body = line:match("^%- %[([ xX])%] (.*)$")
    if mark then
      last = {done = mark ~= " "}
      local path, from, to, rest = body:match("^`([^`]+):(%d+)%-?(%d*)`%s?(.*)$")
      if path then
        last.path, last.from, last.to, last.text = path, tonumber(from), tonumber(to) or tonumber(from), rest
      else
        last.text = body:match("^%(general%)%s?(.*)$") or body
      end
      doc.notes[#doc.notes + 1] = last
    elseif last and line:match("^  > ") then
      last.snapshot = line:sub(5)
    elseif not doc.header and line:match("^# ") then
      doc.header = line
    else
      -- Anything else (agent comments, prose) is kept verbatim at the end.
      if line ~= "" then doc.extra[#doc.extra + 1] = line end
      last = nil
    end
  end
  return doc
end

function M.serialize(doc)
  local out = {doc.header or "# Review", ""}
  for _, n in ipairs(doc.notes) do
    out[#out + 1] = "- [" .. (n.done and "x" or " ") .. "] " .. M.location(n) .. " " .. one_line(n.text)
    if n.snapshot and n.snapshot ~= "" then out[#out + 1] = "  > " .. n.snapshot end
  end
  if #doc.extra > 0 then
    out[#out + 1] = ""
    for _, line in ipairs(doc.extra) do out[#out + 1] = line end
  end
  return table.concat(out, "\n") .. "\n"
end

-- Moves `n` to where its snapshot line now is in `lines` (HEAD content of
-- n.path), searching ±50 lines nearest first; marks it outdated otherwise.
function M.reanchor(n, lines)
  n.outdated = nil
  if not n.path then return n end
  if not lines then n.outdated = true; return n end
  local want = n.snapshot and trim(n.snapshot) or ""
  -- ponytail: a blank snapshot can't be tracked, the note keeps its line.
  if want == "" then
    if n.from > #lines then n.outdated = true end
    return n
  end
  local span = n.to - n.from
  for d = 0, 50 do
    for _, i in ipairs(d == 0 and {n.from} or {n.from - d, n.from + d}) do
      if lines[i] and trim(lines[i]) == want then n.from, n.to = i, i + span; return n end
    end
  end
  n.outdated = true
  return n
end

function M.viewed_parse(text)
  local map = {}
  for path, sha in (text or ""):gmatch("([^\t\n]+)\t([^\n]+)") do map[path] = sha end
  return map
end

function M.viewed_serialize(map)
  local paths = {}
  for path in pairs(map) do paths[#paths + 1] = path end
  table.sort(paths)
  local out = {}
  for _, path in ipairs(paths) do out[#out + 1] = path .. "\t" .. map[path] .. "\n" end
  return table.concat(out)
end

-- Clipboard text for the agent: open notes in file order, general notes last.
function M.copy_text(doc)
  local located, general = {}, {}
  for _, n in ipairs(doc.notes) do
    if not n.done then
      if n.path then located[#located + 1] = n else general[#general + 1] = n end
    end
  end
  table.sort(located, function(a, b) if a.path ~= b.path then return a.path < b.path end; return a.from < b.from end)
  local out = {"Address these review notes (also in .trex/review.md; tick [x] when done):"}
  for _, n in ipairs(located) do
    out[#out + 1] = "- " .. M.location(n) .. " " .. one_line(n.text) .. (n.outdated and " (code changed since this note)" or "")
    if n.snapshot and n.snapshot ~= "" then out[#out + 1] = "  > " .. n.snapshot end
  end
  for _, n in ipairs(general) do out[#out + 1] = "- (general) " .. one_line(n.text) end
  return table.concat(out, "\n") .. "\n"
end

function M.parse_worktrees(text)
  local list, cur = {}, nil
  for line in ((text or "") .. "\n"):gmatch("([^\n]*)\n") do
    local key, value = line:match("^(%S+) ?(.*)$")
    if key == "worktree" then cur = {root = value}; list[#list + 1] = cur
    elseif cur and key == "HEAD" then cur.head = value
    elseif cur and key == "branch" then cur.branch = (value:gsub("^refs/heads/", ""))
    elseif cur and (key == "bare" or key == "detached" or key == "locked" or key == "prunable") then cur[key] = true end
  end
  return list
end

return M
