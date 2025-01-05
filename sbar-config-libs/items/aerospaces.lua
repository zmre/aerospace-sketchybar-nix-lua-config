local colors = require("sbar-config-libs/colors")
local icons = require("sbar-config-libs/icons")
local settings = require("sbar-config-libs/settings")
local app_icons = require("sbar-config-libs/helpers.app_icons")
local Promise = require 'promise'

-- TODO: maybe refactor so the bar on each screen is filtered to the apps and workspaces of that screen
--       OR, they all get everything, but active space highlights indicate current space differently on each screen?
-- TODO  on errors, we want to clear the aerospace stuff and just put an alert about the problem
--       but then also need a way to detect when aerospace is running again...

local spaces = {}
local brackets = {}
local space_paddings = {}
local errorMessageItem = nil

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
    time = os.time()
    newtime = time + seconds
    while (time < newtime) do
      time = os.time()
    end
    resolve()
  end)
end

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
  return sbarExecPromise("aerospace list-workspaces --monitor all --empty --json")
end

local function getNonEmptyWorkspaces()
  return sbarExecPromise("aerospace list-workspaces --monitor all --empty no --json")
end

local function showNonEmptyWorkspaces()
  return getNonEmptyWorkspaces():thenCall(function(workspaces)
    for _, workspace in ipairs(workspaces) do
      local workspaceid = workspace["workspace"]
      spaces[workspaceid]:set({ drawing = true })
      space_paddings[workspaceid]:set({ drawing = true })
    end
  end)
end

local function hideEmptyWorkspaces()
  return getEmptyWorkspaces():thenCall(function(workspaces)
    for _, workspace in ipairs(workspaces) do
      local workspaceid = workspace["workspace"]
      spaces[workspaceid]:set({ drawing = false })
      space_paddings[workspaceid]:set({ drawing = false })
    end
  end)
end

local function highlightVisibleWorkspaces()
  return getVisibleWorkspaces():thenCall(function(workspaces)
    for _, workspace in ipairs(workspaces) do
      local workspaceid = workspace["workspace"]
      local space = spaces[workspaceid]
      local space_bracket = brackets[workspaceid]
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

function onAerospaceError(reason)
  print("Got error trying to run aerospace command: " .. dump(reason))
  -- This finds everything with a name of "space.*" and hides it
  sbar.set("/space\\..*/", { drawing = false })
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

function hideAerospaceError()
  errorMessageItem:set({
    drawing = false,
  })
end

function highlightWorkspace(space, space_bracket, selected, prevselected)
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

function initialize()
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
      local space = sbar.add("item", "space." .. workspaceid, {
        drawing = false, -- default to not showing the space -- we'll show if it has windows or is activated
        updates = true,  -- even if hidden, get events
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
        script = "",
        width = settings.group_paddings,
      })
      space_paddings[workspaceid] = padding

      sbar.add("item", {
        position = "popup." .. space.name,
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
  end, function(reason)
    print("I dunno, some kind of error")
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
      -- then the rest of the non-empty spaces
      local focused = {}
      getVisibleWorkspaces()
          :thenCall(function(workspaces)
            for _, workspace in ipairs(workspaces) do
              local workspaceid = workspace["workspace"]
              print("refreshing windows for " .. workspaceid)
              setIconsForWorkspace(workspaceid)
              focused[workspaceid] = true
            end
          end)
          :thenCall(function()
            getNonEmptyWorkspaces():thenCall(function(workspaces)
              for _, workspace in ipairs(workspaces) do
                local workspaceid = workspace["workspace"]
                if focused[workspaceid] == nil then
                  print("refreshing windows for " .. workspaceid)
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

    spaces_indicator:subscribe("mouse.clicked", function(env)
      sbar.trigger("swap_menus_and_spaces")
    end)
  end):thenCall(function()
    -- last phase of startup -- make sure we highlight visible spaces
    return highlightVisibleWorkspaces()
  end)
end

function dump(o)
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
