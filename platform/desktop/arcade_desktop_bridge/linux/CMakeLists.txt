cmake_minimum_required(VERSION 3.14)
set(PROJECT_NAME "arcade_desktop_bridge")
project(${PROJECT_NAME} LANGUAGES CXX)
set(PLUGIN_NAME "arcade_desktop_bridge_plugin")

add_library(${PLUGIN_NAME} SHARED
  "arcade_desktop_bridge_plugin.cc"
  "clipboard_bridge.cc"
  "lifecycle_bridge.cc"
)

add_executable(arcade_clipboard_wl_capture
  "wl_capture_helper.cc"
)
target_compile_features(arcade_clipboard_wl_capture PRIVATE cxx_std_17)
set_target_properties(arcade_clipboard_wl_capture PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/helpers"
)
install(TARGETS arcade_clipboard_wl_capture
  RUNTIME DESTINATION lib
)

apply_standard_settings(${PLUGIN_NAME})
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden
)
target_compile_features(${PLUGIN_NAME} PUBLIC cxx_std_17)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
)
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter)
set(arcade_desktop_bridge_bundled_libraries "" PARENT_SCOPE)
