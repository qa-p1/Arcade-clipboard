cmake_minimum_required(VERSION 3.14)
set(PROJECT_NAME "arcade_desktop_bridge")
project(${PROJECT_NAME} LANGUAGES CXX)

add_library(${PROJECT_NAME} SHARED
  "arcade_desktop_bridge_plugin.cc"
)

add_executable(arcade_clipboard_wl_capture
  "wl_capture_helper.cc"
)
target_compile_features(arcade_clipboard_wl_capture PRIVATE cxx_std_17)
set_target_properties(arcade_clipboard_wl_capture PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bundle/lib"
)
install(TARGETS arcade_clipboard_wl_capture
  RUNTIME DESTINATION lib
)

apply_standard_settings(${PROJECT_NAME})
set_target_properties(${PROJECT_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden
)
target_compile_features(${PROJECT_NAME} PUBLIC cxx_std_17)
target_compile_definitions(${PROJECT_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
target_include_directories(${PROJECT_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
)
target_link_libraries(${PROJECT_NAME} PRIVATE flutter flutter_wrapper_plugin)

list(APPEND FLUTTER_PLUGIN_LIST ${PROJECT_NAME})
set(FLUTTER_PLUGIN_LIST ${FLUTTER_PLUGIN_LIST} PARENT_SCOPE)
