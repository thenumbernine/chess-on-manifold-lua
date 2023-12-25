local class = require 'ext.class'

local Player = class()

function Player:init(app)
	self.app = assert(app)
	app.players:insert(self)
	self.index = #app.players
end

return Player 
