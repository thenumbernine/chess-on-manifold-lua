# Chess on a manifold

Chessboard neighborhoods are determined by matching vertices.
So in theory you can build a board with any kind of 3D model.

From there, piece movements have been redefined in terms of local moves.
- Rooks / cardinal directions move along the path from edge to adjacent edge.
- Bishops / diagonal directions move one move forward in any cardinal direction (non-blocking) and one move left/right (blocking).
- Horses move two moves forward (non-blocking) and one move left/right (blocking).

# TODO
- en-pessant
- castling
- show friendly-fire attack of pawns (or anything whose move depends on a piece being there)
- I think rook or some piece works for any number of sided polygons, but most pieces assume faces are quads.
- Portals.
- Entangled squares.
- Also make use of local basis and connections...

# Dependencies:
- luajit
- template
- ext
- lua-ffi-bindings
- struct
- vec-ffi
- threadmanager
- netrefl
- image
- gl
- glapp
- imgui
- imguiapp
- `lfs_ffi`
- luasocket (compiled against luajit)
