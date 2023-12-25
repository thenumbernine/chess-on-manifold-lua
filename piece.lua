local class = require 'ext.class'
local table = require 'ext.table'
local vec3f = require 'vec-ffi.vec3f'
local gl = require 'gl'

local Piece = class()

function Piece:init(args)
	self.player = assert(args.player)
	self.place = assert(args.place)
	if self.place.piece then
		error("tried to place a "..self.name.." of team "..self.player.index.." at place #"..self.place.index.." but instead already found a "..self.place.piece.name.." of team "..self.place.piece.player.index.." there")
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
	local player = self.player
	local app = player.app
	local place = self.place
	local n = place.normal
	local viewX = app.view.angle:xAxis()
	local viewY = app.view.angle:yAxis()
	-- project 'x' onto 'n'
	local drawX = n:project(viewX):normalize()
	local drawY = n:cross(drawX):normalize()
	if drawY:dot(viewY) < 0 then drawY = -drawY end	-- draw facing up if possible
	local tex = app.pieceTexs[player.index][self.name]
	tex
		:enable()
		:bind()
	gl.glColor3f(1,1,1)
	gl.glBegin(gl.GL_QUADS)
	for _,uv in ipairs(uvs) do
		gl.glTexCoord3f(uv:unpack())
		gl.glVertex3f((place.center 
			+ (uv.x - .5) * drawX
			- (uv.y - .5) * drawY
			+ .01 * n
		):unpack())
	end
	gl.glEnd()
	tex
		:unbind()
		:disable()
end

-- returns a table-of-places of where the piece on this place can move
function Piece:getMoves()
	local place = assert(self.place)	-- or just nil or {} for no-place?
	--assert(Place:isa(place))
	assert(place.piece == self)

	local moves = table()

	-- now traverse the manifold, stepping in each direction
	local function iterate(draw, p, srcp, step, already, state)
		--assert(Place:isa(p))
		--assert(Place:isa(srcp))
		if already[p] then return end
		already[p] = true
	
		-- TODO "draw" should be "checkTakePiece" or something
		-- and there should be another flag for "checkBlock" (so knighs can distinguish the two)
		if draw or draw == nil then
		
			-- if we hit a friendly then stop movement ... always ... ?
			if p.piece and p.piece.player == place.piece.player then
				return
			end

			moves:insert(p)
			
			-- same, unfriendly
			if p.piece and p.piece.player ~= place.piece.player then
				return
			end
		end

		-- using edges instead of projective basis
		-- find 'p's neighborhood entry that points back to 'srcp'
		local i,nbhd = p.edges:find(nil, function(nbhd)
			return nbhd.place == srcp
		end)
if not nbhd then
	print("came from", srcp.center)
	print("at", p.center)
	print("with edges")
	for _,n in ipairs(p.edges) do
		print('', n.place.center)
	end
end
		assert(nbhd)

		-- now each piece should pick the next neighbor based on the prev neighbor and the neighborhood ...
		-- cycle  around thema nd see if the piece should move in that direction
		-- ...
		-- hmm, for modulo math's sake, 0-based indexes would be very nice here ...
		-- yields:
		-- 1st: neighborhood index
		-- 2nd: mark or not
		for j, draw in self:moveStep(p, i-1, step, state) do
			-- now pick the piece
			local n = p.edges[j+1]
			if n and n.place then
				iterate(draw, n.place, p, step+1, already, state)
			end
		end
	end
	
	-- yields:
	-- 1st: neighborhood index (0-based)
	-- 2nd: mark or not
	-- 3rd: is forwarded as state variables to 'moveStep'
	for j, draw, state in self:moveStart(place) do
		local n = place.edges[j+1]
		if n and n.place then
			-- make a basis between 'place' and neighbor 'n'
			local already = {}
			already[place] = true
			iterate(draw, n.place, place, 1, already, state)
		end
	end

	return moves
end


function Piece:moveTo(to)
	local from = self.place
	if from then
		from.piece = nil
	end

	-- capture piece
	if to.piece then
		to.piece.place = nil
	end
	to.piece = self
	if to.piece then
		to.piece.place = to
	end
end



local Pawn = Piece:subclass()
Piece.Pawn = Pawn

Pawn.name = 'pawn'

-- ... pawns ... which way is up?
-- geodesic from king to king?  closest to the pawn?
-- this also means  store state info for when the piece is created ... this is only true for pawns
-- run this when we're done placing pieces
function Pawn:initAfterPlacing()
	-- initial dir should be the edge whose 'ey' basis vector closest aligns with the vector between kings
	local thisKings = self.player.app.board.places:filter(function(place)
		return place.piece
		and Piece.King:isa(place.piece)
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
		and Piece.King:isa(place.piece)
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
		-- moving forward ...
			if self.moved then return end
			-- if this is our starting square then ...
			if step > 1 then return end
			local destedgeindex = (edgeindex + math.floor(nedges/2)) % nedges
			local neighbor = place.edges[destedgeindex+1].place
			if not neighbor then return end
			if neighbor.piece then return end	-- ... unless we let pawns capture forward ...
			coroutine.yield(destedgeindex)
		else
		-- diagonal attack...
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
Piece.Bishop = Bishop

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
Piece.Knight = Knight

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
Piece.Rook = Rook

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
Piece.Queen = Queen

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


local King = Piece:subclass()
Piece.King = King

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


return Piece 
