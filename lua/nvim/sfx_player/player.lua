-- nvim.sfx_player :: playback engine
--
-- Drives a single background `mpv` process through its JSON IPC socket and
-- renders a floating popup with a live, colored timeline.

local Player = {}

---@type SfxPlayer.Config
local cfg = nil

local ns = vim.api.nvim_create_namespace "nvim_sfx_player"

-- highlight group names, keyed by cfg.highlights key
local HL = {
  title = "SfxPlayerTitle",
  name = "SfxPlayerName",
  meta = "SfxPlayerMeta",
  icon = "SfxPlayerIcon",
  filled = "SfxPlayerBarFilled",
  knob = "SfxPlayerBarKnob",
  remain = "SfxPlayerBarRemain",
  time = "SfxPlayerTime",
  volume = "SfxPlayerVolume",
  loop_active = "SfxPlayerLoopActive",
  loop_inactive = "SfxPlayerLoopInactive",
  help = "SfxPlayerHelp",
}

local ext_set = {}

local state = {
  job = nil, -- mpv job id
  chan = nil, -- ipc socket channel
  sock = nil, -- socket path
  buf = nil,
  win = nil,
  timer = nil, -- render/poll timer
  connect_timer = nil,
  connect_tries = 0,
  recv = "", -- partial socket line buffer
  file = nil,
  meta = {}, -- ffprobe metadata
  duration = 0,
  time_pos = 0,
  volume = 100,
  paused = false,
  loop = false,
  closing = false,
}

----------------------------------------------------------------------
-- setup / highlights
----------------------------------------------------------------------

local function apply_highlights()
  for key, group in pairs(HL) do
    local spec = cfg.highlights[key]
    if spec then
      pcall(vim.api.nvim_set_hl, 0, group, spec)
    end
  end
end

function Player.setup(config)
  cfg = config

  ext_set = {}
  for _, e in ipairs(cfg.extensions or {}) do
    ext_set[e:lower()] = true
  end

  apply_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("NvimSfxPlayerHl", { clear = true }),
    callback = apply_highlights,
  })
end

function Player.is_audio(path)
  if not path then
    return false
  end
  local ext = path:match "%.([%w]+)$"
  return ext ~= nil and ext_set[ext:lower()] == true
end

----------------------------------------------------------------------
-- formatting helpers
----------------------------------------------------------------------

local function fmt_time(sec)
  if not sec or sec < 0 then
    return "--:--"
  end
  sec = math.floor(sec + 0.5)
  local m = math.floor(sec / 60)
  local s = sec % 60
  if m >= 60 then
    local h = math.floor(m / 60)
    m = m % 60
    return string.format("%d:%02d:%02d", h, m, s)
  end
  return string.format("%02d:%02d", m, s)
end

local function human_size(bytes)
  if not bytes or bytes <= 0 then
    return "?"
  end
  local units = { "B", "KB", "MB", "GB" }
  local i, n = 1, bytes
  while n >= 1024 and i < #units do
    n = n / 1024
    i = i + 1
  end
  if i == 1 then
    return string.format("%d %s", n, units[i])
  end
  return string.format("%.1f %s", n, units[i])
end

-- Turn a keymap lhs into a compact label for the help line.
local PRETTY = {
  ["<Space>"] = "Space",
  ["<Left>"] = "←",
  ["<Right>"] = "→",
  ["<Up>"] = "↑",
  ["<Down>"] = "↓",
  ["<Esc>"] = "Esc",
  ["<CR>"] = "⏎",
  ["<Tab>"] = "Tab",
  ["<BS>"] = "⌫",
}

local function pretty_key(lhs)
  if type(lhs) == "table" then
    lhs = lhs[1]
  end
  if not lhs then
    return "?"
  end
  return PRETTY[lhs] or lhs
end

----------------------------------------------------------------------
-- rendering
----------------------------------------------------------------------

-- Build a line from `{ text, hl_group? }` segments, returning the string plus
-- byte-accurate highlight ranges.
local function build(segments)
  local text, hls = "", {}
  for _, seg in ipairs(segments) do
    local col = #text
    text = text .. seg[1]
    if seg[2] then
      hls[#hls + 1] = { col, #text, seg[2] }
    end
  end
  return text, hls
end

local function bar_segments(pos, dur)
  local w = cfg.bar_width
  local d = (dur and dur > 0) and dur or 1
  local ratio = math.max(0, math.min(1, (pos or 0) / d))
  local filled = math.max(0, math.min(w, math.floor(ratio * w + 0.5)))
  return {
    { string.rep("━", filled), HL.filled },
    { "●", HL.knob },
    { string.rep("─", w - filled), HL.remain },
  }
end

local function render()
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then
    return
  end

  local m = state.meta
  local name = vim.fn.fnamemodify(state.file, ":t")

  local meta_parts = {}
  if m.codec then
    meta_parts[#meta_parts + 1] = m.codec:upper()
  end
  if m.sample_rate then
    meta_parts[#meta_parts + 1] = string.format("%.1f kHz", m.sample_rate / 1000)
  end
  if m.channels then
    meta_parts[#meta_parts + 1] = m.channels == 1 and "mono" or (m.channels == 2 and "stereo" or (m.channels .. "ch"))
  end
  if m.bitrate then
    meta_parts[#meta_parts + 1] = string.format("%d kbps", math.floor(m.bitrate / 1000))
  end
  local meta1 = #meta_parts > 0 and table.concat(meta_parts, "  ·  ") or "audio file"
  local meta2 = human_size(m.size) .. "  ·  " .. fmt_time(state.duration)

  local icon = state.paused and cfg.icons.paused or cfg.icons.playing

  -- assemble each line as segments so highlights land on exact byte ranges
  local rows = {}

  rows[#rows + 1] = { { "  " .. cfg.icons.file .. "  ", HL.icon }, { name, HL.name } }
  rows[#rows + 1] = { { "  " .. meta1, HL.meta } }
  rows[#rows + 1] = { { "  " .. meta2, HL.meta } }
  rows[#rows + 1] = {}

  local bar_row = { { "  " .. icon .. "  ", HL.icon }, { fmt_time(state.time_pos) .. " ", HL.time } }
  vim.list_extend(bar_row, bar_segments(state.time_pos, state.duration))
  bar_row[#bar_row + 1] = { " " .. fmt_time(state.duration), HL.time }
  rows[#rows + 1] = bar_row

  rows[#rows + 1] = {}

  local loop_hl = state.loop and HL.loop_active or HL.loop_inactive
  local loop_icon = state.loop and cfg.icons.loop_on or cfg.icons.loop_off
  rows[#rows + 1] = {
    { "  " .. cfg.icons.volume .. " ", HL.volume },
    { string.format("%d%%", state.volume), HL.volume },
    { "    " .. loop_icon .. " ", loop_hl },
    { "loop " .. (state.loop and "on" or "off"), loop_hl },
  }

  local k = cfg.keymaps
  local help = string.format(
    "  [%s] play/pause  [%s/%s] vol  [%s/%s] seek  [%s] loop  [%s] quit",
    pretty_key(k.play_pause),
    pretty_key(k.volume_down),
    pretty_key(k.volume_up),
    pretty_key(k.seek_backward),
    pretty_key(k.seek_forward),
    pretty_key(k.toggle_loop),
    pretty_key(k.quit)
  )
  rows[#rows + 1] = { { help, HL.help } }

  local lines, all_hls = {}, {}
  for i, segs in ipairs(rows) do
    local text, hls = build(segs)
    lines[i] = text
    for _, h in ipairs(hls) do
      all_hls[#all_hls + 1] = { i - 1, h[1], h[2], h[3] }
    end
  end

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
  for _, h in ipairs(all_hls) do
    pcall(vim.api.nvim_buf_add_highlight, state.buf, ns, h[4], h[1], h[2], h[3])
  end
end

----------------------------------------------------------------------
-- ffprobe metadata (best-effort)
----------------------------------------------------------------------

local function probe(path)
  local meta = { size = vim.fn.getfsize(path) }
  if vim.fn.executable(cfg.ffprobe_path) ~= 1 then
    return meta
  end
  local out = vim.fn.system {
    cfg.ffprobe_path,
    "-v",
    "quiet",
    "-print_format",
    "json",
    "-show_format",
    "-show_streams",
    path,
  }
  local ok, data = pcall(vim.json.decode, out)
  if not ok or type(data) ~= "table" then
    return meta
  end
  local f = data.format or {}
  meta.size = tonumber(f.size) or meta.size
  meta.bitrate = tonumber(f.bit_rate)
  meta.duration = tonumber(f.duration)
  for _, s in ipairs(data.streams or {}) do
    if s.codec_type == "audio" then
      meta.codec = s.codec_name
      meta.sample_rate = tonumber(s.sample_rate)
      meta.channels = tonumber(s.channels)
      break
    end
  end
  return meta
end

----------------------------------------------------------------------
-- mpv ipc
----------------------------------------------------------------------

local function send(tbl)
  if not state.chan then
    return
  end
  local ok, encoded = pcall(vim.json.encode, tbl)
  if ok then
    pcall(vim.fn.chansend, state.chan, encoded .. "\n")
  end
end

local function process_line(line)
  if not line or line == "" then
    return
  end
  local ok, msg = pcall(vim.json.decode, line)
  if not ok or type(msg) ~= "table" then
    return
  end
  if msg.request_id and msg.error == "success" then
    if msg.request_id == 1 and type(msg.data) == "number" then
      state.time_pos = msg.data
    elseif msg.request_id == 2 and type(msg.data) == "number" then
      state.duration = msg.data
    elseif msg.request_id == 3 then
      state.paused = msg.data == true
    elseif msg.request_id == 4 and type(msg.data) == "number" then
      state.volume = math.floor(msg.data + 0.5)
    end
  end
end

local function on_data(_, data)
  state.recv = state.recv .. (data[1] or "")
  if #data > 1 then
    process_line(state.recv)
    for i = 2, #data - 1 do
      process_line(data[i])
    end
    state.recv = data[#data] or ""
  end
end

local function tick()
  if state.closing then
    return
  end
  render()
  send { command = { "get_property", "time-pos" }, request_id = 1 }
  if state.duration <= 0 then
    send { command = { "get_property", "duration" }, request_id = 2 }
  end
  send { command = { "get_property", "pause" }, request_id = 3 }
  send { command = { "get_property", "volume" }, request_id = 4 }
end

local function try_connect()
  state.connect_tries = state.connect_tries + 1
  local ok, chan = pcall(vim.fn.sockconnect, "pipe", state.sock, {
    on_data = on_data,
    data_buffered = false,
  })
  if ok and chan and chan > 0 then
    state.chan = chan
    if state.connect_timer then
      vim.fn.timer_stop(state.connect_timer)
      state.connect_timer = nil
    end
    send { command = { "get_property", "duration" }, request_id = 2 }
    state.timer = vim.fn.timer_start(cfg.update_interval, tick, { ["repeat"] = -1 })
    return
  end
  if state.connect_tries > 60 then
    if state.connect_timer then
      vim.fn.timer_stop(state.connect_timer)
      state.connect_timer = nil
    end
    vim.notify("nvim.sfx_player: could not connect to mpv ipc socket", vim.log.levels.ERROR)
  end
end

----------------------------------------------------------------------
-- controls
----------------------------------------------------------------------

local function toggle_pause()
  send { command = { "cycle", "pause" } }
  state.paused = not state.paused
  render()
end

local function seek(delta)
  send { command = { "seek", delta, "relative" } }
  -- optimistic update so the bar reacts instantly; next poll reconciles.
  local pos = state.time_pos + delta
  if state.duration > 0 then
    pos = math.max(0, math.min(state.duration, pos))
  else
    pos = math.max(0, pos)
  end
  state.time_pos = pos
  render()
end

local function change_volume(delta)
  send { command = { "add", "volume", delta } }
  -- optimistic update so the % reacts instantly; next poll reconciles.
  state.volume = math.max(0, math.min(130, state.volume + delta))
  render()
end

local function toggle_loop()
  state.loop = not state.loop
  send { command = { "set_property", "loop-file", state.loop and "inf" or "no" } }
  render()
end

----------------------------------------------------------------------
-- lifecycle
----------------------------------------------------------------------

function Player.close()
  if state.closing then
    return
  end
  state.closing = true

  if state.timer then
    pcall(vim.fn.timer_stop, state.timer)
    state.timer = nil
  end
  if state.connect_timer then
    pcall(vim.fn.timer_stop, state.connect_timer)
    state.connect_timer = nil
  end
  if state.chan then
    pcall(send, { command = { "quit" } })
    pcall(vim.fn.chanclose, state.chan)
    state.chan = nil
  end
  if state.job then
    pcall(vim.fn.jobstop, state.job)
    state.job = nil
  end
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end
  state.win, state.buf = nil, nil
  state.closing = false
end

local function set_keys(buf, spec, fn)
  if spec == false or spec == nil then
    return
  end
  local list = type(spec) == "table" and spec or { spec }
  local opts = { buffer = buf, nowait = true, silent = true, noremap = true }
  for _, lhs in ipairs(list) do
    vim.keymap.set("n", lhs, fn, opts)
  end
end

local function open_window()
  local width = cfg.window.width or (cfg.bar_width + 20)
  local height = 8
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "sfx_player"

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = cfg.window.row or math.floor((vim.o.lines - height) / 2 - 1),
    col = cfg.window.col or math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = cfg.border,
    title = { { " " .. cfg.title .. " ", HL.title } },
    title_pos = "center",
  })
  vim.wo[win].winblend = 0
  vim.wo[win].cursorline = false

  state.buf, state.win = buf, win

  local k = cfg.keymaps
  set_keys(buf, k.play_pause, toggle_pause)
  set_keys(buf, k.seek_forward, function()
    seek(cfg.seek_step)
  end)
  set_keys(buf, k.seek_backward, function()
    seek(-cfg.seek_step)
  end)
  set_keys(buf, k.volume_up, function()
    change_volume(cfg.volume_step)
  end)
  set_keys(buf, k.volume_down, function()
    change_volume(-cfg.volume_step)
  end)
  set_keys(buf, k.toggle_loop, toggle_loop)
  set_keys(buf, k.quit, Player.close)

  if cfg.auto_close_on_leave then
    vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, {
      buffer = buf,
      once = true,
      callback = function()
        vim.schedule(Player.close)
      end,
    })
  end
end

function Player.open(path)
  if not cfg then
    vim.notify("nvim.sfx_player: setup() has not been called", vim.log.levels.ERROR)
    return
  end
  if vim.fn.executable(cfg.mpv_path) ~= 1 then
    vim.notify("nvim.sfx_player: mpv not found (" .. cfg.mpv_path .. ")", vim.log.levels.ERROR)
    return
  end
  path = vim.fn.fnamemodify(path, ":p")
  if vim.fn.filereadable(path) ~= 1 then
    vim.notify("nvim.sfx_player: cannot read file: " .. path, vim.log.levels.ERROR)
    return
  end

  Player.close() -- one player at a time

  state.file = path
  state.meta = probe(path)
  state.duration = state.meta.duration or 0
  state.time_pos = 0
  state.paused = false
  state.volume = cfg.default_volume
  state.loop = cfg.loop_default
  state.recv = ""
  state.connect_tries = 0
  state.sock = vim.fn.tempname()

  open_window()
  render()

  local args = {
    cfg.mpv_path,
    "--no-video",
    "--no-terminal",
    "--really-quiet",
    "--keep-open=yes",
    "--volume=" .. cfg.default_volume,
    "--input-ipc-server=" .. state.sock,
  }
  if cfg.loop_default then
    args[#args + 1] = "--loop-file=inf"
  end
  args[#args + 1] = path

  state.job = vim.fn.jobstart(args, {
    on_exit = function()
      state.job = nil
    end,
  })

  if not state.job or state.job <= 0 then
    vim.notify("nvim.sfx_player: failed to start mpv", vim.log.levels.ERROR)
    Player.close()
    return
  end

  state.connect_timer = vim.fn.timer_start(50, try_connect, { ["repeat"] = -1 })
end

return Player
