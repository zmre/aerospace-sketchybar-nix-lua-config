local colors = require("sbar-config-libs/colors")
local icons = require("sbar-config-libs/icons")
local settings = require("sbar-config-libs/settings")
local app_icons = require("sbar-config-libs/helpers.app_icons")
local Promise = require 'promise'

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

-- The behavior I want is this:
--    I have far more workspaces than I'm typically using.  Certain things like email pinned to letter workspaces.
--    Current project-type things (word docs, presentations, whatever) are sent to the numbers typically.
--
--    Sketchybar should only show the workspaces that have apps on them or visible workspaces (up on a monitor) even
--    if there's no app.
--
--    Each monitor should only show the workspaces that are on that monitor.
--
--    The "highlight" effect (currently red text and with a white border) should apply to each visible (active) workspace
--    on each monitor
--
--    On change of workspace, the new workspace should immediately get highlighted and old workspace unhighlighted.
--    But there are complications since aerospace doesn't provide info about active or not active workspaces in its trigger.
--    So what we want to do is to make a quick change, then update our state and fix up any issues, which can be a slightly delayed
--    action since commands have to be run and output parsed.
--
--    We want to be efficient with our events, but we don't want to miss events, therefore we might get an app change event
--    at the same time as a workspace change event and both of those might trigger state updates.  Or we might have a user
--    quickly bouncing between applications, which would produce a rush of state updates.  So we're going to implement
--    a poor man's lock -- if state is being updated when something else wants to update state, ignore the second request,
--    but we need to error out of promises so bad state doesn't get saved in this case.  If we have an issue with the state
--    snapshot being slow and getting out of date, we'll need to have a flag to trigger a re-run when the state update finishes,
--    but hopefully that won't be necessary.
--
--    When the toggle for showing menus is hit, we hide all the non-active workspaces, but still show the current workspace
--    on each monitor.
--
--    We do an instant update on workspace change, but for other events (like new window)

-- TODO  Moving a workspace to a different screen doesn't trigger any sort of update right now. Maybe the events above?
-- TODO  the sketchybar-app-fonts are great for many apps, but I keep finding ones that are missing (eg, Photos, Ghostty, etc)
--       so is there a way for me to use icons from elsewhere if the repo doesn't support something?  Or do I need a fork
--       and to make my own icons?  I've seen PRs that are languishing and will need to see if that continues.
-- TODO: When disconnecting from external monitors and then waking from sleep, sketchybar flashes and changes and flashes and changes quite a bit.
--       At the same time, aerospace is jumping things around, which may be part of it, but I suspect multiple different events are triggering
--       refreshes.  Perhaps each monitor removal (I have 3 external) is its own event, for example.
--       How can I avoid the flickering and ideally avoid unnecessary work?  I almost need a debounce or something or a way to update the stored state
--       and compare it to the displayed state.  Or really to see if any changes are needed to the stored state and only go through display updates
--       when there are changes.  So maybe two phases: phase 1 is update state, phase 2 executes if changes were made to state and updates display items.
-- TODO: When I go to macos full screen, it uses Mac spaces. But I've disabled keys and swipes for getting into/out of those spaces
--       which means I can't navigate to those windows. If the app has only one window that's full screen, cmd-tab works, but if
--       this is Preview, for example, and one PDF is full screen and another isn't, I might have a hard time getting to the full
--       screen one.
--       Should I disable full screen app options outside of what aerospace does?  Or bring back a way to access them?

local spaces = {}
local brackets = {}
local space_paddings = {}
local errorMessageItem = nil

local state = {
  workspaces = {},
  menubar_on = false,
  updating = false,
}

local function syncBarToGlobalState()
  -- Open question: is there any reason to first check values and only update if they are different?
  -- or is there a way to batch changes?  Maybe animate does this already?
  sbar.animate("tanh", 10, function()
    for workspaceid, workspacestate in pairs(state.workspaces) do
      if (not state.menubar_on and not workspacestate["empty"]) or workspacestate["active"] then
        -- These should be visible
        spaces[workspaceid]:set({
          drawing = true,
          display = workspacestate["monitor"],
          label = {
            string = workspacestate["appicons"],
            highlight = workspacestate["active"],
          },
          icon = {
            highlight = workspacestate["active"],
          },
          background = { border_color = workspacestate["active"] and colors.black or colors.bg2 }
        })
        space_paddings[workspaceid]:set({ drawing = true })
        brackets[workspaceid]:set({
          drawing = true,
          background = { border_color = workspacestate["active"] and colors.grey or colors.bg2 }
        })
      else
        -- These should be hidden
        spaces[workspaceid]:set({
          drawing = false,
          display = workspacestate["monitor"],
          label = workspacestate["appicons"],
        })
        space_paddings[workspaceid]:set({ drawing = false })
        brackets[workspaceid]:set({ drawing = false })
      end
    end
  end)
end

local function onAerospaceError(reason)
  print("Got error trying to run aerospace command: " .. (reason and dump(reason) or "unknown"))

  state.updating = false

  if errorMessageItem ~= nil then
    -- Manual set of error string on error menu item
    errorMessageItem:set({
      drawing = true,
      label = {
        string = reason and dump(reason) or "aerospace not running",
      }
    })
  end

  for _, workspacestate in pairs(state.workspaces) do
    workspacestate["active"] = false
    workspacestate["empty"] = true
  end
  syncBarToGlobalState()
end

-- Function below is an awful hack, but the aerospace monitor ids and the sketchybar monitorids don't line up
-- They both seem to get the primary monitor as 1 if you use aerospace's alternate monitor-appkit-nsscreen-screens-id
-- field, which means in a dual monitor setup they'll pretty much always work out right. But in a three monitor setup,
-- they diverge -- or they can diverge.  They do for me.  So I've hard coded monitor names and values
-- as an ugly hack.
-- See: https://github.com/nikitabobko/AeroSpace/issues/336 which is closed/resolved but compatibility is still awful
local function getSketchyMonitorIdFrom(objWithMonitorInfo)
  if objWithMonitorInfo["monitor-name"] then
    if objWithMonitorInfo["monitor-name"] == "LG Ultra HD" then
      return "2"
    elseif objWithMonitorInfo["monitor-name"] == "RODE_RCV" then
      return "3"
    end
  end
  if objWithMonitorInfo["monitor-appkit-nsscreen-screens-id"] then
    return objWithMonitorInfo["monitor-appkit-nsscreen-screens-id"]
  end
  return objWithMonitorInfo["monitor-id"]
end

local function sbarExecPromise(cmd)
  return Promise.new(function(resolve, failfunc)
    sbar.exec(cmd, function(result, exit_code)
      if exit_code ~= 0 then
        if failfunc ~= nil then
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

local function getAllWorkspaces()
  return sbarExecPromise(
    "aerospace list-workspaces --all --format '%{workspace}%{monitor-appkit-nsscreen-screens-id}%{monitor-id}%{monitor-name}' --json")
end

local function getAllWindows()
  return sbarExecPromise(
    "aerospace list-windows --all --format '%{app-name}%{window-title}%{workspace}%{monitor-id}%{monitor-appkit-nsscreen-screens-id}%{monitor-name}' --json"
  )
end

local function getVisibleWorkspaces()
  return sbarExecPromise(
    "aerospace list-workspaces --visible --monitor all --format '%{workspace}%{monitor-appkit-nsscreen-screens-id}%{monitor-id}%{monitor-name}' --json")
end

local function getCurrentState()
  local newstate = {
    workspaces = {},
  }

  for workspaceid, space in pairs(spaces) do
    -- assume not visible and empty and we'll update
    newstate.workspaces[workspaceid] = {
      monitor = 0,
      active = false,
      empty = true,
      apps = {},
      appicons = ''
    }
  end

  local visiblePromise = getVisibleWorkspaces()
  local allPromise = getAllWorkspaces()
  local appsPromise = getAllWindows()

  return Promise.all({ visiblePromise, allPromise, appsPromise }):thenCall(function(values)
    local visible, all, apps = values[1], values[2], values[3]
    -- Assign workspaces to monitors
    for _, workspace in ipairs(all) do
      local workspaceid = workspace["workspace"]
      newstate.workspaces[workspaceid]["monitor"] = getSketchyMonitorIdFrom(workspace)
    end

    -- Make sure visible workspaces are marked as active
    for _, workspace in ipairs(visible) do
      local workspaceid = workspace["workspace"]
      newstate.workspaces[workspaceid]["active"] = true
    end

    -- figure out what apps are where and set "empty" flag appropriately
    for _, window in ipairs(apps) do
      local workspaceid = window["workspace"]
      local appname = window["app-name"]
      newstate.workspaces[workspaceid]["apps"][appname] = true
      newstate.workspaces[workspaceid]["empty"] = false
    end

    -- lookup icons for each app looping through all workspaces
    for workspaceid, workspacestate in pairs(newstate.workspaces) do
      -- Lua is awful; we just want a sorted list of app names for the windows on this workspace
      -- so we can build up a decent icon line
      -- also, we only want to do this if num entries in workspacestate["apps"] > 0
      -- but #workspacestate["apps"] only counts items indexed with a number
      -- which is so stupid I could spit
      -- https://stackoverflow.com/questions/2705793/how-to-get-number-of-entries-in-a-lua-table
      local appkeys = {}
      for app in pairs(workspacestate["apps"]) do
        table.insert(appkeys, app)
      end
      table.sort(appkeys) -- okay, sorted and unique list to minimize updates to the screen
      if #appkeys > 0 then
        for _, app in ipairs(appkeys) do
          local lookup = app_icons[app]
          local icon = ((lookup == nil) and app_icons["Default"] or lookup)
          workspacestate["appicons"] = workspacestate["appicons"] .. " " .. icon
        end
      else
        workspacestate["appicons"] = " —"
      end
    end
    return newstate
  end)
end

local function updateCurrentState()
  if not state.updating then
    state.updating = true
    return getCurrentState():thenCall(function(newstate)
      -- IMPROVEMENT: maybe calculate diffs for a partial update in-place in existing global? Not sure on memory
      --              implications of the current approach though it should be more atomic-ish
      state.workspaces = newstate.workspaces
      state.updating = false
    end)
  end
  return Promise.reject('State is already updating')
end

local function updateCurrentStateAndSync()
  return updateCurrentState():thenCall(syncBarToGlobalState)
end


local function highlightWorkspace(space, space_padding, space_bracket, selected)
  space:set({
    drawing = true, -- if we go to a space, make it visible
    icon = { highlight = selected },
    label = { highlight = selected },
    background = { border_color = selected and colors.black or colors.bg2 }
  })
  space_padding:set({
    drawing = true,
  })
  space_bracket:set({
    background = { border_color = selected and colors.grey or colors.bg2 }
  })
end


local function onActiveWorkspaceChange(env)
  local focused_workspace = env.FOCUSED_WORKSPACE
  local last_workspace = env.PREV_WORKSPACE
  print("aerospace_workspace_change from " .. last_workspace .. " to " .. focused_workspace)

  local space = spaces[focused_workspace]
  local space_bracket = brackets[focused_workspace]
  local space_padding = space_paddings[focused_workspace]

  local prev_space = spaces[last_workspace]
  local prev_space_bracket = brackets[last_workspace]
  local prev_space_padding = space_paddings[last_workspace]

  sbar.animate("tanh", 10, function()
    -- highlight the newly focused workspace
    highlightWorkspace(space, space_padding, space_bracket, true)
    -- if the new workspace is on the same monitor, unhighlight the previous one
    if state.workspaces[last_workspace]["monitor"] == state.workspaces[focused_workspace]["monitor"] then
      highlightWorkspace(prev_space, prev_space_padding, prev_space_bracket, false)
    end
  end)

  updateCurrentStateAndSync()
end

local function hideAerospaceError()
  if errorMessageItem ~= nil then
    errorMessageItem:set({
      drawing = false,
    })
  end
  updateCurrentStateAndSync()
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
      local display = getSketchyMonitorIdFrom(workspace)
      local space = sbar.add("item", "space." .. workspaceid, {
        drawing = false, -- default to not showing the space -- we'll show if it has windows or is activated
        updates = "when_shown",
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
      })

      spaces[workspaceid] = space


      -- Single item bracket for space items to achieve double border on highlight
      local space_bracket = sbar.add("bracket", "bracket." .. workspaceid, { space.name }, {
        display = display,
        updates = "when_shown",
        background = {
          color = colors.transparent,
          border_color = colors.bg2,
          height = 28,
          border_width = 2
        }
      })
      brackets[workspaceid] = space_bracket

      space:subscribe("mouse.entered", function(env)
        sbar.animate("tanh", 10, function()
          space_bracket:set({
            background = { border_color = colors.grey }
          })
        end)
      end)

      space:subscribe("mouse.exited", function(env)
        sbar.animate("tanh", 10, function()
          space_bracket:set({
            background = { border_color = colors.bg2 }
          })
        end)
      end)

      -- Padding space
      local padding = sbar.add("space", "space.padding." .. space.name, {
        drawing = false,
        updates = "when_shown",
        display = display,
        script = "",
        width = settings.group_paddings,
      })
      space_paddings[workspaceid] = padding
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

    space_window_observer:subscribe("aerospace_workspace_change", onActiveWorkspaceChange)

    -- space_windows_change triggers when a window is created or destroyed
    -- unfortunately, we don't know enough to know what was added or deleted
    -- so we have to go through all non-empty workspaces
    space_window_observer:subscribe("space_windows_change", updateCurrentStateAndSync)

    -- This is sort of a gratuitous call to make sure aerospace is still running any time we change apps
    -- just highlight all the visible workspaces
    space_window_observer:subscribe("front_app_switched", updateCurrentStateAndSync)

    -- only displayed and updated when there's already been an error
    errorMessageItem:subscribe("aerospace_started", function(env)
      hideAerospaceError()
      updateCurrentStateAndSync()
    end)

    spaces_indicator:subscribe("swap_menus_and_spaces", function(env)
      local currently_on = spaces_indicator:query().icon.value == icons.switch.on
      spaces_indicator:set({
        icon = currently_on and icons.switch.off or icons.switch.on
      })
      state.menubar_on = currently_on

      sbar.animate("tanh", 10, function()
        for workspaceid, space in pairs(spaces) do
          local vis = (not currently_on and not state.workspaces[workspaceid].empty) or
              state.workspaces[workspaceid].active
          space:set({ drawing = vis })
          space_paddings[workspaceid]:set({ drawing = vis })
          brackets[workspaceid]:set({ drawing = vis })
        end
      end)
    end)

    spaces_indicator:subscribe("mouse.entered", function(env)
      sbar.animate("tanh", 10, function()
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
      sbar.animate("tanh", 10, function()
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
  end):thenCall(updateCurrentStateAndSync)
end

initialize()
