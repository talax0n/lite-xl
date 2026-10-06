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

-- Symlinks resolved (/tmp -> /private/tmp), so server and editor paths meet.
function M.canonical(path) return system.absolute_path(path) or path end

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

-- Positions are converted at publish time and go stale as the text changes;
-- clamp them into the current lines before using them as a location.
function M.clamp(lines, line, col)
  line = math.max(1, math.min(line, #lines))
  return line, math.max(1, math.min(col, #lines[line]))
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
