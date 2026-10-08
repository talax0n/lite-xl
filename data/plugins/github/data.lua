-- GitHub activity: pure query building and parsing, no editor or network.
-- model = {login, days = {{date = "2025-10-05", count = 3}, ...} (rolling last-year calendar, oldest first),
--   windows = {{label = "Today", contributions}, ...}}
-- The panel adds streak (M.streak) and fetched_at.
local json = require "plugins.lsp.json"
local M = {}

local LABELS = {"Today", "This week", "This month", "This year"}

-- Windows start at Asia/Jakarta midnights (UTC+7, no DST). GitHub honours the offset only when it is
-- written out; a "Z" timestamp gets snapped to the UTC day.
local OFFSET, DAY = 7 * 3600, 86400

function M.windows(now)
  local t = os.date("!*t", now + OFFSET)
  local midnight = now - (now + OFFSET) % DAY
  local starts = {midnight, midnight - (t.wday + 5) % 7 * DAY, midnight - (t.day - 1) * DAY, midnight - (t.yday - 1) * DAY}
  local result = {}
  for i, start in ipairs(starts) do result[i] = {label = LABELS[i], from = os.date("!%Y-%m-%dT%H:%M:%S+07:00", start + OFFSET)} end
  return result
end

-- Today's "YYYY-MM-DD" in Jakarta.
function M.today(now) return os.date("!%Y-%m-%d", now + OFFSET) end

local TOTALS = "totalCommitContributions totalPullRequestContributions totalIssueContributions totalPullRequestReviewContributions restrictedContributionsCount"

function M.query(windows)
  local aliases = {}
  for i, w in ipairs(windows) do aliases[i] = string.format('w%d: contributionsCollection(from: "%s") { %s }', i, w.from, TOTALS) end
  -- No `from`: the calendar covers the last year like the profile graph, so streaks cross January 1st.
  return "{ viewer { login " .. table.concat(aliases, " ")
    .. " cal: contributionsCollection { contributionCalendar { weeks { contributionDays { date contributionCount } } } } } }"
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
    -- Private org work only shows up as restricted contributions, so the one number is everything.
    model.windows[i] = {label = label, contributions = (c.totalCommitContributions or 0) + (c.totalPullRequestContributions or 0)
      + (c.totalIssueContributions or 0) + (c.totalPullRequestReviewContributions or 0) + (c.restrictedContributionsCount or 0)}
  end
  local calendar = viewer.cal and viewer.cal.contributionCalendar
  for _, week in ipairs(list(calendar and calendar.weeks)) do
    for _, day in ipairs(list(week.contributionDays)) do
      if day.date and day.contributionCount then model.days[#model.days + 1] = {date = day.date, count = day.contributionCount} end
    end
  end
  return model
end

-- `today` is a "YYYY-MM-DD" date in the calendar's own days (Jakarta, see M.today). Ranges are nil for a 0 streak.
local function upto(days, today)
  local last = 0
  for i, day in ipairs(days) do if day.date <= today then last = i end end
  return last
end

local function stamp(date)
  local y, m, d = date:match("(%d+)-(%d+)-(%d+)")
  return os.time({year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12})
end

-- Whole days from `a` to `b`; rounding absorbs DST shifts.
local function gap(a, b) return math.floor((stamp(b) - stamp(a)) / 86400 + 0.5) end

-- First and last index of this year's days up to today; "this year" stats ignore the rest of the rolling calendar.
local function this_year(days, today)
  local first, jan1 = 1, today:sub(1, 4) .. "-01-01"
  while days[first] and days[first].date < jan1 do first = first + 1 end
  return first, upto(days, today)
end

function M.streak(days, today)
  local last = upto(days, today)
  local s, run = {current = 0, longest = 0}, 0
  for i = 1, last do
    run = days[i].count == 0 and 0 or (run > 0 and gap(days[i - 1].date, days[i].date) == 1) and run + 1 or 1
    if run > s.longest then s.longest, s.longest_from, s.longest_to = run, days[i - run + 1].date, days[i].date end
  end
  -- Today isn't over yet: a zero today keeps yesterday's streak alive.
  local i = (last > 0 and days[last].date == today and days[last].count == 0) and last - 1 or last
  local to = i
  if i > 0 and gap(days[i].date, today) > 1 then i = 0 end
  while i > 0 and days[i].count > 0 and (i == to or gap(days[i].date, days[i + 1].date) == 1) do s.current = s.current + 1; i = i - 1 end
  if s.current > 0 then s.current_from, s.current_to = days[i + 1].date, days[to].date end
  return s
end

local MONTHS = {"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}
function M.short_date(date)
  local m, d = date:match("%d+-(%d+)-(%d+)")
  return MONTHS[tonumber(m)] .. " " .. tonumber(d)
end

-- 0 is Sunday, as in os.date's wday - 1.
function M.weekday(date) return os.date("*t", stamp(date)).wday - 1 end

-- `n` totals of 7-day buckets, the last one ending today.
function M.weekly(days, today, n)
  local totals = {}
  for k = 1, n do totals[k] = 0 end
  for i = 1, upto(days, today) do
    local k = n - gap(days[i].date, today) // 7
    if k >= 1 then totals[k] = totals[k] + days[i].count end
  end
  return totals
end

-- Monday first.
function M.weekdays(days, today)
  local totals = {0, 0, 0, 0, 0, 0, 0}
  local first, last = this_year(days, today)
  for i = first, last do
    local wd = (M.weekday(days[i].date) + 6) % 7 + 1
    totals[wd] = totals[wd] + days[i].count
  end
  return totals
end

function M.best_day(days, today)
  local best
  local first, last = this_year(days, today)
  for i = first, last do if not best or days[i].count > best.count then best = days[i] end end
  return best
end

function M.average(days, today)
  local first, last = this_year(days, today)
  local sum = 0
  for i = first, last do sum = sum + days[i].count end
  return last >= first and sum / (last - first + 1) or 0
end

return M
