-- Database explorer: URL parsing, per-engine SQL and argv, CSV and config parsing. No editor or processes.
-- Connection = {name, url, kind = "postgres"|"sqlite", source = "saved"|"env", error, ...parsed fields}
local M = {}

local function ident(s) return '"' .. s:gsub('"', '""') .. '"' end
local function literal(s) return "'" .. s:gsub("'", "''") .. "'" end
local function unescape(s) return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)) end

function M.parse_url(name, url, root)
  local conn = {name = name, url = url, source = "saved"}
  local rest = url:match("^postgres://(.*)$") or url:match("^postgresql://(.*)$")
  if rest then
    conn.kind = "postgres"
    local authority, tail = rest:match("^([^/?]*)(.*)$")
    local userinfo, hostport = authority:match("^(.*)@(.-)$")
    hostport = hostport or authority
    if userinfo then
      conn.user, conn.password = userinfo:match("^([^:]*):(.*)$")
      conn.user = conn.user or userinfo
      conn.password = conn.password and unescape(conn.password)
    end
    conn.host, conn.port = hostport:match("^(.-):(%d+)$")
    conn.host = conn.host or hostport
    conn.database = tail:match("^/([^?]*)")
    conn.conninfo = "postgresql://" .. (conn.user and conn.user ~= "" and conn.user .. "@" or "") .. hostport .. tail
    return conn
  end
  rest = url:match("^sqlite:(.*)$")
  if rest then
    conn.kind = "sqlite"
    rest = rest:match("^//(/.*)$") or rest
    if rest == "" then conn.error = "SQLite URL has no path"
    elseif rest:sub(1, 1) == "/" then conn.path = rest
    elseif root then conn.path = root .. "/" .. rest
    else conn.error = "Relative SQLite path needs an open project" end
    return conn
  end
  conn.error = "Unsupported URL, use postgres:// or sqlite:"
  return conn
end

M.DRIVERS = {
  postgres = {
    argv = function(conn, sql, readonly)
      return "psql", {"-X", "-q", "--csv", "-v", "ON_ERROR_STOP=1", "-d", conn.conninfo, "-c", sql}, {
        PGPASSWORD = conn.password, PGCONNECT_TIMEOUT = "5",
        PGOPTIONS = "-c statement_timeout=30000" .. (readonly and " -c default_transaction_read_only=on" or ""),
      }
    end,
    schemas_sql = "select schema_name from information_schema.schemata where schema_name not in ('pg_catalog', 'information_schema') and schema_name not like 'pg\\_%' order by 1",
    tables_sql = function(schema) return "select table_name, lower(replace(table_type, 'BASE ', '')) from information_schema.tables where table_schema = " .. literal(schema) .. " order by 1" end,
    columns_sql = function(schema, table)
      return "select column_name, data_type from information_schema.columns where table_schema = " .. literal(schema) .. " and table_name = " .. literal(table) .. " order by ordinal_position"
    end,
    preview_sql = function(schema, table) return "select * from " .. ident(schema) .. "." .. ident(table) .. " limit 100" end,
  },
  sqlite = {
    -- SQL goes through stdin: an argv starting with "-" (a "--" comment) would be read as an option.
    argv = function(conn, sql, readonly)
      local args = {"-csv", "-header", "-bail"}
      if readonly then args[#args + 1] = "-readonly" end
      args[#args + 1] = conn.path
      return "sqlite3", args, {}, sql
    end,
    schemas_sql = "select 'main' as name",
    tables_sql = function() return "select name, type from sqlite_master where type in ('table', 'view') and name not like 'sqlite\\_%' escape '\\' order by 1" end,
    columns_sql = function(_, table) return "select name, type from pragma_table_info(" .. literal(table) .. ")" end,
    preview_sql = function(schema, table) return "select * from " .. ident(schema) .. "." .. ident(table) .. " limit 100" end,
  },
}

function M.parse_csv(text)
  local records, row, i, n = {}, {}, 1, #text
  while i <= n do
    local value
    if text:sub(i, i) == '"' then
      local parts = {}
      i = i + 1
      while true do
        local q = text:find('"', i, true)
        if not q then parts[#parts + 1] = text:sub(i); i = n + 1; break end
        parts[#parts + 1] = text:sub(i, q - 1)
        if text:sub(q + 1, q + 1) == '"' then parts[#parts + 1] = '"'; i = q + 2 else i = q + 1; break end
      end
      value = table.concat(parts)
    else
      local e = text:find("[,\r\n]", i) or n + 1
      value, i = text:sub(i, e - 1), e
    end
    row[#row + 1] = value
    if text:sub(i, i) == "," then
      i = i + 1
      if i > n then row[#row + 1] = "" end
    else
      if text:sub(i, i) == "\r" then i = i + 1 end
      if text:sub(i, i) == "\n" then i = i + 1 end
      records[#records + 1] = row; row = {}
    end
  end
  if #row > 0 then records[#records + 1] = row end
  return {columns = table.remove(records, 1) or {}, rows = records}
end

function M.load_conf(text)
  local list = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local name, url = line:match("^%s*([^#=][^=]-)%s*=%s*(.-)%s*$")
    if name and url ~= "" then list[#list + 1] = {name = name, url = url} end
  end
  return list
end

function M.serialize_conf(list)
  local out = {}
  for _, e in ipairs(list) do out[#out + 1] = e.name .. " = " .. e.url .. "\n" end
  return table.concat(out)
end

function M.read_env_url(text)
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local value = line:match("^%s*export%s+DATABASE_URL%s*=%s*(.-)%s*$") or line:match("^%s*DATABASE_URL%s*=%s*(.-)%s*$")
    if value then
      value = value:match('^"(.*)"$') or value:match("^'(.*)'$") or value
      if value ~= "" then return value end
    end
  end
end

local READ_ONLY = {select = true, with = true, explain = true, show = true, pragma = true, values = true, table = true}
function M.is_read_only(sql)
  local i = 1
  while true do
    local s = sql:find("%S", i)
    if not s then return false end
    if sql:sub(s, s + 1) == "--" then i = (sql:find("\n", s, true) or #sql) + 1
    elseif sql:sub(s, s + 1) == "/*" then i = (select(2, sql:find("*/", s + 2, true)) or #sql) + 1
    else return READ_ONLY[(sql:match("^%a+", s) or ""):lower()] == true end
  end
end

return M
