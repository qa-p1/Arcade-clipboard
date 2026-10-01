cmake_minimum_required(VERSION 3.14)
set(PROJECT_NAME "arcade_desktop_bridge")
project(${PROJECT_NAME} LANGUAGES CXX)
set(PLUGIN_NAME "arcade_desktop_bridge_plugin")

add_library(${PLUGIN_NAME} SHARED
  "arcade_desktop_bridge_plugin.cpp"
  "windows_support.cpp"
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
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin gdiplus shell32 advapi32 ole32)
set(arcade_desktop_bridge_bundled_libraries "" PARENT_SCOPE)
