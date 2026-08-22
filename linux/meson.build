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
# charttable decodes raster tiles and writes snapshots through these, so the
# core archive carries the references and the app has to name the libraries.
png_dep = dependency('libpng16')
webp_dep = dependency('libwebp')
# Chart links: the shell fetches a publisher's MapLibre style and serves its
# tiles (lookout does no networking), which takes an HTTP client and a JSON
# writer — lk-json.c only reads.
soup_dep = dependency('libsoup-3.0')
json_dep = dependency('json-glib-1.0')
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
deps = [gtk_dep, vulkan_dep, png_dep, webp_dep, soup_dep, json_dep, m_dep]

# Where installed data lands. Named here rather than in the desktop-integration
# section below because the plugin directory is BAKED INTO the binary, so the
# compile line needs it.
datadir = get_option('prefix') / get_option('datadir')

# The core plugins travel with the install. Own ship, AIS, NMEA 0183, Signal K
# and laylines are all wasm plugins, so a build that ships none is a
# chartplotter with no boat and no traffic. build-core.sh stages the shipped
# set in the build dir and the install script below places it here.
#
# An absolute prefix path is what a distro package wants and what a relocatable
# bundle (AppImage) does not: a shell that has to relocate should prefer a
# /proc/self/exe-relative ../share/lookout-marine/plugins and fall back to this.
plugin_dir = datadir / 'lookout-marine' / 'plugins'
c_args += '-DLK_PLUGIN_DIR="' + plugin_dir + '"'

# The host that RUNS them. Separate from the directory above: the modules ship
# either way, and -Dplugins=false leaves a core that ignores them, which is the
# only thing an architecture with no WAMR archive can build.
#
# No compile-time flag rides on this. lookout.h declares the plugin calls in
# every build and a core built without the host answers -1 to all of them, so
# the shell reads "no plugins loaded" and shows no plugin settings, which is
# also what a core WITH the host and an empty plugin directory looks like.
plugins = get_option('plugins')

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
#
# libvmlib.a is the WAMR interpreter, and it is an output only when the host is
# on. Off Apple the static core leaves it unembedded (an ELF linker rejects an
# archive nested inside an archive), so the executable links the pair; naming it
# AFTER liblookout_marine.a is what resolves the wasm symbols the core calls.
core_outputs = ['liblookout_marine.a', 'libtile57.a', 'lookout.h', 'tile57.h']
core_command = [
  build_core, core_root, get_option('core-optimize'),
  '@OUTPUT0@', '@OUTPUT1@', '@OUTPUT2@', '@OUTPUT3@',
]
if plugins
  core_outputs += 'libvmlib.a'
  core_command += '@OUTPUT4@'
endif

core = custom_target('lookout-core',
  output: core_outputs,
  console: true,
  build_always_stale: true,
  command: core_command,
)

sources = files(
  'src/main.c',
  'src/lk-alerts.c',
  'src/lk-app-model.c',
  'src/lk-chart-bake.c',
  'src/lk-chart-controller.c',
  'src/lk-chart-links.c',
  'src/lk-chart-scan.c',
  'src/lk-chart-view.c',
  'src/lk-hud.c',
  'src/lk-json.c',
  'src/lk-mariner.c',
  'src/lk-native-surface.c',
  'src/lk-overlay-pick.c',
  'src/lk-pick-report.c',
  'src/lk-plugin-install.c',
  'src/lk-plugins.c',
  'src/lk-raster.c',
  'src/lk-search.c',
  'src/lk-settings-window.c',
  'src/lk-store.c',
  'src/lk-table-window.c',
  'src/lk-window.c',
)

# ---- the app's own icons -----------------------------------------------------
#
# The stock icon theme carries nothing marine, so the settings sections draw
# their own. They are compiled INTO the binary: an icon installed into hicolor
# does not resolve when the app runs from the build tree, and one there can be
# shadowed by whatever theme the desktop is using. main.c puts the resource
# prefix on the icon theme's search path.
#
# glib-compile-resources comes with glib, which gtk4 already requires, so this
# adds no prerequisite a GTK build did not already have.
gnome = import('gnome')
resources = gnome.compile_resources(
  'lk-resources',
  'data' / 'lookout-marine.gresource.xml',
  source_dir: 'data' / 'icons' / 'scalable' / 'actions',
  c_name: 'lk',
)

executable('lookout-marine',
  sources, resources,
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

# ---- the shipped plugin set --------------------------------------------------
#
# An install script rather than install_data: the pairs are build output, so
# their names are not known when this file is read. The argument is
# prefix-relative and the script joins it to MESON_INSTALL_DESTDIR_PREFIX, so
# a staged package install (DESTDIR=) lands in the right place.
meson.add_install_script(
  'install-plugins.sh',
  get_option('datadir') / 'lookout-marine' / 'plugins',
)
