#include "api.h"
#include <vterm.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#ifdef _WIN32
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#include <windows.h>
#else
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <sys/stat.h>
#ifdef __APPLE__
#include <util.h>
#else
#include <pty.h>
#endif
#endif

#define TERMINAL_TYPE "Terminal"
#define HISTORY_BYTES (4 * 1024 * 1024)
#define IO_BYTES (256 * 1024)
#define MAX_COLS 500
#define MAX_ROWS 200

typedef struct { int cols; VTermScreenCell *cells; } HistoryLine;
typedef struct {
  VTerm *vt;
  VTermScreen *screen;
  int rows, cols, dirty, visible, closed, exited, exit_code;
  int history_limit, history_count, history_head;
  size_t history_bytes;
  HistoryLine *history;
  char title[256];
  char input[IO_BYTES];
  size_t input_len;
#ifdef _WIN32
  HPCON console;
  HRESULT (WINAPI *create_console)(COORD, HANDLE, HANDLE, DWORD, HPCON *);
  HRESULT (WINAPI *resize_console)(HPCON, COORD);
  void (WINAPI *close_console)(HPCON);
  HANDLE process, input_pipe, output_pipe, reader, writer;
  CRITICAL_SECTION lock;
  CONDITION_VARIABLE condition;
  int lock_ready, closing, reader_done;
  char output[IO_BYTES];
  size_t output_len;
#else
  int fd;
  pid_t pid;
#endif
} Terminal;

static Terminal *check(lua_State *L) {
  Terminal *t = luaL_checkudata(L, 1, TERMINAL_TYPE);
  luaL_argcheck(L, t->vt && !t->closed, 1, "terminal is closed");
  return t;
}
static int damage(VTermRect rect, void *user) { (void)rect; ((Terminal *)user)->dirty = 1; return 1; }
static int cursor(VTermPos pos, VTermPos old, int visible, void *user) {
  (void)pos; (void)old; Terminal *t = user; t->visible = visible; t->dirty = 1; return 1;
}
static int property(VTermProp prop, VTermValue *value, void *user) {
  Terminal *t = user;
  if (prop == VTERM_PROP_TITLE) {
    if (value->string.initial) t->title[0] = 0;
    size_t used = strlen(t->title), n = value->string.len;
    if (n > sizeof(t->title) - used - 1) n = sizeof(t->title) - used - 1;
    memcpy(t->title + used, value->string.str, n); t->title[used + n] = 0;
  }
  t->dirty = 1; return 1;
}
static void drop_history(Terminal *t) {
  if (!t->history_count) return;
  HistoryLine *line = &t->history[t->history_head];
  t->history_bytes -= line->cols * sizeof(VTermScreenCell);
  free(line->cells); line->cells = NULL;
  t->history_head = (t->history_head + 1) % t->history_limit; t->history_count--;
}
static int pushline(int cols, const VTermScreenCell *cells, void *user) {
  Terminal *t = user;
  size_t bytes = cols * sizeof(*cells);
  if (!t->history_limit || bytes > HISTORY_BYTES) return 1;
  while (t->history_count && (t->history_count == t->history_limit || t->history_bytes + bytes > HISTORY_BYTES)) drop_history(t);
  HistoryLine *line = &t->history[(t->history_head + t->history_count) % t->history_limit];
  line->cells = malloc(bytes);
  if (!line->cells) return 0;
  memcpy(line->cells, cells, bytes); line->cols = cols;
  t->history_count++; t->history_bytes += bytes; t->dirty = 1; return 1;
}
static int popline(int cols, VTermScreenCell *cells, void *user) {
  Terminal *t = user;
  if (!t->history_count) return 0;
  HistoryLine *line = &t->history[(t->history_head + t->history_count - 1) % t->history_limit];
  memset(cells, 0, cols * sizeof(*cells));
  memcpy(cells, line->cells, (cols < line->cols ? cols : line->cols) * sizeof(*cells));
  t->history_bytes -= line->cols * sizeof(*cells); free(line->cells); line->cells = NULL;
  t->history_count--; return 1;
}
static int clear_history(void *user) { Terminal *t = user; while (t->history_count) drop_history(t); return 1; }
static const VTermScreenCallbacks callbacks = {
  .damage = damage, .movecursor = cursor, .settermprop = property,
  .sb_pushline = pushline, .sb_popline = popline, .sb_clear = clear_history
};
static void output(const char *data, size_t len, void *user) {
  Terminal *t = user;
#ifdef _WIN32
  EnterCriticalSection(&t->lock);
#endif
  if (len <= sizeof(t->input) - t->input_len) {
    memcpy(t->input + t->input_len, data, len); t->input_len += len;
  }
#ifdef _WIN32
  WakeAllConditionVariable(&t->condition); LeaveCriticalSection(&t->lock);
#endif
}
#ifdef _WIN32
static DWORD WINAPI reader_thread(void *user) {
  Terminal *t = user; char data[8192]; DWORD n;
  while (ReadFile(t->output_pipe, data, sizeof(data), &n, NULL) && n) {
    size_t offset = 0;
    EnterCriticalSection(&t->lock);
    while (offset < n && !t->closing) {
      while (t->output_len == sizeof(t->output) && !t->closing)
        SleepConditionVariableCS(&t->condition, &t->lock, INFINITE);
      size_t take = n - offset;
      if (take > sizeof(t->output) - t->output_len) take = sizeof(t->output) - t->output_len;
      memcpy(t->output + t->output_len, data + offset, take); t->output_len += take; offset += take;
    }
    LeaveCriticalSection(&t->lock);
  }
  EnterCriticalSection(&t->lock); t->reader_done = 1; LeaveCriticalSection(&t->lock);
  return 0;
}
static DWORD WINAPI writer_thread(void *user) {
  Terminal *t = user; char data[4096]; DWORD n;
  for (;;) {
    EnterCriticalSection(&t->lock);
    while (!t->input_len && !t->closing) SleepConditionVariableCS(&t->condition, &t->lock, INFINITE);
    if (t->closing) { LeaveCriticalSection(&t->lock); break; }
    size_t take = t->input_len < sizeof(data) ? t->input_len : sizeof(data);
    memcpy(data, t->input, take); memmove(t->input, t->input + take, t->input_len - take); t->input_len -= take;
    LeaveCriticalSection(&t->lock);
    size_t offset = 0;
    while (offset < take) {
      if (!WriteFile(t->input_pipe, data + offset, (DWORD)(take - offset), &n, NULL) || !n) return 0;
      offset += n;
    }
  }
  return 0;
}
static wchar_t *wide(const char *text) {
  int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, NULL, 0);
  wchar_t *result = n ? malloc(n * sizeof(wchar_t)) : NULL;
  if (result) MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, result, n);
  return result;
}
#endif
static void close_terminal(Terminal *t) {
  if (t->closed) return;
  t->closed = 1;
#ifdef _WIN32
  if (t->lock_ready) {
    EnterCriticalSection(&t->lock); t->closing = 1; WakeAllConditionVariable(&t->condition); LeaveCriticalSection(&t->lock);
  }
  if (t->process) TerminateProcess(t->process, 0);
  if (t->console) t->close_console(t->console);
  if (t->writer) { CancelSynchronousIo(t->writer); WaitForSingleObject(t->writer, INFINITE); CloseHandle(t->writer); }
  if (t->reader) { CancelSynchronousIo(t->reader); WaitForSingleObject(t->reader, INFINITE); CloseHandle(t->reader); }
  if (t->input_pipe) CloseHandle(t->input_pipe);
  if (t->output_pipe) CloseHandle(t->output_pipe);
  if (t->process) CloseHandle(t->process);
  if (t->lock_ready) DeleteCriticalSection(&t->lock);
#else
  if (t->fd >= 0) { close(t->fd); t->fd = -1; }
  if (t->pid > 0 && !t->exited) {
    kill(-t->pid, SIGHUP);
    if (waitpid(t->pid, NULL, WNOHANG) == 0) { kill(-t->pid, SIGKILL); waitpid(t->pid, NULL, 0); }
  }
#endif
  clear_history(t); free(t->history); t->history = NULL;
  if (t->vt) vterm_free(t->vt);
  t->vt = NULL;
}
static int l_close(lua_State *L) { close_terminal(luaL_checkudata(L, 1, TERMINAL_TYPE)); return 0; }
static int optint(lua_State *L, const char *key, int fallback, int max) {
  lua_getfield(L, 1, key); int n = luaL_optinteger(L, -1, fallback); lua_pop(L, 1);
  return n < 1 ? 1 : n > max ? max : n;
}
static int l_start(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  int rows = optint(L, "rows", 24, MAX_ROWS), cols = optint(L, "cols", 80, MAX_COLS);
  int limit = optint(L, "scrollback", 1000, 10000);
  lua_getfield(L, 1, "shell"); const char *shell = luaL_checkstring(L, -1);
  lua_getfield(L, 1, "cwd"); const char *cwd = luaL_optstring(L, -1, NULL);
  lua_getfield(L, 1, "args");
  const char *args[66] = {shell}; size_t count = 1;
  if (lua_istable(L, -1)) {
    size_t n = lua_rawlen(L, -1); luaL_argcheck(L, n <= 64, 1, "too many shell arguments");
    for (size_t i = 1; i <= n; i++) { lua_rawgeti(L, -1, i); args[count++] = luaL_checkstring(L, -1); lua_pop(L, 1); }
  }
  args[count] = NULL;
#ifndef _WIN32
  struct stat st;
  if (cwd && (stat(cwd, &st) || !S_ISDIR(st.st_mode))) return luaL_error(L, "invalid terminal directory: %s", cwd);
#endif
  Terminal *t = lua_newuserdata(L, sizeof(*t)); memset(t, 0, sizeof(*t));
#ifndef _WIN32
  t->fd = -1;
#endif
  luaL_setmetatable(L, TERMINAL_TYPE);
  t->rows = rows; t->cols = cols; t->history_limit = limit; t->visible = 1;
  t->history = calloc(limit, sizeof(*t->history)); t->vt = vterm_new(rows, cols);
  if (!t->history || !t->vt) { close_terminal(t); return luaL_error(L, "cannot allocate terminal"); }
#ifdef _WIN32
  InitializeCriticalSection(&t->lock); InitializeConditionVariable(&t->condition); t->lock_ready = 1;
  HANDLE child_input = NULL, child_output = NULL;
  if (!CreatePipe(&child_input, &t->input_pipe, NULL, IO_BYTES) || !CreatePipe(&t->output_pipe, &child_output, NULL, IO_BYTES)) {
    if (child_input) CloseHandle(child_input); if (child_output) CloseHandle(child_output);
    close_terminal(t); return luaL_error(L, "cannot create terminal pipes");
  }
  HMODULE kernel = GetModuleHandleW(L"kernel32.dll");
  t->create_console = (void *)GetProcAddress(kernel, "CreatePseudoConsole");
  t->resize_console = (void *)GetProcAddress(kernel, "ResizePseudoConsole");
  t->close_console = (void *)GetProcAddress(kernel, "ClosePseudoConsole");
  if (!t->create_console || !t->resize_console || !t->close_console) {
    CloseHandle(child_input); CloseHandle(child_output); close_terminal(t);
    return luaL_error(L, "The built-in terminal requires Windows 10 version 1809 or later");
  }
  HRESULT hr = t->create_console((COORD){(SHORT)cols, (SHORT)rows}, child_input, child_output, 0, &t->console);
  CloseHandle(child_input); CloseHandle(child_output);
  if (FAILED(hr)) { close_terminal(t); return luaL_error(L, "ConPTY requires Windows 10 version 1809 or later"); }
  SIZE_T bytes = 0; InitializeProcThreadAttributeList(NULL, 1, 0, &bytes);
  STARTUPINFOEXW si = {0}; si.StartupInfo.cb = sizeof(si); si.lpAttributeList = malloc(bytes);
  if (!si.lpAttributeList || !InitializeProcThreadAttributeList(si.lpAttributeList, 1, 0, &bytes) ||
      !UpdateProcThreadAttribute(si.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, t->console, sizeof(t->console), NULL, NULL)) {
    free(si.lpAttributeList); close_terminal(t); return luaL_error(L, "cannot initialize ConPTY");
  }
  /* Quote argv using the CommandLineToArgvW rules, including embedded quotes. */
  char command[32768]; size_t used = 0;
  for (size_t a = 0; a < count; a++) {
    if (used + 3 >= sizeof(command)) goto command_overflow;
    if (a) command[used++] = ' '; command[used++] = '"';
    const char *p = args[a];
    while (*p) {
      size_t slashes = 0; while (*p == '\\') { slashes++; p++; }
      size_t emit = (*p == '"' || !*p) ? slashes * 2 : slashes;
      if (used + emit + 3 >= sizeof(command)) goto command_overflow;
      while (emit--) command[used++] = '\\';
      if (*p == '"') command[used++] = '\\';
      if (*p) command[used++] = *p++;
    }
    command[used++] = '"';
  }
  command[used] = 0;
  wchar_t *cmd = wide(command), *dir = cwd ? wide(cwd) : NULL;
  PROCESS_INFORMATION pi = {0};
  int ok = cmd && (!cwd || dir) && CreateProcessW(NULL, cmd, NULL, NULL, FALSE, EXTENDED_STARTUPINFO_PRESENT, NULL, dir, &si.StartupInfo, &pi);
  free(cmd); free(dir); DeleteProcThreadAttributeList(si.lpAttributeList); free(si.lpAttributeList);
  if (!ok) { close_terminal(t); return luaL_error(L, "cannot launch terminal shell"); }
  t->process = pi.hProcess; CloseHandle(pi.hThread);
  t->reader = CreateThread(NULL, 65536, reader_thread, t, 0, NULL);
  t->writer = CreateThread(NULL, 65536, writer_thread, t, 0, NULL);
  if (!t->reader || !t->writer) { close_terminal(t); return luaL_error(L, "cannot start terminal IO threads"); }
  goto launched;
command_overflow:
  DeleteProcThreadAttributeList(si.lpAttributeList); free(si.lpAttributeList); close_terminal(t);
  return luaL_error(L, "terminal command is too long");
launched:
#else
  struct winsize size = {.ws_row = (unsigned short)rows, .ws_col = (unsigned short)cols};
  t->pid = forkpty(&t->fd, NULL, NULL, &size);
  if (t->pid == 0) {
    setenv("TERM", "xterm-256color", 1); setenv("COLORTERM", "truecolor", 1);
    if (cwd && chdir(cwd)) { perror("terminal chdir"); _exit(127); }
    execvp(shell, (char *const *)args); perror("terminal shell"); _exit(127);
  }
  if (t->pid < 0) { close_terminal(t); return luaL_error(L, "forkpty: %s", strerror(errno)); }
  if (fcntl(t->fd, F_SETFL, O_NONBLOCK) < 0 || fcntl(t->fd, F_SETFD, FD_CLOEXEC) < 0) {
    close_terminal(t); return luaL_error(L, "cannot configure terminal descriptor");
  }
#endif
  vterm_set_utf8(t->vt, 1); t->screen = vterm_obtain_screen(t->vt);
  vterm_screen_enable_altscreen(t->screen, 1);
  vterm_screen_set_callbacks(t->screen, &callbacks, t);
  vterm_screen_set_damage_merge(t->screen, VTERM_DAMAGE_ROW);
  vterm_output_set_callback(t->vt, output, t); vterm_screen_reset(t->screen, 1); t->dirty = 1;
  return 1;
}
static int l_poll(lua_State *L) {
  Terminal *t = check(L); char data[8192]; size_t budget = 65536;
#ifndef _WIN32
  if (t->input_len && t->fd >= 0) {
    ssize_t n = write(t->fd, t->input, t->input_len);
    if (n > 0) { memmove(t->input, t->input + n, t->input_len - n); t->input_len -= n; }
  }
  while (budget && t->fd >= 0) {
    ssize_t n = read(t->fd, data, sizeof(data));
    if (n <= 0) { if (!n || (errno != EAGAIN && errno != EINTR)) { close(t->fd); t->fd = -1; t->input_len = 0; } break; }
    vterm_input_write(t->vt, data, n); budget -= n;
  }
  int status;
  if (!t->exited && waitpid(t->pid, &status, WNOHANG) == t->pid) {
    t->exited = 1; t->exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status); t->dirty = 1;
  }
#else
  while (budget) {
    EnterCriticalSection(&t->lock);
    size_t n = t->output_len < sizeof(data) ? t->output_len : sizeof(data);
    memcpy(data, t->output, n); memmove(t->output, t->output + n, t->output_len - n); t->output_len -= n;
    WakeAllConditionVariable(&t->condition); LeaveCriticalSection(&t->lock);
    if (!n) break;
    vterm_input_write(t->vt, data, n); budget -= n;
  }
  DWORD code;
  if (!t->exited && GetExitCodeProcess(t->process, &code) && code != STILL_ACTIVE) { t->exited = 1; t->exit_code = (int)code; t->dirty = 1; }
#endif
  vterm_screen_flush_damage(t->screen);
  lua_pushboolean(L, t->dirty); t->dirty = 0;
  if (t->exited) lua_pushinteger(L, t->exit_code); else lua_pushnil(L);
#ifdef _WIN32
  EnterCriticalSection(&t->lock);
  lua_pushboolean(L, !t->exited || !t->reader_done || t->output_len || t->input_len);
  LeaveCriticalSection(&t->lock);
#else
  lua_pushboolean(L, !t->exited || t->fd >= 0 || t->input_len);
#endif
  return 3;
}
static int l_resize(lua_State *L) {
  Terminal *t = check(L); int cols = luaL_checkinteger(L, 2), rows = luaL_checkinteger(L, 3);
  luaL_argcheck(L, cols > 0 && cols <= MAX_COLS && rows > 0 && rows <= MAX_ROWS, 2, "invalid terminal size");
  if (cols == t->cols && rows == t->rows) return 0;
#ifdef _WIN32
  t->resize_console(t->console, (COORD){(SHORT)cols, (SHORT)rows});
#else
  struct winsize size = {.ws_row = (unsigned short)rows, .ws_col = (unsigned short)cols};
  if (t->fd >= 0) ioctl(t->fd, TIOCSWINSZ, &size);
#endif
  t->cols = cols; t->rows = rows; vterm_set_size(t->vt, rows, cols); t->dirty = 1; return 0;
}
static int l_write(lua_State *L) {
  Terminal *t = check(L); size_t n; const char *data = luaL_checklstring(L, 2, &n);
#ifdef _WIN32
  EnterCriticalSection(&t->lock);
#endif
  int fits = n <= sizeof(t->input) - t->input_len;
  if (fits) { memcpy(t->input + t->input_len, data, n); t->input_len += n; }
#ifdef _WIN32
  WakeAllConditionVariable(&t->condition); LeaveCriticalSection(&t->lock);
#endif
  lua_pushboolean(L, fits); return 1;
}
static int l_paste(lua_State *L) {
  Terminal *t = check(L); size_t n; const char *data = luaL_checklstring(L, 2, &n);
  luaL_argcheck(L, n <= 65536, 2, "paste exceeds 64 KiB; paste a smaller selection");
#ifdef _WIN32
  EnterCriticalSection(&t->lock);
#endif
  size_t available = sizeof(t->input) - t->input_len;
#ifdef _WIN32
  LeaveCriticalSection(&t->lock);
#endif
  luaL_argcheck(L, available >= n + 32, 2, "terminal input queue is full; retry after the shell consumes input");
  vterm_keyboard_start_paste(t->vt); output(data, n, t); vterm_keyboard_end_paste(t->vt); return 0;
}
static int l_key(lua_State *L) {
  Terminal *t = check(L); int key = luaL_checkinteger(L, 2), mods = luaL_optinteger(L, 3, 0);
  vterm_keyboard_key(t->vt, key, mods); return 0;
}
static int l_char(lua_State *L) {
  Terminal *t = check(L); uint32_t ch = (uint32_t)luaL_checkinteger(L, 2); int mods = luaL_optinteger(L, 3, 0);
  vterm_keyboard_unichar(t->vt, ch, mods); return 0;
}
static int utf8(char *out, uint32_t ch) {
  if (ch < 128) { out[0] = ch; return 1; }
  if (ch < 2048) { out[0] = 0xc0 | (ch >> 6); out[1] = 0x80 | (ch & 63); return 2; }
  if (ch < 65536) { out[0] = 0xe0 | (ch >> 12); out[1] = 0x80 | ((ch >> 6) & 63); out[2] = 0x80 | (ch & 63); return 3; }
  out[0] = 0xf0 | (ch >> 18); out[1] = 0x80 | ((ch >> 12) & 63); out[2] = 0x80 | ((ch >> 6) & 63); out[3] = 0x80 | (ch & 63); return 4;
}
static int color(Terminal *t, VTermColor c, int fg) {
  if ((fg && VTERM_COLOR_IS_DEFAULT_FG(&c)) || (!fg && VTERM_COLOR_IS_DEFAULT_BG(&c))) return -1;
  vterm_screen_convert_color_to_rgb(t->screen, &c); return (c.rgb.red << 16) | (c.rgb.green << 8) | c.rgb.blue;
}
static void integer(lua_State *L, const char *key, int value) { lua_pushinteger(L, value); lua_setfield(L, -2, key); }
static int l_screen(lua_State *L) {
  Terminal *t = check(L); int offset = luaL_optinteger(L, 2, 0);
  if (offset < 0) offset = 0; if (offset > t->history_count) offset = t->history_count;
  lua_createtable(L, t->rows, 4);
  integer(L, "history", t->history_count); integer(L, "history_bytes", (int)t->history_bytes);
  lua_pushstring(L, t->title); lua_setfield(L, -2, "title");
  VTermPos pos; vterm_state_get_cursorpos(vterm_obtain_state(t->vt), &pos);
  integer(L, "cursor_row", pos.row + offset + 1); integer(L, "cursor_col", pos.col + 1);
  lua_pushboolean(L, t->visible && !offset); lua_setfield(L, -2, "cursor_visible");
  for (int row = 0; row < t->rows; row++) {
    lua_newtable(L); int run = 1, start = 0, prev_fg = -2, prev_bg = -2, prev_flags = -1, width = 0;
    char text[MAX_COLS * VTERM_MAX_CHARS_PER_CELL * 4 + 1]; size_t len = 0;
    for (int col = 0; col <= t->cols; col++) {
      VTermScreenCell cell = {0}; int fg = -2, bg = -2, flags = 0;
      if (col < t->cols) {
        int screen_row = row - offset;
        if (screen_row < 0) {
          HistoryLine *line = &t->history[(t->history_head + t->history_count + screen_row) % t->history_limit];
          if (col < line->cols) cell = line->cells[col];
        } else vterm_screen_get_cell(t->screen, (VTermPos){screen_row, col}, &cell);
        if (cell.chars[0] == (uint32_t)-1) continue;
        fg = color(t, cell.fg, 1); bg = color(t, cell.bg, 0);
        flags = cell.attrs.bold | (cell.attrs.underline ? 2 : 0) | (cell.attrs.reverse ? 4 : 0) | (cell.attrs.italic ? 8 : 0) | (cell.attrs.strike ? 16 : 0);
      }
      if (len && (fg != prev_fg || bg != prev_bg || flags != prev_flags || col == t->cols)) {
        lua_createtable(L, 6, 0); lua_pushlstring(L, text, len); lua_rawseti(L, -2, 1);
        int values[] = {start, width, prev_fg, prev_bg, prev_flags};
        for (int i = 0; i < 5; i++) { lua_pushinteger(L, values[i]); lua_rawseti(L, -2, i + 2); }
        lua_rawseti(L, -2, run++); len = 0; width = 0;
      }
      if (col == t->cols) break;
      if (!len) { start = col; prev_fg = fg; prev_bg = bg; prev_flags = flags; }
      if (!cell.chars[0] || cell.attrs.conceal) text[len++] = ' ';
      else for (int i = 0; i < VTERM_MAX_CHARS_PER_CELL && cell.chars[i]; i++) len += utf8(text + len, cell.chars[i]);
      width += cell.width > 0 ? cell.width : 1;
    }
    lua_rawseti(L, -2, row + 1);
  }
  return 1;
}
static int l_copy(lua_State *L) {
  Terminal *t = check(L);
  int offset = (int)luaL_optinteger(L, 2, 0);
  int r1 = (int)luaL_checkinteger(L, 3), c1 = (int)luaL_checkinteger(L, 4);
  int r2 = (int)luaL_checkinteger(L, 5), c2 = (int)luaL_checkinteger(L, 6);
  luaL_argcheck(L, r1 >= 0 && r2 >= r1 && r2 < t->rows && c1 >= 0 && c1 <= t->cols && c2 >= 0 && c2 <= t->cols, 3, "invalid terminal selection");
  if (offset < 0) offset = 0; if (offset > t->history_count) offset = t->history_count;
  luaL_Buffer buffer; luaL_buffinit(L, &buffer);
  for (int row = r1; row <= r2; row++) {
    char text[MAX_COLS * VTERM_MAX_CHARS_PER_CELL * 4]; size_t len = 0;
    int end = row == r2 ? c2 : t->cols;
    for (int col = row == r1 ? c1 : 0; col < end; col++) {
      VTermScreenCell cell = {0}; int screen_row = row - offset;
      if (screen_row < 0) {
        HistoryLine *line = &t->history[(t->history_head + t->history_count + screen_row) % t->history_limit];
        if (col < line->cols) cell = line->cells[col];
      } else vterm_screen_get_cell(t->screen, (VTermPos){screen_row, col}, &cell);
      if (cell.chars[0] == (uint32_t)-1) continue;
      if (!cell.chars[0] || cell.attrs.conceal) text[len++] = ' ';
      else for (int i = 0; i < VTERM_MAX_CHARS_PER_CELL && cell.chars[i]; i++) len += utf8(text + len, cell.chars[i]);
    }
    while (len && text[len - 1] == ' ') len--;
    luaL_addlstring(&buffer, text, len);
    if (row < r2) luaL_addchar(&buffer, '\n');
  }
  luaL_pushresult(&buffer); return 1;
}
static int l_clear(lua_State *L) { Terminal *t = check(L); clear_history(t); vterm_screen_reset(t->screen, 1); t->dirty = 1; return 0; }
static int l_mouse(lua_State *L) {
  Terminal *t = check(L); int row = luaL_checkinteger(L, 2), col = luaL_checkinteger(L, 3);
  vterm_mouse_move(t->vt, row, col, 0);
  if (!lua_isnoneornil(L, 4)) vterm_mouse_button(t->vt, luaL_checkinteger(L, 4), lua_toboolean(L, 5), 0);
  return 0;
}
int luaopen_terminal(lua_State *L) {
  luaL_newmetatable(L, TERMINAL_TYPE);
  luaL_Reg methods[] = {{"poll", l_poll}, {"resize", l_resize}, {"write", l_write}, {"paste", l_paste}, {"key", l_key}, {"char", l_char},
    {"screen", l_screen}, {"copy", l_copy}, {"clear", l_clear}, {"mouse", l_mouse}, {"close", l_close}, {"__gc", l_close}, {NULL, NULL}};
  luaL_setfuncs(L, methods, 0); lua_pushvalue(L, -1); lua_setfield(L, -2, "__index"); lua_pop(L, 1);
  lua_newtable(L); lua_pushcfunction(L, l_start); lua_setfield(L, -2, "start"); return 1;
}
