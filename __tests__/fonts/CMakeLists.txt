cmake_minimum_required(VERSION 3.22.1)
project(SubtitleFontTests C CXX)
set(CMAKE_CXX_STANDARD 17)
find_package(ZLIB REQUIRED)
set(ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../cpp/fonts")
file(GLOB BROTLI_SOURCES "${ROOT}/vendor/brotli/c/common/*.c" "${ROOT}/vendor/brotli/c/dec/*.c")
file(GLOB WOFF2_SOURCES "${ROOT}/vendor/woff2/src/*.cc")
add_executable(font-decoder-tests FontDecoderTests.cpp "${ROOT}/FontDecoder.cpp"
  "${ROOT}/FontMetadata.cpp"
  ${BROTLI_SOURCES} ${WOFF2_SOURCES})
target_include_directories(font-decoder-tests PRIVATE "${ROOT}"
  "${ROOT}/vendor/woff2/include" "${ROOT}/vendor/brotli/c/include")
target_compile_definitions(font-decoder-tests PRIVATE BROTLI_BUILD_PORTABLE)
target_link_libraries(font-decoder-tests PRIVATE ZLIB::ZLIB)
enable_testing()
add_test(NAME font-decoder COMMAND font-decoder-tests "${CMAKE_CURRENT_SOURCE_DIR}/font.woff2"
  "${CMAKE_CURRENT_BINARY_DIR}/fixtures")
