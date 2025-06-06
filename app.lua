local ffi = require 'ffi'
local gl = require 'gl'
local table = require 'ext.table'
local class = require 'ext.class'
local assert = require 'ext.assert'
local math = require 'ext.math'
local vec4ub = require 'vec-ffi.vec4ub'
local Image = require 'image'
local GLTex2D = require 'gl.tex2d'
local GLSceneObject = require 'gl.sceneobject'
local ig = require 'imgui'
local sdl = require 'sdl'
local ThreadManager = require 'threadmanager'
local NetCom = require 'netrefl.netcom'
local netField = require 'netrefl.netfield'

local Piece = require 'piece'
local Board = require 'board'
local Player = require 'player'


local App = require 'imgui.appwithorbit'()

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
	local pieceTexWidth = math.floor(piecesImg.width/6)
	local pieceTexHeight = math.floor(piecesImg.height/2)
	--assert(piecesImg.width == texsize*6)
	--assert(piecesImg.height == texsize*2)
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
				x = pieceTexWidth*(x-1),
				y = pieceTexHeight*(y-1),
				width = pieceTexWidth,
				height = pieceTexHeight,
			}
			local tex = GLTex2D{
				image = image,
				minFilter = gl.GL_LINEAR_MIPMAP_LINEAR,
				magFilter = gl.GL_LINEAR,
				generateMipmap = true,
			}
			tex.image = image
			--tex.image:save(piece..'-'..color..'.png')
			self.pieceTexs[color][piece] = tex
		
			Piece.classForName[piece].texs = Piece.classForName[piece].texs or table()
			Piece.classForName[piece].texs:insert(tex)
		end
	end

	self.solidTriSceneObj = GLSceneObject{
		program = {
			version = 'latest',
			precision = 'best',
			vertexCode = [[
layout(location=0) in vec3 vertex;
uniform mat4 mvProjMat;
void main() {
	gl_Position = mvProjMat * vec4(vertex, 1.);
}
]],
			fragmentCode = [[
uniform vec4 color;
layout(location=0) out vec4 fragColor;
void main() {
	fragColor = color;
}
]],
		},
		vertexes = {
			dim = 3,
			useVec = true,
		},
		geometry = {
			mode = gl.GL_TRIANGLES,
		},
	}

	self.drawPieceSceneObj = GLSceneObject{
		program = {
			version = 'latest',
			precision = 'best',
			vertexCode = [[
layout(location=0) in vec2 vertex;
out vec2 tcv;
uniform vec3 center;
uniform vec3 drawX, drawY, normal;
uniform mat4 mvProjMat;
void main() {
	tcv = vertex;
	vec3 rvtx = center
		+ (vertex.x - .5) * drawX
		- (vertex.y - .5) * drawY
		+ .01 * normal;
	gl_Position = mvProjMat * vec4(rvtx, 1.);
}
]],
			fragmentCode = [[
in vec2 tcv;
layout(location=0) out vec4 fragColor;
uniform sampler2D tex;
void main() {
	fragColor = texture(tex, tcv);
	if (fragColor.a <= .1) discard;
}
]],
			uniforms = {
				tex = 0,
			},
		},
		vertexes = {
			data = {
				0,0,
				0,1,
				1,0,
				1,0,
				0,1,
				1,1,
			},
			dim = 2,
		},
		geometry = {
			mode = gl.GL_TRIANGLES,
			count = 6,
		},
	}

	gl.glBlendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE_MINUS_SRC_ALPHA)
	gl.glEnable(gl.GL_BLEND)

	gl.glEnable(gl.GL_DEPTH_TEST)

	self.netcom = NetCom()
	self.netcom:addClientToServerCall{
		name = 'initPlayerConn',
		returnArgs = {
			netField.netFieldNumber,
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
	}

-- TODO automatically wrap member functions ...
-- or a better TODO would be to just reflect the board pieces state ...
	for _,f in ipairs{'addClientToServerCall', 'addServerToClientCall'} do
		self.netcom[f](self.netcom, {
			name = 'doMove',
			args = {
				netField.netFieldNumber,
				netField.netFieldNumber,
				netField.netFieldNumber,
			},
			returnArgs = {
				netField.netFieldBoolean,
			},
			func = function(serverConn, ...)
--DEBUG:print('netcom doMove', serverConn.index, ...)
				return self:doMove(...)
			end,
		})
		self.netcom[f](self.netcom, {
			name = 'newGame',
			args = {
				netField.netFieldString,
			},
			func = function(serverConn, ...)
				return self:newGame(...)
			end,
		})
	end

	-- TODO assign each connecting player a player #
	-- use a 'clientToServerCall' to call the server when a player moves
	-- TODO make this a server-to-client-only reflected object?
	self.shared = setmetatable({
		playing = false,	-- wait til they click the 'play!' button
		turn = 1,
		enablePieces = setmetatable({
			king = true,	-- always
			queen = true,
			bishop = true,
			knight = true,
			rook = true,
			pawn = true,
		}, {__index={
			-- TODO move __netfields to the metatable?  technically it can go into the __index metatable as things stand...
			__netfields = {
				king = netField.netFieldBoolean,	-- always
				queen = netField.netFieldBoolean,
				bishop = netField.netFieldBoolean,
				knight = netField.netFieldBoolean,
				rook = netField.netFieldBoolean,
				pawn = netField.netFieldBoolean,
			},
		}}),
		customPieceLayout = false,
		customBoard = false,
		playersAI = {
			false,
			true,
		},
	}, {__index={
		__netfields = {
			-- doMove will handle turns ... so this really isn't shared ...
			--turn = netField.netFieldNumber,
			enablePieces = netField.NetFieldObject,
			customPieceLayout = netField.netFieldBoolean,
			--board = netField.NetFieldObject,
		},
	}})
	-- only push updates from the server
	self.netcom:addObjectForDir('serverToClientObjects', {
		name = 'shared',
		object = self.shared,
	})

	self.address = 'localhost'
	self.port = 12345
	self.threads = ThreadManager()

	-- init gui vars:
	self.transparentBoard = false
	self.showHints = false

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

function App:newGame(genname)
	local boardGenerator = Board.generatorForName[genname]
	--boardGenerator = boardGenerator or Board.Cube
	boardGenerator = boardGenerator or select(2, next(Board.generators[1]))
	-- per-game
	self.players = table()
	-- TODO where to set # of players?
	for i=1,2 do
		Player(self)
	end
	self.shared.board = boardGenerator(self)
	self.history = table()
	self.historyIndex = nil
	self.shared.board:refreshMoves()
	self.shared.playing = false
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

--[[
returns:
	true = move was succesful
	false = something went wrong
TODO return some state of the move result:
	1) game keeps going
	2) stalemate
	3) checkmate
--]]
function App:doMove(playerIndex, fromPlaceIndex, toPlaceIndex)
--DEBUG:print('App:doMove', playerIndex, fromPlaceIndex, toPlaceIndex)

	-- if we're in a net game then only allow this if our remotePlayerIndex is the current turn ...
	if playerIndex ~= self.shared.turn then
--DEBUG:print("App:doMove playerIndex doesn't match turn", self.shared.turn)
		return false
	end

	local fromPlace = self.shared.board.places[fromPlaceIndex]
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

	local toPlace = self.shared.board.places[toPlaceIndex]
	if not toPlace then
--DEBUG:print("...couldn't find toPlaceIndex "..tostring(toPlaceIndex))
		return false
	end

	if not fromMoves then
--DEBUG:print("...we have no selectedMoves")
		return false
	end

	local _, movePath = fromMoves:find(nil, function(move) 
		return move:last().placeIndex == toPlace.index 
	end)
	if not movePath then
--DEBUG:print("...couldn't find toPlace in selectedMoves")
		return false
	end

	-- don't allow moving yourself into check
	local newBoard = self.shared.board:clone()
	newBoard.places[fromPlaceIndex].piece:move(movePath)
	newBoard:refreshMoves()
	if newBoard.checks[playerIndex] then return false end

	-- TODO do this client-side ...
	self.history:insert(self.shared.board:clone():refreshMoves())

	-- move the piece to that square
--DEBUG:print('App:doMove self.shared.board.lastMovedPlaceIndex before', self.shared.board.lastMovedPlaceIndex)
	fromPlace.piece:move(movePath)
--DEBUG:print('App:doMove self.shared.board.lastMovedPlaceIndex after', self.shared.board.lastMovedPlaceIndex)

	self.shared.board:refreshMoves()

	self.shared.turn = self.shared.turn % #self.players + 1
--DEBUG:print('App:doMove self.shared.turn='..tostring(self.shared.turn))
	return true
end

local result = vec4ub()
function App:update()
	local canHandleMouse = not ig.igGetIO()[0].WantCaptureMouse
	local canHandleKeyboard = not ig.igGetIO()[0].WantCaptureKeyboard

	self.threads:update()
	-- why not just make this another update thread?
	if self.server then
		self.server:update()
	end

	if self.shared.playing
	and self.shared.playersAI[self.shared.turn] 
	then
		-- then do an AI move
		local move = assert(self:getBestMove(self.shared.board, self.shared.turn))
		if not self:doMove(
			self.shared.turn,
			move[1].placeIndex,
			move:last().placeIndex
		) then
			print"something went wrong.  is the game done yet?"
			--error("failed")
		end
	end

	-- determine tile under mouse
	gl.glClearColor(0,0,0,1)
	gl.glClear(bit.bor(gl.GL_COLOR_BUFFER_BIT, gl.GL_DEPTH_BUFFER_BIT))
	self.shared.board:drawPicking()
	local i, j = self.mouse.ipos:unpack()
	j = self.height - j - 1
	if i >= 0 and j >= 0 and i < self.width and j < self.height then
		gl.glReadPixels(i, j, 1, 1, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, result.s)
		self.mouseOverPlace, self.mouseOverPlaceIndex = self.shared.board:getPlaceForRGB(result:unpack())
		-- if we are clicking ...
		if canHandleMouse 
		and self.mouse.leftClick
		then
			-- if we're not playing the game yet ..
			if not self.shared.playing then
				if self.shared.customBoard then
					-- handle any changing-board requests ...
					-- technically I don't need the pick-scene render for this ...
					-- hmm the more I think about this, the more I just want to import OBJ files ...
				elseif self.shared.customPieceLayout then
					-- handle any placing-pieces requests ...
					if self.mouseOverPlace then
						if self.isPlacingCustomGenerator then
							self.isPlacingCustomGenerator(self.mouseOverPlace)
						else
							self.mouseOverPlace.piece = nil
						end
					end
				end
			else
				-- if we have already selected a piece ....
				if self.selectedPlace
				and self.selectedPlace.piece
				then
					-- if its ours and we're clicking a valid square ... 
					if self.selectedPlace.piece.player.index == self.shared.turn
					and self.selectedMoves
					and self.mouseOverPlace
					and self.selectedMoves:find(nil, function(move) return move:last().placeIndex == self.mouseOverPlace.index end)
					then
						-- move the piece
						local playerIndex = self.clientConn and self.remotePlayerIndex or self.shared.turn
						local fromPlaceIndex = assert(self.selectedPlace.index, "couldn't find fromPlaceIndex")
						local toPlaceIndex = assert(self.mouseOverPlace.index, "couldn't find toPlaceIndex")
						local done = function(result)
	--DEBUG:print('doMove done result', result)
							if not result then
								-- failed move -- deselect
								self.selectedMoves = nil
								self.selectedPlace = nil
								self.selectedPlaceIndex = nil
							else
								-- successful move ...

								-- [[ now if we're the server then we want to send to the client the fact that we moved ...
								if self.server then
									for _,serverConn in ipairs(self.server.serverConns) do
	--DEBUG:print('sending serverConn doMove')
										serverConn:netcall{
											'doMove',
											playerIndex,
											fromPlaceIndex,
											toPlaceIndex,
											-- TODO
											--done = block for all sends to finish
										}
									end
								else
								--]] do
								-- if we're not the server then we still have to do the move ourselves...
									local result = self:doMove(playerIndex, fromPlaceIndex, toPlaceIndex)
	--DEBUG:print('after remote doMove, local doMove result', result)
								end

								self.selectedMoves = nil

								self.selectedPlace = nil
								self.selectedPlaceIndex = nil
							end
						end
						-- TODO I'm sure netrefl has this functionality...
						if self.clientConn then
	--DEBUG:print('server sending clientConn doMove')
							self.clientConn:netcall{
								done = done,
								'doMove',
								playerIndex,
								fromPlaceIndex,
								toPlaceIndex,
							}
						else
	--DEBUG:print('local doMove')
							done(self:doMove(
								playerIndex,
								fromPlaceIndex,
								toPlaceIndex
							))
						end
					else
						-- else deselect it
						self.selectedMoves = nil
						self.selectedPlace = nil
						self.selectedPlaceIndex = nil
					end
				else
					-- if we don't have a piece selected ... try to select it
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
								self.selectedMoves = self.selectedMoves:filter(function(movePath)
									local forecastBoard = self.shared.board:clone()
									local forecastSelPiece = forecastBoard.places[self.selectedPlaceIndex].piece
									if forecastSelPiece then
										forecastSelPiece:move(movePath)
									end
									forecastBoard:refreshMoves()
									return not forecastBoard.checks[self.shared.turn]
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
		end

		if self.selectedPlace
		and self.selectedPlace.piece
		and self.mouseOverPlace
		--[[ only forecast valid moves ...
		and self.selectedMoves:find(nil, function(movePath) return movePath:last().placeIndex == self.mouseOverPlace.index end)
		--]]
		then
			if not self.forecastPlace
			or self.forecastPlace ~= self.mouseOverPlace
			then
				self.forecastPlace = self.mouseOverPlace
				self.forecastBoard = self.shared.board:clone()

				-- look for a valid move from the selected piece's location
				local _, movePath = self.selectedPlace.piece.movePaths:find(nil, function(movePath)
					return movePath:last().placeIndex == self.mouseOverPlace.index
				end)

				local forecastSelPiece = self.forecastBoard.places[self.selectedPlaceIndex].piece
				if forecastSelPiece then
					-- if there was a valid move then use that move (i.e. castle etc)
					if movePath then
						forecastSelPiece:move(movePath)
					else
						-- otherwise just look at what teleporting the piece would do ...
						forecastSelPiece:move(table{
							{
								placeIndex = self.selectedPlace.index,
								-- edgeIndex should be there but isn't ...
							},
							{
								placeIndex = self.mouseOverPlaceIndex,
							}
						})
					end
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
		drawBoard = self.forecastBoard or self.shared.board
	end
	drawBoard:draw()

	if self.showHints
	and #drawBoard.attacks > 0 
	then
		for _,attack in ipairs(drawBoard.attacks) do
			local cr,cg,cb,ca
			if attack[3] then
				cr,cg,cb,ca = 0, 1, 0, .7
			else
				cr,cg,cb,ca = 1, 0, 0, .7
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
				
			local x1,y1,z1 = (pa.center - ax * right + ay * dir + .05 * pa.normal):unpack()
			local x2,y2,z2 = (pa.center + ax * right + ay * dir + .05 * pa.normal):unpack()
			local x3,y3,z3 = (pb.center + bx * right - by * dir + .05 * pa.normal):unpack()
			self:drawSolidTri(
				x1,y1,z1,
				x2,y2,z2,
				x3,y3,z3,
				cr,cg,cb,ca
			)

			local x1,y1,z1 = (pb.center + bx * right - by * dir + .05 * pa.normal):unpack()
			local x2,y2,z2 = (pb.center - bx * right - by * dir + .05 * pa.normal):unpack()
			local x3,y3,z3 = (pa.center - ax * right + ay * dir + .05 * pa.normal):unpack()
			self:drawSolidTri(
				x1,y1,z1,
				x2,y2,z2,
				x3,y3,z3,
				cr,cg,cb,ca
			)

			local x1,y1,z1 = (pb.center + arrowWidth * right - by * dir + .05 * pa.normal):unpack()
			local x2,y2,z2 = (pb.center - arrowWidth * right - by * dir + .05 * pa.normal):unpack()
			local x3,y3,z3 = (pb.center - (by - arrowWidth) * dir + .05 * pa.normal):unpack()
			self:drawSolidTri(
				x1,y1,z1,
				x2,y2,z2,
				x3,y3,z3,
				cr,cg,cb,ca
			)

			--gl.glVertex3f((pa.center - .3 * right + .05 * pa.normal):unpack())
			--gl.glVertex3f((pb.center + .05 * pb.normal):unpack())
		end
	end

	if self.selectedPlace then
		self.selectedPlace:drawHighlight(1,0,0, .3)
	end
	if self.selectedMoves then
		for _,move in ipairs(self.selectedMoves) do
			self.shared.board.places[move:last().placeIndex]:drawHighlight(0,1,0, .5)
		end
	end

	if self.mouseOverPlace then
		self.mouseOverPlace:drawHighlight(0,0,1, .3)
	end

	-- this does the gui drawing *and* does the gl matrix setup
	App.super.update(self)
end

function App:drawSolidTri(
	x1,y1,z1,
	x2,y2,z2,
	x3,y3,z3,
	r,g,b,a
)
	local sceneObj = self.solidTriSceneObj
	sceneObj.uniforms.mvProjMat = self.view.mvProjMat.ptr
	sceneObj.uniforms.color = {r,g,b,a}
	local vertexCPU = sceneObj.attrs.vertex.buffer.vec
	sceneObj:beginUpdate()
	vertexCPU:emplace_back():set(x1,y1,z1)
	vertexCPU:emplace_back():set(x2,y2,z2)
	vertexCPU:emplace_back():set(x3,y3,z3)
	sceneObj:endUpdate()
end

function App:drawSolidLineLoop(
	vtxs,
	r,g,b,a
)
	local sceneObj = self.solidTriSceneObj
	assert.eq(sceneObj.geometry.mode, gl.GL_TRIANGLES)
	sceneObj.geometry.mode = gl.GL_LINE_LOOP
	sceneObj.uniforms.mvProjMat = self.view.mvProjMat.ptr
	sceneObj.uniforms.color = {r,g,b,a}
	local vertexCPU = sceneObj.attrs.vertex.buffer.vec
	sceneObj:beginUpdate()
	for _,v in ipairs(vtxs) do
		vertexCPU:emplace_back():set(v:unpack())
	end
	sceneObj:endUpdate()
	sceneObj.geometry.mode = gl.GL_TRIANGLES
end

function App:event(event, ...)
	if App.super.event then
		App.super.event(self, event, ...)
	end
	local canHandleMouse = not ig.igGetIO()[0].WantCaptureMouse
	local canHandleKeyboard = not ig.igGetIO()[0].WantCaptureKeyboard
	if canHandleKeyboard then
		if event[0].type == sdl.SDL_EVENT_KEY_DOWN then
			if event[0].key.key == sdl.SDLK_LEFT then
				self.historyIndex = self.historyIndex or #self.history + 1
				self.historyIndex = math.clamp(self.historyIndex - 1, 1, #self.history + 1)
				if self.historyIndex == #self.history + 1 then self.historyIndex = nil end
print('historyIndex', self.historyIndex)
			elseif event[0].key.key == sdl.SDLK_RIGHT then
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

					-- TODO same with doMove ...
					-- sort of ...
					-- only server is allowed to call this
					if self.server then
--DEBUG:print('App:updateGUI netcall newGame', name)
						self:newGame(name)
						for _,serverConn in ipairs(self.server.serverConns) do
							serverConn:netcall{
								'newGame',
								name
							}
						end
					else
--DEBUG:print('App:updateGUI local newGame', name)
						self:newGame(name)
					end
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
			ig.igText'allow...'
			ig.luatableCheckbox('pawns', self.shared.enablePieces, 'pawn')
			ig.luatableCheckbox('bishops', self.shared.enablePieces, 'bishop')
			ig.luatableCheckbox('knights', self.shared.enablePieces, 'knight')
			ig.luatableCheckbox('rooks', self.shared.enablePieces, 'rook')
			ig.luatableCheckbox('queens', self.shared.enablePieces, 'queen')
			
			-- TODO make this an "edit pieces" button, and grey it out mid-game ... only enable it if the game is reset and untouched.
			ig.igSeparator()
			ig.luatableCheckbox('custom pieces...', self.shared, 'customPieceLayout')
			-- TODO custom placement ... but then, also reflect across network
			ig.igSeparator()
--			ig.luatableCheckbox('custom board...', self.shared, 'customBoard')
			ig.igSeparator()
			for i=1,#self.players do
				ig.luatableCheckbox('player #'..i..' as AI', self.shared.playersAI, i)
			end
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
			ig.luatableCheckbox('Show Hints', self, 'showHints')
			ig.igEndMenu()
		end
		local str = '...  '..self.colors[self.shared.turn].."'s turn"
		if self.shared.board.checks[self.shared.turn] then
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
	if not self.shared.playing then
		if ig.igBegin('Ready...') then
			if ig.igButton('Play!') then
				self.shared.customPieceLayout = false
				self.shared.board:initPieces()
				self.shared.board:refreshMoves()
				self.shared.playing = true
			end
			ig.igEnd()
		end
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
	
	-- only do custom-board or custom-pieces one at a time
	if not self.shared.playing then
		if self.shared.customBoard then
			if ig.igBegin('Editing Board...') then
				if ig.igButton'Done' then
					self.shared.customBoard = false
				end
				ig.igEnd()
			end
		elseif self.shared.customPieceLayout then
			if ig.igBegin('Placing Pieces...') then
				ig.igText'Click a tile to change its piece'
				if ig.igButton'clear' then
					self.isPlacingCustomGeneratorIndex = 0
					self.isPlacingCustomGenerator = function(place)
						place.piece = nil
					end
				end
				for team,color in ipairs(self.colors) do
					for i,cl in ipairs(Piece.subclasses) do
						local genIndex = (team-1) * #Piece.subclasses + i
						if i > 1 then ig.igSameLine() end
						local sel = self.isPlacingCustomGeneratorIndex == genIndex
						if sel then
							ig.igPushStyleColor_Vec4(ig.ImGuiCol_Button, ig.ImVec4(1,0,0,.5))
						end
						if ig.igImageButton(
							'new'..cl.name..color,
							ffi.cast('ImTextureID', cl.texs[team].id),
							ig.ImVec2(32, 32),
							ig.ImVec2(0, 0),
							ig.ImVec2(1, 1),
							ig.ImVec4(0, 0, 0, 0),
							self.isPlacingCustomGenerator == genIndex and ig.ImVec4(1, 0, 0, 1) or ig.ImVec4(1, 1, 1, 1)
						) then
							self.isPlacingCustomGeneratorIndex = genIndex 
							self.isPlacingCustomGenerator = function(place)
								local placeIndex = place.index
								place.piece = nil
								place.piece = cl{
									board = self.shared.board,
									player = assert(self.players[team]),
									placeIndex = placeIndex,
								}
							end
						end
						if sel then
							ig.igPopStyleColor(1)
						end
					end
				end
				if ig.igButton'Done' then
					self.shared.customPieceLayout = false
				end

				ig.igEnd()
			end
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
			-- TODO BIG FLAW IN NETREFL's DESIGN
			-- you HAVE TO assign this here upon onConnect:
			-- it doesn't return.
			self.clientConn = clientConn

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
--DEBUG:print('App:startRemote created netcom')
--DEBUG:print('self.clientConn', self.clientConn)
--DEBUG:print('self.server', self.server)
end

function App:getBestMove(board, turn, depth)
	local maxDepth = 1
	depth = depth or 0
--DEBUG:print('App:getBestMove', depth)
	local allMovesAndScores = table()
	for _,place in ipairs(board.places) do
		if place.piece 
		and place.piece.player.index == turn
		then
			for _,move in ipairs(place.piece.movePaths) do
--DEBUG:print('App:getBestMove', depth, 'checking from', move[1].placeIndex, 'to', move:last().placeIndex)
				local nextBoard = board:clone()
				local nextPlace = nextBoard.places[place.index]
				local nextPiece = nextPlace.piece
				nextPiece:move(move)
				nextBoard:refreshMoves(true)
				
--DEBUG:		local thisScore = nextBoard.scores[turn] - nextBoard.scores[3-turn]
--DEBUG:print('App:getBestMove', depth, 'for this move we got score', thisScore)
				local lastMoveBoard = nextBoard
				if depth < maxDepth then
					local nextMove
					nextMove, lastMoveBoard = self:getBestMove(
						nextBoard,
						turn % #self.players + 1,
						depth + 1
					)
				end
				local nextScore = lastMoveBoard.scores[turn] - lastMoveBoard.scores[3-turn]
--DEBUG:print('App:getBestMove', depth, 'from recursive moves we got score', nextScore)
				allMovesAndScores:insert{
					move = move,
					score = nextScore,
					board = nextBoard,
				}
			end
		end
	end
	allMovesAndScores:sort(function(a,b) return a.score > b.score end)
	allMovesAndScores = allMovesAndScores:filter(function(a) return a.score == allMovesAndScores[1].score end)
	local moveAndScore = allMovesAndScores:pickRandom()
	return moveAndScore.move, moveAndScore.board
end

return App
