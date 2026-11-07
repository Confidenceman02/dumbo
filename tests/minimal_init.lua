vim.opt.rtp:prepend(".")
local lazy_plenary = vim.fn.expand("~/.local/share/nvim/lazy/plenary.nvim")

if vim.fn.isdirectory(lazy_plenary) == 1 then
	vim.opt.rtp:append(lazy_plenary)
elseif os.getenv("PLENARY_DIR") and vim.fn.isdirectory(os.getenv("PLENARY_DIR")) == 1 then
	vim.opt.rtp:append(os.getenv("PLENARY_DIR"))
else
	vim.notify("Error: plenary.nvim not found at " .. lazy_plenary)
	vim.cmd("cquit 1")
end

-- 3. Source plenary's plugin file to register the :PlenaryBustedDirectory command
vim.cmd("runtime! plugin/plenary.vim")
