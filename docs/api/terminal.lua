---@meta
---Native PTY and VT terminal emulator. Constructed only when a terminal opens.
---@class terminal
local terminal = {}
---@class terminal.options
---@field shell string Shell executable
---@field args? string[] Up to 64 arguments
---@field cwd? string Initial working directory
---@field cols? integer 1..500, defaults to 80
---@field rows? integer 1..200, defaults to 24
---@field scrollback? integer Default 1000; cells capped at 4 MiB
---@param options terminal.options
---@return terminal
function terminal.start(options) end
---Nonblocking; consumes at most 64 KiB and flushes queued keyboard input.
---@return boolean changed
---@return integer? exit_code
---@return boolean pending True while the shell or its output still needs polling
function terminal:poll() end
---@param cols integer
---@param rows integer
function terminal:resize(cols, rows) end
---@param data string
---@return boolean accepted False when the 256 KiB input queue is full
function terminal:write(data) end
---Uses bracketed paste when requested by the application. Maximum 64 KiB.
---@param text string
function terminal:paste(text) end
---VT key codes follow vterm_keycodes.h; modifiers: Shift=1, Alt=2, Ctrl=4.
---@param key integer
---@param modifiers? integer
function terminal:key(key, modifiers) end
---@param codepoint integer
---@param modifiers? integer
function terminal:char(codepoint, modifiers) end
---Rows contain runs {text, zero_based_column, width, fg, bg, flags}.
---Colors are packed RGB integers or -1 for theme defaults. Flags contain
---bold=1, underline=2, reverse=4, italic=8, strike=16. Metadata includes history,
---history_bytes, title, cursor_row/col (one based), and cursor_visible.
---@param history_offset? integer Lines above the current screen
---@return table screen
function terminal:screen(history_offset) end
---Extract a selection using terminal cell widths, including wide characters.
---Coordinates are zero based and the ending column is exclusive.
---@param history_offset integer
---@param start_row integer
---@param start_col integer
---@param end_row integer
---@param end_col integer
---@return string text
function terminal:copy(history_offset, start_row, start_col, end_row, end_col) end
function terminal:clear() end
---Idempotent. Releases PTY/process, emulator, and scrollback resources.
function terminal:close() end
return terminal
