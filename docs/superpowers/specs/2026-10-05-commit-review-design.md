# Commit Review — Design

Date: 2026-10-05
Status: approved in chat, awaiting spec review

## Intent

Agents write the code; the user reviews before pushing. Make reviewing local
unpushed commits fast and thorough inside TreX: read every changed file, leave
line notes the agent can act on, occasionally fix things by hand, then push.

Success: open one view, walk all changed files with viewed tracking, leave
notes, hand them to the agent (clipboard or file), commit own fixes, push.

Out of scope (later): GitHub PR review via `gh`, fixup/autosquash of own fixes
into original commits, threaded replies.

## Scope of a review

- Range: `@{upstream}..HEAD`; fallback `origin/HEAD..HEAD`; no remote → prompt
  for a base ref.
- 0 commits ahead → "Nothing to review".
- Detached HEAD or rebase/merge in progress → banner, Push disabled.

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

First write into `.trex/` appends `.trex/` to `$(git rev-parse --git-dir)/info/exclude`
if absent. Nothing in `.trex/` is ever committed; `.gitignore` is untouched.

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

## Refresh

- Reload when HEAD sha changes or `review.md` mtime changes, piggybacking on
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
| `data/plugins/scm/review.lua` | `ReviewView`: layout, file list, picker, notes UI, actions, git calls via `git.enqueue` | ~300 lines |
| `data/plugins/scm.lua` | `scm:review` command, sidebar button | small |
| `data/core/keymap-macos.lua`, `data/core/keymap.lua` | keybinding | 1 line each |
| `scripts/tests/ui-runtime.lua` | end-to-end block | ~40 lines |

`review_notes.lua` interface:

- `parse(text) -> doc` — `{header, notes = {{done, path, from, to, text, snapshot, raw}}, extra}`
- `serialize(doc) -> text`
- `reanchor(note, lines) -> note` — sets `from/to` or `outdated = true`
- `viewed_parse(text) -> map`, `viewed_serialize(map) -> text`
- `copy_text(doc) -> string`

## Testing

1. `review_notes.lua` self-check (`demo()` run headless): parse/serialize
   round-trip incl. ticked, range, general and unknown lines; re-anchor moved
   / gone / duplicate-nearest; viewed reset on blob change.
2. `scripts/tests/ui-runtime.lua` e2e on the existing bare-remote clones:
   2 commits ahead → `scm:review` lists files and 2 commits; add note → file
   written and `.trex/` excluded; third commit edits a viewed file → unviewed
   and note re-anchored; edit + Commit fixes → commit contains only that file,
   unrelated dirty file untouched; Push → range empty, review archived.
3. Headless raster of the review tab to PNG, visually checked.
