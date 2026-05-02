#!/bin/env bash

glslc src/renderer/shaders/grid.vert  -o src/renderer/shaders/grid.vert.spv
glslc src/renderer/shaders/grid.frag  -o src/renderer/shaders/grid.frag.spv
glslc src/renderer/shaders/shapes.vert -o src/renderer/shaders/shapes.vert.spv
glslc src/renderer/shaders/shapes.frag -o src/renderer/shaders/shapes.frag.spv
glslc src/renderer/shaders/text.vert  -o src/renderer/shaders/text.vert.spv
glslc src/renderer/shaders/text.frag  -o src/renderer/shaders/text.frag.spv

RDOC=""
if [ "$RENDERDOC" = "1" ]; then
    RDOC="-define:RENDERDOC=true"
fi

odin build ./apps/demo     -debug -o:none $RDOC -out:dist/odin      -collection:src=./src
odin build ./apps/sudoku   -debug -o:none $RDOC -out:dist/sudoku    -collection:src=./src
odin build ./apps/grid_test -debug -o:none $RDOC -out:dist/grid_test -collection:src=./src
