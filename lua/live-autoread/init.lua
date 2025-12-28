--
-- Live filesystem watching for visible buffers, plus standard autoread for all.
--
-- Behavior:
-- - Sets vim.o.autoread = true (baseline for all buffers)
-- - Runs :checktime on FocusGained/BufEnter (hidden buffers update when visited)
-- - Adds libuv fs-event watchers for real-time reload of *visible* buffers
--   (current tabpage only) without needing focus change.
-- - If buffer is modified, warns instead.
--

local M = {}

local uv = vim.uv

---@class LiveAutoreadConfig
---@field debounce_ms? integer
---@field notify_on_conflict? boolean
---@field notify_on_reload? boolean
---@field debug? boolean

local cfg = {
  debounce_ms = 250,
  notify_on_conflict = true,
  notify_on_reload = false,
  debug = false,
}

local handle_by_buf = {}
local path_by_buf = {}
local last_ms_by_buf = {}

local function debug(msg)
  if cfg.debug then
    vim.notify("[live-autoread] " .. msg, vim.log.levels.INFO)
  end
end

local function is_normal_file_buf(bufnr)
  return vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].buftype == "" and vim.api.nvim_buf_get_name(bufnr) ~= ""
end

local function buf_visible_in_current_tab(bufnr)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      return true
    end
  end
  return false
end

local function close_watch(bufnr)
  local h = handle_by_buf[bufnr]
  if not h then
    return
  end
  pcall(function()
    h:stop()
  end)
  pcall(function()
    h:close()
  end)
  handle_by_buf[bufnr] = nil
  path_by_buf[bufnr] = nil
  last_ms_by_buf[bufnr] = nil
  debug("stopped watcher for bufnr=" .. tostring(bufnr))
end

local start_watch

local function checktime_buf(bufnr, path, restart_watcher)
  if not is_normal_file_buf(bufnr) or not buf_visible_in_current_tab(bufnr) then
    return
  end

  if vim.bo[bufnr].modified then
    if cfg.notify_on_conflict then
      vim.notify(vim.fn.fnamemodify(path, ":.") .. " changed on disk (buffer has unsaved changes)", vim.log.levels.WARN)
    end
    return
  end

  vim.api.nvim_buf_call(bufnr, function()
    vim.cmd("checktime")
  end)

  if cfg.notify_on_reload then
    vim.notify(vim.fn.fnamemodify(path, ":.") .. " reloaded (external change)", vim.log.levels.INFO)
  end

  -- Restart watcher after checktime to ensure fresh inode tracking
  if restart_watcher then
    close_watch(bufnr)
    start_watch(bufnr)
  end
end

local function debounce_ok(bufnr)
  local now = uv.now()
  local prev = last_ms_by_buf[bufnr]
  if prev and (now - prev) < cfg.debounce_ms then
    debug("debounced bufnr=" .. tostring(bufnr))
    return false
  end
  last_ms_by_buf[bufnr] = now
  return true
end

start_watch = function(bufnr)
  if not is_normal_file_buf(bufnr) or handle_by_buf[bufnr] then
    return
  end

  local path = vim.api.nvim_buf_get_name(bufnr)
  local st = uv.fs_stat(path)
  if not st or st.type ~= "file" then
    debug("not a file, skip watch: " .. path)
    return
  end

  local h = uv.new_fs_event()
  if not h then
    vim.notify("[live-autoread] failed to create fs_event handle", vim.log.levels.ERROR)
    return
  end

  path_by_buf[bufnr] = path

  local ok, err = pcall(function()
    h:start(path, {}, function(werr, _, events)
      if werr then
        vim.schedule(function()
          vim.notify("[live-autoread] watcher error: " .. tostring(werr), vim.log.levels.ERROR)
          close_watch(bufnr)
        end)
        return
      end

      if not debounce_ok(bufnr) then
        return
      end

      vim.schedule(function()
        local cur_path = vim.api.nvim_buf_get_name(bufnr)
        if not vim.api.nvim_buf_is_valid(bufnr) or cur_path == "" then
          close_watch(bufnr)
          return
        end

        -- If path changed (e.g., :saveas), restart watcher on the new path.
        if cur_path ~= path_by_buf[bufnr] then
          debug("path changed for bufnr=" .. bufnr .. " -> restarting watcher")
          close_watch(bufnr)
          start_watch(bufnr)
          return
        end

        -- Atomic save patterns often show up as rename; handle may go stale.
        if events and events.rename then
          debug("rename event for bufnr=" .. tostring(bufnr) .. " path=" .. cur_path)
          close_watch(bufnr)
          -- Hardcoded short delay to let filesystem settle (NOT tied to debounce_ms).
          vim.defer_fn(function()
            if vim.api.nvim_buf_is_valid(bufnr) then
              start_watch(bufnr)
              -- Don't restart again here since we just started
              checktime_buf(bufnr, cur_path, false)
            end
          end, 80)
          return
        end

        -- Always restart watcher after reload to ensure fresh inode tracking
        checktime_buf(bufnr, cur_path, true)
      end)
    end)
  end)

  if not ok then
    pcall(function()
      h:close()
    end)
    handle_by_buf[bufnr] = nil
    path_by_buf[bufnr] = nil
    vim.notify("[live-autoread] failed to start watcher: " .. tostring(err), vim.log.levels.ERROR)
    return
  end

  handle_by_buf[bufnr] = h
  debug("started watcher for bufnr=" .. tostring(bufnr) .. " path=" .. path)
end

---@param user_cfg? LiveAutoreadConfig
function M.setup(user_cfg)
  cfg = vim.tbl_deep_extend("force", cfg, user_cfg or {})

  vim.o.autoread = true

  local aug = vim.api.nvim_create_augroup("LiveAutoread", { clear = true })

  -- Baseline: keep core Neovim behavior for buffers that aren't currently on screen.
  vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter" }, {
    group = aug,
    pattern = "*",
    callback = function()
      if vim.fn.mode() ~= "c" then
        vim.cmd("checktime")
      end
      -- Always restart watcher on focus to handle stale inode after atomic saves
      local bufnr = vim.api.nvim_get_current_buf()
      close_watch(bufnr)
      start_watch(bufnr)
    end,
  })

  -- Ensure watchers for opened/read file buffers.
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
    group = aug,
    pattern = "*",
    callback = function(args)
      start_watch(args.buf)
    end,
  })

  -- After writes, ensure watcher still points at the right path (e.g., saveas/atomic save).
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = aug,
    pattern = "*",
    callback = function(args)
      vim.defer_fn(function()
        if vim.api.nvim_buf_is_valid(args.buf) then
          -- Restart if path changed; otherwise ensure exists.
          if handle_by_buf[args.buf] then
            local cur = vim.api.nvim_buf_get_name(args.buf)
            if cur ~= "" and cur ~= path_by_buf[args.buf] then
              close_watch(args.buf)
            end
          end
          start_watch(args.buf)
        end
      end, 80)
    end,
  })

  -- Cleanup on buffer death.
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = aug,
    pattern = "*",
    callback = function(args)
      close_watch(args.buf)
    end,
  })

  start_watch(vim.api.nvim_get_current_buf())
end

function M.stop()
  for bufnr, _ in pairs(handle_by_buf) do
    close_watch(bufnr)
  end
end

function M.status()
  local watchers = {}
  for bufnr, _ in pairs(handle_by_buf) do
    table.insert(watchers, { bufnr = bufnr, path = path_by_buf[bufnr] })
  end
  return watchers
end

return M
