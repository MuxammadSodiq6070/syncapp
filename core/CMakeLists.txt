cmake_minimum_required(VERSION 3.16)
project(sync_core LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_C_VISIBILITY_PRESET hidden)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)

option(SYNC_BUILD_TESTS "Build sync_core tests" OFF)
find_package(Threads REQUIRED)

# TLS. Threading is enabled through src/mbedtls_user_config.h.
set(ENABLE_TESTING OFF CACHE BOOL "" FORCE)
set(ENABLE_PROGRAMS OFF CACHE BOOL "" FORCE)
set(GEN_FILES OFF CACHE BOOL "" FORCE)
set(MBEDTLS_FATAL_WARNINGS OFF CACHE BOOL "" FORCE)
set(USE_SHARED_MBEDTLS_LIBRARY OFF CACHE BOOL "" FORCE)
set(USE_STATIC_MBEDTLS_LIBRARY ON CACHE BOOL "" FORCE)
add_compile_definitions(MBEDTLS_USER_CONFIG_FILE="${CMAKE_CURRENT_SOURCE_DIR}/src/mbedtls_user_config.h")
add_subdirectory(third_party/mbedtls EXCLUDE_FROM_ALL)

add_library(sync_vendor STATIC
  third_party/monocypher/monocypher.c
  third_party/monocypher/monocypher-ed25519.c
  third_party/sqlite/sqlite3.c)
target_include_directories(sync_vendor PUBLIC third_party/monocypher third_party/sqlite third_party/nlohmann)
target_compile_definitions(sync_vendor PRIVATE
  SQLITE_THREADSAFE=2 SQLITE_OMIT_LOAD_EXTENSION SQLITE_DEFAULT_WAL_SYNCHRONOUS=1 SQLITE_DQS=0)
target_compile_options(sync_vendor PRIVATE -w)

set(SYNC_SOURCES src/crypto.cpp src/db.cpp src/net.cpp src/ca_bundle.cpp src/client.cpp)

add_library(sync_core SHARED ${SYNC_SOURCES})
target_include_directories(sync_core PUBLIC include)
target_link_libraries(sync_core PRIVATE sync_vendor mbedtls Threads::Threads ${CMAKE_DL_LIBS})
target_compile_options(sync_core PRIVATE -Wall -Wextra)

if(ANDROID)
  # Android 15+ devices use 16 KB pages; the library must be aligned for them.
  target_link_options(sync_core PRIVATE "-Wl,-z,max-page-size=16384")
endif()

if(SYNC_BUILD_TESTS)
  # Tests link statically so they can reach internal symbols hidden from the shared library.
  add_library(sync_core_static STATIC src/crypto.cpp src/db.cpp src/net.cpp src/ca_bundle.cpp)
  target_include_directories(sync_core_static PUBLIC include src)
  target_compile_definitions(sync_core_static PUBLIC SYNC_TESTING)
  target_link_libraries(sync_core_static PUBLIC sync_vendor mbedtls Threads::Threads ${CMAKE_DL_LIBS})

  enable_testing()
  add_executable(core_tests tests/core_tests.cpp)
  target_include_directories(core_tests PRIVATE src)
  target_link_libraries(core_tests PRIVATE sync_core_static)
  add_test(NAME core_tests COMMAND core_tests)
endif()
