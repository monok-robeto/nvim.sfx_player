-- nvim.sfx_player
-- A tiny, mpv-backed audio player popup for Neovim, made to open sound files
-- straight from a file explorer such as nvim-tree.
--
-- Quick start:
--   require("nvim.sfx_player").setup()
--
-- See :help nvim-sfx-player or the README for full configuration.

local Config = require "nvim.sfx_player.config"
local Player = require "nvim.sfx_player.player"

local M = {}

---Open the player popup for an audio file.
---@param path string
function M.open(path)
  Player.open(path)
end

---Close the player popup and stop playback.
function M.close()
  Player.close()
end

---Return true when `path` has an audio extension known to the plugin.
---@param path string
---@return boolean
function M.is_audio(path)
  return Player.is_audio(path)
end

---Configure and initialise the plugin.
---@param opts SfxPlayer.Config|nil
function M.setup(opts)
  local cfg = Config.merge(opts)
  Player.setup(cfg)

  vim.api.nvim_create_user_command("SfxPlayerOpen", function(a)
    M.open(vim.fn.expand(a.args))
  end, { nargs = 1, complete = "file", desc = "Play an audio file with nvim.sfx_player" })

  vim.api.nvim_create_user_command("SfxPlayerClose", function()
    M.close()
  end, { desc = "Close the nvim.sfx_player popup" })
end

---Helper for nvim-tree's `on_attach`: makes <CR>/<Tab> open the player for
---audio files and fall back to the default action otherwise. Call it AFTER
---`api.config.mappings.default_on_attach(bufnr)`.
---@param bufnr integer
---@param opts { open?: string, preview?: string }|nil  keys to bind (defaults <CR>, <Tab>)
function M.nvimtree_attach(bufnr, opts)
  opts = opts or {}
  local api = require "nvim-tree.api"

  local function bind(lhs, fallback)
    vim.keymap.set("n", lhs, function()
      local node = api.tree.get_node_under_cursor()
      if node and node.type == "file" and Player.is_audio(node.absolute_path) then
        Player.open(node.absolute_path)
      else
        fallback()
      end
    end, { buffer = bufnr, noremap = true, silent = true, nowait = true, desc = "nvim.sfx_player" })
  end

  bind(opts.open or "<CR>", function()
    api.node.open.edit()
  end)
  bind(opts.preview or "<Tab>", function()
    api.node.open.preview()
  end)
end

return M
