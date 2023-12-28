local class = require 'ext.class'
local table = require 'ext.table'
local vec3f = require 'vec-ffi.vec3f'
local gl = require 'gl'

local Piece = class()

function Piece:init(args)
	self.player = assert(args.player)
	self.board = assert(args.board)
	self.placeIndex = assert(args.placeIndex)
	if self.board.places[self.placeIndex].piece then
		error("tried to place a "..self.name.." of team "..self.player.index.." at place #"..self.placeIndex.." but instead already found a "..self.board.places[self.placeIndex].piece.name.." of team "..self.board.places[self.placeIndex].piece.player.index.." there")
	end
	self.board.places[self.placeIndex].piece = self
end

function Piece:clone(newBoard)
	local piece = getmetatable(self){
		board = newBoard,
		player = self.player,
		placeIndex = self.placeIndex,
		lastPlaceIndex = self.lastPlaceIndex,
		moved = self.moved,
	}
	return piece
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
	local place = self.board.places[self.placeIndex]
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
-- friendlyFire = true means consider friendly-fire attacks.  this is useful for generating the help arrow annotations.
function Piece:getMoves(friendlyFire)
	local startPlace = assert(self.board.places[self.placeIndex])	-- or just nil or {} for no-place?
--DEBUG:assert(Place:isa(startPlace))
	assert(startPlace.piece == self)

	-- TODO don't return a list of places
	-- return a list of paths / edges
	-- then use this with pawn/king to determine en-pessant and castle
	local movePaths = table()

	-- now traverse the manifold, stepping in each direction
	local function iterate(path, blocking, place, prevPlace, step, already, state)
--DEBUG:assert(Place:isa(place))
--DEBUG:assert(Place:isa(prevPlace))
		if already[place] then return end
		already[place] = true

		if blocking then

			-- if we hit a friendly then stop movement
			if place.piece and place.piece.player == startPlace.piece.player
			and not friendlyFire
			then
				return
			end

			-- notice I'm only ever doing shallow-copies of the 'path' entries ... not that it matters atm, nothing is modifying them.
			local movePath = table(path)
			movePath:insert{
				placeIndex = place.index,
			}
			movePaths:insert(movePath)

			-- same, unfriendly
			if place.piece then
				return
			end
		end

		-- using edges instead of projective basis
		-- find 'place's neighborhood entry that points back to 'prevPlace'
		local edgeIndex,edge = place.edges:find(nil, function(edge)
			return self.board.places[edge.placeIndex] == prevPlace
		end)
		if not edge then
			print("came from", prevPlace.center)
			print("at", place.center)
			print("with edges")
			for _,edge in ipairs(place.edges) do
				print('', self.board.places[edge.placeIndex].center)
			end
			error"couldn't find edge"
		end

		-- now each piece should pick the next neighbor based on the prev neighbor and the neighborhood ...
		-- cycle  around thema nd see if the piece should move in that direction
		-- ...
		-- hmm, for modulo math's sake, 0-based indexes would be very nice here ...
		-- yields:
		-- 1st: neighborhood index
		-- 2nd: mark or not
		for moveEdgeIndex, blocking in self:moveStep{
			place = place,
			edgeIndex = edgeIndex-1,
			step = step,
			state = state,
			friendlyFire = friendlyFire,
		} do
			-- now pick the piece
			local edge = place.edges[moveEdgeIndex+1]
			if edge and self.board.places[edge.placeIndex] then
				local nextPath = table(path)
				nextPath:insert{
					placeIndex = place.index,
					edge = moveEdgeIndex+1,
				}
				iterate(nextPath, blocking, self.board.places[edge.placeIndex], place, step+1, already, state)
			end
		end
	end

	-- yields:
	-- 1st: neighborhood index (0-based)
	-- 2nd: mark or not
	-- 3rd: is forwarded as state variables to 'moveStep'
	for moveEdgeIndex, blocking, state in self:moveStart{
		place = startPlace,
		friendlyFire = friendlyFire,
	} do
		local edge = startPlace.edges[moveEdgeIndex+1]
		if edge then
			local nextPlace = self.board.places[edge.placeIndex]
			if nextPlace then
				local already = {}
				already[startPlace] = true
				local path = table()
				path:insert{
					placeIndex = startPlace.index,
					edge = moveEdgeIndex+1,
				}
				iterate(path, blocking, nextPlace, startPlace, 1, already, state)
			end
		end
	end

	return movePaths
end


function Piece:moveTo(to)--movePath)
-- TODO assert movePath[1].place == self.place
--	local to = movePath:last().place 
	
	self.lastPlaceIndex = self.placeIndex
	local from = self.board.places[self.placeIndex]
	if from then
		from.piece = nil
	end

	-- capture piece
	if to.piece then
		to.piece.placeIndex = nil
	end
	to.piece = self
	self.placeIndex = to.index
	self.moved = true
end



local Pawn = Piece:subclass()
Piece.Pawn = Pawn

Pawn.name = 'pawn'

function Pawn:clone(...)
	local piece = Pawn.super.clone(self, ...)
	piece.dir = self.dir
	return piece
end

-- ... pawns ... which way is up?
-- geodesic from king to king?  closest to the pawn?
-- this also means  store state info for when the piece is created ... this is only true for pawns
-- run this when we're done placing pieces
function Pawn:initAfterPlacing()
	self.dir = self.board.places[self.placeIndex]:getEdgeIndexForDir(
		self.board.playerDirToOtherKings[self.player.index]
	)
	assert(self.dir)
--	local edge = self.board.places[self.placeIndex].edges[self.dir]
--print('dir', edge.ex, edge.ey)
end

--[[
args:
	place
yields:
	moveEdgeIndex, = 0-based edge that we are considering moving to
	blocking, = true for if this is a step that can capture / be blocked
	state
--]]
function Pawn:moveStart(args)
	local place = args.place
	local nedges = #place.edges
	return coroutine.wrap(function()
		for lr=-1,1 do
			if lr == 0 then
				-- move forward if nothing is there ...
				local neighbor = self.board.places[place.edges[self.dir].placeIndex]
				if neighbor
				and not neighbor.piece
				then -- ... unless we let pawns capture forward 1 tile ...
					coroutine.yield(self.dir-1, true, lr)
				end
			else
				-- start our diagonal step for captures
				coroutine.yield(self.dir-1, false, lr)
			end
		end
	end)
end

--[[
args:
	place
	edgeIndex (0-based)
	step
	state
--]]
function Pawn:moveStep(args)
	local place = args.place
	local edgeindex = args.edgeIndex
	local step = args.step
	local lr = args.state
	local nedges = #place.edges
	return coroutine.wrap(function()
		if lr == 0 then
			-- moving forward ...
			if self.moved then return end
			-- if this is our starting square then ...
			if step > 1 then return end
			local destedgeindex = (edgeindex + math.floor(nedges/2)) % nedges
			local neighbor = self.board.places[place.edges[destedgeindex+1].placeIndex]
			if not neighbor then return end
			if neighbor.piece then return end	-- ... unless we let pawns capture forward 2 tiles ...
			coroutine.yield(destedgeindex, true)
		else
		-- diagonal attack...
			if step > 1 then return end
			local destedgeindex = (edgeindex + math.floor(nedges/2) + lr) % nedges
			local neighbor = self.board.places[place.edges[destedgeindex+1].placeIndex]
			if not neighbor then return end
			if neighbor.piece then
				coroutine.yield(destedgeindex, true)
			else
				-- else -
				-- TODO if no piece - then look if a pawn just hopped over this last turn ... if so then allow en piss ant
			end
		end
	end)
end

function Pawn:moveTo(...)
	Pawn.super.moveTo(self, ...)
	-- TODO here - if we ended up moving 2 squares then save our from and to
	-- and esp the square between
	-- and, for the length of 1 move, save that as the en-pessant square
end

local Bishop = Piece:subclass()
Piece.Bishop = Bishop

Bishop.name = 'bishop'

function Bishop:moveStart(args)
	local place = args.place
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

function Bishop:moveStep(args)
	local place = args.place
	local edgeindex = args.edgeIndex
	local step = args.step
	local lr = args.state
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

function Knight:moveStart(args)
	local place = args.place
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

function Knight:moveStep(args)
	local place = args.place
	local edgeindex = args.edgeIndex
	local step = args.step
	local lr = args.state
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

function Rook:moveStart(args)
	local place = args.place
	local nedges = #place.edges
	return coroutine.wrap(function()
		for i=0,nedges-1 do
			coroutine.yield(i, true)
		end
	end)
end

function Rook:moveStep(args)
	local place = args.place
	local edgeindex = args.edgeIndex
	local step = args.step
	local nedges = #place.edges
	return coroutine.wrap(function()
		for ofs=math.floor(nedges/2),math.ceil(nedges/2) do
			coroutine.yield(
				(edgeindex + ofs) % nedges,
				true--, step % 2 == 0	-- ex: rook that must change tile color
			)
		end
	end)
end


local Queen = Piece:subclass()
Piece.Queen = Queen

Queen.name = 'queen'

function Queen:moveStart(args)
	local place = args.place
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

function Queen:moveStep(args)
	local place = args.place
	local edgeindex = args.edgeIndex
	local step = args.step
	local lr = args.state
	local nedges = #place.edges
	return coroutine.wrap(function()
		if lr == 0 then	-- rook move
			for ofs=math.floor(nedges/2),math.ceil(nedges/2) do
				coroutine.yield(
					(edgeindex + ofs) % nedges,
					true
				)
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

function King:moveStart(args)
	local place = args.place
	local nedges = #place.edges
	local fwddir = place:getEdgeIndexForDir(self.board.playerDirToOtherKings[self.player.index])
	return coroutine.wrap(function()
		for i=0,nedges-1 do
			for lr=-1,1 do	-- left, center, right
				coroutine.yield(
					i,		-- neighbor
					lr == 0,	-- mark? not for the first step
					lr		-- state: left vs right
				)
			end
		end
		-- TODO here, yield for the left and right neighbors, with a 'lr' of +2/-2 ...
		-- and then code in the lr == +-2 states below ...
		-- and for those, don't allow them to move if the move would put us in check ...
		if not self.moved then
			-- TODO if the left rook hasn't moved ...
			-- and there's no check ...
			-- on the king, on the tile to the left, on the tile two left ...
			coroutine.yield(fwddir % nedges, false, 2)
			-- TODO if the right rook hasn't moved ...
			coroutine.yield((fwddir + 2) % nedges, false, -2)
		end
	end)
end

function King:moveStep(args)
	local place = args.place
	local edgeindex = args.edgeIndex
	local step = args.step
	local lr = args.state
	local nedges = #place.edges
	return coroutine.wrap(function()
		assert(step > 0)
		if lr == 1 or lr == -1 then	-- diagonal move
			if step == 1 then
				coroutine.yield(
					(edgeindex + math.floor(nedges/2) + lr) % nedges,
					true
				)
			end
		elseif lr == 2 or lr == -2 then	-- castle
			if step == 1 then
				coroutine.yield(
					(edgeindex + math.floor(nedges/2)) % nedges,
					true
				)
			end
		end
	end)
end


return Piece
