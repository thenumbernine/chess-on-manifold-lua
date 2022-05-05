#! /usr/bin/env luajit
local gl = require 'gl'
local table = require 'ext.table'
local App = require 'glapp.orbit'(require 'imguiapp')
local vec3f = require 'vec-ffi.vec3f'
local vec4ub = require 'vec-ffi.vec4ub'
local class = require 'ext.class'


local Place = class()

function Place:init(args)
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

	-- fill out later
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


local Board = class()

function Board:init()
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

	for a=1,#self.places-1 do
		local pa = self.places[a]
		for b=a+1,#self.places do
			local pb = self.places[b]
			for i=1,#pa.vtxs do
				for j=1,#pb.vtxs do
					if edgeMatches(
						pa.vtxs[i],
						pa.vtxs[i%#pa.vtxs+1],
						pb.vtxs[j],
						pb.vtxs[j%#pb.vtxs+1])
					then
						-- TODO do this per-direction
						pa.neighbors:insert(pb)
						pb.neighbors:insert(pa)
					end
				end
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

function Board:showMoves(place, canmove)
	place:drawHighlight(0,1,0)

	local already = {}
	already[place] = true

	-- now traverse the manifold, stepping in each direction
	-- neighbor info ... needs a direction ...
	local function iterate(p, p2)
		if already[p] then return end
		already[p] = true
		p:drawHighlight(1,0,0)
		for _,n in ipairs(p.neighbors) do
			local dir = project(p.center - p2.center, p.normal):normalize()
			local dir2 = project(n.center - p.center, p.normal):normalize()
			if canmove(dir, dir2) then
				iterate(n, p)
			end
		end
	end
	
	for _,n in ipairs(place.neighbors) do
		iterate(n, place)
	end
end


local TraditionalBoard = class(Board)

function TraditionalBoard:makePlaces()
	for j=0,7 do
		for i=0,7 do
			self.places:insert(Place{
				color = (i+j)%2 == 0 and vec3f(1,1,1) or vec3f(.2, .2, .2),
				vtxs={
					vec3f(i-4, j-4, 0),
					vec3f(i-3, j-4, 0),
					vec3f(i-3, j-3, 0),
					vec3f(i-4, j-3, 0),
				},
			})
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
					self.places:insert(Place{
						color = (i+j+a)%2 == 0 and vec3f(1,1,1) or vec3f(.2, .2, .2),
						vtxs = {
							vtx(i-2, j-2),
							vtx(i-1, j-2),
							vtx(i-1, j-1),
							vtx(i-2, j-1),
						},
					})
				end
			end
		end
	end
end

function App:initGL()
	App.super.initGL(self)

	--self.board = TraditionalBoard()
	self.board = CubeBoard()

	gl.glBlendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE_MINUS_SRC_ALPHA)
	gl.glEnable(gl.GL_DEPTH_TEST)
end

local result = vec4ub()
function App:update()
	-- determine tile under mouse
	gl.glClear(bit.bor(gl.GL_COLOR_BUFFER_BIT, gl.GL_DEPTH_BUFFER_BIT))
	self.board:drawPicking()
	local i, j = self.mouse.ipos:unpack()
	j = self.height - j - 1
	if i >= 0 and j >= 0 and i < self.width and j < self.height then
		gl.glReadPixels(i, j, 1, 1, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, result.s)
		self.selectedPlace = self.board:getPlaceForRGB(result:unpack())
	end

	-- draw
	gl.glClear(bit.bor(gl.GL_COLOR_BUFFER_BIT, gl.GL_DEPTH_BUFFER_BIT))
	self.board:draw()

	if self.selectedPlace then
		self.board:showMoves(self.selectedPlace, function(dir, dir2)
			return dir:dot(dir2) > .1
		end)
	end

	-- this does the gui drawing *and* does the gl matrix setup
	App.super.update(self)
end

App():run()
