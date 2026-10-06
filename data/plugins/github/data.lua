-- GitHub activity: pure query building and parsing, no editor or network.
local json = require "plugins.lsp.json"
local M = {}

local LABELS = {"Today", "This week", "This month", "This year"}

function M.windows(now)
  local t = os.date("*t", now)
  local starts = {
    {year = t.year, month = t.month, day = t.day},
    {year = t.year, month = t.month, day = t.day - (t.wday + 5) % 7},
    {year = t.year, month = t.month, day = 1},
    {year = t.year, month = 1, day = 1},
  }
  local result = {}
  for i, start in ipairs(starts) do
    start.hour = 0
    result[i] = {label = LABELS[i], from = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time(start))}
  end
  return result
end

local TOTALS = "totalCommitContributions totalPullRequestContributions totalIssueContributions totalPullRequestReviewContributions restrictedContributionsCount"

function M.query(windows)
  local aliases = {}
  for i, w in ipairs(windows) do
    local calendar = i == #windows and " contributionCalendar { weeks { contributionDays { date contributionCount } } }" or ""
    aliases[i] = string.format('w%d: contributionsCollection(from: "%s") { %s%s }', i, w.from, TOTALS, calendar)
  end
  return "{ viewer { login " .. table.concat(aliases, " ") .. " } }"
end

function M.thousands(n) return (tostring(n):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")) end

-- The JSON decoder turns `null` array entries into holes, so ipairs would stop at the first one.
local function list(t)
  local items, n = {}, 0
  if type(t) ~= "table" then return items end
  for k in pairs(t) do if math.type(k) == "integer" and k > n then n = k end end
  for i = 1, n do if type(t[i]) == "table" then items[#items + 1] = t[i] end end
  return items
end

function M.parse(graphql_json)
  local ok, data = pcall(json.decode, graphql_json)
  if not ok or type(data) ~= "table" then return nil, "Unreadable response from GitHub" end
  if data.errors then return nil, data.errors[1] and data.errors[1].message or "GitHub API error" end
  local viewer = data.data and data.data.viewer
  if not viewer then return nil, "Unexpected response from GitHub" end
  local model = {login = viewer.login, windows = {}, days = {}}
  for i, label in ipairs(LABELS) do
    local c = viewer["w" .. i] or {}
    local commits = c.totalCommitContributions or 0
    model.windows[i] = {label = label, commits = commits, contributions = commits + (c.totalPullRequestContributions or 0)
      + (c.totalIssueContributions or 0) + (c.totalPullRequestReviewContributions or 0) + (c.restrictedContributionsCount or 0)}
    if c.contributionCalendar then
      for _, week in ipairs(list(c.contributionCalendar.weeks)) do
        for _, day in ipairs(list(week.contributionDays)) do
          if day.date and day.contributionCount then model.days[#model.days + 1] = {date = day.date, count = day.contributionCount} end
        end
      end
    end
  end
  return model
end

-- `today` is a "YYYY-MM-DD" date in the calendar's own (UTC) days. Ranges are nil for a 0 streak.
function M.streak(days, today)
  local last = 0
  for i, day in ipairs(days) do if day.date <= today then last = i end end
  local s, run = {current = 0, longest = 0}, 0
  for i = 1, last do
    run = days[i].count > 0 and run + 1 or 0
    if run > s.longest then s.longest, s.longest_from, s.longest_to = run, days[i - run + 1].date, days[i].date end
  end
  -- Today isn't over yet: a zero today keeps yesterday's streak alive.
  local i = (last > 0 and days[last].date == today and days[last].count == 0) and last - 1 or last
  local to = i
  while i > 0 and days[i].count > 0 do s.current = s.current + 1; i = i - 1 end
  if s.current > 0 then s.current_from, s.current_to = days[i + 1].date, days[to].date end
  return s
end

local MONTHS = {"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}
function M.short_date(date)
  local m, d = date:match("%d+-(%d+)-(%d+)")
  return MONTHS[tonumber(m)] .. " " .. tonumber(d)
end

return M
