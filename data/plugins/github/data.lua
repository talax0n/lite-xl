-- GitHub activity: pure query building and parsing, no editor or network.
local json = require "plugins.lsp.json"
local M = {}

local LABELS = {"Today", "This week", "This month", "This year"}
local MAX_ROWS = 10

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
local PR = "title url updatedAt repository { nameWithOwner }"

function M.query(windows)
  local aliases = {}
  for i, w in ipairs(windows) do
    local calendar = i == #windows and " contributionCalendar { weeks { contributionDays { date contributionCount } } }" or ""
    aliases[i] = string.format('w%d: contributionsCollection(from: "%s") { %s%s }', i, w.from, TOTALS, calendar)
  end
  return "{ viewer { login " .. table.concat(aliases, " ")
    .. " pullRequests(states: OPEN, first: 10, orderBy: {field: UPDATED_AT, direction: DESC}) { nodes { " .. PR .. " } } }"
    .. ' search(query: "is:pr is:open review-requested:@me", type: ISSUE, first: 10) { nodes { ... on PullRequest { ' .. PR .. " } } } }"
end

local function pull_requests(nodes)
  local rows = {}
  for _, n in ipairs(nodes or {}) do
    if n.url and #rows < MAX_ROWS then
      rows[#rows + 1] = {title = n.title, repo = n.repository and n.repository.nameWithOwner or "", url = n.url, updated = n.updatedAt}
    end
  end
  return rows
end

local function pushes(events)
  local rows = {}
  for _, e in ipairs(events) do
    if e.type == "PushEvent" and e.payload and #rows < MAX_ROWS then
      rows[#rows + 1] = {repo = e.repo.name, branch = (e.payload.ref or ""):gsub("^refs/heads/", ""),
        url = "https://github.com/" .. e.repo.name .. "/commit/" .. (e.payload.head or ""), at = e.created_at}
    end
  end
  return rows
end

function M.parse(graphql_json, events_json)
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
      for _, week in ipairs(c.contributionCalendar.weeks or {}) do
        for _, day in ipairs(week.contributionDays or {}) do model.days[#model.days + 1] = {date = day.date, count = day.contributionCount} end
      end
    end
  end
  model.prs = pull_requests(viewer.pullRequests and viewer.pullRequests.nodes)
  model.reviews = pull_requests(data.data.search and data.data.search.nodes)
  local events_ok, events = pcall(json.decode, events_json)
  model.pushes = events_ok and type(events) == "table" and pushes(events) or nil
  return model
end

-- `today` is a "YYYY-MM-DD" date in the calendar's own (UTC) days.
function M.streak(days, today)
  local last = 0
  for i, day in ipairs(days) do if day.date <= today then last = i end end
  local longest, run = 0, 0
  for i = 1, last do
    run = days[i].count > 0 and run + 1 or 0
    longest = math.max(longest, run)
  end
  -- Today isn't over yet: a zero today keeps yesterday's streak alive.
  local i = (last > 0 and days[last].date == today and days[last].count == 0) and last - 1 or last
  local current = 0
  while i > 0 and days[i].count > 0 do current = current + 1; i = i - 1 end
  return {current = current, longest = longest}
end

return M
