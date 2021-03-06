cmake_minimum_required(VERSION 3.3.2)

project(pairhmm)

set(CMAKE_CXX_STANDARD 11)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_FLAGS "-Wall -Wextra -fext-numeric-literals")
set(CMAKE_CXX_FLAGS_RELEASE "-O3")

set(EXTERNAL_INSTALL_LOCATION ${CMAKE_BINARY_DIR}/external)

include(ExternalProject)
ExternalProject_Add(universal
        GIT_REPOSITORY https://github.com/lvandam/universal
        GIT_TAG master
        PREFIX ${EXTERNAL_INSTALL_LOCATION}
        CMAKE_ARGS -DCMAKE_INSTALL_PREFIX=${EXTERNAL_INSTALL_LOCATION}
        CONFIGURE_COMMAND ""
        BUILD_COMMAND ""
        INSTALL_COMMAND ""
        )

include_directories(${EXTERNAL_INSTALL_LOCATION}/src/universal)

file(GLOB pairhmm_SRC
        "src/*.hpp"
        "src/*.cpp"
        )

add_executable(pairhmm ${pairhmm_SRC})
add_dependencies(pairhmm universal)

find_library(LIB_FLETCHER fletcher)
find_library(LIB_ARROW arrow)

find_package(OpenMP REQUIRED)
if (OPENMP_FOUND)
    set (CMAKE_C_FLAGS "${CMAKE_C_FLAGS} ${OpenMP_C_FLAGS}")
    set (CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} ${OpenMP_CXX_FLAGS}")
    set (CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} ${OpenMP_EXE_LINKER_FLAGS}")
endif()

option(RUNTIME_PLATFORM "The run-time platform to use. Currently 2: CAPI SNAP" 2)

message("Chose CAPI SNAP as run-time platform.")

if(NOT EXISTS "$ENV{SNAP_ROOT}")
message(FATAL_ERROR "Attempting to CMake with SNAP support, but SNAP_ROOT is not set. Please do something to fix that.")
endif()

set(PLATFORM_INCLUDE_DIRS ${PLATFORM_INCLUDE_DIRS} $ENV{SNAP_ROOT}/software/include)

find_library(LIB_SNAP snap HINTS $ENV{SNAP_ROOT}/software/lib)
message(STATUS "SNAP libsnap.so at: " ${LIB_SNAP})
set(LIB_PLATFORM ${LIB_SNAP})

option(ENABLE_DEBUG "Enable debugging" OFF)

if (ENABLE_DEBUG)
    message(STATUS "DEBUG ON")
  target_compile_definitions(${PROJECT_NAME} PRIVATE DEBUG)
endif()

target_compile_definitions(${PROJECT_NAME} PRIVATE PLATFORM=${RUNTIME_PLATFORM})

target_link_libraries(${PROJECT_NAME}
  ${REQUIRED}
  ${LIB_FLETCHER}
  ${LIB_ARROW}
  ${LIB_PLATFORM}
)
