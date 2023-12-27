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
	self.netcom:addClientToServerCall{
		name = 'initPlayerConn',
		returnArgs = {
			require 'netrefl.netfield'.netFieldNumber,
		},
		func = function(serverConn)
			-- serverConn is either a localserverconn or remoteserverconn
			-- this is called upon server init before onConnect returns,
			-- so it is before self.server is defined
			-- it's also called before serverConn is inserted into server.serverConns
			local remotePlayerIndex = #serverConn.server.serverConns
--DEBUG:print('netcom initPlayerConn func returning remotePlayerIndex=', remotePlayerIndex)
			return remotePlayerIndex
		end,
		postFunc = function(...)
--DEBUG:print('netcom initPlayerConn done', ...)
			--clientConn.playerIndexes = playerIndexes
		end,
	}
	
-- TODO automatically wrap member functions ...
	for _,f in ipairs{'addClientToServerCall', 'addServerToClientCall'} do
		self.netcom[f](self.netcom, {
			name = 'doMove',
			args = {
				require 'netrefl.netfield'.netFieldNumber,
				require 'netrefl.netfield'.netFieldNumber,
				require 'netrefl.netfield'.netFieldNumber,
			},
			returnArgs = {
				require 'netrefl.netfield'.netFieldBoolean,
			},
			func = function(serverConn, ...)
	--DEBUG:print('netcom doMove', serverConn.index, ...)
				return self:doMove(...)
			end,
		})
	end

	-- TODO assign each connecting player a player #
	-- use a 'clientToServerCall' to call the server when a player moves
	self.shared = {
		turn = 1,
		__netfields = {
			-- doMove will handle turn
			--turn = require 'netrefl.netfield'.netFieldNumber,
		},
	}
	self.netcom:addObject{name='shared', object=self.shared}

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


	if cmdline.listen then
		self.connectWaiting = true
		if type(cmdline.listen) == 'number' then
			self.port = cmdline.listen	-- TODO allow listening on specific addresses
		end
		self:startRemote'listen'
	elseif cmdline.connect then
		local addr, port = cmdline.connect:match'^(.*):(%d+)$'
		assert(addr, "failed to parse connect destination "..tostring(cmdline.connect))
		port = assert(tonumber(port), "port expected number, found "..tostring(port))
		self.connectWaiting = true
		self.address = addr
		self.port = port
		self:startRemote'connect'
	end
end

function App:newGame(boardGenerator)
	--boardGenerator = boardGenerator or Board.Cube
	boardGenerator = boardGenerator or select(2, next(Board.generators[1]))
	-- per-game
	self.players = table()
	self.board = boardGenerator(self)
	self.history = table()
	self.historyIndex = nil
	self.board:refreshMoves()

	self.shared.turn = 1
end

function App:resetView()
	self.view.pos:set(0, 0, self.viewDist)
	self.view.orbit:set(0, 0, 0)
	self.view.angle:set(0,0,0,1)
end

-- i = axis 1..3
-- j = 1 for -90, 2 for +90
function App:rotateView(i, j)
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

function App:doMove(playerIndex, fromPlaceIndex, toPlaceIndex)
--DEBUG:print('App:doMove', playerIndex, fromPlaceIndex, toPlaceIndex)
	
	-- if we're in a net game then only allow this if our remotePlayerIndex is the current turn ...
	if playerIndex ~= self.shared.turn then 
--DEBUG:print("App:doMove playerIndex doesn't match turn", self.shared.turn)
		return false
	end

	local fromPlace = self.board.places[fromPlaceIndex]
	if not fromPlace then
--DEBUG:print("...couldn't find fromPlaceIndex "..tostring(fromPlaceIndex))
		return false
	end

	local fromPiece = fromPlace.piece
	if not fromPiece then
--DEBUG:print('...fromPlace had no piece')	
		return false
	end
	
	if fromPiece.player.index ~= self.shared.turn then
--DEBUG:print('...fromPiece was of player '..tostring(fromPiece.player.index).." when it's player "..tostring(self.shared.turn).."'s turn")
		return false
	end

	local fromMoves = fromPiece:getMoves()
	
	if not fromMoves then
--DEBUG:print("...we have no selectedMoves")
		return false
	end

	local toPlace = self.board.places[toPlaceIndex]
	if not toPlace then
--DEBUG:print("...couldn't find toPlaceIndex "..tostring(toPlaceIndex))	
		return false
	end
	
	if not fromMoves then
--DEBUG:print("...we have no selectedMoves")
		return false
	end

	if not fromMoves:find(toPlace) then
--DEBUG:print("...couldn't find toPlace in selectedMoves")
		return false
	end


	-- TODO do this client-side ...
	self.history:insert(
		self.board:clone()
			:refreshMoves()
	)

	-- move the piece to that square
	fromPlace.piece:moveTo(toPlace)

	self.shared.turn = self.shared.turn % #self.players + 1
--DEBUG:print('App:doMove self.shared.turn='..tostring(self.shared.turn))
	return true
end

local result = vec4ub()
function App:update()
	
	self.threads:update()
	-- why not just make this another update thread?
	if self.server then
		self.server:update()
	end

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
			and self.selectedPlace.piece.player.index == self.shared.turn
			and self.selectedMoves 
			and self.selectedMoves:find(self.mouseOverPlace)
			then
				-- move the piece
				local playerIndex = self.clientConn and self.remotePlayerIndex or self.shared.turn
				local fromPlaceIndex = self.selectedPlace.index
				local toPlaceIndex = self.mouseOverPlace.index
				local done = function(result)
					if not result then 
						-- failed move -- deselect
						self.selectedMoves = nil
						self.selectedPlace = nil
						self.selectedPlaceIndex = nil
					else
						-- successful move ...
						self.selectedMoves = nil
						
						self.board:refreshMoves()
						
						self.selectedPlace = nil
						self.selectedPlaceIndex = nil
					
						-- now if we're the server then we want to send to the client the fact that we moved ...
						if self.server then
							for _,serverConn in ipairs(self.server.serverConns) do
								serverConn:netcall{
									'doMove',
									playerIndex,
									fromPlaceIndex,
									toPlaceIndex,
									-- TODO 
									--done = block for all sends to finish
								}
							end
						end
					end
				end
				-- TODO I'm sure netrefl has this functionality...
				if self.clientConn then
					self.clientConn:netcall{
						done = done,
						'doMove',
						playerIndex,
						fromPlaceIndex,
						toPlaceIndex,
					}
				else
					done(self:doMove(
						playerIndex,
						fromPlaceIndex,
						toPlaceIndex
					))
				end
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

							-- if we dont want to allow manual capturing of the king...
							-- ... then filter out all moves that won't end the check
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
				self:resetView()
			end
			for j=1,2 do
				for i=1,3 do
					if i>1 then ig.igSameLine() end
					if ig.igButton(
						({'X', 'Y', 'Z'})[i]..({'-', '+'})[j]
					) then
						self:rotateView(i, j)
					end
				end
			end
			
			for i=1,2 do
				if ig.igButton(({'<', '>'})[i]) then
					local delta = 2*i-1
					self.historyIndex = self.historyIndex or #self.history + 1
					self.historyIndex = math.clamp(self.historyIndex + delta, 1, #self.history + 1)
					if self.historyIndex == #self.history + 1 then self.historyIndex = nil end
--DEBUG:print('historyIndex', self.historyIndex)
				end
				if i == 1 then
					ig.igSameLine()
				end
			end

			ig.igSeparator()
			ig.luatableCheckbox('Transparent Board', self, 'transparentBoard')
			ig.igEndMenu()
		end
		local str = '...  '..self.colors[self.shared.turn].."'s turn"
		if self.board.inCheck then
			str = str .. '... CHECK!'
		end
		if self.remotePlayerIndex then
			str = str .. ' ... you are '..tostring(self.colors[self.remotePlayerIndex])
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
--DEBUG:print(self.connectPopupOpen, self.address, self.port)
				self:startRemote(self.connectPopupOpen)
				self.connectPopupOpen = nil
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

-- method = 'connect' or 'listen'
function App:startRemote(method)
	self.connectWaiting = true
--DEBUG:print('App:startRemote', method, 'port='..tostring(self.port), 'address='..tostring(self.address))
	self.clientConn, self.server = self.netcom:start{
		port = self.port,
		threads = self.threads,
		addr = method == 'connect' and self.address or nil,
		
		-- misnomer ... this function inits immediately for the server
		-- so what gets called when the server gets a client?
		-- nothing yet I think ...
		onConnect = function(clientConn)
--DEBUG:print('App:startRemote got connection '..method)
			self.connectWaiting = nil

			clientConn:netcall{
				'initPlayerConn',
				done = function(remotePlayerIndex)
--DEBUG:print('clientConn:netcall initPlayerConn done', self.remotePlayerIndex)
					--clientConn.playerIndexes = playerIndexes
					self.remotePlayerIndex = remotePlayerIndex
					self:resetView()
					if self.remotePlayerIndex == 2 then
						self:rotateView(3, 2)
						self:rotateView(3, 2)
					end
				end,
		
			}

			self:newGame()
		end,
	}
--DEBUG:print('App:startRemote created netcom', self.clientConn, self.server)				
end

return App
