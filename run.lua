#!/usr/bin/env luajit
cmdline = require 'ext.cmdline'(...)	--global
local App = require 'app'
App.viewUseGLMatrixMode = true
return App():run()
