cmake_minimum_required(VERSION 3.16)
project(NebulaDrift VERSION 1.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()

find_package(PkgConfig REQUIRED)
pkg_check_modules(SDL2 REQUIRED IMPORTED_TARGET sdl2)
pkg_check_modules(CAIRO REQUIRED IMPORTED_TARGET cairo cairo-ft freetype2)
find_package(OpenGL REQUIRED)
find_package(Threads REQUIRED)

add_executable(nebuladrift
    src/main.cpp
    src/audio.cpp
    src/renderer.cpp
    src/instruments.cpp
    src/cockpit.cpp
    src/draw.cpp
    src/miniaudio.c
)
target_include_directories(nebuladrift PRIVATE src third_party)
target_compile_definitions(nebuladrift PRIVATE NEBULADRIFT_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}")
# miniaudio loads the sound server's client library (PulseAudio/PipeWire, ALSA, JACK) at runtime.
target_link_libraries(nebuladrift PRIVATE PkgConfig::SDL2 PkgConfig::CAIRO OpenGL::GL Threads::Threads
                      ${CMAKE_DL_LIBS} m)
set_source_files_properties(src/miniaudio.c PROPERTIES COMPILE_OPTIONS "-w")
set_target_properties(nebuladrift PROPERTIES INSTALL_RPATH "$ORIGIN/../lib")

# Run straight from the build tree: shaders and font sit next to the binary.
add_custom_command(TARGET nebuladrift POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_directory ${CMAKE_CURRENT_SOURCE_DIR}/shaders $<TARGET_FILE_DIR:nebuladrift>/shaders
    COMMAND ${CMAKE_COMMAND} -E copy_directory ${CMAKE_CURRENT_SOURCE_DIR}/assets $<TARGET_FILE_DIR:nebuladrift>/assets)

include(GNUInstallDirs)
install(TARGETS nebuladrift RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
install(DIRECTORY shaders assets DESTINATION ${CMAKE_INSTALL_DATADIR}/nebuladrift)
install(FILES packaging/nebuladrift.desktop DESTINATION ${CMAKE_INSTALL_DATADIR}/applications)
install(FILES packaging/nebuladrift.png DESTINATION ${CMAKE_INSTALL_DATADIR}/icons/hicolor/256x256/apps)
