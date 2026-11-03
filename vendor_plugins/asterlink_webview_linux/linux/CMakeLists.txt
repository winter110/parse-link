cmake_minimum_required(VERSION 3.10)
set(PROJECT_NAME "asterlink_webview_linux")
project(${PROJECT_NAME} LANGUAGES CXX)

cmake_policy(VERSION 3.10...3.24)

set(PLUGIN_NAME "${PROJECT_NAME}_plugin")

# WebKitGTK 4.1 is the engine; it is provided by the distribution
# (libwebkit2gtk-4.1-dev at build time, libwebkit2gtk-4.1-0 at run time).
# Nothing is vendored or compiled from source here.
find_package(PkgConfig REQUIRED)
pkg_check_modules(WEBKIT2GTK REQUIRED IMPORTED_TARGET webkit2gtk-4.1)
pkg_check_modules(JSCOREGTK REQUIRED IMPORTED_TARGET javascriptcoregtk-4.1)

# The runner project already imports GTK before adding plugin subdirectories,
# and pkg_check_modules errors out when the imported target exists. The guard
# keeps this file usable both standalone and as a child of the runner.
if(NOT TARGET PkgConfig::GTK)
  pkg_check_modules(GTK REQUIRED IMPORTED_TARGET gtk+-3.0)
endif()

# The implementation sits next to this file, matching the upstream plugin
# layout. Flutter links the whole plugin directory in as
# flutter/ephemeral/.plugin_symlinks/<name>/, so the sibling include/ directory
# below resolves in CI as well.
add_library(${PLUGIN_NAME} SHARED
  "asterlink_webview_linux_plugin.cc"
)

# Deliberately not using apply_standard_settings(): it enables -Werror, and
# WebKitGTK marks a few of the context/cookie entry points as deprecated across
# minor releases. Warnings stay visible in the CI log without breaking the build.
target_compile_features(${PLUGIN_NAME} PRIVATE cxx_std_17)
target_compile_options(${PLUGIN_NAME} PRIVATE -Wall -Wno-deprecated-declarations)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

# The public header lives in <plugin>/include/, one level above this directory.
set(PLUGIN_INCLUDE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../include")
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${PLUGIN_INCLUDE_DIR}")
target_include_directories(${PLUGIN_NAME} PRIVATE
  "${PLUGIN_INCLUDE_DIR}")

target_link_libraries(${PLUGIN_NAME} PRIVATE flutter)
target_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::GTK)
target_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::WEBKIT2GTK)
target_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::JSCOREGTK)
