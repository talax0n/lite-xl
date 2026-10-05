# Commit Review — Design

Date: 2026-10-05
Status: approved in chat, awaiting spec review

## Intent

Agents write the code; the user reviews before pushing. Make reviewing local
unpushed commits fast and thorough inside TreX: read every changed file, leave
line notes the agent can act on, occasionally fix things by hand, then push.

Success: open one view, walk all changed files with viewed tracking, leave
notes, hand them to the agent (clipboard or file), commit own fixes, push.

Agents often work in their own git worktrees (t3code `~/.t3/worktrees`,
Claude Code `.claude/worktrees`, …). Each worktree branch is a review target
with its own finish actions: merge, push, or discard.

Out of scope (later): GitHub PR review via `gh`, fixup/autosquash of own fixes
into original commits, threaded replies.

## Review targets

A target is `{root, branch, base}`. Targets come from
`git worktree list --porcelain` run in the current repo, so every worktree is
found regardless of where the agent created it.

- **Main checkout**: base = `@{upstream}`; fallback `origin/HEAD`; no remote →
  prompt for a base ref. Range `base..HEAD`.
- **Worktree**: base = the main checkout's current branch (e.g. `master`).
  Range = `git diff <base>...<branch>` (from the merge-base), commits
  `<base>..<branch>`. Base is changeable from the toolbar.
- Bare entries and the worktree list's `prunable` entries are skipped.
- Locked worktrees are listed; Discard is disabled for them.

`scm:review` with more than one target ahead > 0 → quick picker:
`⎇ agent/fix-auth  · 3 commits · dirty   ~/.t3/worktrees/lite-xl/fix-auth`.
One target → opens directly. In the view, a target picker sits left of the
commit picker: `[⎇ agent/fix-auth ▾] [All changes ▾]`.

### Dirty worktrees

If the target has uncommitted changes, a banner shows
`Agent left uncommitted changes: N files [Show]`; Show opens the existing
working-tree diff view. Merge/Push ask for confirmation while dirty, since the
uncommitted work would not be included.

## Scope of a review

- 0 commits ahead → "Nothing to review".
- Detached HEAD or rebase/merge in progress → banner, Push/Merge disabled.

## Entry points

- Command `scm:review`, keybinding `cmd+shift+r` (mac) / `ctrl+shift+r`.
- Source Control sidebar button "Review N commits", shown only when ahead > 0.

## View

One tab, `ReviewView` (in `data/plugins/scm/review.lua`), subclass of
`views.Text` so the existing diff renderer (file headers, hunks, gutter,
tinted rows, commit card) is reused.

```
┌ toolbar: [All changes ▾] 3/7 reviewed │ 4 notes │ Copy notes  Push ┐
├─ files (220px) ─────┬─ diff ──────────────────────────────────────────┤
│ ✓ scm.lua   +40 −3  │ scm.lua                                 +40 −3  │
│ ○ views.lua +12 −8  │ @@ ...                                          │
│ ● review.lua  new   │  42 + local x = …                               │
│                     │      ┃ rename this, too vague       [edit][del] │
└─────────────────────┴─────────────────────────────────────────────────┘
```

- Commit picker: "All changes" = combined `base..HEAD` diff (default); each
  commit by subject = that commit's `git show` (card + diff).
- File list: ✓ viewed, ○ unviewed, ● has open notes. Click name → scroll to
  file; click mark → toggle viewed.
- Key `v`: mark current file viewed, jump to next unviewed.
- Viewed files collapse to their header row.
- Toolbar counter "N/M reviewed", open-note count.

## Notes

- Add: click a diff line or press `c` on the selected line → prompt. Select
  lines then add → range note `path:42-48`. "General note" button → no anchor.
- Notes on deleted lines anchor to the nearest new-side line, so every
  location exists in HEAD.
- Inline under the anchored line as an accent-barred band with [edit] [del].

### File `.trex/review.md`

Human- and agent-editable:

```markdown
# Review: master · 98bab82..f8ec323

- [ ] `data/plugins/scm.lua:42` rename this, too vague
  > local x = foo()
- [ ] `data/plugins/scm/views.lua:110-118` layout recomputed every frame, cache it
  > function Text:layout()
- [x] `src/main.c:10` include not needed
  > #include <string.h>
- [ ] (general) no test for parse.hunks edge cases
```

- `> ` line = snapshot of the first anchored line (trimmed), used to
  re-anchor.
- `[x]` = resolved (the agent may tick it). Resolved notes render dimmed and
  are excluded from Copy.
- Lines the parser does not recognise are kept verbatim on save and ignored.
- File is re-read when its mtime changes (checked on the existing SCM poll and
  on view focus).

### Re-anchoring

On load and on every reload, for each note with an anchor, against the HEAD
version of the file:

1. Line at the stored number matches the snapshot → keep.
2. Else search ±50 lines for the snapshot; nearest match wins → move the note
   and rewrite the line number.
3. Not found → mark **outdated** (dimmed, listed, never deleted).

In single-commit mode, a clicked line is stored with the snapshot and its HEAD
line resolved through the same search.

### Viewed state `.trex/viewed`

One `path<TAB>blob-sha` per line (blob of the file at HEAD). A file is viewed
only if its current HEAD blob equals the stored sha, so new agent commits that
touch a file reset it to unviewed while untouched files stay ✓.

### Git hygiene

Notes and viewed state live in `<target root>/.trex/`, so each worktree has
its own review. First write appends `.trex/` to
`$(git rev-parse --git-common-dir)/info/exclude` if absent; that file is
shared by all worktrees of the repo. Nothing in `.trex/` is ever committed; `.gitignore` is untouched.

## Copy notes

Clipboard text:

```
Address these review notes (also in .trex/review.md; tick [x] when done):
<all open, non-outdated and outdated notes in file order, general last>
```

## Own fixes

- "Open at line" / double-click a diff line → open the real file at that line
  in a split to the right; review tab stays.
- The review tracks files the user saved from TreX since the review opened.
  If any are dirty, a strip shows `Uncommitted fixes: N files [Commit fixes]`.
- Commit fixes: prompt with editable message `fix: address review`, then
  `git add -A -- <only those files>` and `git commit`. Other dirty files are
  never included.
- The new commit appears in the range on reload like any other commit.

## Push

- Toolbar Push is highlighted when all files are viewed and no open notes.
- Otherwise confirm: "N files unviewed, M open notes. Push anyway?"
- Reuses the existing push operation (with set-upstream fallback).
- On success: range empty → "All reviewed and pushed"; `review.md` moved to
  `.trex/reviews/<YYYY-MM-DD>-<shortsha>.md`; `.trex/viewed` cleared.

## Finish actions for worktree targets

Shown in the toolbar instead of Push when the target is a worktree. Same
"N files unviewed, M open notes" confirm as Push when the review is incomplete.

- **Merge into `<base>`**: runs in the main checkout. Refuses if the main
  checkout is not on `<base>` or has uncommitted changes (error names the
  problem). `git merge --ff-only <branch>`; if not fast-forwardable,
  `git merge --no-edit <branch>`; conflicts → stop and open Source Control on
  the main checkout. On success confirm "Remove worktree and delete branch?"
  → `git worktree remove <root>` + `git branch -d <branch>`.
- **Push branch**: in the worktree, `git push -u origin <branch>`. Worktree
  kept.
- **Discard**: confirm "Delete worktree <root> and branch <branch> with N
  unmerged commits? This cannot be undone." → `git worktree remove --force
  <root>` + `git branch -D <branch>`.

Before a worktree is removed (merge or discard), its `.trex/review.md` is
archived to the main checkout's `.trex/reviews/<YYYY-MM-DD>-<branch>-<shortsha>.md`,
because the worktree folder is deleted. After removal the view switches to the
next target, or shows "Nothing to review".

## Refresh

- Target list re-read on the same poll, so new agent worktrees appear.
- Reload when the target's HEAD sha changes or `review.md` mtime changes, piggybacking on
  the existing background SCM poll — no new watcher.
- Preserve scroll position, current file and viewed marks across reloads.

## Errors

- Range resolution fails → base-ref prompt.
- Diff over 20k lines → existing truncation note; viewed tracking still per file.
- Git command failure → `core.error` with git's stderr, view stays usable.

## Components

| File | Role | Size |
|---|---|---|
| `data/plugins/scm/review_notes.lua` | pure: parse/serialize `review.md`, re-anchor, viewed state, copy text. No UI, no git. | ~120 lines |
| `data/plugins/scm/review.lua` | `ReviewView`: targets, layout, file list, pickers, notes UI, actions, git calls via `git.enqueue` | ~380 lines |
| `data/plugins/scm.lua` | `scm:review` command, sidebar button | small |
| `data/core/keymap-macos.lua`, `data/core/keymap.lua` | keybinding | 1 line each |
| `scripts/tests/ui-runtime.lua` | end-to-end block | ~40 lines |

`review_notes.lua` interface:

- `parse(text) -> doc` — `{header, notes = {{done, path, from, to, text, snapshot, raw}}, extra}`
- `serialize(doc) -> text`
- `reanchor(note, lines) -> note` — sets `from/to` or `outdated = true`
- `viewed_parse(text) -> map`, `viewed_serialize(map) -> text`
- `copy_text(doc) -> string`
- `parse_worktrees(porcelain) -> {{root, branch, head, bare, locked, prunable}}`

## Testing

1. `review_notes.lua` self-check (`demo()` run headless): parse/serialize
   round-trip incl. ticked, range, general and unknown lines; re-anchor moved
   / gone / duplicate-nearest; viewed reset on blob change; worktree porcelain
   parsing incl. detached, locked, bare, prunable.
2. `scripts/tests/ui-runtime.lua` e2e on the existing bare-remote clones:
   2 commits ahead → `scm:review` lists files and 2 commits; add note → file
   written and `.trex/` excluded; third commit edits a viewed file → unviewed
   and note re-anchored; edit + Commit fixes → commit contains only that file,
   unrelated dirty file untouched; Push → range empty, review archived.
   Worktrees: `git worktree add -b agent/x` with 1 commit → listed as target
   with base `main`; dirty file → banner; Merge into main → main has the
   commit, worktree and branch gone, review archived in main's `.trex/reviews`;
   second worktree → Discard → removed, branch deleted; locked worktree →
   Discard disabled.
3. Headless raster of the review tab to PNG, visually checked.
