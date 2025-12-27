# live-autoread.nvim

True auto-refresh for visible buffers in Neovim.

## The Problem

Neovim's built-in `autoread` option only reloads files on specific events like `FocusGained` or `BufEnter`. If you have a file open in a visible split and an external process modifies it, Neovim won't update the buffer until you interact with it.

## The Solution

This plugin uses libuv filesystem watchers to detect changes instantly and triggers `:checktime` only for buffers that are currently visible on screen.

## Features

- Instant reload when external changes are detected
- Only reloads buffers visible in the current tabpage
- Warns instead of reloading if buffer has unsaved changes
- Debounces rapid filesystem events
- Handles atomic saves (write-to-temp + rename pattern)
- Cleans up watchers automatically when buffers are closed

## Requirements

- Neovim >= 0.10 (requires `vim.uv`)

### Note for tmux users

If you run Neovim inside tmux, add this to your `~/.tmux.conf`:

```tmux
set -g focus-events on
```

This allows tmux to pass focus events through to Neovim, enabling `FocusGained` triggers when you switch panes or windows.

## Installation

### lazy.nvim

```lua
{
  "diegok/live-autoread.nvim",
  event = "BufReadPost",
  opts = {},
}
```

### packer.nvim

```lua
use {
  "diegok/live-autoread.nvim",
  config = function()
    require("live-autoread").setup()
  end,
}
```

## Configuration

```lua
require("live-autoread").setup({
  -- Debounce time for filesystem events (ms)
  debounce_ms = 250,

  -- Show warning when file changes but buffer has unsaved modifications
  notify_on_conflict = true,

  -- Show notification when a file is reloaded
  notify_on_reload = false,

  -- Enable debug logging
  debug = false,
})
```

All options are optional - the defaults above work well for most cases.

## API

```lua
-- Stop all file watchers
require("live-autoread").stop()
```

## How It Works

1. Sets `vim.o.autoread = true` (baseline Neovim behavior)
2. Runs `:checktime` on `FocusGained`/`BufEnter` for hidden buffers
3. Creates libuv `fs_event` watchers for each file buffer
4. When a watched file changes, checks if its buffer is visible in any window of the current tabpage
5. If visible and unmodified: reloads via `:checktime`
6. If visible but modified: shows a warning instead

## License

MIT
