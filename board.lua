local gl = require 'gl'
local class = require 'ext.class'
local table = require 'ext.table'
local vec3f = require 'vec-ffi.vec3f'
local Place = require 'place'
local Piece = require 'piece'

local Board = class()

Board.__netfields = {
	places = require 'netrefl.netfield'.netFieldList(
		require 'netrefl.netfield'.NetFieldObject:subclass{
			-- __netallocator is only used for members of netFieldList
			__netallocator = function(board)
				print('Place.netField __netallocator arg:', boardPlaces)
				error'here'
				return Place{
					board = board,
					color = vec4f(),	-- ... some default value, to-be-updated
					vtxs = table(),	-- ... some default value, to-be-updated
				}
			end,
		}
	),
}

function Board:init(app)
	self.app = assert(app)
	self.places = table()
end

function Board:makePiece(args)
	local cl = assert(args.class)
	if not self.app.shared.enablePieces[cl.name] then return end
	args.class = nil
	args.board = self
	cl(args)
end

function Board:buildEdges()
	local epsilon = 1e-7

	local function vertexMatches(a,b)
		return (a - b):lenSq() < epsilon
	end

	local function edgeMatches(a1,a2,b1,b2)
		return (vertexMatches(a1,b1) and vertexMatches(a2,b2))
		or (vertexMatches(a1,b2) and vertexMatches(a2,b1))
	end

	for a,pa in ipairs(self.places) do
		for i=1,#pa.vtxs do
			local i2 = i % #pa.vtxs + 1

			local o = (i+2 - 1) % #pa.vtxs + 1
			local o2 = o % #pa.vtxs + 1

			local neighbor
			local neighborIndex
			for b,pb in ipairs(self.places) do
				if pb ~= pa then
					for j=1,#pb.vtxs do
						local j2 = j % #pb.vtxs+1

						if edgeMatches(
							pa.vtxs[i],
							pa.vtxs[i2],
							pb.vtxs[j],
							pb.vtxs[j2])
						then
							neighborIndex = b
							neighbor = pb
							break
						end
					end
				end
			end
			local edge = {
				placeIndex = neighborIndex,
			}
			edge.ex = (pa.vtxs[i] - pa.vtxs[i2]):normalize()
			-- edge.ez = pa.normal
			edge.ey = pa.normal:cross(edge.ex):normalize()
			pa.edges:insert(edge)
		end
		--[[
		io.write('nbhd', '\t', pa.index, '\t', #pa.edges)
		for i=1,#pa.edges do
			local pb = self.places[pa.edges[i].placeIndex]
			local pc = self.places[pa.edges[(i % #pa.edges)+1].placeIndex]
			if pb and pc then
				local n2 = (pb.center - pa.center):cross(pc.center - pb.center)
				-- should be positive ...
				local dot = n2:dot(pa.normal)
				io.write('\t', dot)
			end
		end
		print()
		--]]
	end
end

-- call this last in generation
-- ... to get the vector from kings
-- ... to init the pawns fwd dir and kings left/right dirs
function Board:initPieces()
	local playersKingPos = self.app.players:mapi(function(player)
		local kingPos = self.places:filter(function(place)
			return place.piece
			and Piece.King:isa(place.piece)
			and place.piece.player == player
		end):mapi(function(place)
			return place.center
		end)
		if #kingPos == 0 then
			error("found a player without a king")
		end
		return kingPos:sum() / #kingPos
	end)

	self.playerDirToOtherKings = playersKingPos:mapi(function(pos,i)
		local otherPos = playersKingPos:filter(function(pos,j)
			return i ~= j
		end)
		otherPos = otherPos:sum() / #otherPos
		return (otherPos - pos):normalize()
	end)

	-- run this after placing all pieces
	for _,place in ipairs(self.places) do
		local piece = place.piece
		if piece
		and piece.initAfterPlacing
		then
			piece:initAfterPlacing()
		end
	end
end

function Board:draw()
	for _,place in ipairs(self.places) do
		place:draw()
	end
end

function Board:drawPicking()
	self.placeForIndex = table()
	for i,place in ipairs(self.places) do
		-- TODO maybe shift a bit or two if the rgba8 resolution isn't 8 bit (on some cards/implementations its not, especially the alpha channel)
		local r = bit.band(0xff, i)
		local g = bit.band(0xff, bit.rshift(i, 8))
		local b = bit.band(0xff, bit.rshift(i, 16))
		gl.glColor3ub(r,g,b)
		place:drawPicking()
		self.placeForIndex[i] = place
	end
end

function Board:getPlaceForRGB(r,g,b)
	local i = bit.bor(
		r,
		bit.lshift(g, 8),
		bit.lshift(b, 16)
	)
	return self.placeForIndex[i], i
end

-- calculate all moves for all pieces
function Board:refreshMoves(noCues)
	self.scores = self.app.players:mapi(function() return 0 end)
	self.checks = {}
	self.attacks = table()
	for _,place in ipairs(self.places) do
		local piece = place.piece
		if piece then
			self.scores[piece.player.index] = self.scores[piece.player.index] + piece.score
			piece.movePaths = piece:getMoves()
			if not noCues then
				piece.cueMovePaths = piece:getMoves(true)
				for _,move in ipairs(piece.cueMovePaths) do
					local targetPiece = self.places[move:last().placeIndex].piece
					if targetPiece then
						local friendly = targetPiece.player == piece.player
						self.attacks:insert{
							piece,
							targetPiece,
							friendly,
						}

						if not friendly
						and Piece.King:isa(targetPiece)
						then
							self.checks[targetPiece.player.index] = true
						end
					end
				end
			end
		end
	end
	return self
end

-- TODO don't subclass dif board types, just use a generator
function Board:clone()
	local newBoard = getmetatable(self)(self.app)
	for _,srcPlace in ipairs(self.places) do
		srcPlace:clone(newBoard)
	end
	newBoard.lastMovedPlaceIndex = self.lastMovedPlaceIndex
--DEBUG(Board):print('Board:clone lastMovedPlaceIndex', newBoard.lastMovedPlaceIndex)
	-- shallow copy
	newBoard.playerDirToOtherKings = self.playerDirToOtherKings
	for placeIndex,newPlace in ipairs(newBoard.places) do
		newPlace.edges = self.places[placeIndex].edges
	end

	return newBoard
end


Board.generators = table()
Board.generators:insert{Traditional = function(app)
	local board = Board(app)

	for j=0,7 do
		for i=0,7 do
			Place{
				board = board,
				color = (i+j)%2 == 1 and vec3f(1,1,1) or vec3f(.2, .2, .2),
				vtxs = {
					vec3f(i-4, j-4, 0),
					vec3f(i-3, j-4, 0),
					vec3f(i-3, j-3, 0),
					vec3f(i-4, j-3, 0),
				},
			}
		end
	end
	board:buildEdges()

	-- board makes players?  or app makes players?  hmm
	-- board holds players?
	assert(#app.players == 2)
	for i=1,2 do
		local player = app.players[i]
		local y = 7 * (i-1)
		board:makePiece{class=Piece.Rook, player=player, placeIndex=1 + 0 + 8 * y}
		board:makePiece{class=Piece.Knight, player=player, placeIndex=1 + 1 + 8 * y}
		board:makePiece{class=Piece.Bishop, player=player, placeIndex=1 + 2 + 8 * y}
		board:makePiece{class=Piece.Queen, player=player, placeIndex=1 + 3 + 8 * y}
		board:makePiece{class=Piece.King, player=player, placeIndex=1 + 4 + 8 * y}
		board:makePiece{class=Piece.Bishop, player=player, placeIndex=1 + 5 + 8 * y}
		board:makePiece{class=Piece.Knight, player=player, placeIndex=1 + 6 + 8 * y}
		board:makePiece{class=Piece.Rook, player=player, placeIndex=1 + 7 + 8 * y}
		local y = 5 * (i-1) + 1
		for x=0,7 do
			board:makePiece{class=Piece.Pawn, player=player, placeIndex = 1 + x + 8 * y}
		end
	end

	board:initPieces()

	return board
end}

Board.generators:insert{Cylinder = function(app)
	local board = Board(app)

	local function getpos(i, j)
		local r = 2
		local th = -i/8*2*math.pi
		return vec3f(r * math.cos(th), j - 4, r * math.sin(th))
	end
	for j=0,7 do
		for i=0,7 do
			Place{
				board = board,
				color = (i+j)%2 == 1 and vec3f(1,1,1) or vec3f(.2, .2, .2),
				vtxs = {
					getpos(i, j),
					getpos(i+1, j),
					getpos(i+1, j+1),
					getpos(i, j+1),
				},
			}
		end
	end
	board:buildEdges()

	-- board makes players?  or app makes players?  hmm
	-- board holds players?
	assert(#app.players == 2)
	for i=1,2 do
		local player = app.players[i]
		local y = 7 * (i-1)
		board:makePiece{class=Piece.Rook, player=player, placeIndex=1 + 0 + 8 * y}
		board:makePiece{class=Piece.Knight, player=player, placeIndex=1 + 1 + 8 * y}
		board:makePiece{class=Piece.Bishop, player=player, placeIndex=1 + 2 + 8 * y}
		board:makePiece{class=Piece.Queen, player=player, placeIndex=1 + 3 + 8 * y}
		board:makePiece{class=Piece.King, player=player, placeIndex=1 + 4 + 8 * y}
		board:makePiece{class=Piece.Bishop, player=player, placeIndex=1 + 5 + 8 * y}
		board:makePiece{class=Piece.Knight, player=player, placeIndex=1 + 6 + 8 * y}
		board:makePiece{class=Piece.Rook, player=player, placeIndex=1 + 7 + 8 * y}
		local y = 5 * (i-1) + 1
		for x=0,7 do
			board:makePiece{class=Piece.Pawn, player=player, placeIndex = 1 + x + 8 * y}
		end
	end

	board:initPieces()

	return board
end}

Board.generators:insert{Cube = function(app)
	local board = Board(app)
	local placesPerSide = {}
	for a=0,2 do
		placesPerSide[a] = {}
		local b = (a+1)%3
		local c = (b+1)%3
		for pm=-1,1,2 do
			placesPerSide[a][pm] = {}
			local function vtx(i,j)
				local v = vec3f()
				v.s[a] = i
				v.s[b] = j
				v.s[c] = pm*2
				return v
			end
			for j=0,3 do
				placesPerSide[a][pm][j] = {}
				for i=0,3 do
					local vtxs = table{
						vtx(i-2, j-2),
						vtx(i-1, j-2),
						vtx(i-1, j-1),
						vtx(i-2, j-1),
					}
					if pm == -1 then vtxs = vtxs:reverse() end
					local place = Place{
						board = board,
						color = (i+j+a)%2 == 0 and vec3f(1,1,1) or vec3f(.2, .2, .2),
						vtxs = vtxs,
					}
					placesPerSide[a][pm][j][i] = place
				end
			end
		end
	end
	board:buildEdges()

	for i=1,2 do
		local player = app.players[i]
		assert(player.index == i)
		local places = placesPerSide[0][2*i-3]

		board:makePiece{class=Piece.Pawn, player=player, placeIndex=places[0][0].index}
		board:makePiece{class=Piece.Pawn, player=player, placeIndex=places[1][0].index}
		board:makePiece{class=Piece.Pawn, player=player, placeIndex=places[2][0].index}
		board:makePiece{class=Piece.Pawn, player=player, placeIndex=places[3][0].index}

		board:makePiece{class=Piece.Bishop, player=player, placeIndex=places[0][1].index}
		board:makePiece{class=Piece.Rook, player=player, placeIndex=places[1][1].index}
		board:makePiece{class=Piece.Queen, player=player, placeIndex=places[2][1].index}
		board:makePiece{class=Piece.Knight, player=player, placeIndex=places[3][1].index}

		board:makePiece{class=Piece.Knight, player=player, placeIndex=places[0][2].index}
		board:makePiece{class=Piece.King, player=player, placeIndex=places[1][2].index}
		board:makePiece{class=Piece.Rook, player=player, placeIndex=places[2][2].index}
		board:makePiece{class=Piece.Bishop, player=player, placeIndex=places[3][2].index}

		board:makePiece{class=Piece.Pawn, player=player, placeIndex=places[0][3].index}
		board:makePiece{class=Piece.Pawn, player=player, placeIndex=places[1][3].index}
		board:makePiece{class=Piece.Pawn, player=player, placeIndex=places[2][3].index}
		board:makePiece{class=Piece.Pawn, player=player, placeIndex=places[3][3].index}
	end

	board:initPieces()

	return board
end}

-- [[ whoops, my obj file loader triangulates on load.  not very useful here ...
-- how about i override the loader and make it spit out board places ...
local OBJLoader = require 'mesh.objloader'
local PlaceLoader = OBJLoader:subclass() 
function PlaceLoader:init(...)
	self.faces = table()
	PlaceLoader.super.init(self, ...)
end
function PlaceLoader:loadFace(vis, mesh, group)
	self.faces:insert(vis)
	-- vis is an array of {v=vi, vt=vti, vn=vni}
	PlaceLoader.super.loadFace(self, vis, mesh, group)
end
function PlaceLoader:buildTris(vs, vts, vns)
	for i,face in ipairs(self.faces) do
		local vtxs = face:mapi(function(vis)
			return vec3f(vs[vis.v]:unpack())
		end)
		local area = 0
		for j=2,#vtxs-1 do
			local a = vtxs[1]
			local b = vtxs[j]
			local c = vtxs[j+1]
			local ab = b - a
			local ac = c - a
			area = area + .5 * ab:cross(ac):norm()
		end
		if area <= 1e-7 then
			print("disregarding zero-area face...")
		else
			local center = vtxs:sum() / #vtxs
			local bw = (math.floor(center.x) + math.floor(center.y) + math.floor(center.z)) % 2 == 0
			Place{
				board = self.board,
				color = bw and vec3f(1,1,1) or vec3f(.2, .2, .2),
				vtxs = vtxs,
			}
		end
	end
end
Board.generators:insert{ObjFile = function(app, filename)
	local board = Board(app)
	
	filename = filename or 'board.obj'
	local loader = PlaceLoader()
	loader.board = board		--assign before calling :load()
	loader:load(filename)
	board:buildEdges()
	-- TODO pieces too 
	return board
end}
--]]

Board.generatorForName = {}
for _,genpair in ipairs(Board.generators) do
	local name, gen = next(genpair)
	Board.generatorForName[name] = gen
end

return Board
