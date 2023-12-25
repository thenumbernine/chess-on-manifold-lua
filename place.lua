local class = require 'ext.class'
local table = require 'ext.table'
local vec3f = require 'vec-ffi.vec3f'
local gl = require 'gl'


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
	self.edges = {
		{
			place = neighborPlace,
		},
	}
	--]]
	self.edges = table()
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

	if self == self.board.app.mouseOverPlace then
		gl.glColor3f(0,0,1)
	else
		gl.glColor3f(self.color:unpack())
	end
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

return Place
