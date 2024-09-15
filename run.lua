#!/usr/bin/env luajit
cmdline = require 'ext.cmdline'(...)	--global
local App = require 'app'
return App():run()
