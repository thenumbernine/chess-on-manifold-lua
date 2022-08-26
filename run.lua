#! /usr/bin/env luajit
local gl = require 'gl'
local table = require 'ext.table'
local class = require 'ext.class'
local math = require 'ext.math'
local vec3f = require 'vec-ffi.vec3f'
local vec4ub = require 'vec-ffi.vec4ub'
local quatf = require 'vec-ffi.quatf'

local App = require 'imguiapp.withorbit'()
App.title = 'Chess or something'

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

App():run()
