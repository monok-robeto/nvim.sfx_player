-- nvim.sfx_player :: default configuration
--
-- Everything here is overridable through `require("nvim.sfx_player").setup{ ... }`.
-- Named entries (keymaps, highlights, icons) are replaced per key rather than
-- deep-merged, so you can override a single action without re-declaring the rest.

local M = {}

---@class SfxPlayer.Config
M.defaults = {
  -- Popup window title.
  title = "nvim.sfx_player",

  -- External binaries. Change if they live outside your $PATH.
  mpv_path = "mpv",
  ffprobe_path = "ffprobe", -- optional, only used for extra metadata

  -- Playback.
  default_volume = 100, -- 0-130 (mpv soft volume)
  volume_step = 5, -- % per key press
  seek_step = 3, -- seconds per seek
  loop_default = false, -- start with loop enabled

  -- UI.
  update_interval = 200, -- timeline refresh in ms
  bar_width = 34, -- progress bar width in cells
  border = "rounded", -- any nvim_open_win border style
  auto_close_on_leave = true, -- close popup when it loses focus

  window = {
    width = nil, -- default: bar_width + 20
    row = nil, -- default: vertically centered
    col = nil, -- default: horizontally centered
  },

  icons = {
    file = "🎵",
    paused = "▶", -- shown while paused (press to play)
    playing = "⏸", -- shown while playing (press to pause)
    volume = "🔊",
    loop_on = "🔁",
    loop_off = "➡",
  },

  -- File extensions treated as audio (lower-case, no dot).
  extensions = {
    "mp3",
    "wav",
    "flac",
    "ogg",
    "oga",
    "opus",
    "m4a",
    "aac",
    "wma",
    "aiff",
    "aif",
    "alac",
    "ape",
    "mka",
  },

  -- Keymaps active inside the popup. Each value is a string or a list of
  -- strings. Set to false to disable an action.
  keymaps = {
    play_pause = "<Space>",
    seek_forward = "<Right>",
    seek_backward = "<Left>",
    volume_up = "<Up>",
    volume_down = "<Down>",
    toggle_loop = "L", -- Shift+L
    quit = { "<Esc>", "q" },
  },

  -- Highlight groups. Each value is passed straight to nvim_set_hl(), so use
  -- `{ link = "Group" }` to follow your colorscheme or explicit attrs like
  -- `{ fg = "#7aa2f7", bold = true }`. Re-applied on every :colorscheme change.
  highlights = {
    title = { link = "Title" },
    name = { link = "Title" },
    meta = { link = "Comment" },
    icon = { link = "Special" },
    filled = { link = "Statement" }, -- played part of the bar
    knob = { link = "Special" }, -- playhead
    remain = { link = "Comment" }, -- unplayed part of the bar
    time = { link = "Number" },
    volume = { link = "Number" },
    loop_active = { link = "String" },
    loop_inactive = { link = "Comment" },
    help = { link = "NonText" },
  },
}

---Merge user options over the defaults.
---@param opts table|nil
---@return SfxPlayer.Config
function M.merge(opts)
  opts = opts or {}
  local cfg = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)

  -- keymaps and highlights are replaced per key, never deep-merged, so that a
  -- partial override does not leave stale defaults behind (e.g. link + fg).
  cfg.keymaps = vim.tbl_extend("force", vim.deepcopy(M.defaults.keymaps), opts.keymaps or {})
  cfg.highlights = vim.tbl_extend("force", vim.deepcopy(M.defaults.highlights), opts.highlights or {})
  cfg.icons = vim.tbl_extend("force", vim.deepcopy(M.defaults.icons), opts.icons or {})

  return cfg
end

return M
