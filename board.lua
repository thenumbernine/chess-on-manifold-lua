local gl = require 'gl'
local class = require 'ext.class'
local table = require 'ext.table'
local vec3f = require 'vec-ffi.vec3f'
local Place = require 'place'
local Piece = require 'piece'
local Player = require 'player'

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
Board.Traditional = TraditionalBoard 

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
			self:makePiece{class=Piece.Rook, player=player, place=self.places[1 + 0 + 8 * y]}
			self:makePiece{class=Piece.Knight, player=player, place=self.places[1 + 1 + 8 * y]}
			self:makePiece{class=Piece.Bishop, player=player, place=self.places[1 + 2 + 8 * y]}
			self:makePiece{class=Piece.Queen, player=player, place=self.places[1 + 3 + 8 * y]}
			self:makePiece{class=Piece.King, player=player, place=self.places[1 + 4 + 8 * y]}
			self:makePiece{class=Piece.Bishop, player=player, place=self.places[1 + 5 + 8 * y]}
			self:makePiece{class=Piece.Knight, player=player, place=self.places[1 + 6 + 8 * y]}
			self:makePiece{class=Piece.Rook, player=player, place=self.places[1 + 7 + 8 * y]}
			local y = 5 * (i-1) + 1
			for x=0,7 do
				self:makePiece{class=Piece.Pawn, player=player, place=self.places[1 + x + 8 * y]}
			end
		end
	end
end


local CubeBoard = Board:subclass()
Board.Cube = CubeBoard 

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
			
			self:makePiece{class=Piece.Pawn, player=player, place=places[0][0]}
			self:makePiece{class=Piece.Pawn, player=player, place=places[1][0]}
			self:makePiece{class=Piece.Pawn, player=player, place=places[2][0]}
			self:makePiece{class=Piece.Pawn, player=player, place=places[3][0]}

			self:makePiece{class=Piece.Bishop, player=player, place=places[0][1]}
			self:makePiece{class=Piece.Rook, player=player, place=places[1][1]}
			self:makePiece{class=Piece.Queen, player=player, place=places[2][1]}
			self:makePiece{class=Piece.Knight, player=player, place=places[3][1]}
			
			self:makePiece{class=Piece.Knight, player=player, place=places[0][2]}
			self:makePiece{class=Piece.King, player=player, place=places[1][2]}
			self:makePiece{class=Piece.Rook, player=player, place=places[2][2]}
			self:makePiece{class=Piece.Bishop, player=player, place=places[3][2]}
			
			self:makePiece{class=Piece.Pawn, player=player, place=places[0][3]}
			self:makePiece{class=Piece.Pawn, player=player, place=places[1][3]}
			self:makePiece{class=Piece.Pawn, player=player, place=places[2][3]}
			self:makePiece{class=Piece.Pawn, player=player, place=places[3][3]}
		end
	end
end

return Board
