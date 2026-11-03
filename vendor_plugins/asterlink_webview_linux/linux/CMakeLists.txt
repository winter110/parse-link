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

add_library(${PLUGIN_NAME} SHARED
  "asterlink_webview_linux_plugin.cc"
)

# Deliberately not using apply_standard_settings(): it enables -Werror, and
# WebKitGTK marks a few of the context/cookie entry points as deprecated across
# minor releases. Warnings stay visible in the CI log without breaking the build.
target_compile_features(${PLUGIN_NAME} PRIVATE cxx_std_17)
target_compile_options(${PLUGIN_NAME} PRIVATE -Wall -Wno-deprecated-declarations)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_include_directories(${PLUGIN_NAME} PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}")

target_link_libraries(${PLUGIN_NAME} PRIVATE flutter)
target_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::GTK)
target_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::WEBKIT2GTK)
target_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::JSCOREGTK)
