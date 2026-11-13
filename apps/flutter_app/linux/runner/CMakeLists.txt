cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME}
  "main.cc"
  "my_application.cc"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the application ID.
add_definitions(-DAPPLICATION_ID="${APPLICATION_ID}")

# The workspace version, so --version answers before GTK and the Flutter
# engine start (CB-5). Cargo.toml's first `version =` is [workspace.package].
file(STRINGS "${CMAKE_SOURCE_DIR}/../../../Cargo.toml" ARCADE_CARGO_VERSION_LINE REGEX "^version = \"[^\"]+\"" LIMIT_COUNT 1)
string(REGEX REPLACE "^version = \"([^\"]+)\".*" "\\1" ARCADE_CLIPBOARD_VERSION "${ARCADE_CARGO_VERSION_LINE}")
if(NOT ARCADE_CLIPBOARD_VERSION)
  message(FATAL_ERROR "Couldn't read the version from Cargo.toml")
endif()
target_compile_definitions(${BINARY_NAME} PRIVATE ARCADE_CLIPBOARD_VERSION="${ARCADE_CLIPBOARD_VERSION}")

# Add dependency libraries. Add any application-specific dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::GTK)

target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")
