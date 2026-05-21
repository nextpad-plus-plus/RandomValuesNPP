cmake_minimum_required(VERSION 3.20)
project(RandomValuesNppPlugin LANGUAGES CXX OBJCXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_OSX_DEPLOYMENT_TARGET "11.0")
set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64")

# Host header path — NppPluginInterfaceMac.h, Scintilla.h etc.
set(NPP_MACOS_DIR      "${CMAKE_SOURCE_DIR}/../../notepad-plus-plus-macos")
set(NPP_WIN_DIR        "${CMAKE_SOURCE_DIR}/../../notepad-plus-plus")
set(SCINTILLA_INCLUDE  "${NPP_WIN_DIR}/scintilla/include")
set(NPP_PLUGIN_INCLUDE "${NPP_MACOS_DIR}/src")

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()

add_library(RandomValuesNppPlugin SHARED
    src/RandomValues.mm
)
target_include_directories(RandomValuesNppPlugin PRIVATE
    ${NPP_PLUGIN_INCLUDE}
    ${SCINTILLA_INCLUDE}
    src)
target_link_libraries(RandomValuesNppPlugin PRIVATE
    "-framework Cocoa")
target_compile_options(RandomValuesNppPlugin PRIVATE
    -Wall -Wno-unused-parameter
    -fvisibility=hidden
    $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
set_target_properties(RandomValuesNppPlugin PROPERTIES PREFIX "" SUFFIX ".dylib")

set(PLUGIN_INSTALL_DIR "$ENV{HOME}/.nextpad++/plugins/RandomValuesNppPlugin")
install(TARGETS RandomValuesNppPlugin DESTINATION "${PLUGIN_INSTALL_DIR}")

# Toolbar icons (dice.png light, dice_dark.png dark). The plugin passes the
# bare hint "dice.png"; the host probes "dice_dark.png" in dark mode and
# searches both the plugin root and resources/.
install(DIRECTORY resources/ DESTINATION "${PLUGIN_INSTALL_DIR}/resources"
    PATTERN ".DS_Store"  EXCLUDE
    PATTERN ".gitignore" EXCLUDE)
