# Commit Browsing and Review Polish — Design

Date: 2026-10-06
Status: approved in chat, awaiting spec review

## Intent

Agents make most commits; the user checks them. Two jobs, weighted equally:
browse recent history and see what each commit did, and review unpushed or
agent-worktree commits before they leave the machine. Today the Graph and
History are flooded by T3 Code checkpoint commits, History rows are one long
monospace line that clips the subject and hides author/date, and a commit
opens as a flat `git show` text view with no file pane.

Success: History shows only real commits, readable at a glance; Enter on a
commit opens it in the same file-pane + diff layout as the review tab, with
syntax-colored diff lines; `[`/`]` step through commits; the review tab lets
the user filter to one commit from a list in its pane.

Out of scope: side-by-side diffs, commit search, author/path filters.

## Data shape

A review target `{root, main_root, branch, base, main, ...}` gains one optional
field:

- `commit = <hash>` → **commit target**: read-only view of one commit.
- no `commit` → **review target**: unchanged behavior.

`Review` branches on `target.commit`. A commit target has no notes, viewed
boxes, fixes banner, uncommitted-changes banner, or push/merge/discard.

Tabs: at most one commit tab and one review tab. Opening a commit retargets
the existing commit tab; `M.show` keeps retargeting only review-mode tabs.
Browsing never touches review state.

## Changes

### `scm/git.lua`: checkpoints hidden

- History log uses `--exclude=refs/t3/* --all` unless
  `config.plugins.scm.show_checkpoints` (default false).
- Command `scm:toggle-checkpoints` flips it, resets history, reloads; the
  sidebar Graph and any open History tab redraw.
- History load also reads `git rev-list @{u}..HEAD` into
  `repo.unpushed[hash] = true`; skipped (empty set) without an upstream.

### `scm/views.lua`: History rows

Each Graph row draws, left to right: lane graphics, subject (clipped with
`…` to leave room for the right side), refs as pills, author (dim), relative
date right-aligned. Unpushed commits get an accent dot before the subject.
The sidebar GRAPH section uses the same unpushed dot.

Keys in History: Up/Down move the selection (scrolling it into view), Enter
opens the selected commit. Click selects and opens.

### `scm/views.lua`: syntax-colored diffs

`Text:draw_row` for `add`/`del`/`ctx` rows draws syntax tokens instead of
one flat color. Syntax from `syntax.get(file.path)`; tokens computed lazily
when a row is first drawn and cached on the row (`row.tokens`); tokenizer
state carried from the previous code row within the same hunk, reset at each
hunk. Plain-text syntax or binary → no tokens, today's drawing. Add/del
background tints unchanged. Applies everywhere `Text` draws diffs (commit
tab, review tab, working-tree diffs).

### `scm/review.lua`: commit target

- `Review:load` for a commit target: `git show --first-parent ... <hash>`;
  unknown hash → empty diff and a "Commit not found" banner.
- Tab name `Commit: <short hash> <subject>`.
- Toolbar: Previous, Next, Copy hash, Compare with HEAD, Revert,
  Cherry-pick, Open on GitHub (moved from `scm.lua` `inspect`).
- Previous/Next walk `repo.history` (the loaded History list, newest
  first): Next = older. Next past the last loaded commit loads the next page
  then moves; Previous at the newest is a no-op. Keys `[` previous, `]` next.
  Unknown hash disables both.
- Left pane: file list as today, without viewed boxes.

### `scm/review.lua`: review target pane

The pane shows a **Commits** list above the files: an "All changes" row,
then each commit (`subject`, relative time). Clicking selects `self.mode`
(the existing "all"/hash mode) and reloads. The `All changes` toolbar picker
is removed. Pane scrolling covers both lists. `ops.commits` also returns the
commit time.

### `scm.lua`

`inspect(repo, commit)` opens the commit tab. The old `show_output` commit
view and its action list are removed.

## Edge cases

- Hash gone (rebased/gc'd) → "Commit not found", Previous/Next disabled.
- Merge commits → first parent diff.
- Root commit → all files added (git default).
- Big commits → existing 20,000-line cap; tokens only for drawn rows.
- No syntax / binary → plain drawing; highlight state resets per hunk.
- No upstream → no unpushed dots.
- Toggle checkpoints → history resets and redraws immediately.

## Testing

1. Native (`scripts/tests/ide.lua`), real temp repos:
   - a `refs/t3/x` commit is excluded from history by default, included with
     `show_checkpoints = true`;
   - `repo.unpushed` equals `git rev-list @{u}..HEAD`;
   - a `.lua` add row's first token is `keyword`; a `.zzz` row has no tokens.
2. UI runtime (`scripts/tests/ui-runtime.lua`):
   - open History, Down, Enter → commit tab with that commit's files;
   - `]` then `[` change the tab name accordingly;
   - the review tab's notes survive using the commit tab;
   - in a review, clicking a pane commit filters files to that commit;
   - an unknown hash shows "Commit not found".
3. Screenshots, read before reporting: History without checkpoints; commit
   tab with colored diff; review tab with the Commits pane.
4. `docs/ide-features.md` Source control and Commit review sections updated.
