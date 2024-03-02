# Try Dev Branch

## Setup Lazy for Devs

Go to the `dev` directory you specify to lazy.nvim.

``` bash
git clone git@github.com:pysan3/neo-tree.nvim.git
cd ./neo-tree.nvim
git checkout -t origin/v4-dev
```

You cannot have dev tree installed alongside neo-tree, and you cannot access neo-tree while developing. That's a bad thing, so let's make it so we can switch which neo-tree to use via an environment variable.

With this hack and something like tmux, run nvim in one pane as usual to get good old neo-tree, and run `NVIM_NEOTREE_DEV=1 nvim` in another pane to launch a nvim instance with dev-tree installed side-by-side.

``` lua
return {
  "nvim-neo-tree/neo-tree.nvim",
  dir = vim.env.NVIM_NEOTREE_DEV and "/path/to/neo-tree.nvim" or nil, -- Add this line and point to the cloned repo.
  version = false,
  dependencies = {
    { "MunifTanjim/nui.nvim" },
    { "3rd/image.nvim" },
    { "pysan3/pathlib.nvim" },
    { "nvim-neotest/nvim-nio" },
    { "nvim-tree/nvim-web-devicons" },
    { "miversen33/netman.nvim" },
  },
  opts = {
    -- ...
  }
}
```

Rest of your config should not have any breaking changes, except that I haven't implemented the complete feature set yet, so some options are just ignored now.

# Road Map

Here are the list of features that I haven't implemented / tested yet. I'll mostly work from top to bottom, but I may skip one or another based on my interests haha.

## 🔳 Command Parser Autoload

Make auto completion possible with `:Neotree` command. This one is pretty difficult as results must be returned before lazy loading.

## 🔳 Neotree float

I just haven't looked into the nui options.

- [ ] Implement `wm.create_win`.
- [ ] Set window color groups here.

## ✅ Highlights

Least priority for me sadly. I'm pretty sure old code will just work as is.

- [x] existing code worked as-is!!

## ✅ Steal Prevention

This is my next big thing to tackle.

- [x] send current buffer to previous **non** neo-tree window.
  - [x] autocmd for each manager.
  - [ ] update jump info.
  - [x] remember previous window on WinLeave

## ✅ Cursor Position Save

- [x] when curpos is saved
  - [x] close
    - [x] no need to do this anymore? `bufdelete` should handle this
  - [x] before render\_tree
  - [x] follow\_internal
    - [x] instead use focus\_node
  - [x] `bufdelete`
    - [x] use BufWinLeave instead
- [x] when restored
  - [x] after render\_tree

## 🔳 More Position Work

Pre-alpha.

Current code is very hacky.

- [ ] Revisit this and implement it a bit cleaner.
- [ ] Back port <https://github.com/nvim-neo-tree/neo-tree.nvim/pull/1355>

Implement some kind of session save / restore mechanism that is able to survive across different nvim sessions.

- [ ] <https://github.com/nvim-neo-tree/neo-tree.nvim/pull/1366#issuecomment-1968943373>

## ✅ Keybinds

- [x] Make the code cleaner.
- [x] assign mappings to bufnr in each source. [./lua/neo-tree/ui/renderer.lua](./lua/neo-tree/ui/renderer.lua) \> `set_buffer_mappings`

### Keybind Commands

- [ ] rewrite `common/commands`.
