local M = {}

M.check = function()
  vim.health.start("live-autoread")

  -- Check Neovim version
  if vim.fn.has("nvim-0.10") == 1 then
    vim.health.ok("Neovim >= 0.10")
  else
    vim.health.error("Neovim >= 0.10 required", { "Upgrade Neovim to 0.10 or later" })
  end

  -- Check vim.uv availability
  if vim.uv then
    vim.health.ok("vim.uv available")
  else
    vim.health.error("vim.uv not available", { "Upgrade Neovim to 0.10 or later" })
  end

  -- Check active watchers
  local ok, live_autoread = pcall(require, "live-autoread")
  if ok and live_autoread.status then
    local watchers = live_autoread.status()
    local count = #watchers
    if count > 0 then
      vim.health.ok(string.format("%d active file watcher(s)", count))
      for _, w in ipairs(watchers) do
        vim.health.info(string.format("  buf %d: %s", w.bufnr, w.path))
      end
    else
      vim.health.ok("No active file watchers (normal if no file buffers open)")
    end
  end
end

return M
