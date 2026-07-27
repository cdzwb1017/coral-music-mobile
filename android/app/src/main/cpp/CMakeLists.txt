cmake_minimum_required(VERSION 3.22.1)
project(coral_quickjs LANGUAGES C CXX)

set(QJS_DIR ${CMAKE_CURRENT_LIST_DIR}/../../../../../third_party/quickjs-ng)
add_library(qjs STATIC
  ${QJS_DIR}/dtoa.c
  ${QJS_DIR}/libregexp.c
  ${QJS_DIR}/libunicode.c
  ${QJS_DIR}/quickjs.c
)
target_include_directories(qjs PUBLIC ${QJS_DIR})
target_compile_definitions(qjs PRIVATE QUICKJS_NG_BUILD _GNU_SOURCE)

add_library(coral_quickjs SHARED quickjs_bridge.cpp)
target_link_libraries(coral_quickjs PRIVATE qjs log m)
