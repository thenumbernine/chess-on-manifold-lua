local gl = require 'gl'
local table = require 'ext.table'
local class = require 'ext.class'
local math = require 'ext.math'
local vec4ub = require 'vec-ffi.vec4ub'
local Image = require 'image'
local GLTex2D = require 'gl.tex2d'
local ig = require 'imgui'
local sdl = require 'ffi.req' 'sdl'
local NetCom = require 'netrefl.netcom'
local ThreadManager = require 'threadmanager'

local Place = require 'place'
local Piece = require 'piece'
local Board = require 'board'


local App = require 'imguiapp.withorbit'()

App.title = 'Chess on a Manifold'
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

function App:newGame(boardGenerator)
	--boardGenerator = boardGenerator or Board.Cube
	boardGenerator = boardGenerator or select(2, next(Board.generators[1]))
	-- per-game
	self.players = table()
	self.board = boardGenerator(self)
	self.turn = 1
	self.history = table()
	self.historyIndex = nil
	self.board:refreshMoves()
end

local result = vec4ub()
function App:update()
	
	self.threads:update()

	-- determine tile under mouse
	gl.glClearColor(0,0,0,1)
	gl.glClear(bit.bor(gl.GL_COLOR_BUFFER_BIT, gl.GL_DEPTH_BUFFER_BIT))
	self.board:drawPicking()
	local i, j = self.mouse.ipos:unpack()
	j = self.height - j - 1
	if i >= 0 and j >= 0 and i < self.width and j < self.height then
		gl.glReadPixels(i, j, 1, 1, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, result.s)
	
		self.mouseOverPlace, self.mouseOverPlaceIndex = self.board:getPlaceForRGB(result:unpack())
		if self.mouse.leftClick then
			if self.selectedPlace
			and self.selectedPlace.piece
			and self.selectedPlace.piece.player.index == self.turn
			and self.selectedMoves 
			and self.selectedMoves:find(self.mouseOverPlace)
			then
				self.selectedMoves = nil

				self.history:insert(
					self.board:clone()
						:refreshMoves()
				)

				-- move the piece to that square
				self.selectedPlace.piece:moveTo(
					self.mouseOverPlace
				)
			
				self.turn = self.turn % #self.players + 1

				self.board:refreshMoves()
			else
				if self.mouseOverPlace
				and self.mouseOverPlace.piece
				and self.mouseOverPlace ~= self.selectedPlace
				then
					self.selectedPlace = self.mouseOverPlace
					self.selectedPlaceIndex = self.mouseOverPlaceIndex

					if self.selectedPlace then
						local piece = self.selectedPlace.piece
						if piece then
							self.selectedMoves = piece:getMoves()

							-- if we're in check (and we dont want to allow manual capturing of the king...) then filter out all moves that won't end the check
							if self.board.inCheck then
								self.selectedMoves = self.selectedMoves:filter(function(place)
									local destPlaceIndex = place.index

									local forecastBoard = self.board:clone()
									local forecastSelPiece = forecastBoard.places[self.selectedPlaceIndex].piece
									if forecastSelPiece then
										forecastSelPiece:moveTo(forecastBoard.places[destPlaceIndex])
									end
									forecastBoard:refreshMoves()
									return not forecastBoard.inCheck
								end)
							end
						else
							self.selectedMoves = nil
						end
					end
				else
					self.selectedMoves = nil
					
					self.selectedPlace = nil
					self.selectedPlaceIndex = nil
				end
			end
		end

		if self.selectedPlace
		and self.selectedPlace.piece
		and self.mouseOverPlace
		--and self.selectedMoves:find(self.mouseOverPlace)
		then
			if not self.forecastPlace
			or self.forecastPlace ~= self.mouseOverPlace
			then
				self.forecastPlace = self.mouseOverPlace
				self.forecastBoard = self.board:clone()
				
				local forecastSelPiece = self.forecastBoard.places[self.selectedPlaceIndex].piece
				if forecastSelPiece then
					forecastSelPiece:moveTo(self.forecastBoard.places[self.mouseOverPlaceIndex])
				end
				self.forecastBoard:refreshMoves()
			end
		else
			self.forecastBoard = nil
			self.forecastPlace = nil
		end
	end

	-- draw
	gl.glClearColor(.5, .5, .5, 1)
	gl.glClear(bit.bor(gl.GL_COLOR_BUFFER_BIT, gl.GL_DEPTH_BUFFER_BIT))
	
	local drawBoard 
	if self.historyIndex then
		drawBoard = self.history[self.historyIndex]
	else
		drawBoard = self.forecastBoard or self.board
	end
	drawBoard:draw()

	if #drawBoard.attacks > 0 then
		gl.glBegin(gl.GL_TRIANGLES)
		for _,attack in ipairs(drawBoard.attacks) do
			if attack[3] then
				gl.glColor4f(0, 1, 0, .7)
			else
				gl.glColor4f(1, 0, 0, .7)
			end
			local ax = .05
			local ay = .45
			local bx = .05
			local by = .45
			local arrowWidth = .2

			-- TODO draw arrow 
			local pa = drawBoard.places[attack[1].placeIndex]
			local pb = drawBoard.places[attack[2].placeIndex]
			local dir = (pb.center - pa.center):normalize()
			local right = dir:cross(pa.normal):normalize()
			
			gl.glVertex3f((pa.center - ax * right + ay * dir + .05 * pa.normal):unpack())
			gl.glVertex3f((pa.center + ax * right + ay * dir + .05 * pa.normal):unpack())
			gl.glVertex3f((pb.center + bx * right - by * dir + .05 * pa.normal):unpack())
			
			gl.glVertex3f((pb.center + bx * right - by * dir + .05 * pa.normal):unpack())
			gl.glVertex3f((pb.center - bx * right - by * dir + .05 * pa.normal):unpack())
			gl.glVertex3f((pa.center - ax * right + ay * dir + .05 * pa.normal):unpack())
			
			gl.glVertex3f((pb.center + arrowWidth * right - by * dir + .05 * pa.normal):unpack())
			gl.glVertex3f((pb.center - arrowWidth * right - by * dir + .05 * pa.normal):unpack())
			gl.glVertex3f((pb.center - (by - arrowWidth) * dir + .05 * pa.normal):unpack())
			
			--gl.glVertex3f((pa.center - .3 * right + .05 * pa.normal):unpack())
			--gl.glVertex3f((pb.center + .05 * pb.normal):unpack())
		end
		gl.glEnd()
	end

	if self.selectedPlace then
		self.selectedPlace:drawHighlight(1,0,0, .3)
	end
	if self.selectedMoves then
		for _,place in ipairs(self.selectedMoves) do
			place:drawHighlight(0,1,0, .5)
		end
	end
	
	if self.mouseOverPlace then
		self.mouseOverPlace:drawHighlight(0,0,1, .3)
	end

	-- this does the gui drawing *and* does the gl matrix setup
	App.super.update(self)
end

function App:event(event, ...)
	if App.super.event then
		App.super.event(self, event, ...)
	end
	local canHandleMouse = not ig.igGetIO()[0].WantCaptureMouse
	local canHandleKeyboard = not ig.igGetIO()[0].WantCaptureKeyboard
	if canHandleKeyboard then
		if event.type == sdl.SDL_KEYDOWN then
			if event.key.keysym.sym == sdl.SDLK_LEFT then
				self.historyIndex = self.historyIndex or #self.history + 1
				self.historyIndex = math.clamp(self.historyIndex - 1, 1, #self.history + 1)
				if self.historyIndex == #self.history + 1 then self.historyIndex = nil end
	print('historyIndex', self.historyIndex)
			elseif event.key.keysym.sym == sdl.SDLK_RIGHT then
				self.historyIndex = self.historyIndex or #self.history + 1
				self.historyIndex = math.clamp(self.historyIndex + 1, 1, #self.history + 1)
				if self.historyIndex == #self.history + 1 then self.historyIndex = nil end
	print('historyIndex', self.historyIndex)
			end
		end
	end
end

function App:updateGUI()
	local mesh = self.mesh
	if ig.igBeginMainMenuBar() then
		if ig.igBeginMenu'File' then
			ig.igSeparator()
			ig.igText'Local'
			for _,genpair in ipairs(Board.generators) do
				local name, generator = next(genpair)
				if ig.igButton('New Game: '..name) then
					self:newGame(generator)
				end
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
			if ig.igButton'Reset' then
				self.view.pos:set(0, 0, self.viewDist)
				self.view.orbit:set(0, 0, 0)
				self.view.angle:set(0,0,0,1)
			end
			for j=1,2 do
				for i=1,3 do
					if i>1 then ig.igSameLine() end
					if ig.igButton(
						({'X', 'Y', 'Z'})[i]..({'-', '+'})[j]
					) then
						local quatf = require 'vec-ffi.quatf'
						local rot = quatf()
						rot.w = 90 * (2*j-1)
						rot.s[i-1] = 1
						-- how did I pick this for an API:
						rot:fromAngleAxis(rot:unpack())
						local dist = (self.view.pos - self.view.orbit):length()
						self.view.angle = self.view.angle * rot
						self.view.pos = self.view.angle:zAxis() * dist + self.view.orbit
					end
				end
			end
			
			for i=1,2 do
				if ig.igButton(({'<', '>'})[i]) then
					local delta = 2*i-1
					self.historyIndex = self.historyIndex or #self.history + 1
					self.historyIndex = math.clamp(self.historyIndex + delta, 1, #self.history + 1)
					if self.historyIndex == #self.history + 1 then self.historyIndex = nil end
print('historyIndex', self.historyIndex)
				end
				if i == 1 then
					ig.igSameLine()
				end
			end

			ig.igSeparator()
			ig.luatableCheckbox('Transparent Board', self, 'transparentBoard')
			ig.igEndMenu()
		end
		local str = '...  '..self.colors[self.turn].."'s turn"
		if self.board.inCheck then
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
print('got connection '..self.connectPopupOpen)
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

return App
