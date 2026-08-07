project('lookout-marine-gtk', 'c',
  version: '0.1.0',
  license: 'MIT',
  default_options: ['c_std=gnu11', 'warning_level=2'],
)

cc = meson.get_compiler('c')

# Two -Wextra warnings that fire on idiomatic GLib and nothing else: callback
# signatures are fixed by the signal they answer, so most take parameters they
# don't use, and a GActionEntry table is always written with trailing fields
# left out.
add_project_arguments(cc.get_supported_arguments(
  '-Wno-unused-parameter',
  '-Wno-missing-field-initializers',
), language: 'c')

gtk_dep = dependency('gtk4', version: '>= 4.10')
# The core is a static library that deliberately leaves the loader to its host,
# so the executable is what resolves libvulkan.
vulkan_dep = dependency('vulkan')
m_dep = cc.find_library('m', required: false)

# X11 and Wayland are both optional and both compiled in by default: which one
# a session uses is a RUNTIME decision (GDK_BACKEND), so a build with only one
# simply cannot start under the other.
x11_dep = dependency('x11', required: get_option('x11'))
wayland_dep = dependency('wayland-client', required: get_option('wayland'))

if not x11_dep.found() and not wayland_dep.found()
  error('need at least one of x11 or wayland-client — lookout renders Vulkan ' +
        'and has nowhere to present without a native surface')
endif

c_args = []
deps = [gtk_dep, vulkan_dep, m_dep]

if x11_dep.found()
  c_args += '-DLK_HAVE_X11'
  deps += x11_dep
endif
if wayland_dep.found()
  c_args += '-DLK_HAVE_WAYLAND'
  deps += wayland_dep
endif

# ---- the Zig core -----------------------------------------------------------
#
# `zig build lib` builds the tile57 engine and the lookout core from source and
# installs liblookout_marine.a, libtile57.a, lookout.h and tile57.h into
# zig-out/. It is its own build system with its own cache, so it runs as one
# always-stale custom target rather than being modelled file-by-file here.

zig = find_program('zig', required: true)
build_core = find_program('build-core.sh', native: true)
core_root = meson.current_source_dir() / '..'

# The headers ride along as outputs so meson orders this target before the C
# sources compile — an archive-only output is just a link input to meson, and
# lookout.h would not exist yet.
core = custom_target('lookout-core',
  output: ['liblookout_marine.a', 'libtile57.a', 'lookout.h', 'tile57.h'],
  console: true,
  build_always_stale: true,
  command: [
    build_core, core_root, get_option('core-optimize'),
    '@OUTPUT0@', '@OUTPUT1@', '@OUTPUT2@', '@OUTPUT3@',
  ],
)

sources = files(
  'src/main.c',
  'src/lk-app-model.c',
  'src/lk-chart-controller.c',
  'src/lk-chart-view.c',
  'src/lk-hud.c',
  'src/lk-json.c',
  'src/lk-mariner.c',
  'src/lk-native-surface.c',
  'src/lk-pick-report.c',
  'src/lk-raster.c',
  'src/lk-search.c',
  'src/lk-settings-window.c',
  'src/lk-store.c',
  'src/lk-window.c',
)

executable('lookout-marine',
  sources,
  core,
  # lookout.h and tile57.h land in the build dir alongside the archives.
  c_args: c_args + ['-I' + meson.current_build_dir()],
  dependencies: deps,
  install: true,
)

# ---- desktop integration -----------------------------------------------------
#
# The app id is the icon name: main.c passes it to gtk_window_set_default_icon_name
# and the .desktop file names it in Icon=, so all three resolve to the files
# installed here. Everything lands in the hicolor theme, which is the fallback
# every icon theme inherits from — an icon installed there is found whatever
# theme the desktop is using.

app_id = 'org.beetlebug.LookoutMarine'
datadir = get_option('prefix') / get_option('datadir')

# The sizes the brand pack rasterizes. No cache is generated: GTK falls back to
# scanning the theme directories when index.theme has no cache, so the icon
# resolves from a plain `meson install`. Distro packaging runs
# gtk-update-icon-cache in its own post-install.
foreach size : ['16', '32', '48', '64', '128', '256', '512']
  dim = size + 'x' + size
  install_data(
    'data' / 'icons' / 'hicolor' / dim / 'apps' / (app_id + '.png'),
    install_dir: datadir / 'icons' / 'hicolor' / dim / 'apps',
  )
endforeach

# The scalable icon, for the sizes the ladder does not cover.
install_data(
  'data' / 'icons' / 'hicolor' / 'scalable' / 'apps' / (app_id + '.svg'),
  install_dir: datadir / 'icons' / 'hicolor' / 'scalable' / 'apps',
)

install_data(
  'data' / (app_id + '.desktop'),
  install_dir: datadir / 'applications',
)
