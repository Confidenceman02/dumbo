local M = {}
M.__index = M

function M.new()
	local self = setmetatable({}, M)
	self.listeners = {
		gather = {}, -- Array of fn(ctx)
		configure = {}, -- Array of fn(ctx)
		dispatch = nil, -- Single runner: fn(ctx, done)
		render = {}, -- Array of fn(ctx)
		cleanup = {}, -- Array of fn() run on tear-down
	}
	return self
end
