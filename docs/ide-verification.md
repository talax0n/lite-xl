# Local verification

Verified on macOS arm64 with Clang 17, Lua 5.4.6, SDL 3.2.24, and libvterm 0.3.3.
Both debug and optimized release builds compiled successfully.

`scripts/test-ide.sh build-release` passes:

- 37 checks using real temporary Git repositories, a local bare remote, and PTYs.
- Actual editor plugin loading, sidebar and terminal layout, keyboard routing,
  terminal splits, and session cleanup through SDL's dummy video driver.

Interactive verification in the custom macOS app showed the repository branch
and changed files, rendered the first page of its commit graph, and executed a
typed `printf` command in the built-in terminal with the expected output.

## Resource sample

A ten-second idle sample of the release editor with Source Control and one shell
open measured 0.29 seconds of CPU time, or approximately 2.9% of one CPU core.
Resident memory stayed between 78.17 and 78.23 MiB. A debug-build sample with the
first 100 graph commits also open measured about 118.6 MiB and 3.7% of one core.
These are local process samples, not guaranteed limits. Rendering resolution,
project size, open documents, themes, and other plugins affect the total. Shell
and Git child processes are not included in these figures.

To repeat, open the editor and the desired panes, allow startup work to finish,
then run `python3 scripts/measure-ide.py PID --seconds 10`. The source code caps
scrollback storage, process queues, status previews, history, and output buffers;
the native test includes a flood exceeding the 4 MiB history cap.

## Remaining platform and account checks

Linux and Windows need native-platform execution. The ConPTY backend was added
but was not compiled or exercised on Windows during this session. Authenticated
GitHub publish/PR/review/issue operations were not executed against an account.
GitHub CLI command options were checked against its official manual; those
operations run on explicit user actions and still need authenticated QA.

Design references are [VS Code's Git backend](https://github.com/microsoft/vscode/blob/main/extensions/git/src/git.ts),
[repository model](https://github.com/microsoft/vscode/blob/main/extensions/git/src/model.ts),
[history view](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/contrib/scm/browser/scmHistoryViewPane.ts),
and [PTY backend](https://github.com/microsoft/vscode/blob/main/src/vs/platform/terminal/node/terminalProcess.ts).
The implementation adapts their separation of repository state, asynchronous Git
operations, history views, and PTY sessions to Lite XL's Lua/C architecture.
