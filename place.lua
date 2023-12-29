local class = require 'ext.class'
local table = require 'ext.table'
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
			local placeIndex = assert(tonumber((parser:next())))
			lastValue = lastValue or cl{
				player = app.players[playerIndex],
				board = app.board,
				placeIndex = place.index,
			}
			return lastValue
		end,
		--]]
		--[[
		-- __netsend is for a single field of a parent object ...
		__netsend = require 'netrefl.netfield'.NetFieldObject.__netsend,
		--]]
		--[[
		__netsend = function(netfield, socket, prefix, field, thisObj, lastObj, thisValue)
			-- thisObj should always be the Place
			-- field should always be 'piece'
			-- thisValue will be nil or a Piece object
		end,
		--]]
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

	if not self.board.app.transparentBoard then
		gl.glColor3f(self.color:unpack())
		self:drawPolygon()
	end
	if self.piece then
if not self.piece.draw then
	print('self.piece', self.piece)
	error("somehow your piece is of type "..tostring(type(self.piece)).." metatype "..tostring(getmetatable(self.piece)))
end

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
	self:drawPolygon()
	gl.glDepthFunc(gl.GL_LESS)
end

return Place
