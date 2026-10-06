lite_sources = [
    'api/api.c',
    'api/renderer.c',
    'api/renwindow.c',
    'api/regex.c',
    'api/system.c',
    'api/process.c',
    'api/terminal.c',
    'api/utf8.c',
    'arena_allocator.c',
    'custom_events.c',
    'renderer.c',
    'renwindow.c',
    'rencache.c',
    'main.c',
]

#===============================================================================
# Dependencies
#===============================================================================
libm = cc.find_library('m', required : false)
libdl = cc.find_library('dl', required : false)

default_fallback_options = ['warning_level=0', 'werror=false']

# Lua has no official .pc file
# so distros come up with their own names
lua_names = [
    'lua5.4', # Debian
    'lua-5.4', # FreeBSD
    'lua',    # Fedora
]

if get_option('use_system_lua')
    foreach lua : lua_names
        last_lua = (lua == lua_names[-1] or get_option('wrap_mode') == 'forcefallback')
        lua_dep = dependency(lua, required : false,
        )
        if lua_dep.found()
            break
        endif

        if last_lua
            # If we could not find lua on the system and fallbacks are disabled
            # try the compiler as a last ditch effort, since Lua has no official
            # pkg-config support.
            lua_dep = cc.find_library('lua', required : true)
        endif
    endforeach
else
    lua_dep = dependency('', fallback: ['lua', 'lua_dep'], required : true,
        default_options: default_fallback_options + ['default_library=static', 'line_editing=disabled', 'interpreter=false']
    )
endif

pcre2_dep = dependency('libpcre2-8', fallback: ['pcre2', 'libpcre2_8'],
    default_options: default_fallback_options + ['default_library=static', 'grep=false', 'test=false']
)

freetype_dep = dependency('freetype2', fallback: ['freetype2', 'freetype_dep'],
    default_options: default_fallback_options + ['default_library=static', 'zlib=disabled', 'bzip2=disabled', 'png=disabled', 'harfbuzz=disabled', 'brotli=disabled']
)


sdl_dep = dependency('sdl3', static: true)

lite_deps = [lua_dep, sdl_dep, freetype_dep, pcre2_dep, libm, libdl]

lite_sources += 'api/dirmonitor.c'
# dirmonitor backend
if get_option('dirmonitor_backend') == ''
    if cc.has_function('inotify_init', prefix : '#include<sys/inotify.h>')
        dirmonitor_backend = 'inotify'
    elif host_machine.system() == 'darwin' and cc.check_header('CoreServices/CoreServices.h')
        dirmonitor_backend = 'fsevents'
    elif cc.has_function('kqueue', prefix : '#include<sys/event.h>')
        dirmonitor_backend = 'kqueue'
    elif cc.has_function('create_inode_watcher', prefix : '#include<fcntl.h>')
        dirmonitor_backend = 'inodewatcher'
    elif dependency('libkqueue', required : false).found()
        dirmonitor_backend = 'kqueue'
    elif host_machine.system() == 'windows'
        dirmonitor_backend = 'win32'
    else
        dirmonitor_backend = 'dummy'
        warning('no suitable backend found, defaulting to dummy backend')
    endif
else
    dirmonitor_backend = get_option('dirmonitor_backend')
endif

if dirmonitor_backend == 'inotify'
    lite_sources += 'api' / 'dirmonitor' / 'inotify.c'
elif dirmonitor_backend == 'fsevents'
    lite_cargs += '-DLITE_FSEVENTS'
    lite_sources += 'api' / 'dirmonitor' / 'fsevents.c'
elif dirmonitor_backend == 'kqueue'
    lite_sources += 'api' / 'dirmonitor' / 'kqueue.c'
    libkqueue_dep = dependency('libkqueue', required : false)
    if libkqueue_dep.found()
        lite_deps += libkqueue_dep
    endif
elif dirmonitor_backend == 'inodewatcher'
    add_languages('cpp')
    lite_sources += 'api' / 'dirmonitor' / 'inodewatcher.cpp'
elif dirmonitor_backend == 'win32'
    lite_sources += 'api' / 'dirmonitor' / 'win32.c'
else
    lite_sources += 'api' / 'dirmonitor' / 'dummy.c'
endif

message('dirmonitor_backend: @0@'.format(dirmonitor_backend))

lite_rc = []
if host_machine.system() == 'windows'
    windows = import('windows')
    lite_rc += windows.compile_resources('..' / 'resources' / 'icons' / 'icon.rc')
    lite_rc += windows.compile_resources('..' / 'resources' / 'windows' / 'manifest.rc')
elif host_machine.system() == 'darwin'
    add_languages('objc')
    lite_sources += 'bundle_open.m'
endif

vterm_sources = files(
    'vendor/libvterm/src/encoding.c', 'vendor/libvterm/src/keyboard.c',
    'vendor/libvterm/src/mouse.c', 'vendor/libvterm/src/parser.c',
    'vendor/libvterm/src/pen.c', 'vendor/libvterm/src/screen.c',
    'vendor/libvterm/src/state.c', 'vendor/libvterm/src/unicode.c',
    'vendor/libvterm/src/vterm.c',
)
vterm_includes = include_directories('vendor/libvterm/include')
vterm_lib = static_library('vterm', vterm_sources,
    include_directories: vterm_includes, c_args: ['-std=c99'],
)
vterm_dep = declare_dependency(link_with: vterm_lib, include_directories: vterm_includes)
lite_deps += vterm_dep
if host_machine.system() != 'windows'
    lite_deps += cc.find_library('util', required: false)
endif
lite_includes += include_directories('.')

executable('lite-xl',
    lite_sources + lite_rc,
    include_directories: lite_includes,
    dependencies: lite_deps,
    c_args: lite_cargs,
    objc_args: lite_cargs,
    link_args: lite_link_args,
    install_dir: lite_bindir,
    install: true,
    win_subsystem: 'windows',
)

# Exercise the actual Git process API and PTY emulator on Unix hosts.
if host_machine.system() != 'windows'
    ide_tests = executable('ide-test-runner',
        '../scripts/tests/native.c', 'api/terminal.c', 'api/process.c', 'arena_allocator.c',
        include_directories: lite_includes, dependencies: lite_deps,
        c_args: lite_cargs, link_args: lite_link_args, install: false,
    )
    test('source-control-and-terminal', ide_tests,
        args: [meson.project_source_root() / 'scripts/tests/ide.lua'],
        workdir: meson.project_source_root(), timeout: 120, env: {'IDE_TEST_RUNNER': ide_tests.full_path()},
    )
endif
