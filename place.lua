local class = require 'ext.class'
local table = require 'ext.table'
local asserttype = require 'ext.assert'.type
local asserteq = require 'ext.assert'.eq
local vec3f = require 'vec-ffi.vec3f'
local gl = require 'gl'
local Piece = require 'piece'

local Place = class()

Place.__netfields = {
	index = require 'netrefl.netfield'.netFieldNumber,
	-- we have to make this netfield such that it constructs pieces for the place, and with the correct info ...
	--[[ createFieldOrNil might not be working... it might only work for lists ...
	piece = require 'netrefl.netfield_list'.createFieldOrNil(
		require 'netrefl.netfield'.NetFieldObject:subclass{
			__netallocator = function(place)
error'here'			
				return Piece{
					board = place.board,
					player = place.board.app.players[1],	-- fake for ctor
					placeIndex = 1,	-- fake for ctor
				}
			end,
		}
	),
	--]]
	piece = {
		-- [[
		__netsend = require 'netrefl.netfield'.NetField.__netsend,
		__netdiff = require 'ext.op'.ne,
		__netcopy = function(x) return x end,
		-- __netencode is only used with default NetField.__netsend implementations
		-- NetFieldObject overrides __netsend, so it doesn't ever call __netencode / __netparse ...
		__netencode = function(piece)
			if piece == nil then
				return ''
			end
			return piece.name..' '..piece.player.index
		end,
		__netparse = function(parser, lastValue, place)
			assert(Place:isa(place))
			local name = parser:next()
			if name == '' then return nil end
			local cl = assert(Piece.classForName[name])
			local playerIndex = assert(tonumber((parser:next())))
			-- this assumes we're never changing a Piece object relative to the client, only creating and destroying them
			if not lastValue then
				lastValue = cl{
					player = place.board.app.players[playerIndex],
					board = place.board,
					placeIndex = place.index,
				}
			end
			return lastValue
		end,
	},
}

function Place:init(args)
	self.board = assert(args.board)
	self.board.places:insert(self)
	self.index = #self.board.places
	
	self.color = args.color
	self.vtxs = table(args.vtxs)
	
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
	self.edges = {
		{
			place = neighborPlace,
		},
	}
	--]]
	self.edges = table()
end

function Place:getEdgeIndexForDir(dir)
	return select(2, self.edges:mapi(function(edge)
		--[[ use edge basis ...
		-- ... but what if the edge basis is in the perpendicular plane?
		return (edge.ey:dot(dirToOtherKing))
		--]]
		-- [[ use line to neighboring tile
		if not edge.placeIndex then return -math.huge end
		return (
			self.board.places[edge.placeIndex].center
			- self.center
		):normalize():dot(dir)
		--]]
	end):sup())
end


function Place:clone(newBoard)
	local place = Place{
		board = newBoard,
		color = self.color,
		vtxs = self.vtxs:mapi(function(v) return v:clone() end),
	}
	if self.piece then
		place.piece = self.piece:clone(newBoard)
	end
	return place
end

function Place:drawLine(r,g,b,a)
	self.board.app:drawSolidLineLoop(self.vtxs, r,g,b,a)
end

function Place:drawPolygon(r,g,b,a)
	local app = self.board.app
	local v0 = self.vtxs[1]
	for j=3,#self.vtxs do
		local vi = self.vtxs[j-1]
		local vj = self.vtxs[j]
		app:drawSolidTri(
			v0.x, v0.y, v0.z, 
			vi.x, vi.y, vi.z, 
			vj.x, vj.y, vj.z, 
			asserttype(r,'number'),asserttype(g,'number'),asserttype(b,'number'),asserttype(a,'number')
		)
	end
end

function Place:draw()
	self:drawLine(0,0,0,1)

	if not self.board.app.transparentBoard then
		asserteq(self.color.dim, 3)
		local r,g,b = self.color:unpack()
		self:drawPolygon(r,g,b,1)
	end
	if self.piece then
if not self.piece.draw then
	print('self.piece', self.piece)
	error("somehow your piece is of type "..tostring(type(self.piece)).." metatype "..tostring(getmetatable(self.piece)))
end

		self.piece:draw()
	end
end

function Place:drawPicking(r,g,b)
	self:drawPolygon(r,g,b,1)
end

function Place:drawHighlight(r,g,b,a)
	a = a or .8
	gl.glDepthFunc(gl.GL_LEQUAL)
	self:drawLine(r,g,b,a)
	self:drawPolygon(r,g,b,a)
	gl.glDepthFunc(gl.GL_LESS)
end

return Place
