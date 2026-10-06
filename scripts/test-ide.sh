#!/bin/sh
set -eu
build_dir=${1:-build}
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
meson test -C "$build_dir" --print-errorlogs
case "$(uname -s)" in
  Darwin|Linux)
    test_dir=$(mktemp -d)
    trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
    mkdir -p "$test_dir/share" "$test_dir/user"
    ln -s "$project_dir/data" "$test_dir/share/lite-xl"
    cp "$project_dir/scripts/tests/ui-runtime.lua" "$test_dir/user/ide_ui_test.lua"
    TREX_SOURCE="$project_dir" TREX_RUNNER="$(cd "$build_dir" && pwd)/src/ide-test-runner" \
    SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software LITE_PREFIX="$test_dir" \
      LITE_USERDIR="$test_dir/user" LITE_XL_RUNTIME=ide_ui_test \
      "$build_dir/src/lite-xl" "$project_dir"
    ;;
esac
