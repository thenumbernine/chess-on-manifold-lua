#! /usr/bin/env luajit
local gl = require 'gl'
local table = require 'ext.table'
local class = require 'ext.class'
local math = require 'ext.math'
local vec3f = require 'vec-ffi.vec3f'
local vec4ub = require 'vec-ffi.vec4ub'
local Image = require 'image'
local GLTex2D = require 'gl.tex2d'
local ig = require 'imgui'
local NetCom = require 'netrefl.netcom'
local ThreadManager = require 'threadmanager'

local Place = require 'place'
local Piece = require 'piece'


local King
local Pawn = Piece:subclass()

Pawn.name = 'pawn'

-- ... pawns ... which way is up?
-- geodesic from king to king?  closest to the pawn?
-- this also means  store state info for when the piece is created ... this is only true for pawns
-- run this when we're done placing pieces
function Pawn:initAfterPlacing()
	-- initial dir should be the edge whose 'ey' basis vector closest aligns with the vector between kings
	local thisKings = self.player.app.board.places:filter(function(place)
		return place.piece
		and King:isa(place.piece)
		and place.piece.player == self.player
	end):mapi(function(place)
		return place.center
	end)
	if #thisKings == 0 then
		self.dir = 1
		return
	end
	local thisKingPos = thisKings:sum() / #thisKings

	local otherKings = self.player.app.board.places:filter(function(place)
		return place.piece
		and King:isa(place.piece)
		and place.piece.player ~= self.player
	end):mapi(function(place)
		return place.center
	end)
	local otherKingPos = otherKings:sum() / #otherKings

	local dirToOtherKing = (otherKingPos - thisKingPos):normalize()
--print('dirToOtherKing', dirToOtherKing)
	self.dir = select(2, self.place.edges:mapi(function(edge)
		--[[ use edge basis ...
		-- ... but what if the edge basis is in the perpendicular plane?
		return (edge.ey:dot(dirToOtherKing))
		--]]
		-- [[ use line to neighboring tile
		if not edge.place then return -math.huge end
		return (edge.place.center - self.place.center):normalize():dot(dirToOtherKing)
		--]]
	end):sup())
	assert(self.dir)
--	local edge = self.place.edges[self.dir]
--print('dir', edge.ex, edge.ey)
end

function Pawn:moveStart(place)
	local nedges = #place.edges
	return coroutine.wrap(function()
		for lr=-1,1 do
			coroutine.yield((self.dir-1) % nedges, true, lr)
		end
	end)
end

function Pawn:moveStep(place, edgeindex, step, lr)
	local nedges = #place.edges
	return coroutine.wrap(function()
		if lr == 0 then
			if self.moved then return end
			-- if this is our starting square then ...
			if step > 1 then return end
			coroutine.yield((edgeindex + math.floor(nedges/2)) % nedges)
		else
			if step > 1 then return end
			local destedgeindex = (edgeindex + math.floor(nedges/2) + lr) % nedges
			local neighbor = place.edges[destedgeindex+1].place
			if not neighbor then return end
			if neighbor.piece then
				if neighbor.piece.player ~= self.player then -- ... or if we're allowing self-capture ...
					coroutine.yield(
						destedgeindex,
						true
					)
				end
			else
				-- else - 
				-- TODO if no piece - then look if a pawn just hopped over this last turn ... if so then allow en piss ant
			end
		end
	end)
end

function Pawn:moveTo(...)
	Pawn.super.moveTo(self, ...)
	self.moved = true
end

local Bishop = Piece:subclass()

Bishop.name = 'bishop'

function Bishop:moveStart(place)
	return coroutine.wrap(function()
		for i=0,#place.edges-1 do
			for lr=-1,1,2 do	-- left vs right
				coroutine.yield(
					i,		-- neighbor
					false,	-- mark? not for the first step
					lr		-- state: left vs right
				)
			end
		end
	end)
end

function Bishop:moveStep(place, edgeindex, step, lr)
	local nedges = #place.edges
	return coroutine.wrap(function()
		if step % 2 == 0 then
			coroutine.yield(
				(edgeindex + math.floor(nedges/2) - lr) % nedges,
				false
			)
		else
			coroutine.yield(
				(edgeindex + math.floor(nedges/2) + lr) % nedges,
				true
			)
		end
	end)
end


local Knight = Piece:subclass()

Knight.name = 'knight'

function Knight:moveStart(place)
	return coroutine.wrap(function()
		for i=0,#place.edges-1 do
			for lr=-1,1,2 do	-- left vs right
				coroutine.yield(
					i,		-- neighbor
					false,	-- mark? not for the first step
					lr		-- state: left vs right
				)
			end
		end
	end)
end
		
function Knight:moveStep(place, edgeindex, step, lr)
	local nedges = #place.edges
	return coroutine.wrap(function()
		if step < 2 then
			coroutine.yield(
				(edgeindex + math.floor(nedges/2)) % nedges,
				false
			)
		elseif step == 2 then
			coroutine.yield(
				(edgeindex + math.floor(nedges/2) + lr) % nedges,
				true
			)
		end
	end)
end


local Rook = Piece:subclass()

Rook.name = 'rook'

function Rook:moveStart(place)
	local nedges = #place.edges
	return coroutine.wrap(function()
		for i=0,nedges-1 do
			coroutine.yield(i)
		end
	end)
end

function Rook:moveStep(place, edgeindex, step)
	local nedges = #place.edges
	return coroutine.wrap(function()
		for ofs=math.floor(nedges/2),math.ceil(nedges/2) do
			coroutine.yield(
				(edgeindex + ofs) % nedges
				--, step % 2 == 0	-- ex: rook that must change color
			)
		end
	end)
end


local Queen = Piece:subclass()

Queen.name = 'queen'

function Queen:moveStart(place)
	return coroutine.wrap(function()
		for i=0,#place.edges-1 do
			for lr=-1,1 do	-- left, center, right
				coroutine.yield(
					i,		-- neighbor
					lr == 0,	-- mark? not for the first bishop step
					lr		-- state: left vs right
				)
			end
		end
	end)
end
		
function Queen:moveStep(place, edgeindex, step, lr)
	local nedges = #place.edges
	return coroutine.wrap(function()
		if lr == 0 then	-- rook move
			for ofs=math.floor(nedges/2),math.ceil(nedges/2) do
				coroutine.yield((edgeindex + ofs) % nedges)
			end
		else	-- bishop move
			if step % 2 == 0 then
				coroutine.yield(
					(edgeindex + math.floor(nedges/2) - lr) % nedges,
					false
				)
			else
				coroutine.yield(
					(edgeindex + math.floor(nedges/2) + lr) % nedges,
					true
				)
			end
		end
	end)
end


King = Piece:subclass()

King.name = 'king'

function King:moveStart(place)
	return coroutine.wrap(function()
		for i=0,#place.edges-1 do
			for lr=-1,1 do	-- left, center, right
				coroutine.yield(
					i,		-- neighbor
					lr == 0,	-- mark? not for the first step
					lr		-- state: left vs right
				)
			end
		end
	end)
end
		
function King:moveStep(place, edgeindex, step, lr)
	local nedges = #place.edges
	return coroutine.wrap(function()
		if lr ~= 0 then	-- bishop move
			if step == 0 then
				coroutine.yield(
					(edgeindex + math.floor(nedges/2) - lr) % nedges,
					false
				)
			elseif step == 1 then
				coroutine.yield(
					(edgeindex + math.floor(nedges/2) + lr) % nedges,
					true
				)
			end
		end
	end)
end



local Player = class()

function Player:init(app)
	self.app = assert(app)
	app.players:insert(self)
	self.index = #app.players
end


local Board = class()

function Board:init(app)
	self.app = assert(app)
	self.places = table()
end

function Board:makePiece(args)
	local cl = assert(args.class)
	if not self.app.enablePieces[cl.name] then return end
	args.class = nil
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
							neighbor = pb
							break
						end
					end
				end
			end
			local edge = {
				place = neighbor,
			}
			edge.ex = (pa.vtxs[i] - pa.vtxs[i2]):normalize()
			-- edge.ez = pa.normal
			edge.ey = pa.normal:cross(edge.ex):normalize()
			pa.edges:insert(edge)
		end
		--[[
		io.write('nbhd', '\t', pa.index, '\t', #pa.edges)
		for i=1,#pa.edges do
			local pb = pa.edges[i].place
			local pc = pa.edges[(i % #pa.edges)+1].place
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
	return self.placeForIndex[i]
end


local TraditionalBoard = Board:subclass()

function TraditionalBoard:makePlaces()
	for j=0,7 do
		for i=0,7 do
			Place{
				board = self,
				color = (i+j)%2 == 1 and vec3f(1,1,1) or vec3f(.2, .2, .2),
				vtxs={
					vec3f(i-4, j-4, 0),
					vec3f(i-3, j-4, 0),
					vec3f(i-3, j-3, 0),
					vec3f(i-4, j-3, 0),
				},
			}
		end
	end

	self.makePieces = function()
		-- board makes players?  or app makes players?  hmm
		-- board holds players?
		assert(#self.app.players == 0)
		for i=1,2 do
			local player = Player(self.app)
			local y = 7 * (i-1)
			self:makePiece{class=Rook, player=player, place=self.places[1 + 0 + 8 * y]}
			self:makePiece{class=Knight, player=player, place=self.places[1 + 1 + 8 * y]}
			self:makePiece{class=Bishop, player=player, place=self.places[1 + 2 + 8 * y]}
			self:makePiece{class=Queen, player=player, place=self.places[1 + 3 + 8 * y]}
			self:makePiece{class=King, player=player, place=self.places[1 + 4 + 8 * y]}
			self:makePiece{class=Bishop, player=player, place=self.places[1 + 5 + 8 * y]}
			self:makePiece{class=Knight, player=player, place=self.places[1 + 6 + 8 * y]}
			self:makePiece{class=Rook, player=player, place=self.places[1 + 7 + 8 * y]}
			local y = 5 * (i-1) + 1
			for x=0,7 do
				self:makePiece{class=Pawn, player=player, place=self.places[1 + x + 8 * y]}
			end
		end
	end
end


local CubeBoard = Board:subclass()

function CubeBoard:makePlaces()
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
						board = self,
						color = (i+j+a)%2 == 0 and vec3f(1,1,1) or vec3f(.2, .2, .2),
						vtxs = vtxs,
					}
					placesPerSide[a][pm][j][i] = place
				end
			end
		end
	end
	self.makePieces = function()
		for i=1,2 do
			local player = Player(self.app)
			assert(player.index == i)
			local places = placesPerSide[0][2*i-3]
			
			self:makePiece{class=Pawn, player=player, place=places[0][0]}
			self:makePiece{class=Pawn, player=player, place=places[1][0]}
			self:makePiece{class=Pawn, player=player, place=places[2][0]}
			self:makePiece{class=Pawn, player=player, place=places[3][0]}

			self:makePiece{class=Bishop, player=player, place=places[0][1]}
			self:makePiece{class=Rook, player=player, place=places[1][1]}
			self:makePiece{class=Queen, player=player, place=places[2][1]}
			self:makePiece{class=Knight, player=player, place=places[3][1]}
			
			self:makePiece{class=Knight, player=player, place=places[0][2]}
			self:makePiece{class=King, player=player, place=places[1][2]}
			self:makePiece{class=Rook, player=player, place=places[2][2]}
			self:makePiece{class=Bishop, player=player, place=places[3][2]}
			
			self:makePiece{class=Pawn, player=player, place=places[0][3]}
			self:makePiece{class=Pawn, player=player, place=places[1][3]}
			self:makePiece{class=Pawn, player=player, place=places[2][3]}
			self:makePiece{class=Pawn, player=player, place=places[3][3]}
		end
	end
end

local App = require 'imguiapp.withorbit'()

App.title = 'Chess or something'
App.viewDist = 5

-- need as many as is in app.players[]
App.colors = table{
	'white',
	'black',
}

function App:initGL()
	App.super.initGL(self)

	-- pieceTexs[color][piece]
	self.pieceTexs = {}

	-- textures:
	local piecesImg = Image'pieces.png'
	print(piecesImg.width, piecesImg.height)
	local texsize = piecesImg.height/2
	assert(piecesImg.width == texsize*6)
	assert(piecesImg.height == texsize*2)
	assert(piecesImg.channels == 4)
	for y=0,piecesImg.height-1 do
		for x=0,piecesImg.width-1 do
			local i = 4 * (x + piecesImg.width * y)
			if piecesImg.buffer[3 + i] < 127 then
				piecesImg.buffer[0 + i] = 0
				piecesImg.buffer[1 + i] = 0
				piecesImg.buffer[2 + i] = 0
			end
		end
	end
	for y,color in ipairs(self.colors) do
		self.pieceTexs[color] = {}
		self.pieceTexs[y] = self.pieceTexs[color]
		for x,piece in ipairs{
			'king',
			'queen',
			'bishop',
			'knight',
			'rook',
			'pawn',
		} do
			local image = piecesImg:copy{
				x = texsize*(x-1),
				y = texsize*(y-1),
				width = texsize,
				height = texsize,
			}
			local tex = GLTex2D{
				image = image,
				minFilter = gl.GL_LINEAR_MIPMAP_LINEAR,
				magFilter = gl.GL_LINEAR,
				generateMipmap = true,
			}
			tex.image = image
			tex.image:save(piece..'-'..color..'.png')
			self.pieceTexs[color][piece] = tex
		end
	end
	
	gl.glBlendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE_MINUS_SRC_ALPHA)
	gl.glEnable(gl.GL_DEPTH_TEST)

	self.netcom = NetCom()
	self.address = 'localhost'
	self.port = 12345
	self.threads = ThreadManager()

	self.enablePieces = {
		king = true,	-- always
		queen = true,
		bishop = true,
		knight = true,
		rook = true,
		pawn = true,
	}
	self:newGame()
end

function App:newGame(boardClass)
	--boardClass = boardClass or CubeBoard
	boardClass = boardClass or TraditionalBoard
	-- per-game
	self.players = table()
	self.board = boardClass(self)
	self.board:makePlaces()
	self.board:buildEdges()
	self.board:makePieces()
	-- run this after placing all pieces
	for _,place in ipairs(self.board.places) do
		local piece = place.piece
		if piece 
		and piece.initAfterPlacing
		then
			piece:initAfterPlacing()
		end
	end
	self.turn = 1
end

local result = vec4ub()
function App:update()
	-- determine tile under mouse
	gl.glClearColor(0,0,0,1)
	gl.glClear(bit.bor(gl.GL_COLOR_BUFFER_BIT, gl.GL_DEPTH_BUFFER_BIT))
	self.board:drawPicking()
	local i, j = self.mouse.ipos:unpack()
	j = self.height - j - 1
	if i >= 0 and j >= 0 and i < self.width and j < self.height then
		gl.glReadPixels(i, j, 1, 1, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, result.s)
	
		self.mouseOverPlace = self.board:getPlaceForRGB(result:unpack())
		if self.mouse.leftClick then
			if self.selectedPlace
			and self.selectedPlace.piece
			and self.selectedPlace.piece.player.index == self.turn
			and self.highlightedPlaces 
			and self.highlightedPlaces:find(self.mouseOverPlace)
			then
				self.highlightedPlaces = nil
				-- move the piece to that square

				self.selectedPlace.piece:moveTo(
					self.mouseOverPlace
				)
			
				self.turn = self.turn % #self.players + 1
			else
				if self.mouseOverPlace
				and self.mouseOverPlace.piece
				then
					self.selectedPlace = self.mouseOverPlace
					if self.selectedPlace then
						local piece = self.selectedPlace.piece
						if piece 
						and piece.getMoves
						then
							self.highlightedPlaces = piece:getMoves()
						else
							self.highlightedPlaces = nil
						end
					end
				else
					self.selectedPlace = nil
				end
			end
		end
	end

	-- draw
	gl.glClearColor(.5, .5, .5, 1)
	gl.glClear(bit.bor(gl.GL_COLOR_BUFFER_BIT, gl.GL_DEPTH_BUFFER_BIT))
	self.board:draw()
	if self.selectedPlace then
		if self.selectedPlace then
			self.selectedPlace:drawHighlight(0,1,0)
		end
		if self.highlightedPlaces then
			for _,place in ipairs(self.highlightedPlaces) do
				place:drawHighlight(1,0,0)
			end
		end
	end

	-- this does the gui drawing *and* does the gl matrix setup
	App.super.update(self)
end

function App:updateGUI()
	local mesh = self.mesh
	if ig.igBeginMainMenuBar() then
		if ig.igBeginMenu'File' then
			ig.igSeparator()
			ig.igText'Local'
			if ig.igButton'New Game: Traditional' then
				self:newGame(TraditionalBoard)
			end
			if ig.igButton'New Game: Cube' then
				self:newGame(CubeBoard)
			end
			ig.igSeparator()
			ig.igText'Remote'
			if ig.igButton'Listen' then
				self.connectPopupOpen = 'listen'
			end
			if ig.igButton'Connect' then
				self.connectPopupOpen = 'connect'
			end
			ig.igEndMenu()
		end
		if ig.igBeginMenu'Options' then
			ig.luatableCheckbox('pawns', self.enablePieces, 'pawn')
			ig.luatableCheckbox('bishops', self.enablePieces, 'bishop')
			ig.luatableCheckbox('knights', self.enablePieces, 'knight')
			ig.luatableCheckbox('rooks', self.enablePieces, 'rook')
			ig.luatableCheckbox('queens', self.enablePieces, 'queen')
			ig.igEndMenu()
		end
		if ig.igBeginMenu('...  '..self.colors[self.turn].."'s turn") then
			ig.igEndMenu()
		end
		ig.igEndMainMenuBar()
	end
	
	if self.connectPopupOpen then
		ig.igPushID_Str'Connect Window'
		if ig.igBegin(self.connectPopupOpen) then
			if self.connectPopupOpen == 'connect' then
				ig.luatableInputText('address', self, 'address')
			end
			ig.luatableInputText('port', self, 'port')
			if ig.igButton'Go' then
				self.connectWaiting = true
				self.clientConn, self.server = self.netcom:start{
					port = self.port,
					threads = self.threads,
					addr = self.connectPopupOpen == 'connect' and self.address or nil,
					
					-- misnomer ... this function inits immediately for the server
					-- so what gets called when the server 
					onConnect = function()
print('beginning '..self.connectPopupOpen)
						self.connectPopupOpen = nil
						self.connectWaiting = nil
						-- TODO wait for a client to connect ...
					end,
				}
				-- TODO popup 'waiting' ...
			end
		end
		ig.igEnd()
		ig.igPopID()
	end
	if self.connectWaiting then
		if ig.igBegin('Waiting...') then
			if ig.igButton'Cancel' then
				-- TODO cancel the connect
				self.connectWaiting = nil
			end
			ig.igEnd()
		end
	end
end

return App():run()
