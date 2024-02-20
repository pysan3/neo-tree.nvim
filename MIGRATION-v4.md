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
}
```

Rest of your config should not have any breaking changes, except that I haven't implemented the complete feature set yet, so some options are just ignored now.

## Magic Script to Reload Neotree

During plugin development, when you change some code, you'd have to close nvim and then reopen to get the new changes applied. But that's not how we (programmers) work.

Put this in a random lua file (`reload.lua`) and each time you `:so reload.lua`, you'll get the new code applied without closing neovim. Don't forget to use `vim.startswith` cuz we need to also clear required files like `"neo-tree.ui.renderer"`.

``` lua
for key, _ in pairs(package.loaded) do
  if vim.startswith(key, "neo-tree") then
    package.loaded[key] = nil
  -- elseif vim.startswith(key, "nio") then
  --   package.loaded[key] = nil
  -- elseif vim.startswith(key, "nui") then
  --   package.loaded[key] = nil
  -- elseif vim.startswith(key, "pathlib") then
  --   package.loaded[key] = nil
  end
end
local suc, mod = pcall(require, "neo-tree")
assert(suc and mod)
```

BTW if you use noice and `:NoiceHistory` becomes too long, run the following code to flush the history. More info: <https://github.com/folke/noice.nvim/issues/731>.

``` lua
require("noice.message.manager")._history = {}
```

# Roadmap

Here are the list of features that I haven't implemented / tested yet. I'll mostly work from top to bottom, but I may skip one or another based on my interests haha.

## <label><input type="checkbox"> Neotree float </label>

I just haven't looked into the nui options.

## <label><input type="checkbox"> Highlights </label>

Least priority for me sadly. I'm pretty sure old code will just work as is.

## <label><input type="checkbox"> Steal Prevention </label>

This is my next big thing to tackle.

- [ ] autocmd for each manager.
- [ ] send current buffer to `before_jump_info`.
  - [ ] update jump info.

## <label><input type="checkbox"> Cursor Position Save </label>

Current code is very hacky.

- [ ] Revisit this and implement it a bit cleaner.

<!-- -->

- [x] when curpos is saved
  - [x] close
    - [x] no need to do this anymore? bufdelete should handle this
  - [x] before render\_tree
  - [x] follow\_internal
    - [x] instead use focus\_node
  - [x] bufdelete
    - [x] use BufWinLeave instead
- [x] when restored
  - [x] after render\_tree

## <label><input type="checkbox" checked> Keybinds </label>

- [ ] Make the code cleaner.
- [x] assign mappings to bufnr in each source.
- [ ] rewrite `filetree/commands`. [./lua/neo-tree/ui/renderer.lua](./lua/neo-tree/ui/renderer.lua) \> `set_buffer_mappings`

``` lua
keymap.set(state.bufnr, "n", cmd, resolved_mappings[cmd].handler, map_options)
if type(vfunc) == "function" then
  keymap.set(state.bufnr, "v", cmd, function()
    vim.api.nvim_feedkeys(ESC_KEY, "i", true)
    vim.schedule(function()
      local selected_nodes = get_selected_nodes(state)
      if utils.truthy(selected_nodes) then
        state.config = config
        vfunc(state, selected_nodes)
      end
    end)
  end, map_options)
end
```

## <label><input type="checkbox"> Cursor Position </label>

- [ ] Backport <https://github.com/nvim-neo-tree/neo-tree.nvim/pull/1355>

## <label><input type="checkbox"> Event Handlers </label>

None of them are correctly triggered, and the API might change in the future.

- [ ] follow current file
- [ ] change cwd

## <label><input type="checkbox"> File Watcher </label>

- [x] Detect and update tree on file change.
- [ ] file watcher is registered more than once.
- [ ] Use debounce based on num of waiting files.
- [ ] Scan check if dir is already scanned.
  - [ ] [Keybinds](#keybinds) disable detecting file addition on neotree keybind.

## <label><input type="checkbox"> Git Watcher </label>

Use `nio.process` to capture git status instead. Incremental update when done. Debounce.

## <label><input type="checkbox" checked> Tab Sync </label>

On tab switch, recreate the other layouts.

Does not work when left -\> right -\> top -\> right. Do not have any way to test it with code. (Requires human intervention). Maybe create aucmd with AuG ID? create\_aug is not updated.

Solved!!!

- <https://github.com/MunifTanjim/nui.nvim/pull/332>

## <label><input type="checkbox"> Implement `wm.create_win` </label>

## <label><input type="checkbox"> GC old state </label>

Especially window-scoped states when reference is done. Call `state:free`.

# Breaking Changes

## Manager

The biggest rewrite happends at *manager*.

Previously it was `"neo-tree.sources.manager"` which I've moved it to `"neo-tree.manager.init"`. The old manager was to initialize a state and to fetch the current active state in a very hacky code. In my rewrite, the manager strongly holds references to all states and is *the* module that is responsible of deciding which state to use and switch to the appropriate state for each `:Neotree xxx` call.

A new instance of manager is created for each tabpage. This brings a lot of merits, that what state is shown where (left/right/top/left) can be managed in each manager and separately for each tabpage.

However, a globally shared table `manager.source_lookup` is set as a class property, meaning that all managers access the same table so that the [State Instance](#state-instance)s can be shared across all tabpages.

### Share State Among Tabs

I'd like to add a global option `config.share_state_among_tabs` that, when set to true, all tabs will have the exact same neo-tree layouts.

This is very easy. Add a `TabEntered` autocmd for each manager, and when the active tab is what *you* are supposed to handle, reference `global_position_state` and rearrange the layout to match this table.

When a state is opened or closed, submit that to the `global_position_state` so that when user switches to a different tab, *your* layout is copied to them.

## Sources

### Buffer / Window Management

As [Manager](#manager) handles windows and buffers, each source / state does not need to know when / where it is being placed.

Instead, it is told only about the window width, and whether source is allowed to request an expansion of the width.

After state has finished `tree:render()`, it does not need to check whether a window is valid or `aquire_window` or anything like that but just needs to call `manager:done()`.

Therefore, `state` will no longer have `tabid`, `winid`, `bufnr` attributes. `state.current_position` is kept (and updated correctly) for backwards compatibility, but it is advised not to rely on the value of this attribute.

### State Instance

WIP

# External Sources

There are no specific changes regarding external sources. See [Sources](#sources) for the list you changes you need.

However, you have the ability to specify your own commands for users to set for keybinds.
