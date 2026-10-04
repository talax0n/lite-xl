#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <time.h>
#include <stdlib.h>
#include <stdio.h>
#ifndef _WIN32
#include <unistd.h>
#endif
int luaopen_terminal(lua_State *L);
int luaopen_process(lua_State *L);
static int get_time(lua_State *L) {
  struct timespec now; clock_gettime(CLOCK_MONOTONIC, &now);
  lua_pushnumber(L, now.tv_sec + now.tv_nsec / 1e9); return 1;
}
static int sleep_ms(lua_State *L) {
  int ms = luaL_checkinteger(L, 1); struct timespec delay = {ms / 1000, (ms % 1000) * 1000000}; nanosleep(&delay, NULL); return 0;
}
static int absolute_path(lua_State *L) {
  char *path = realpath(luaL_checkstring(L, 1), NULL);
  if (path) {lua_pushstring(L, path); free(path);} else lua_pushnil(L); return 1;
}
int main(int argc, char **argv) {
  if (argc != 2) return 2;
  lua_State *L = luaL_newstate(); luaL_openlibs(L);
  luaL_requiref(L, "terminal", luaopen_terminal, 1); lua_pop(L, 1);
  luaL_requiref(L, "process", luaopen_process, 1); lua_pop(L, 1);
  lua_newtable(L);
  lua_pushcfunction(L, get_time); lua_setfield(L, -2, "get_time");
  lua_pushcfunction(L, sleep_ms); lua_setfield(L, -2, "sleep");
  lua_pushcfunction(L, absolute_path); lua_setfield(L, -2, "absolute_path"); lua_setglobal(L, "system");
  int rc = luaL_dofile(L, argv[1]);
  if (rc) fprintf(stderr, "%s\n", lua_tostring(L, -1));
  lua_close(L); return rc ? 1 : 0;
}
