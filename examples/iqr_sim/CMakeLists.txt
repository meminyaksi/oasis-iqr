cmake_minimum_required(VERSION 3.16)
project(oasis_iqr_sim VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Run IqrRunner against the Coyote software-in-the-loop simulation (no FPGA).
#   cmake -S examples/iqr_sim -B examples/iqr_sim/build -DEN_SIMULATION=ON -DCMAKE_PREFIX_PATH=$HOME/opt
#   cmake --build examples/iqr_sim/build -j
#   COYOTE_SIM_DIR=$PWD/hardware/build-sim ./examples/iqr_sim/build/iqr_sim
option(EN_SIMULATION "Link against the Coyote simulation cThread (no FPGA required)" OFF)

if(EN_SIMULATION)
    # The sim cThread starts Vivado in the background and talks to the RTL over named pipes.
    add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../../parcore/libstf/coyote/sim/sw coyote)
    add_compile_definitions(EN_SIMULATION)
else()
    add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../../parcore/libstf/coyote/sw coyote)
endif()

# Build libstf + parcore from source (not the installed packages under $HOME/opt -- those are linked
# against the REAL Coyote and would clash with the sim cThread). Defining the targets here, at the
# top level, makes them visible to this scope (so iqr_sim can link them) AND makes oasis's
# `if(NOT TARGET libstf)` guard reuse them instead of find_package'ing the installed copies.
add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../../parcore/libstf/software libstf)
add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../../parcore/software parcore)

# Pulls in the oasis library (reuses the Coyote/libstf/parcore targets already defined above).
add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../../software oasis)

add_executable(iqr_sim src/main.cpp)
target_link_libraries(iqr_sim PRIVATE Coyote libstf parcore oasis)

# The oasis target only exports its own headers publicly (libstf/parcore/coyote are PRIVATE there),
# so the executable needs the libstf/parcore/coyote include roots directly.
set(PARCORE_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/../../parcore)
# Source roots FIRST (BEFORE) so the live oasis/libstf/parcore headers win over any stale copies
# installed under $HOME/opt (CMAKE_PREFIX_PATH/include, which we still need for jemalloc).
target_include_directories(iqr_sim BEFORE PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../../software
    ${PARCORE_ROOT}/software
    ${PARCORE_ROOT}/libstf/software)
target_include_directories(iqr_sim PRIVATE
    ${CMAKE_PREFIX_PATH}/include)   # jemalloc (installed under $HOME/opt)
if(EN_SIMULATION)
    target_include_directories(iqr_sim PRIVATE ${PARCORE_ROOT}/libstf/coyote/sim/sw/include)
else()
    target_include_directories(iqr_sim PRIVATE ${PARCORE_ROOT}/libstf/coyote/sw/include)
endif()
