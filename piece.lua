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
	gl.glEnable(gl.GL_ALPHA_TEST)
	gl.glAlphaFunc(gl.GL_GREATER, .5)
	local player = self.player
	local app = player.app
	local place = self.place
	local n = place.normal
	local vx = app.view.angle:xAxis()
	-- project 'x' onto 'n'
	vx = n:project(vx)
	vy = n:cross(vx)
	local tex = app.pieceTexs[player.index][self.name]
	tex
		:enable()
		:bind()
	gl.glColor3f(1,1,1)
	gl.glBegin(gl.GL_QUADS)
	for _,uv in ipairs(uvs) do
		gl.glTexCoord3f(uv:unpack())
		gl.glVertex3f((place.center 
			+ (uv.x - .5) * vx 
			- (uv.y - .5) * vy
			+ .01 * n
		):unpack())
	end
	gl.glEnd()
	tex
		:unbind()
		:disable()
	gl.glDisable(gl.GL_ALPHA_TEST)
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

return Piece 
