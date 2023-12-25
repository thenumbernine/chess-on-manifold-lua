#! /usr/bin/env luajit
local gl = require 'gl'
local table = require 'ext.table'
local class = require 'ext.class'
local math = require 'ext.math'
local vec4ub = require 'vec-ffi.vec4ub'
local Image = require 'image'
local GLTex2D = require 'gl.tex2d'
local ig = require 'imgui'
local NetCom = require 'netrefl.netcom'
local ThreadManager = require 'threadmanager'

local Place = require 'place'
local Piece = require 'piece'
local Board = require 'board'


local App = require 'imguiapp.withorbit'()

App.title = 'Chess or something'
App.viewDist = 5

-- need as many as is in app.players[]
App.colors = table{
	'white',
	'black',
}

function App:initGL()
	App.super.initGL(self)

	-- pieceTexs[color][piece]
	self.pieceTexs = {}

	-- textures:
	local piecesImg = Image'pieces.png'
	print(piecesImg.width, piecesImg.height)
	local texsize = piecesImg.height/2
	assert(piecesImg.width == texsize*6)
	assert(piecesImg.height == texsize*2)
	assert(piecesImg.channels == 4)
	for y=0,piecesImg.height-1 do
		for x=0,piecesImg.width-1 do
			local i = 4 * (x + piecesImg.width * y)
			if piecesImg.buffer[3 + i] < 127 then
				piecesImg.buffer[0 + i] = 0
				piecesImg.buffer[1 + i] = 0
				piecesImg.buffer[2 + i] = 0
			end
		end
	end
	for y,color in ipairs(self.colors) do
		self.pieceTexs[color] = {}
		self.pieceTexs[y] = self.pieceTexs[color]
		for x,piece in ipairs{
			'king',
			'queen',
			'bishop',
			'knight',
			'rook',
			'pawn',
		} do
			local image = piecesImg:copy{
				x = texsize*(x-1),
				y = texsize*(y-1),
				width = texsize,
				height = texsize,
			}
			local tex = GLTex2D{
				image = image,
				minFilter = gl.GL_LINEAR_MIPMAP_LINEAR,
				magFilter = gl.GL_LINEAR,
				generateMipmap = true,
			}
			tex.image = image
			tex.image:save(piece..'-'..color..'.png')
			self.pieceTexs[color][piece] = tex
		end
	end

	gl.glBlendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE_MINUS_SRC_ALPHA)
	gl.glEnable(gl.GL_BLEND)
	
	gl.glAlphaFunc(gl.GL_GREATER, .1)
	gl.glEnable(gl.GL_ALPHA_TEST)
	
	gl.glEnable(gl.GL_DEPTH_TEST)

	self.netcom = NetCom()
	self.address = 'localhost'
	self.port = 12345
	self.threads = ThreadManager()

	-- init gui vars:
	self.transparentBoard = false
	self.enablePieces = {
		king = true,	-- always
		queen = true,
		bishop = true,
		knight = true,
		rook = true,
		pawn = true,
	}
	
	self:newGame()
end

function App:newGame(boardClass)
	--boardClass = boardClass or Board.Cube
	boardClass = boardClass or Board.Traditional
	-- per-game
	self.players = table()
	self.board = boardClass(self)
	self.board:makePlaces()
	self.board:buildEdges()
	self.board:makePieces()
	-- run this after placing all pieces
	for _,place in ipairs(self.board.places) do
		local piece = place.piece
		if piece 
		and piece.initAfterPlacing
		then
			piece:initAfterPlacing()
		end
	end
	self.turn = 1
	self:refreshMoves()
end

-- calculate all moves for all pieces
function App:refreshMoves()
	self.inCheck = false
	self.attacks = table()
	for _,place in ipairs(self.board.places) do
		local piece = place.piece
		if piece then
			piece.moves = piece:getMoves()
			for _,move in ipairs(piece.moves) do
				local targetPiece = move.piece
				if targetPiece 
				and targetPiece.player ~= piece.player	-- .... or allow self-attacks ...
				then
					self.attacks:insert{piece, targetPiece}
				
					if Piece.King:isa(targetPiece) then
						self.inCheck = true
					end
				end
			end
		end
	end
end

local result = vec4ub()
function App:update()
	-- determine tile under mouse
	gl.glClearColor(0,0,0,1)
	gl.glClear(bit.bor(gl.GL_COLOR_BUFFER_BIT, gl.GL_DEPTH_BUFFER_BIT))
	self.board:drawPicking()
	local i, j = self.mouse.ipos:unpack()
	j = self.height - j - 1
	if i >= 0 and j >= 0 and i < self.width and j < self.height then
		gl.glReadPixels(i, j, 1, 1, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, result.s)
	
		self.mouseOverPlace = self.board:getPlaceForRGB(result:unpack())
		if self.mouse.leftClick then
			if self.selectedPlace
			and self.selectedPlace.piece
			and self.selectedPlace.piece.player.index == self.turn
			and self.highlightedPlaces 
			and self.highlightedPlaces:find(self.mouseOverPlace)
			then
				self.highlightedPlaces = nil
				-- move the piece to that square

				self.selectedPlace.piece:moveTo(
					self.mouseOverPlace
				)
			
				self.turn = self.turn % #self.players + 1

				self:refreshMoves()
			else
				if self.mouseOverPlace
				and self.mouseOverPlace.piece
				then
					self.selectedPlace = self.mouseOverPlace
					if self.selectedPlace then
						local piece = self.selectedPlace.piece
						if piece then
							self.highlightedPlaces = piece:getMoves()
						else
							self.highlightedPlaces = nil
						end
					end
				else
					self.selectedPlace = nil
				end
			end
		end
	end

	-- draw
	gl.glClearColor(.5, .5, .5, 1)
	gl.glClear(bit.bor(gl.GL_COLOR_BUFFER_BIT, gl.GL_DEPTH_BUFFER_BIT))
	self.board:draw()
	
	if self.selectedPlace then
		self.selectedPlace:drawHighlight(1,0,0, .3)
	end
	if self.highlightedPlaces then
		for _,place in ipairs(self.highlightedPlaces) do
			place:drawHighlight(0,1,0, .5)
		end
	end
	
	if self.mouseOverPlace then
		self.mouseOverPlace:drawHighlight(0,0,1, .3)
	end

	if #self.attacks > 0 then
		gl.glColor4f(1, 0, 0, .7)
		gl.glBegin(gl.GL_TRIANGLES)
		for _,attack in ipairs(self.attacks) do
			-- TODO draw arrow 
			local pa = attack[1].place
			local pb = attack[2].place
			local dir = (pb.center - pa.center):normalize()
			local right = dir:cross(pa.normal):normalize()
			
			gl.glVertex3f((pa.center - .05 * right + .3 * dir + .05 * pa.normal):unpack())
			gl.glVertex3f((pa.center + .05 * right + .3 * dir + .05 * pa.normal):unpack())
			gl.glVertex3f((pb.center + .05 * right - .3 * dir + .05 * pa.normal):unpack())
			
			gl.glVertex3f((pb.center + .05 * right - .3 * dir + .05 * pa.normal):unpack())
			gl.glVertex3f((pb.center - .05 * right - .3 * dir + .05 * pa.normal):unpack())
			gl.glVertex3f((pa.center - .05 * right + .3 * dir + .05 * pa.normal):unpack())
			
			gl.glVertex3f((pb.center + .15 * right - .3 * dir + .05 * pa.normal):unpack())
			gl.glVertex3f((pb.center - .15 * right - .3 * dir + .05 * pa.normal):unpack())
			gl.glVertex3f((pb.center - .15 * dir + .05 * pa.normal):unpack())
			
			--gl.glVertex3f((pa.center - .3 * right + .05 * pa.normal):unpack())
			--gl.glVertex3f((pb.center + .05 * pb.normal):unpack())
		end
		gl.glEnd()
	end

	-- this does the gui drawing *and* does the gl matrix setup
	App.super.update(self)
end

function App:updateGUI()
	local mesh = self.mesh
	if ig.igBeginMainMenuBar() then
		if ig.igBeginMenu'File' then
			ig.igSeparator()
			ig.igText'Local'
			if ig.igButton'New Game: Traditional' then
				self:newGame(Board.Traditional)
			end
			if ig.igButton'New Game: Cube' then
				self:newGame(Board.Cube)
			end
			ig.igSeparator()
			ig.igText'Remote'
			if ig.igButton'Listen' then
				self.connectPopupOpen = 'listen'
			end
			if ig.igButton'Connect' then
				self.connectPopupOpen = 'connect'
			end
			ig.igEndMenu()
		end
		if ig.igBeginMenu'Options' then
			ig.igSeparator()
			ig.igText'disable...'
			ig.luatableCheckbox('pawns', self.enablePieces, 'pawn')
			ig.luatableCheckbox('bishops', self.enablePieces, 'bishop')
			ig.luatableCheckbox('knights', self.enablePieces, 'knight')
			ig.luatableCheckbox('rooks', self.enablePieces, 'rook')
			ig.luatableCheckbox('queens', self.enablePieces, 'queen')
			ig.igEndMenu()
		end
		if ig.igBeginMenu'View' then
			ig.luatableCheckbox('Transparent Board', self, 'transparentBoard')
			ig.igEndMenu()
		end
		local str = '...  '..self.colors[self.turn].."'s turn"
		if self.inCheck then
			str = str .. '... CHECK!'
		end
		if ig.igBeginMenu(str) then
			ig.igEndMenu()
		end
		ig.igEndMainMenuBar()
	end
	
	if self.connectPopupOpen then
		ig.igPushID_Str'Connect Window'
		if ig.igBegin(self.connectPopupOpen) then
			if self.connectPopupOpen == 'connect' then
				ig.luatableInputText('address', self, 'address')
			end
			ig.luatableInputText('port', self, 'port')
			if ig.igButton'Go' then
				self.connectWaiting = true
				self.clientConn, self.server = self.netcom:start{
					port = self.port,
					threads = self.threads,
					addr = self.connectPopupOpen == 'connect' and self.address or nil,
					
					-- misnomer ... this function inits immediately for the server
					-- so what gets called when the server 
					onConnect = function()
print('beginning '..self.connectPopupOpen)
						self.connectPopupOpen = nil
						self.connectWaiting = nil
						-- TODO wait for a client to connect ...
					end,
				}
				-- TODO popup 'waiting' ...
			end
		end
		ig.igEnd()
		ig.igPopID()
	end
	if self.connectWaiting then
		if ig.igBegin('Waiting...') then
			if ig.igButton'Cancel' then
				-- TODO cancel the connect
				self.connectWaiting = nil
			end
			ig.igEnd()
		end
	end
end

return App():run()
