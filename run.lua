#! /usr/bin/env luajit
local gl = require 'gl'
local table = require 'ext.table'
local class = require 'ext.class'
local math = require 'ext.math'
local vec3f = require 'vec-ffi.vec3f'
local vec4ub = require 'vec-ffi.vec4ub'
local quatf = require 'vec-ffi.quatf'
local Image = require 'image'
local GLTex2D = require 'gl.tex2d'

local App = require 'imguiapp.withorbit'()
App.title = 'Chess or something'

local Place = class()

function Place:init(args)
	self.board = assert(args.board)
	self.board.places:insert(self)
	self.index = #self.board.places
	
	self.color = args.color
	self.vtxs = args.vtxs
	
	local normal = vec3f(0,0,0)
	local n = #self.vtxs
	for i=1,n do
		local a = self.vtxs[i]
		local b = self.vtxs[i%n+1]
		local c = self.vtxs[(i+1)%n+1]
		normal = normal + (b - a):cross(c - b):normalize()
	end
	self.normal = normal:normalize()

	-- TODO volume-weighted average?
	local center = vec3f(0,0,0)
	for _,v in ipairs(self.vtxs) do
		center = center + v
	end
	center = center * (1/n)
	self.center = center

	--[[ fill out later
	self.neighbors = {
		{
			place = neighborPlace,
			opposites = { ... },
		},
	}
	--]]
	self.neighbors = table()
end

function Place:drawLine()
	gl.glBegin(gl.GL_LINE_LOOP)
	for _,v in ipairs(self.vtxs) do
		gl.glVertex3f(v:unpack())
	end
	gl.glEnd()
end

function Place:drawPolygon()
	gl.glBegin(gl.GL_POLYGON)
	for _,v in ipairs(self.vtxs) do
		gl.glVertex3f(v:unpack())
	end
	gl.glEnd()
end

function Place:draw()
	gl.glColor3f(0,0,0)
	self:drawLine()

	gl.glColor3f(self.color:unpack())
	self:drawPolygon()

	if self.piece then
		self.piece:draw()
	end
end

function Place:drawPicking()
	-- assume color is already set
	-- and don't bother draw the outline
	self:drawPolygon()
end

function Place:drawHighlight(r,g,b,a)
	a = a or .8
	gl.glDepthFunc(gl.GL_LEQUAL)
	gl.glColor4f(r,g,b,a)
	self:drawLine()
	gl.glEnable(gl.GL_BLEND)
	self:drawPolygon()
	gl.glDepthFunc(gl.GL_LESS)
	gl.glDisable(gl.GL_BLEND)
end


local Piece = class()

function Piece:init(args)
	self.player = assert(args.player)
	self.place = assert(args.place)
	if self.place.piece then
		error("tried to place a "..self.name.." at place #"..self.place.index.." but instead already found a "..self.place.piece.name.." there")
	end
	self.place.piece = self
end

local uvs = table{
	vec3f(0,0,0),
	vec3f(0,1,0),
	vec3f(1,1,0),
	vec3f(1,0,0),
}
function Piece:draw()
	gl.glEnable(gl.GL_ALPHA_TEST)
	gl.glAlphaFunc(gl.GL_GREATER, .5)
	local player = self.player
	local app = player.app
	local vx = app.view.angle:xAxis()
	local vy = app.view.angle:yAxis()
	local vz = app.view.angle:zAxis()
	local tex = app.pieceTexs[player.index][self.name]
	tex
		:enable()
		:bind()
	gl.glColor3f(1,1,1)
	gl.glBegin(gl.GL_QUADS)
	for _,uv in ipairs(uvs) do
		gl.glTexCoord3f(uv:unpack())
		gl.glVertex3f((self.place.center 
			+ (uv.x - .5) * vx 
			- (uv.y - .5) * vy
			+ vz
		):unpack())
	end
	gl.glEnd()
	tex
		:unbind()
		:disable()
	gl.glDisable(gl.GL_ALPHA_TEST)
end


local Pawn = Piece:subclass()
Pawn.name = 'pawn'

local Bishop = Piece:subclass()
Bishop.name = 'bishop'

local Knight = Piece:subclass()
Knight.name = 'knight'

local Rook = Piece:subclass()
Rook.name = 'rook'

local Queen = Piece:subclass()
Queen.name = 'queen'

local King = Piece:subclass()
King.name = 'king'


local Player = class()

function Player:init(app)
	self.app = assert(app)
	app.players:insert(self)
	self.index = #app.players
end


local Board = class()

function Board:init(app)
	self.app = app
	self.places = table()
	
	self:makePlaces()

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
			local opposites
			for b,pb in ipairs(self.places) do
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
			if neighbor then
				pa.neighbors:insert{
					place = neighbor,
					opposites = {opposite},
				}
			end
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
	return self.placeForIndex[i]
end

local function project(v, n)
	return v - n * v:dot(n) / n:dot(n)
end

local function quatFromVectors(a, b)
	a = a:normalize()
	b = b:normalize()
	local axis = a:cross(b)
	local axislen = axis:length()
	local angle = math.deg(math.asin(math.clamp(axislen,-1,1)))
	return axislen < 1e-7
		and quatf(0,0,0,1) 
		or quatf():fromAngleAxis(
			axis.x, axis.y, axis.z,
			angle
		)
end

function Board:showMoves(place, canmove)
do return end	-- TODO use neighbors[i].place and .opposites[]
	place:drawHighlight(0,1,0)

	local already = {}
	already[place] = true

	local function buildBasis(p, n)
		local bs = {}
		local proj = p.normal
		bs[1] = project(n.center - p.center, proj):normalize()
		bs[2] = vec3f(proj:unpack())
		bs[3] = bs[1]:cross(bs[2]):normalize()
		return bs
	end

	-- now traverse the manifold, stepping in each direction
	-- neighbor info ... needs a direction ...
	local function iterate(p, p2, step, obs)
		if already[p] then return end
		already[p] = true
		p:drawHighlight(1,0,0)

		for _,info in ipairs(p.neighbors) do
			local n = info.place
			local cs = buildBasis(p, n)

			-- now rotate 'b' into the current tangent basis ... based on the normals
			-- [[
			local q = quatFromVectors(p.normal, n.normal)
			local bs = {
				q:rotate(obs[1]),
				q:rotate(obs[2]),
				q:rotate(obs[3]),
			}
			--]]
			--[[
			local bs = {obs[1], obs[2], obs[3]}
			--]]

			if canmove(bs, cs, step) then
				iterate(n, p, step+1, bs)
			end
		end
	end

	for _,n in ipairs(place.neighbors) do
		-- make a basis between 'place' and neighbor 'n'
		local bs = buildBasis(place, n)
		iterate(n, place, 1, bs)
	end
end


local TraditionalBoard = Board:subclass()

function TraditionalBoard:makePlaces()
	for j=0,7 do
		for i=0,7 do
			Place{
				board = self,
				color = (i+j)%2 == 0 and vec3f(1,1,1) or vec3f(.2, .2, .2),
				vtxs={
					vec3f(i-4, j-4, 0),
					vec3f(i-3, j-4, 0),
					vec3f(i-3, j-3, 0),
					vec3f(i-4, j-3, 0),
				},
			}
		end
	end

	-- board makes players?  or app makes players?  hmm
	-- board holds players?
	assert(#self.app.players == 0)
	for i=1,2 do
		local player = Player(self.app)
		local y = 7 * (i-1)
		Rook{player=player, place=self.places[1 + 0 + 8 * y]}
		Knight{player=player, place=self.places[1 + 1 + 8 * y]}
		Bishop{player=player, place=self.places[1 + 2 + 8 * y]}
		Queen{player=player, place=self.places[1 + 3 + 8 * y]}
		King{player=player, place=self.places[1 + 4 + 8 * y]}
		Bishop{player=player, place=self.places[1 + 5 + 8 * y]}
		Knight{player=player, place=self.places[1 + 6 + 8 * y]}
		Rook{player=player, place=self.places[1 + 7 + 8 * y]}
		local y = 5 * (i-1) + 1
		for x=0,7 do
			Pawn{player=player, place=self.places[1 + x + 8 * y]}
		end
	end
end


local CubeBoard = class(Board)

function CubeBoard:makePlaces()
	for a=0,2 do
		local b = (a+1)%3
		local c = (b+1)%3
		for pm=-1,1,2 do
			local function vtx(i,j)
				local v = vec3f()
				v.s[a] = i
				v.s[b] = j
				v.s[c] = pm*2
				return v
			end
			for j=0,3 do
				for i=0,3 do
					Place{
						board = self,
						color = (i+j+a)%2 == 0 and vec3f(1,1,1) or vec3f(.2, .2, .2),
						vtxs = {
							vtx(i-2, j-2),
							vtx(i-1, j-2),
							vtx(i-1, j-1),
							vtx(i-2, j-1),
						},
					}
				end
			end
		end
	end
end

function App:initGL()
	App.super.initGL(self)

	-- pieceTexs[color][piece]
	self.pieceTexs = {}

	-- textures:
	local piecesImg = Image'pieces.png'
	print(piecesImg.width, piecesImg.height)
	assert(piecesImg.width == 256*6)
	assert(piecesImg.height == 256*2)
	assert(piecesImg.channels == 4)
	for y=0,piecesImg.height-1 do
		for x=0,piecesImg.width-1 do
			local i = 4 * (x + piecesImg.width * y)
			if piecesImg.buffer[3 + i] < 127 then
				piecesImg.buffer[0 + i] = 0
				piecesImg.buffer[1 + i] = 0xff
				piecesImg.buffer[2 + i] = 0xff
			end
		end
	end
	for y,color in ipairs{
		'white',
		'black',
	} do
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
				x = 256*(x-1),
				y = 256*(y-1),
				width = 256,
				height = 256,
			}
			local tex = GLTex2D{
				image = image,
				minFilter = gl.GL_NEAREST,
				magFilter = gl.GL_LINEAR,
			}
			tex.image = image
			tex.image:save(piece..'-'..color..'.png')
			self.pieceTexs[color][piece] = tex
		end
	end

	-- per-game
	self.players = table()
	self.board = TraditionalBoard(self)
	--self.board = CubeBoard()

	gl.glBlendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE_MINUS_SRC_ALPHA)
	gl.glEnable(gl.GL_DEPTH_TEST)
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
	
		self.selectedPlace = self.board:getPlaceForRGB(result:unpack())
		if self.mouse.leftClick then
			print(result:unpack(), self.selectedPlace.center)
		end
	end

	-- draw
	gl.glClearColor(.5, .5, .5, 1)
	gl.glClear(bit.bor(gl.GL_COLOR_BUFFER_BIT, gl.GL_DEPTH_BUFFER_BIT))
	self.board:draw()
	if self.selectedPlace then
		-- [[ rook moves
		self.board:showMoves(self.selectedPlace, function(bs, cs, step)
			return bs[1]:dot(cs[1]) > .7
		end)
		--]]
		--[[ bishop moves
		self.board:showMoves(self.selectedPlace, function(bs, cs, step)
			if step % 2 == 1 then
				return bs[1]:dot(cs[1]) > .7
			elseif step % 2 == 0 then
				return bs[2]:dot(cs[1]) > .7
			end
		end)
		--]]
	end

	-- this does the gui drawing *and* does the gl matrix setup
	App.super.update(self)
end

return App():run()
