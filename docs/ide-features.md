# Source control and terminal

Both features are bundled with the editor. Open the command palette and type
`scm`, `github`, or `terminal` to see their actions.

## Source control

Press **Ctrl+Shift+G**, or click the branch icon in the activity bar at the far
left, to toggle Source Control. The activity bar badge counts changed files
across all repositories. The file explorer hides while this sidebar is open and
returns when you close it.

The sidebar has three collapsible sections. **Repositories** lists each
repository with its branch (`*` when dirty) and incoming/outgoing counts (click to
sync). Click a repository to select it. **Changes** shows the selected
repository's commit message box, Commit button, and grouped changes. With
nothing staged, the button reads **Commit All** and stages everything first.
**Graph** shows recent commits with pull, push, and full-graph actions. Use **Select
Repository** when several repositories are open. **Add Repository** accepts any
local checkout, including a worktree. Workspace folders and nested repositories are discovered automatically when
Source Control opens. The scan visits siblings before deeper folders.
**Scan Repositories** repeats discovery on demand;
it defaults to three levels and 100 folders, skipping hidden directories,
node_modules, vendor, and build. Add repositories manually beyond that limit.

Source Control syncs in the background from startup, even while the panel is
closed. Commits, staging, checkouts, pulls, and pushes from any tool, including
the terminal, show up within about a second. Status also refreshes every
`refresh_interval` seconds (5 by default) and whenever the window regains
focus. Branches with an upstream are fetched quietly every `fetch_interval`
seconds (180 by default; 0 disables it), so incoming/outgoing counts stay
current.

Click a changed file to review its colored unified diff. Hover a file to stage
(`+`), unstage (`−`), or discard it; hover a group to stage or unstage all. Right-click a file for its actions. In a diff, click a hunk
before choosing **Stage hunk** or **Unstage hunk**. Changes shown by Git are saved
changes on disk; save your editor buffers before staging.

**Commit** opens the message prompt and commits the index. **Pull** only performs
a fast-forward. For divergent history, choose **Merge** or **Rebase** explicitly.
**Sync** pulls successfully before pushing. Use **Push Set Upstream** for a new
branch. The action menu also provides fetch, clone/init, branches, amend, tags,
stashes, remotes, worktrees, and file history. Discard, amend, revert, cherry-pick,
and rebase actions display confirmations for their changes.

**Graph** loads 100 commits at a time, with parent edges, merge lanes, hashes,
branch/tag labels, messages, authors, and dates. Click a commit, or move with
Up/Down and press Enter, to open it in the commit tab: changed files on the left,
its message and syntax-colored diff on the right, and Copy hash, Compare with
HEAD, Revert, Cherry-pick and GitHub in the toolbar. **[** and **]** (or
Previous/Next) step to the newer and older commit. A dot marks commits not
pushed yet. T3 Code checkpoint commits (`refs/t3/*`) are hidden; **Toggle
checkpoints** shows them. Click
**Load next 100 commits** at the bottom for another page. The view keeps at most
2,000 commits and 32 simultaneous graph lanes per repository. A notice marks
commits whose additional lanes cannot be displayed. Open history again after changing branches or
adding commits to reload it.

Conflicted files offer base/current/incoming previews and **Use current** or
**Use incoming**. Edit the working file to combine changes manually, then stage
and commit it. Rebase continue/abort and merge abort are available in the action
menu. This version uses separate previews and editable files, rather than a
three-pane merge editor.

## GitHub

Install Git for source control and [GitHub CLI](https://cli.github.com/) for
GitHub actions. Existing SSH keys and Git credential helpers remain in use.
**GitHub Sign In** runs the CLI's browser sign-in flow in a terminal session.
Credentials remain managed by Git/GitHub CLI. Authentication Status displays
its diagnostic output without exposing stored tokens.

GitHub actions include publishing a repository with an explicit public/private
choice, browsing the repository and commits, listing and creating pull requests,
checking out a pull request, viewing its diff and checks, submitting reviews,
and listing/creating issues. Publishing and review operations run only when you
choose their actions. GitHub Actions administration, releases, and repository
settings are accessible through the integrated terminal or GitHub website.

### GitHub activity panel

The chart icon in the activity bar (`github:toggle`) opens a panel on the right
with your own GitHub activity. A streak card at the top shows this year's total
commits and your current and longest streaks with their date ranges.
Below it are contribution counts for today, this week, this month and this
year, a heatmap of the last year, weekly totals for the last
26 weeks, totals by weekday, and your best day and daily average.

Data comes from the signed-in GitHub CLI (`gh api graphql`). The panel refreshes on first open, every 10 minutes while visible, and
from its Refresh button. Each count is one number, the same figure as the
profile graph: commits, pull requests, issues and reviews, private organization
work included. The heatmap and streak use
GitHub's calendar days, which follow your local time zone, over the last year like the profile
graph, so streaks carry across January 1st and the longest streak is the
longest in the last year. Weekday totals, best day and average count this
year only. If `gh` is missing or signed out, the
panel asks you to run `gh auth login`. Set `config.plugins.github.width` to
change its width.

## Database

The **Database** item in the activity bar toggles a right-side panel that lists
connections, then schemas, tables and columns. Each level loads when you expand
it. Click a table to open its first 100 rows in a results tab.

Click **+** (or run `database:add-connection`) to add a connection. You enter a
name and then a URL:

- `postgres://user:pass@host:port/db?params` (or `postgresql://`), run through `psql`
- `sqlite:///abs/path.db`, or `sqlite:relative.db` relative to the project root, run through `sqlite3`

Connections are saved as `name = url` lines in `databases.conf` in the user
directory. The file has mode 600, and passwords are stored in plain text. To
edit, delete or refresh a connection, right-click it or click its **…** button.
If the project root's `.env` defines `DATABASE_URL`, the panel also shows that
connection as read-only, named after the project folder plus ` (.env)`.

`database:run-query` runs the selection, or the whole document, against the
selected connection and shows the result in a results tab. In `.sql` files,
**Cmd+Return** runs it. TreX asks for confirmation before it runs a statement
that does not start with `select`, `with`, `explain`, `show`, `pragma`,
`values` or `table`. Table browsing is read-only. Statements time out after 30
seconds, and the Postgres password goes to `psql` through `PGPASSWORD`, never
on the command line.

## Terminal

Press **Ctrl+`** to toggle the terminal, or **Ctrl+Shift+`** for a new session.
**Terminal Open Here** starts in the active file's folder. **SCM Terminal** starts
in the selected repository. **New Profile** lets you choose a shell executable.

The bottom panel has session tabs, `+`, split, close, and hide actions. Drag its
divider to resize it. Click inside a split to focus that shell. Closing a session
terminates its processes; hiding retains sessions. Shell sessions continue while
the window is unfocused. Shell processes are not restored after quitting.

Use **Ctrl+Shift+C/V** to copy/paste, or **Cmd+C/V** on macOS. Drag to select text;
copy with no selection copies the visible screen. The wheel scrolls history.
Ctrl+C interrupts the foreground program. Colors, UTF-8, wide characters,
alternate screens, cursor keys, shell completion, and bracketed paste use the
native terminal emulator. The default font may lack some prompt/emoji glyphs.
Terminal mouse reporting is not currently forwarded by the Lua view; use
keyboard controls for full-screen applications.

The native backend uses Unix PTYs on macOS/Linux and ConPTY on Windows 10 1809
or later. Older Windows hosts can load the editor but cannot open a terminal.

## Resource limits and configuration

No Electron, browser view, Node runtime, or persistent Git daemon is added.
Git operations have a global two-process limit and run serially per repository.
Automatic status refresh runs only while Source Control is visible and the
window is focused. The selected repository refreshes at most every five seconds;
other repositories refresh in rotation no faster than every fifteen seconds.
Saving a tracked file marks its repository for refresh. Network operations are
explicit, with no automatic fetch. History loads on demand. Views draw visible
rows and cache terminal snapshots until output or dimensions change. Text diff
and command-output previews reuse one tab per editor pane.

Each terminal has a lazily populated scrollback ring capped at 4 MiB of cells
and 1,000 lines by default. Input is capped at 256 KiB, paste at 64 KiB, and each
poll consumes at most 64 KiB of output. Terminal output uses backpressure instead
of growing an unlimited buffer. At most eight sessions can be open by default.
Git output is capped at 8 MiB, status previews at 10,000 path entries, and text
previews at 20,000 lines. Large selections
can be inspected in the terminal.

Customize in your user init.lua:

```lua
local config = require "core.config"
config.plugins.scm.width = 280
config.plugins.scm.refresh_interval = 10
-- Optional executable paths, useful for apps launched outside your shell:
-- config.plugins.scm.git_path = "/usr/bin/git"
-- config.plugins.scm.gh_path = "/opt/homebrew/bin/gh"
config.plugins.terminal.height = 240
config.plugins.terminal.scrollback = 500
config.plugins.terminal.max_sessions = 4
config.plugins.terminal.shell = "/bin/zsh"
config.plugins.terminal.args = {"-l"}
```

## Build the custom macOS app

Install Xcode Command Line Tools if they are missing (`xcode-select --install`).
With Homebrew installed, install the build tools and dependencies:

```sh
brew install meson ninja pkgconf cmake sdl3 pcre2
# Optional, required for the GitHub-specific commands:
brew install gh
```

From the repository directory, configure a fresh build directory. Using a new
directory avoids reusing paths from the temporary tooling used for the initial
local build. Lua 5.4 and FreeType are downloaded and built by Meson when needed;
libvterm is included in this repository.

```sh
meson setup build-macos --buildtype=release -Dportable=true -Dbundle=false
meson compile -C build-macos
scripts/test-ide.sh build-macos
scripts/package-custom-macos.sh build-macos
open "build-macos/TreX.app"
```

For later rebuilds, repeat the compile, test, and package commands. Quit the
custom app before replacing its bundle. The package has an ad-hoc local
signature and a separate application identifier.

To install it, quit both editor apps, then copy `TreX.app` from the
build directory into `/Applications` using Finder. Launch that copy and check
Source Control and the terminal. You can then move the original `Lite XL.app`
to Trash and replace its Dock shortcut with the custom app. Keep your user
configuration directory; both applications use the existing Lite XL settings
unless `LITE_USERDIR` overrides it. Removing the application bundle does not
require deleting settings or projects.

The already-built app is `build-release/TreX.app`. It can be copied
into Applications without rebuilding. This build links to Homebrew PCRE2 at
`/opt/homebrew/opt/pcre2/lib/libpcre2-8.0.dylib`, so keep PCRE2 installed. Builds
made with other dependency configurations may also need those libraries on the
machine. Git and GitHub CLI remain external tools. A local build is not a
notarized distribution for other Macs.

## Verification

Build normally with Meson, then run `scripts/test-ide.sh build`. The native tests
use temporary repositories and a local bare remote. They exercise real status,
staging, hunk patches, commits, merge graphs, worktrees, fetch/push/pull, conflicts,
PTY input, UTF-8, colors, resize, alternate screens, scrollback limits, Ctrl+C,
and process cleanup. The second test boots the actual editor with SDL's dummy
video driver and checks plugin loading, panes, keyboard input, splits, and
cleanup. These tests run on Unix hosts and never publish to GitHub.

The macOS build and interactive graph/terminal were verified locally. Linux and
Windows backends still need verification on those operating systems. GitHub
account operations need authenticated testing before treating that integration
as fully verified.

## Commit review

Press **Cmd+Shift+R** (Ctrl+Shift+R elsewhere), or click **Review N unpushed
commits** in Source Control, to review work before it leaves your machine.
TreX lists the main checkout when it is ahead of its upstream, and every git
worktree with commits ahead of the main checkout's branch (agent worktrees from
t3code, Claude Code and others are found through `git worktree list`).

The left pane lists changed files. Click the box or press **v** to mark a file
viewed and jump to the next one; viewed files collapse, and become unviewed
again when a new commit changes them. The **Commits** list at the top of the
left pane filters the diff to one commit; **All changes** shows the whole range.

Click a line number (or select a line and press **c**; Shift+click selects a
range) to leave a note. Notes are saved to `.trex/review.md` in the checkout,
which git ignores through `info/exclude`. **Copy notes** puts the open notes
on the clipboard for your agent; the agent can also read the file and tick
`[x]` when done. Notes follow their code when it moves and are marked outdated
when it disappears.

Double-click a line to open the file beside the review. Files you save while
reviewing appear in an **Uncommitted fixes** banner; **Commit fixes** commits
only those files as `fix: address review`.

Finish with **Push** (main checkout), or for a worktree **Merge into
<branch>** (then remove the worktree), **Push branch**, or **Discard**, which
deletes the worktree and its branch. Finished reviews are archived to
`.trex/reviews/` in the main checkout.

## Languages and language servers

TreX highlights TypeScript/TSX/JSX, JSON, SCSS, Rust, Go, Zig, shell, YAML,
TOML, Dockerfile, Makefile, SQL, `.env` and diffs out of the box.

For TypeScript/JavaScript, JSON, Rust, Go, Zig, shell, YAML, TOML and
Dockerfiles TreX also runs a language server. Errors and warnings appear as
wavy underlines with a gutter dot; rest the mouse on one for the message.
The left end of the status bar shows the file's error and warning counts;
click them, or press **Cmd+Shift+M**, for the **Problems** tab. **F8** /
**Shift+F8** step through problems in the file.

Navigation: **F12** or **Cmd+click** goes to the definition, **Shift+F12**
lists references, resting the mouse on a symbol (or **Cmd+I**) shows its
type and docs, **Cmd+Shift+O** jumps to a symbol in the file and **Cmd+T**
searches symbols in the project.

When a server is missing, TreX offers to install it into
`~/.local/share/trex/lsp` (npm or `go install`; Zig's `zls` comes from
Homebrew). The status bar shows the server state; click it to restart a
crashed server or see its log (`lsp:show-log`).
