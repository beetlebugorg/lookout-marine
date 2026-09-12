# The shell's test suites. Two tiers:
#
# - unit: pure logic (readout geometry, JSON, the store). No display.
# - widget: real GTK widgets driven headless. Each test binary skips itself
#   (exit 77) when no display can be opened; run-headless.sh supplies Xvfb
#   with the cairo renderer where the session has none.
#
# Every test links the same objects the app links, so what a test proves is
# what the app runs.

# Three real S-57 cells, the ones the core's bake gate uses. A scan of a
# folder reads the cells themselves, so a name on an empty file proves
# nothing: the engine reports no chart for it, which is correct and useless to
# test with.
test_c_args = shell_c_args + [
  '-DLK_TEST_CELLS="' + meson.project_source_root() / '..' / 'test' / 'cells' + '"',
]

unit_tests = ['bands', 'coastline', 'format', 'import', 'json', 'library', 'noaa', 'store', 'pick']

foreach name : unit_tests
  exe = executable('test-' + name,
    'test-@0@.c'.format(name),
    core_headers,
    link_with: [lkshell] + core_archives,
    include_directories: include_directories('../src'),
    c_args: test_c_args,
    dependencies: deps,
  )
  test(name, exe, suite: 'unit', timeout: 60)
endforeach

widget_tests = ['coverage', 'hud', 'window', 'pick-report']
headless = find_program ('run-headless.sh')

foreach name : widget_tests
  exe = executable('test-' + name,
    'test-@0@.c'.format(name),
    core_headers,
    link_with: [lkshell] + core_archives,
    include_directories: include_directories('../src'),
    c_args: test_c_args,
    dependencies: deps,
  )
  # Serial: each widget test spawns its own Xvfb through `xvfb-run -a`, and two
  # of those racing for a display number is what makes one die.
  test(name, headless, args: [exe], suite: 'widget', timeout: 120, is_parallel: false)
endforeach
