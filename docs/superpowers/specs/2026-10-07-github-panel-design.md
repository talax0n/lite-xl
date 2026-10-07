# GitHub Panel — Design

Date: 2026-10-07
Status: approved in chat, awaiting spec review

## Intent

The user wants to see their own GitHub activity without leaving TreX: how
much they contributed today and over longer windows, their contribution
heatmap and streak, and charts of how their contributions break down. It
lives in a panel docked on the right.

Success: one click on a new activity-bar icon opens a right-side panel
showing a streak card (year total, current and longest streak with date
ranges), counts for Today / This week / This month / This year, a year
heatmap, and charts: contribution types this year, weekly totals for the
last 26 weeks, totals by weekday, best day and daily average.

Out of scope: PR, review and push lists (removed 2026-10-07), profile card,
top repos, other users, writing to GitHub, local-git counts.

## Data source

All data comes from the `gh` CLI already logged in on the machine
(`gh api graphql`). No token handling in
TreX.

Known limit, measured on the user's account: GitHub reports private
org work (e.g. `solhedge-team`) only as `restrictedContributionsCount`, so
`totalCommitContributions` can read 0 on a day with 85 private
contributions. Therefore:

- Headline numbers are **contributions** (commits + PRs + issues + reviews,
  private included), the same figure as the GitHub profile graph:
  `totalCommitContributions + totalPullRequestContributions +
  totalIssueContributions + totalPullRequestReviewContributions +
  restrictedContributionsCount` for that window.
- One number per window, labelled as commits ("Total Commits" on the card).
  No commits/private split is shown: the user found it confusing. Numbers
  use thousands separators ("6,183").

## Data shape

```lua
model = {
  login = "talax0n",
  windows = {            -- in this order
    {label = "Today", contributions = 85},
    {label = "This week",  ...}, {label = "This month", ...}, {label = "This year", ...},
  },
  days = {{date = "2025-10-05", count = 3}, ...},  -- rolling last-year calendar, oldest first
  streak = {current = 43, longest = 43,           -- ranges are ISO dates, nil when 0
    current_from = "2026-08-25", current_to = "2026-10-06", longest_from = ..., longest_to = ...},
  fetched_at = <os.time>, error = nil | "message",
}
```

## Units

### `data/plugins/github/data.lua` (pure, no editor or network)

- `windows(now)` → the four `{label, from}` windows as UTC ISO strings,
  computed from local midnight: today, Monday of this week, the 1st of this
  month, Jan 1st of this year.
- `query(windows)` → one GraphQL query string with aliased
  `contributionsCollection(from:)` per window (to defaults to now), a `cal`
  alias with no `from` whose `contributionCalendar` covers the last year
  (about 53 weeks, starting on a Sunday, like the profile graph) and
  `viewer.login`.
- `parse(graphql_json)` → `model` (without `streak` and `fetched_at`).
- `streak(days, today)` → `{current, longest, current_from, current_to,
  longest_from, longest_to}`. Current counts back from today; if today is 0
  it counts back from yesterday (today isn't over). Runs follow actual
  dates: a missing date breaks them. Both streaks span the rolling year, so
  they cross January 1st and the longest is the longest in the last year.
- `weekly(days, today, n)` → `n` totals of 7-day buckets, the last ending
  today (even if the calendar stops earlier), oldest first.
  `weekdays(days, today)` → 7 totals, Monday first. `best_day(days, today)`
  → the first busiest day. `average(days, today)` → contributions per
  calendar day up to today. These three only count this year (Jan 1st to
  today); the heatmap and weekly bars use the whole rolling calendar. `short_date("2026-08-25")` →
  `"Aug 25"`.
- Uses `plugins.lsp.json` for decoding.

### `data/plugins/github.lua` (panel)

- `GitHub` view docked right like `Backlog`
  (`get_primary_node():split("right", panel, {x = true}, true)`), width
  `config.plugins.github.width` (default 320).
- Command `github:toggle`; activity-bar entry in
  `data/plugins/toolbarview.lua` after Backlog, symbol from the icon font,
  active when the panel is visible.
- Fetch runs in a coroutine through `scm/git.lua`'s `exec(cwd, "gh",
  args)` (non-blocking, finds `/opt/homebrew/bin/gh`), one GraphQL call.
- Refresh on first open, every 10 minutes while visible, and on the
  header refresh button. One fetch at a time.
- Layout, top to bottom: header (`GITHUB · <login>`, refresh button, "updated
  N min ago"); streak card modelled on github-readme-streak-stats (rounded
  card, 1px light border, three columns: year total in blue with "Jan 1 -
  Present", current streak in purple inside a ring with a flame in its top
  gap, longest streak in blue; date ranges in teal); 2×2 tiles (big
  number, label); heatmap (53 columns × 7 rows,
  cell size fit to width, a dim empty cell and 4 GitHub greens by quartile);
  WEEKLY ACTIVITY (26 vertical bars, max labelled); BY WEEKDAY (7 horizontal
  bars, busiest highlighted); a line "Best day N on Mon D · Avg N/day".
  The renderer only draws rectangles, so the rounded corners, ring and
  flame are built from rows and dots of `draw_rect`. Mouse wheel scrolls.

## Errors

- `gh` missing or not logged in (exec fails or stderr mentions auth) →
  panel body says "Run `gh auth login` in a terminal, then refresh."
- Network or API error with earlier data → keep the data, show
  "Couldn't refresh: <first line of error>" under the header.

## Testing

1. Native (`scripts/tests/ide.lua`), no network:
   - `windows` for a fixed `now` (a Wednesday mid-month) gives today's
     midnight, that Monday, the 1st, Jan 1st.
   - `streak`: run ending today; run ending yesterday with today 0; gap
     resets current; longest picks the longest run; each with its dates;
     current crosses Jan 1st; a missing date breaks a run.
   - `weekly`, `weekdays`, `best_day`, `average` on fixed day lists.
   - `parse` on a saved GraphQL fixture gives the expected window totals
     (restricted included), commit counts and kind breakdown, and no lists.
2. UI runtime (`scripts/tests/ui-runtime.lua`): set a model directly,
   toggle the panel, draw it and assert the card, legend, chart and stats
   text; auth-error model shows the login hint.
3. Screenshot of the panel with live data, read before reporting.
4. `docs/ide-features.md` gains a short GitHub panel section.
