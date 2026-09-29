-- net_picker.nvim — network process + container picker.
--
-- Pick a listening process (or a container exposing ports) and kill it,
-- signal it, tail its log, restart it, debug it, yank its info or jump to
-- the source file named in its cmdline.
--
-- Two interchangeable backends are bundled:
--   * `telescope`  — requires telescope.nvim + plenary.nvim
--   * `fzf`        — requires fzf-lua
--
-- Exactly one backend is used. Pick it in `setup()`:
--
--   require("net_picker").setup({ telescope = true, fzf = false })  -- default
--   require("net_picker").setup({ telescope = false, fzf = true })
--   require("net_picker").net_picker()
--
-- When both options are `true`, the `fzf` backend wins.

local M = {}

M.defaults = {
	telescope = true,
	fzf = false,
}

M.config = vim.deepcopy(M.defaults)

local backends = {
	telescope = "net_picker.telescope",
	fzf = "net_picker.fzf",
}

-- Resolved backend module, cached until the next `setup()`.
local loaded = nil

local function configured()
	if M.config.fzf then
		return "fzf"
	end
	if M.config.telescope then
		return "telescope"
	end
	return nil
end

--- Configure the picker.
--- @param opts table|nil `{ telescope = boolean, fzf = boolean }`
--- @return table M
function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
	loaded = nil
	return M
end

--- Return the active backend module (lazily required), or nil + notify.
--- @return table|nil
function M.backend()
	if loaded then
		return loaded
	end

	local name = configured()
	if not name then
		vim.notify(
			"net_picker: no backend enabled — call setup({ telescope = true }) or setup({ fzf = true })",
			vim.log.levels.ERROR
		)
		return nil
	end

	local ok, mod = pcall(require, backends[name])
	if not ok then
		vim.notify(("net_picker: could not load the %s backend: %s"):format(name, mod), vim.log.levels.ERROR)
		return nil
	end

	loaded = mod
	return mod
end

--- Open the picker using the configured backend.
--- @param opts table|nil backend-specific options
function M.net_picker(opts)
	local backend = M.backend()
	if not backend then
		return
	end
	return backend.net_picker(opts)
end

return M
