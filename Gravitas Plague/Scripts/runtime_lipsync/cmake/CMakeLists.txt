cmake_minimum_required(VERSION 3.25)

project(TuringPocketSphinxNative VERSION 1.0.0 LANGUAGES C)

set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(FIXED_POINT OFF CACHE BOOL "" FORCE)
set(PS_THREAD_LOCAL_RNG ON CACHE BOOL "" FORCE)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

if(NOT DEFINED POCKETSPHINX_SOURCE_DIR)
    message(FATAL_ERROR "POCKETSPHINX_SOURCE_DIR is required")
endif()

add_subdirectory(
    "${POCKETSPHINX_SOURCE_DIR}"
    pocketsphinx-build
    EXCLUDE_FROM_ALL
)

add_library(
    TuringPocketSphinxBridge
    STATIC
    "${CMAKE_CURRENT_LIST_DIR}/../bridge/TuringPocketSphinxBridge.c"
)

target_include_directories(
    TuringPocketSphinxBridge
    PUBLIC
    "${CMAKE_CURRENT_LIST_DIR}/../bridge"
    "${POCKETSPHINX_SOURCE_DIR}/include"
    "${CMAKE_BINARY_DIR}/include"
)

target_link_libraries(TuringPocketSphinxBridge PRIVATE pocketsphinx)

set_target_properties(
    TuringPocketSphinxBridge
    PROPERTIES OUTPUT_NAME "TuringPocketSphinxBridgeOnly"
)
