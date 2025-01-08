local colors = require("sbar-config-libs/colors")
local icons = require("sbar-config-libs/icons")
local settings = require("sbar-config-libs/settings")
local app_icons = require("sbar-config-libs/helpers.app_icons")
local Promise = require 'promise'

-- TODO  I think we need to store state and maybe monitor more events such as aerospace on-focused-monitor-change
--       and/or sketchybar space_change or display_change all of which should trigger on the same thing in our case
--       Using state, we could track active workspace on each display to fix bugs there and we can probably do better
--       at tracking when workspaces move between displays.
--       display_woke and system_woke might be good times to re-init
--       Annoyingly will need to track the global previous workspace and the per-display active workspace and then
--       once those globals have been updated, run through and get the highlights correct on everything
-- TODO  Bugs when the menus are toggled in and then workspaces are changed. Need a var that tracks display state
--       so if workspace display is off, we don't accidentally start redrawing stuff in piecemeal
-- TODO  If there's a display that doesn't have an app on it, the bar doesn't show what workspace is there. Need to show empty workspaces that are active on displays
-- TODO  Moving a workspace to a different screen doesn't trigger any sort of update right now. Maybe the events above?
-- TODO  the sketchybar-app-fonts are great for many apps, but I keep finding ones that are missing (eg, Photos, Ghostty, etc)
--       so is there a way for me to use icons from elsewhere if the repo doesn't support something?  Or do I need a fork
--       and to make my own icons?  I've seen PRs that are languishing and will need to see if that continues.
-- TODO  Bug: screens sometimes jumbled so the B workspace is on my left and shows in sketchy like it's on the right
--       See: https://github.com/nikitabobko/AeroSpace/issues/336
--       It appears that sketchybar is using a private API with unknown ordering that's not compatible public API or Aerospace. But sometimes lines up with NSScreens. Ugh.
--       I don't see any way to fix this. It changes. Sketchy doesn't allow addressing via name or left-to-right order or anything.
--       Fix: best I can do is let it assign and if I detect it's wrong, press a hotkey to send an event that swaps them. 1 will likely always be right.
-- TODO: When disconnecting from external monitors and then waking from sleep, sketchybar flashes and changes and flashes and changes quite a bit.
--       At the same time, aerospace is jumping things around, which may be part of it, but I suspect multiple different events are triggering
--       refreshes.  Perhaps each monitor removal (I have 3 external) is its own event, for example.
--       How can I avoid the flickering and ideally avoid unnecessary work?  I almost need a debounce or something or a way to update the stored state
--       and compare it to the displayed state.  Or really to see if any changes are needed to the stored state and only go through display updates
--       when there are changes.  So maybe two phases: phase 1 is update state, phase 2 executes if changes were made to state and updates display items.

local spaces = {}
local brackets = {}
local space_paddings = {}
local errorMessageItem = nil

local state = {
  monitors = {},
  workspaces = {},
  menubaron = false
}

local function onAerospaceError(reason)
  print("Got error trying to run aerospace command: " .. dump(reason))
  -- This finds everything with a name of "space.*" and hides it
  sbar:set("/space\\..*/", { drawing = false })
  if errorMessageItem ~= nil then
    -- Manual set of error string on error menu item
    errorMessageItem:set({
      drawing = true,
      label = {
        string = dump(reason),
      }
    })
  end
end

local function sbarExecPromise(cmd)
  return Promise.new(function(resolve, failfunc)
    sbar.exec(cmd, function(result, exit_code)
      if exit_code ~= 0 then
        if fail ~= nil then
          failfunc(string.format("Exit Code: %s Message: %s", tostring(exit_code), dump(result)))
        end
      else
        if resolve ~= nil then
          resolve(result)
        end
      end
    end)
  end):catch(onAerospaceError)
end

-- Needed for a hack right now. Hope to ditch it later.
local function delay(seconds)
  return Promise.new(function(resolve)
    local time = os.time()
    local newtime = time + seconds
    while (time < newtime) do
      time = os.time()
    end
    resolve()
  end)
end

-- monitor-appkit-nsscreen-screens-id works with list-monitors (maybe I should keep this up to date?)
-- list-windows, and list-workspaces

local function getAllWorkspaces()
  return sbarExecPromise(
    "aerospace list-workspaces --all --format '%{workspace}%{monitor-appkit-nsscreen-screens-id}' --json")
end

local function getWindowsOnWorkspace(workspaceid)
  return sbarExecPromise(string.format("aerospace list-windows --workspace '%s' --format '%%{app-name}' --json",
    workspaceid))
end

local function getVisibleWorkspaces()
  return sbarExecPromise(
    "aerospace list-workspaces --visible --monitor all --format '%{workspace}%{monitor-appkit-nsscreen-screens-id}' --json")
end

local function getEmptyWorkspaces()
  return sbarExecPromise(
    "aerospace list-workspaces --monitor all --empty --format '%{workspace}%{monitor-appkit-nsscreen-screens-id}' --json")
end

local function getNonEmptyWorkspaces()
  return sbarExecPromise(
    "aerospace list-workspaces --monitor all --empty no --format '%{workspace}%{monitor-appkit-nsscreen-screens-id}' --json")
end

local function highlightWorkspace(space, space_bracket, selected, prevselected)
  space:set({
    drawing = true, -- if we go to a space, make it visible
    icon = { highlight = selected or prevselected, },
    label = { highlight = selected },
    background = { border_color = selected and colors.black or colors.bg2 }
  })
  space_bracket:set({
    background = { border_color = selected and colors.grey or colors.bg2 }
  })
end

local function showNonEmptyWorkspaces()
  return getNonEmptyWorkspaces():thenCall(function(workspaces)
    for _, workspace in ipairs(workspaces) do
      local workspaceid = workspace["workspace"]
      local display = workspace["monitor-appkit-nsscreen-screens-id"]
      spaces[workspaceid]:set({ drawing = true, display = display })
      space_paddings[workspaceid]:set({ drawing = true, display = display })
    end
  end)
end

local function hideEmptyWorkspaces()
  return getEmptyWorkspaces():thenCall(function(workspaces)
    for _, workspace in ipairs(workspaces) do
      local workspaceid = workspace["workspace"]
      local display = workspace["monitor-appkit-nsscreen-screens-id"]
      spaces[workspaceid]:set({ drawing = false, display = display })
      space_paddings[workspaceid]:set({ drawing = false, display = display })
    end
  end)
end

local function highlightVisibleWorkspaces()
  return getVisibleWorkspaces():thenCall(function(workspaces)
    for _, workspace in ipairs(workspaces) do
      local workspaceid = workspace["workspace"]
      local display = workspace["monitor-appkit-nsscreen-screens-id"]
      local space = spaces[workspaceid]
      local space_bracket = brackets[workspaceid]
      space:set({ display = display })
      space_bracket = ({ display = display })
      highlightWorkspace(space, space_bracket, true, false)
    end
  end)
end

local function setIconsForWorkspace(workspaceid)
  return getWindowsOnWorkspace(workspaceid):thenCall(function(windows)
    local icon_line = ""
    local has_apps = #windows > 0
    local loaded_icons = {} -- we use this to avoid duplicating app icons for multiple windows

    if has_apps then
      for _, window in ipairs(windows) do
        local app = window["app-name"]
        local lookup = app_icons[app]
        local icon = ((lookup == nil) and app_icons["Default"] or lookup)
        if loaded_icons[icon] == nil then
          loaded_icons[icon] = true
          icon_line = icon_line .. " " .. icon
        end
      end
    else
      icon_line = " —"
    end

    local space = spaces[workspaceid]
    local padding = space_paddings[workspaceid]

    sbar.animate("tanh", 10, function()
      space:set({ drawing = has_apps, label = icon_line })
      padding:set({ drawing = has_apps })
    end)
  end)
end

local function onActiveWorkspaceChange(env, space, space_bracket, space_padding)
  local workspaceid = space.name:gsub("^space.", "")
  local focused_workspace = env.FOCUSED_WORKSPACE
  local last_workspace = env.PREV_WORKSPACE
  local selected = focused_workspace == workspaceid
  local prevselected = last_workspace == workspaceid

  if selected then
    -- Even if we switch to an empty workspace, display it
    space:set({ drawing = true })
    space_padding:set({ drawing = true })
  end

  -- Only update selection indicators for items that are displayed
  if space:query().geometry.drawing == "on" then
    sbar.animate("tanh", 10, function()
      highlightWorkspace(space, space_bracket, selected, prevselected)
    end)
    if selected then
      -- Make sure apps in bar are up to date when we switch both for this space
      -- and previous. This should catch moves of windows between workspaces.
      setIconsForWorkspace(focused_workspace)
          :thenCall(function() setIconsForWorkspace(last_workspace) end)
    end
  end
end

local function hideAerospaceError()
  if errorMessageItem ~= nil then
    errorMessageItem:set({
      drawing = false,
    })
  end
end

local function initialize()
  errorMessageItem = sbar.add("item", "error", {
    drawing = false,
    updates = "when_shown", -- only listen for aerospace startup if an error is showing
    scroll_texts = true,
    icon = {
      font = { family = settings.font.numbers, size = 16.0 },
      string = icons.error,
      padding_left = 12,
      padding_right = 1,
      color = colors.white,
    },
    label = {
      padding_right = 12,
      color = colors.white,
      font = "sketchybar-app-font:Regular:14.0",
      string = "",
      max_chars = 35,
    },
    padding_right = 2,
    padding_left = 2,
    background = {
      color = colors.red,
      border_width = 1,
      height = 26,
      border_color = colors.black,
    },
  })
  getAllWorkspaces():thenCall(function(workspaces)
    for _, workspace in ipairs(workspaces) do
      local workspaceid = workspace["workspace"]
      local display = workspace["monitor-appkit-nsscreen-screens-id"]
      local space = sbar.add("item", "space." .. workspaceid, {
        drawing = false, -- default to not showing the space -- we'll show if it has windows or is activated
        updates = true,  -- even if hidden, get events
        display = display,
        icon = {
          font = { family = settings.font.numbers, size = 12.0 },
          string = workspaceid,
          padding_left = 12,
          padding_right = 6,
          color = colors.white,
          highlight_color = colors.red,
        },
        label = {
          padding_right = 12,
          color = colors.grey,
          highlight_color = colors.white,
          font = "sketchybar-app-font:Regular:14.0",
          y_offset = -1,
        },
        padding_right = 1,
        padding_left = 1,
        background = {
          color = colors.bg1,
          border_width = 1,
          height = 26,
          border_color = colors.black,
        },
        click_script = "aerospace workspace " .. workspaceid,
        popup = { background = { border_width = 5, border_color = colors.black } }
      })

      spaces[workspaceid] = space


      -- Single item bracket for space items to achieve double border on highlight
      local space_bracket = sbar.add("bracket", "bracket." .. workspaceid, { space.name }, {
        display = display,
        background = {
          color = colors.transparent,
          border_color = colors.bg2,
          height = 28,
          border_width = 2
        }
      })
      brackets[workspaceid] = space_bracket

      -- Padding space
      local padding = sbar.add("space", "space.padding." .. space.name, {
        drawing = false,
        display = display,
        script = "",
        width = settings.group_paddings,
      })
      space_paddings[workspaceid] = padding

      sbar.add("item", {
        position = "popup." .. space.name,
        display = display,
        padding_left = 5,
        padding_right = 0,
        background = {
          drawing = true,
          image = {
            corner_radius = 9,
            scale = 0.2
          }
        }
      })

      space:subscribe("aerospace_workspace_change", function(env)
        onActiveWorkspaceChange(env, space, space_bracket, padding)
      end)

      -- Add any icons
      setIconsForWorkspace(workspaceid)
    end
  end):thenCall(function()
    -- this chain makes sure we get async things in the right order
    local space_window_observer = sbar.add("item", {
      drawing = false,
      updates = true,
    })

    local spaces_indicator = sbar.add("item", {
      padding_left = -3,
      padding_right = 0,
      icon = {
        padding_left = 8,
        padding_right = 9,
        color = colors.grey,
        string = icons.switch.on,
      },
      label = {
        width = 0,
        padding_left = 0,
        padding_right = 8,
        string = "Spaces",
        color = colors.bg1,
      },
      background = {
        color = colors.with_alpha(colors.grey, 0.0),
        border_color = colors.with_alpha(colors.bg1, 0.0),
      }
    })

    -- space_windows_change triggers when a window is created or destroyed
    -- unfortunately, we don't know enough to know what was added or deleted
    -- so we have to go through all non-empty workspaces
    space_window_observer:subscribe("space_windows_change", function(env)
      print("window added or removed")
      -- we want to optimize by refreshing the currently visible spaces first,
      -- then worry about the rest of the non-empty spaces
      local focused = {}
      getVisibleWorkspaces()
          :thenCall(function(workspaces)
            for _, workspace in ipairs(workspaces) do
              local workspaceid = workspace["workspace"]
              local display = workspace["monitor-appkit-nsscreen-screens-id"]
              print("refreshing windows for " .. workspaceid)
              local space = spaces[workspaceid]
              space:set({ display = display })
              setIconsForWorkspace(workspaceid)
              focused[workspaceid] = true
            end
          end)
          :thenCall(function()
            getNonEmptyWorkspaces():thenCall(function(workspaces)
              for _, workspace in ipairs(workspaces) do
                local workspaceid = workspace["workspace"]
                local display = workspace["monitor-appkit-nsscreen-screens-id"]
                if focused[workspaceid] == nil then
                  print("refreshing windows for " .. workspaceid)
                  local space = spaces[workspaceid]
                  space:set({ display = display })
                  setIconsForWorkspace(workspaceid)
                end
              end
            end)
          end)
    end)
    space_window_observer:subscribe("front_app_switched", function(env)
      -- This is sort of a gratuitous call to make sure aerospace is still running any time we change apps
      -- just highlight all the visible workspaces
      highlightVisibleWorkspaces()
    end)

    -- only displayed and updated whebn there's already been an error
    errorMessageItem:subscribe("aerospace_started", function(env)
      hideAerospaceError()
      showNonEmptyWorkspaces()
    end)

    spaces_indicator:subscribe("swap_menus_and_spaces", function(env)
      local currently_on = spaces_indicator:query().icon.value == icons.switch.on
      spaces_indicator:set({
        icon = currently_on and icons.switch.off or icons.switch.on
      })
      -- TODO: ditch this hack and implement the menus stuff better so all workspaces aren't made visible
      delay(1):thenCall(hideEmptyWorkspaces)
    end)

    spaces_indicator:subscribe("mouse.entered", function(env)
      sbar.animate("tanh", 30, function()
        spaces_indicator:set({
          background = {
            color = { alpha = 1.0 },
            border_color = { alpha = 1.0 },
          },
          icon = { color = colors.bg1 },
          label = { width = "dynamic" }
        })
      end)
    end)

    spaces_indicator:subscribe("mouse.exited", function(env)
      sbar.animate("tanh", 30, function()
        spaces_indicator:set({
          background = {
            color = { alpha = 0.0 },
            border_color = { alpha = 0.0 },
          },
          icon = { color = colors.grey },
          label = { width = 0, }
        })
      end)
    end)

    spaces_indicator:subscribe("mouse.clicked", function(_)
      sbar.trigger("swap_menus_and_spaces")
    end)
  end):thenCall(function()
    -- last phase of startup -- make sure we highlight visible spaces
    return highlightVisibleWorkspaces()
  end)
end

local function dump(o)
  if type(o) == 'table' then
    local s = '{ '
    for k, v in pairs(o) do
      if type(k) ~= 'number' then k = '"' .. k .. '"' end
      s = s .. '[' .. k .. '] = ' .. dump(v) .. ','
    end
    return s .. '} '
  else
    return tostring(o)
  end
end

initialize()
