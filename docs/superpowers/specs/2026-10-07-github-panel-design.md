# GitHub Panel — Design

Date: 2026-10-07
Status: approved in chat, awaiting spec review

## Intent

The user wants to see their own GitHub activity without leaving TreX: how
much they contributed today and over longer windows, their contribution
heatmap and streak, and the PRs and pushes that need attention. It lives in
a panel docked on the right.

Success: one click on a new activity-bar icon opens a right-side panel
showing counts for Today / This week / This month / This year, a year
heatmap with current and longest streak, and three clickable lists (my open
PRs, PRs waiting for my review, my recent pushes). Clicking a row opens it
on GitHub.

Out of scope: profile card, top repos, other users, writing to GitHub
(merging, commenting), local-git counts.

## Data source

All data comes from the `gh` CLI already logged in on the machine
(`gh api graphql`, `gh api /users/<login>/events`). No token handling in
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
- Each tile has a second line "N commits visible" from
  `totalCommitContributions`.

## Data shape

```lua
model = {
  login = "talax0n",
  windows = {            -- in this order
    {label = "Today",      contributions = 85, commits = 0},
    {label = "This week",  ...}, {label = "This month", ...}, {label = "This year", ...},
  },
  days = {{date = "2026-01-01", count = 3}, ...},  -- year calendar, oldest first
  streak = {current = 12, longest = 40},
  prs = {{title, repo, url, updated}},             -- my open PRs, newest first, max 10
  reviews = {{title, repo, url, updated}},         -- review-requested:@me, open, max 10
  pushes = {{repo, branch, url, at}},              -- PushEvents, newest first, max 10
  fetched_at = <os.time>, error = nil | "message",
}
```

## Units

### `data/plugins/github/data.lua` (pure, no editor or network)

- `windows(now)` → the four `{label, from}` windows as UTC ISO strings,
  computed from local midnight: today, Monday of this week, the 1st of this
  month, Jan 1st of this year.
- `query(windows)` → one GraphQL query string with aliased
  `contributionsCollection(from:)` per window (to defaults to now), the
  year `contributionCalendar` (on the This-year alias),
  `viewer.login`, `viewer.pullRequests(states: OPEN, first: 10,
  orderBy: UPDATED_AT DESC)` and `search(query: "is:pr is:open
  review-requested:@me", type: ISSUE, first: 10)`.
- `parse(graphql_json, events_json)` → `model` (without `fetched_at`).
  Pushes keep only `PushEvent`; branch is `payload.ref` without
  `refs/heads/`; url is `https://github.com/<repo>/commit/<payload.head>`.
- `streak(days, today)` → `{current, longest}`. Current counts back from
  today; if today is 0 it counts back from yesterday (today isn't over).
- Uses `plugins.lsp.json` for decoding.

### `data/plugins/github.lua` (panel)

- `GitHub` view docked right like `Backlog`
  (`get_primary_node():split("right", panel, {x = true}, true)`), width
  `config.plugins.github.width` (default 320).
- Command `github:toggle`; activity-bar entry in
  `data/plugins/toolbarview.lua` after Backlog, symbol from the icon font,
  active when the panel is visible.
- Fetch runs in a coroutine through `scm/git.lua`'s `exec(cwd, "gh",
  args)` (non-blocking, finds `/opt/homebrew/bin/gh`): GraphQL first, then
  `api /users/<login>/events?per_page=50`.
- Refresh on first open, every 10 minutes while visible, and on the
  header refresh button. One fetch at a time.
- Layout, top to bottom: header (`GITHUB · <login>`, refresh button, "updated
  N min ago"), 2×2 tiles (big contributions number, label, "N commits
  visible"), heatmap (53 columns × 7 rows, cell size fit to width, 5 shades
  of `style.accent` by quartile), streak line, then sections MY PULL
  REQUESTS, REVIEW REQUESTS, RECENT PUSHES. Rows show title / repo and a
  relative time; empty sections say "None". Long text cut with `…`.
- Clicking a row opens its url with `open` (`system.exec`). Mouse wheel
  scrolls.

## Errors

- `gh` missing or not logged in (exec fails or stderr mentions auth) →
  panel body says "Run `gh auth login` in a terminal, then refresh."
- Network or API error with earlier data → keep the data, show
  "Couldn't refresh: <first line of error>" under the header.
- Partial: events call fails but GraphQL works → show everything else,
  RECENT PUSHES says "Unavailable".

## Testing

1. Native (`scripts/tests/ide.lua`), no network:
   - `windows` for a fixed `now` (a Wednesday mid-month) gives today's
     midnight, that Monday, the 1st, Jan 1st.
   - `streak`: run ending today; run ending yesterday with today 0; gap
     resets current; longest picks the longest run.
   - `parse` on a saved fixture (GraphQL + events JSON) gives the expected
     window totals (restricted included), commit counts, PR rows, and push
     rows (non-PushEvents dropped, branch stripped, commit url).
2. UI runtime (`scripts/tests/ui-runtime.lua`): set a model directly,
   toggle the panel, draw it, click the first PR row and assert the opened
   url (stub the opener); auth-error model shows the login hint.
3. Screenshot of the panel with live data, read before reporting.
4. `docs/ide-features.md` gains a short GitHub panel section.
