cmake_minimum_required(VERSION 3.6)

project(lookout_app)

# SDL3::SDL3 comes from add_subdirectory(SDL) in the parent CMakeLists.
if(NOT TARGET SDL3::SDL3)
    find_package(SDL3 CONFIG REQUIRED)
endif()

# The Zig core, prebuilt per ABI (see build-libs.sh). On android the two archives
# stay separate (liblookout_marine.a doesn't embed tile57 — a nested .a member
# breaks ld.lld); liblookout is listed first so its undefined tile57 symbols
# resolve against libtile57 after it.
set(PREBUILT ${CMAKE_CURRENT_SOURCE_DIR}/../prebuilt/${ANDROID_ABI})

# SDLActivity loads "libmain.so" and calls its SDL_main (our main() below).
add_library(main SHARED main.c)
target_include_directories(main PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/../include)
target_link_libraries(main PRIVATE
    SDL3::SDL3
    ${PREBUILT}/liblookout_marine.a
    ${PREBUILT}/libtile57.a
    log        # __android_log_*
    android    # ANativeWindow / asset glue
    m)
