################################################################################
# FlashTeX — a native, live-rendering LaTeX editor.
#
#   Native stack : C++20, Qt 6 (Widgets), Poppler-qt6
#   Build tool   : CMake >= 3.24
#
# Prerequisites (macOS via Homebrew):
#     brew install qt@6 poppler
#
# Configure & build:
#     cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
#     cmake --build build -j
#     open build/FlashTeX.app
################################################################################

cmake_minimum_required(VERSION 3.24)

project(FlashTeX VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Qt needs AUTOMOC to generate Q_OBJECT meta-object boilerplate.
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTOUIC OFF)
set(CMAKE_AUTORCC OFF)
set(CMAKE_INCLUDE_CURRENT_DIR ON)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

# -----------------------------------------------------------------------------
# Dependencies
# -----------------------------------------------------------------------------
find_package(Qt6 6.4 REQUIRED COMPONENTS Widgets)
find_package(Poppler REQUIRED COMPONENTS Qt6)

# Source list (kept explicit — nothing hidden, nothing that isn't here).
set(FLASHTEX_SOURCES
    src/main.cpp
    src/mainwindow.cpp
    src/latexworker.cpp
    src/pdfviewerwidget.cpp
    src/codeeditor.cpp
    src/latexhighlighter.cpp
)

set(FLASHTEX_HEADERS
    src/mainwindow.h
    src/latexworker.h
    src/pdfviewerwidget.h
    src/codeeditor.h
    src/latexhighlighter.h
)

add_executable(FlashTeX ${FLASHTEX_SOURCES} ${FLASHTEX_HEADERS})

# ---------------------------------------------------------------------------
# macOS: bundle into a proper .app with a native-looking binary.
# ---------------------------------------------------------------------------
if(APPLE)
    set_target_properties(FlashTeX PROPERTIES
        MACOSX_BUNDLE TRUE
        MACOSX_BUNDLE_BUNDLE_VERSION "${PROJECT_VERSION}"
        MACOSX_BUNDLE_SHORT_VERSION_STRING "${PROJECT_VERSION_MAJOR}.${PROJECT_VERSION_MINOR}"
        MACOSX_BUNDLE_GUI_IDENTIFIER "com.flashtex.editor"
        MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist"
    )
endif()

# ---------------------------------------------------------------------------
# Link Qt + Poppler. Poppler exports two possible CMake target names
# depending on how it was built; we support both.
# ---------------------------------------------------------------------------
target_link_libraries(FlashTeX PRIVATE Qt6::Widgets)
if(TARGET Poppler::Qt6)
    target_link_libraries(FlashTeX PRIVATE Poppler::Qt6)
elseif(TARGET poppler-qt6)
    target_link_libraries(FlashTeX PRIVATE poppler-qt6)
else()
    message(FATAL_ERROR "No Poppler Qt6 target found. Build poppler with -D with the qt6 plugin.")
endif()

if(APPLE)
    target_link_options(FlashTeX PRIVATE
        -Wl,-rpath,"@loader_path/../Frameworks"
        -Wl,-headerpad_max_install_names
    )
endif()