local class = require 'ext.class'
local table = require 'ext.table'
local vec3f = require 'vec-ffi.vec3f'
local gl = require 'gl'

local netFieldPlayerRef = require 'netrefl.netfield'.NetField:subclass{
	__netencode = function(player) 
		if not parser then return '' end
		return tostring(player.index) 
	end,
	__netparse = function(parser) 
		local s = parser:next()
		if s == '' then return nil end
		local i = assert(tonumber(s))
		return assert(app.players[i]) 
	end,
}

local Piece = class()

Piece.__netfields = {
	placeIndex = require 'netrefl.netfield'.netFieldNumber,
	-- send/recv the player index ...
	player = netFieldPlayerRef,
}

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
	vec3f(1,0,0),
	vec3f(1,0,0),
	vec3f(0,1,0),
	vec3f(1,1,0),
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
	local sceneObj = app.drawPieceSceneObj
	sceneObj.uniforms.mvProjMat = app.view.mvProjMat.ptr
	sceneObj.texs[1] = tex
	sceneObj.uniforms.center = {place.center:unpack()}
	sceneObj.uniforms.drawX = {drawX:unpack()}
	sceneObj.uniforms.drawY = {drawY:unpack()}
	sceneObj.uniforms.normal = {n:unpack()}
	sceneObj:draw()
end

-- returns a table-of-places of where the piece on this place can move
-- friendlyFire = true means consider friendly-fire attacks.  this is useful for generating the help arrow annotations.
function Piece:getMoves(friendlyFire)
	local startPlace = assert(self.board.places[self.placeIndex])	-- or just nil or {} for no-place?
--DEBUG(Piece):assert(require 'place':isa(startPlace))
	assert(startPlace.piece == self)

	-- TODO don't return a list of places
	-- return a list of paths / edges
	-- then use this with pawn/king to determine en-passant and castle
	local movePaths = table()

	-- now traverse the manifold, stepping in each direction
	local function iterate(path, blocking, place, prevPlace, step, already, state)
--DEBUG(Piece):assert(require 'place':isa(place))
--DEBUG(Piece):assert(require 'place':isa(prevPlace))
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
		-- if we have a one-way edge ...
		if not edge then
			print("came from", prevPlace.center)
			print("at", place.center)
			print("with edges")
			for _,edge in ipairs(place.edges) do
				print('', self.board.places[edge.placeIndex].center)
			end
			print"couldn't find edge"
			return
		end

		-- now each piece should pick the next neighbor based on the prev neighbor and the neighborhood ...
		-- cycle  around thema nd see if the piece should move in that direction
		-- ...
		-- hmm, for modulo math's sake, 0-based indexes would be very nice here ...
		-- yields:
		-- 1st: edge index
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
					edgeIndex = moveEdgeIndex+1,
				}
				iterate(nextPath, blocking, self.board.places[edge.placeIndex], place, step+1, already, state)
			end
		end
	end

	-- yields:
	-- 1st: edge index (0-based)
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
				path.state = state	-- state doesn't change throughout a path
				path:insert{
					placeIndex = startPlace.index,
					edgeIndex = moveEdgeIndex+1,
				}
				iterate(path, blocking, nextPlace, startPlace, 1, already, state)
			end
		end
	end

	return movePaths
end


function Piece:move(movePath)
--DEBUG(Piece):assert(movePath[1].placeIndex == self.placeIndex)
	local to = self.board.places[movePath:last().placeIndex]
	
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
	self.lastMovePath = movePath
	self.board.lastMovedPlaceIndex = assert(to.index)
end



local Pawn = Piece:subclass()
Piece.Pawn = Pawn

Pawn.name = 'pawn'
Pawn.score = 1

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
				local edge = place.edges[(self.dir-1)%nedges+1]
				if edge then
					local nextPlace = self.board.places[edge.placeIndex]
					if nextPlace
					and not nextPlace.piece
					then -- ... unless we let pawns capture forward 1 tile ...
						coroutine.yield(self.dir-1, true, lr)
					end
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
			local nextPlace = self.board.places[place.edges[destedgeindex+1].placeIndex]
			if not nextPlace then return end
			if nextPlace.piece then return end	-- ... unless we let pawns capture forward 2 tiles ...
			coroutine.yield(destedgeindex, true)
		else
		-- diagonal attack...
			if step > 1 then return end
			local destedgeindex = (edgeindex + math.floor(nedges/2) + lr) % nedges
			local nextPlace = self.board.places[place.edges[destedgeindex+1].placeIndex]
			if nextPlace then
				if nextPlace.piece then
					coroutine.yield(destedgeindex, true)
				else
					-- TODO if no piece is there ...
					-- then look if a pawn just hopped over this last turn ... 
					-- if so then allow en piss ant
					local enpassant
					for _,p in ipairs(self.board.places) do
						-- TODO en-passant last-moved-only gameplay flag?
						if self.board.lastMovedPlaceIndex == p.index then	-- this was the last-moved piece
							local piece = p.piece
							if piece 
							and Pawn:isa(piece) 
							and piece.lastMovePath
							and piece.lastMovePath.state == 0	-- it was a straight move, not a diagonal capture
							and #piece.lastMovePath == 3			-- it went 2 tiles
							and piece.lastMovePath[2].placeIndex == nextPlace.index	-- the middle tile is our target
							then
								enpassant = true
								break
							end
						end
					end
					if enpassant then
						-- ok and LOL now we need EXTRA RULES for making the move
						-- (as well as just detecting the move)
						coroutine.yield(destedgeindex, true)
					end
				end
			end
		end
	end)
end

function Pawn:move(movePath)
--DEBUG(Piece):print('Pawn:move self.board.lastMovedPlaceIndex', self.board.lastMovedPlaceIndex)
	local to = self.board.places[movePath:last().placeIndex]
	-- if the move is an en-passant ...
	-- then make sure to eat the piece
	if to.piece == nil then
		for _,p in ipairs(self.board.places) do
			if self.board.lastMovedPlaceIndex == p.index then	-- this was the last-moved piece
				local piece = p.piece
				if piece 
				and Pawn:isa(piece) 
				and piece.player ~= self.player
				and piece.lastMovePath
				and piece.lastMovePath.state == 0	-- it was a straight move, not a diagonal capture
				and #piece.lastMovePath == 3			-- it went 2 tiles
				and piece.lastMovePath[2].placeIndex == to.index
				-- and the piece was the last-moved-piece of this player
				then
					piece.placeIndex = nil
					p.piece = nil
				end
			end
		end
	end

	Pawn.super.move(self, movePath)
	-- TODO here - if we ended up moving 2 squares then save our from and to
	-- and esp the square between
	-- and, for the length of 1 move, save that as the en-passant square
end

local Bishop = Piece:subclass()
Piece.Bishop = Bishop

Bishop.name = 'bishop'
Bishop.score = 3

function Bishop:moveStart(args)
	local place = args.place
	return coroutine.wrap(function()
		for i=0,#place.edges-1 do
			for lr=-1,1,2 do	-- left vs right
				coroutine.yield(
					i,		-- edge to next place
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
Knight.score = 3

function Knight:moveStart(args)
	local place = args.place
	return coroutine.wrap(function()
		for i=0,#place.edges-1 do
			for lr=-1,1,2 do	-- left vs right
				coroutine.yield(
					i,		-- edge to next place
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
Rook.score = 5

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
Queen.score = 10

function Queen:moveStart(args)
	local place = args.place
	return coroutine.wrap(function()
		for i=0,#place.edges-1 do
			for lr=-1,1 do	-- left, center, right
				coroutine.yield(
					i,		-- edge to next place
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
King.score = 99

function King:moveStart(args)
	local place = args.place
	local nedges = #place.edges
	local fwddir = place:getEdgeIndexForDir(self.board.playerDirToOtherKings[self.player.index])
	return coroutine.wrap(function()
		for i=0,nedges-1 do
			for lr=-1,1 do	-- left, center, right
				coroutine.yield(
					i,		-- edge to next place
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
				-- only allow this if ...
				if self.moved then
--DEBUG(Piece):print("...can't castle, the king has already moved")				
				else
					-- ... the king hasn't moved
					-- rook must be friendly, not moved, and no pieces between, with no attacks
					local rook = self:findCastleRook(place, edgeindex+1)
					if rook then
--DEBUG(Piece):print("King found castle-able rook!")						
						coroutine.yield(
							(edgeindex + math.floor(nedges/2)) % nedges,
							true
						)
					end
				end
			end
		end
	end)
end

-- place = first place next to the king
-- edgeIndex = 1-based edge in the direction we're going
function King:findCastleRook(place, edgeIndex)
--DEBUG(Piece):print("King:findCastleRook starting at", place.index, "centered", place.center, "edge", edgeIndex)
	local nedges = #place.edges
	edgeIndex = (edgeIndex - 1 + math.floor(nedges/2)) % nedges + 1
	while true do
		local piece = place.piece 
		if piece then
--DEBUG(Piece):print("King:findCastleRook found a piece ...")			
			if not Rook:isa(piece) then
--DEBUG(Piece):print("... but it's a "..tostring(piece.name)..", not a rook, failing")
			else
--DEBUG(Piece):print("it's a rook ...")
				if piece.moved then
--DEBUG(Piece):print("... but it's moved, failing")
				else
--DEBUG(Piece):print("it hasn't moved ...")
					if piece.player ~= self.player then
--DEBUG(Piece):print("... but it's not ours, failing")
					else
--DEBUG(Piece):print("and it's ours - returning")
						return piece
					end
				end
			end
			return nil 
		end
		-- if it's empty, make sure no attacks go through this tile
		-- i.e. of all enemy moves, none touch this tile
		for _,otherPlace in ipairs(self.board.places) do
			local piece = otherPlace.piece
			if piece
			and piece.player ~= self.player
			and piece.movePaths
			then
				if piece.movePaths:find(nil, function(movePath)
					for _,pathStep in ipairs(movePath) do
						if movePath.placeIndex == place.index then return true end
					end
				end) then
--DEBUG(Piece):print("found an enemy attacking this square - failing")					
					return nil
				end
			end
		end
	
		-- take a step ...
		local edge = place.edges[edgeIndex]
		if not edge then break end
		local nextPlace = self.board.places[edge.placeIndex]
		if not nextPlace then break end
		local nextEdgeIndex = nextPlace.edges:find(nil, function(edge)
			return self.board.places[edge.placeIndex] == place
		end)
		if not nextEdgeIndex then break end
		place = nextPlace
		local nedges = #place.edges
		edgeIndex = ((nextEdgeIndex-1) + math.floor(nedges/2)) % nedges + 1
--DEBUG(Piece):print("King:findCastleRook stepping to", place.center)
	end
--DEBUG(Piece):print("couldn't find a castle rook")	
	return nil
end

function King:move(movePath)
	-- if we were castling then move 
	if movePath.state == 2 or movePath.state == -2 then
		local step1place = self.board.places[movePath[1].placeIndex]
		local step2place = self.board.places[movePath[2].placeIndex]
		local edgeIndex, edge = step2place.edges:find(nil, function(edge)
			return self.board.places[edge.placeIndex] == step1place
		end)
		assert(edgeIndex)

		local rook = self:findCastleRook(
			step2place,
			edgeIndex
		)
		assert(rook)

		rook:move(table{
			{
				placeIndex = rook.placeIndex,
			},
			{
				placeIndex = step2place.index
			}
		})
	end

	-- register the kings move as the last move
	King.super.move(self, movePath)
end

Piece.subclasses = table{
	Piece.Pawn,
	Piece.Bishop,
	Piece.Knight,
	Piece.Rook,
	Piece.Queen,
	Piece.King,
}
Piece.classForName = {}
for _,cl in ipairs(Piece.subclasses) do
	Piece.classForName[cl.name] = cl
end

return Piece
