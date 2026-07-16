cmake_minimum_required(VERSION 3.20)

project(chrome_debug_agent_cpp LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

option(CHROME_AGENT_STATIC_MSVC_RUNTIME "Link the MSVC runtime statically" ON)

set(DEFAULT_RELAY_SERVER_URL "" CACHE STRING "Compiled default relay URL")
set(DEFAULT_AGENT_ENROLLMENT_TOKEN "" CACHE STRING "Compiled default agent token")
set(DEFAULT_AGENT_VERSION "1.0.0" CACHE STRING "Compiled default agent version")
set(DEFAULT_CHROME_PATH "" CACHE STRING "Optional compiled default Chrome path")

set(DEFAULT_DEV_RELAY_SERVER_URL "http://127.0.0.1:9998" CACHE STRING "Dev compiled relay URL")
set(DEFAULT_DEV_AGENT_ENROLLMENT_TOKEN "dev-agent-token" CACHE STRING "Dev compiled agent token")
set(DEFAULT_DEV_AGENT_VERSION "dev" CACHE STRING "Dev compiled agent version")

function(configure_agent_target target_name output_name relay_url token version chrome_path)
    add_executable(${target_name} client.cpp)
    set_target_properties(${target_name} PROPERTIES
        OUTPUT_NAME "${output_name}"
        RUNTIME_OUTPUT_DIRECTORY "${CHROME_AGENT_OUTPUT_DIR}"
        RUNTIME_OUTPUT_DIRECTORY_DEBUG "${CHROME_AGENT_OUTPUT_DIR}"
        RUNTIME_OUTPUT_DIRECTORY_RELEASE "${CHROME_AGENT_OUTPUT_DIR}"
        RUNTIME_OUTPUT_DIRECTORY_RELWITHDEBINFO "${CHROME_AGENT_OUTPUT_DIR}"
        RUNTIME_OUTPUT_DIRECTORY_MINSIZEREL "${CHROME_AGENT_OUTPUT_DIR}"
    )
    target_compile_definitions(${target_name} PRIVATE
        WIN32_LEAN_AND_MEAN
        NOMINMAX
        DEFAULT_RELAY_SERVER_URL="${relay_url}"
        DEFAULT_AGENT_ENROLLMENT_TOKEN="${token}"
        DEFAULT_AGENT_VERSION="${version}"
        DEFAULT_CHROME_PATH="${chrome_path}"
    )
    target_link_libraries(${target_name} PRIVATE winhttp ws2_32 shell32)
    if(MSVC)
        target_compile_options(${target_name} PRIVATE /W4 /EHsc /utf-8)
        target_link_options(${target_name} PRIVATE /OPT:REF /OPT:ICF)
    else()
        target_compile_options(${target_name} PRIVATE -Wall -Wextra)
    endif()
endfunction()

if(NOT DEFINED CHROME_AGENT_OUTPUT_DIR OR CHROME_AGENT_OUTPUT_DIR STREQUAL "")
    set(CHROME_AGENT_OUTPUT_DIR "${CMAKE_SOURCE_DIR}/../build")
endif()

if(MSVC AND CHROME_AGENT_STATIC_MSVC_RUNTIME)
    set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
endif()

configure_agent_target(
    chrome_debug_agent_cpp_dev
    client_debug_agent_cpp_dev
    "${DEFAULT_DEV_RELAY_SERVER_URL}"
    "${DEFAULT_DEV_AGENT_ENROLLMENT_TOKEN}"
    "${DEFAULT_DEV_AGENT_VERSION}"
    ""
)

configure_agent_target(
    chrome_debug_agent_cpp
    client_debug_agent_cpp
    "${DEFAULT_RELAY_SERVER_URL}"
    "${DEFAULT_AGENT_ENROLLMENT_TOKEN}"
    "${DEFAULT_AGENT_VERSION}"
    "${DEFAULT_CHROME_PATH}"
)
