local colors = require("sbar-config-libs/colors")
local icons = require("sbar-config-libs/icons")
local settings = require("sbar-config-libs/settings")
local app_icons = require("sbar-config-libs/helpers.app_icons")
local Promise = require 'promise'

local function dump(o, seen)
  if type(o) == 'table' then
    seen = seen or {}
    if seen[o] then
      return '<cycle>'
    end
    seen[o] = true
    local s = '{ '
    for k, v in pairs(o) do
      local key = type(k) ~= 'number' and ('"' .. k .. '"') or k
      s = s .. '[' .. key .. '] = ' .. dump(v, seen) .. ','
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

local spaces = {}
local brackets = {}
local space_paddings = {}
local errorMessageItem = nil

local state = {
  workspaces = {},
  menubar_on = false,
  updating = nil, -- os.time() while an update holds the lock; nil when free
  update_pending = false,
  bar_dirty = false, -- a quick highlight painted outside of state; force next repaint
  sticky_windows = {},
  focused_workspace = nil, -- unknown until fetched at startup or set by a workspace change event
}

local sticky_window_titles = {
  ["Picture-in-picture"] = true,
  ["Picture-in-Picture"] = true,
  ["Picture in Picture"] = true,
  ["Picture in picture"] = true,
  ["MiniPlayer"] = true, -- Music's mini player
}

-- Creates the bar items (space + bracket + padding) and mouse handlers for
-- one workspace.  Called at init for every known workspace and again from
-- syncBarToGlobalState when a workspace appears after startup.
-- Caveat: items created post-startup append at the end of the bar's left
-- section rather than in sorted order.
local function createWorkspaceItem(workspaceid, display)
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
    click_script = "aerospace workspace '" .. workspaceid .. "'",
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
    -- restore the active highlight on the focused workspace instead of
    -- unconditionally clearing the border
    local ws = state.workspaces[workspaceid]
    local border = (ws and ws["active"]) and colors.grey or colors.bg2
    sbar.animate("tanh", 10, function()
      space_bracket:set({
        background = { border_color = border }
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

  return space
end

local function paintBarFromState()
  for workspaceid, workspacestate in pairs(state.workspaces) do
    local visible = (not state.menubar_on and not workspacestate["empty"]) or workspacestate["active"]
    if spaces[workspaceid] == nil and visible then
      -- workspace appeared after init; create its bar items on the fly
      createWorkspaceItem(workspaceid, workspacestate["monitor"])
    end
    if spaces[workspaceid] == nil then
      -- hidden workspace with no bar item; nothing to draw
    elseif visible then
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
end

-- Pass animated = false to snap instead of tween.  Callers batch either way:
-- sbar.animate opens its own transaction, and every other path into here runs
-- inside an exec or delay callback, both of which SbarLua already wraps in one.
local function syncBarToGlobalState(animated)
  if animated == false then
    paintBarFromState()
  else
    sbar.animate("tanh", 10, paintBarFromState)
  end
end

local function onAerospaceError(reason)
  print("Got error trying to run aerospace command: " .. (reason and dump(reason) or "unknown"))

  -- NOTE: do not touch state.updating here.  This runs for failures of any
  -- aerospace command, including ones outside the state-update chain, and an
  -- early release would let a second update overlap the one still in flight.
  -- The lock is released only by updateCurrentState (success or catch), or by
  -- updateLockIsHeld once the outstanding exec child is known to be dead.

  if errorMessageItem ~= nil then
    -- Manual set of error string on error menu item
    errorMessageItem:set({
      drawing = true,
      label = {
        string = "aerospace errors",
      }
    })
  end

  for _, workspacestate in pairs(state.workspaces) do
    workspacestate["active"] = false
    workspacestate["empty"] = true
  end
  syncBarToGlobalState()
end

-- Current monitor arrangement, as sketchybar sees it.
--
-- An item's `display = N` is stored as the bitmask `1 << N` and matched against
-- each bar's arrangement id (SketchyBar bar_item.c:1172, bar.c:11), and those
-- arrangement ids come straight from `display_arrangement` (bar_manager.c:593,
-- 615).  So `display =` means "arrangement position", which renumbers whenever
-- a monitor is added, removed, or dragged around in System Settings.  Nothing
-- about it is stable across a dock event.
--
-- signature stays nil until the first successful query; until then we have no
-- idea what exists and validation is skipped rather than guessed at.
local displays = {
  valid_ids = {},
  signature = nil,
}

-- sbar.query is a synchronous mach roundtrip that does not fork and does not
-- touch aerospace, so unlike every other probe in this file it still answers
-- while aerospace is wedged mid-relayout.  That is exactly what we need to key
-- display handling off of.  It is also safe to call during config load: query
-- notices an open transaction, commits it, sends, and reopens it
-- (SbarLua sketchybar.c:392-396).
local function readDisplays()
  local ok, result = pcall(sbar.query, "displays")
  if not ok or type(result) ~= "table" then
    -- The failure mode here is not an exception: when sketchybar doesn't answer
    -- in time, SbarLua leaves the argument on the stack and we get the string
    -- "displays" back instead of a table.  Its receive timeout is 1s, so this
    -- means sketchybar's main thread is busy -- which during a dock event means
    -- it is mid bar-destroy-and-recreate.  Treat it as "ask again shortly",
    -- never as "nothing changed".
    return nil
  end
  local valid_ids = {}
  local parts = {}
  for _, display in ipairs(result) do
    local id = tonumber(display["arrangement-id"])
    if id then
      valid_ids[id] = true
      -- key the signature on UUID, not arrangement id or count: swapping one
      -- monitor for another keeps the count identical but is still a change
      parts[#parts + 1] = id .. ":" .. tostring(display["UUID"])
    end
  end
  if #parts == 0 then
    return nil
  end
  return { valid_ids = valid_ids, signature = table.concat(parts, ",") }
end

-- Returns "changed", "unchanged", or "failed".  These have to stay distinct:
-- collapsing "failed" into "unchanged" is what made an unplug take ~15s to
-- settle, because the first probe landed while sketchybar was too busy to
-- answer and the retry never happened.
local function refreshDisplays()
  local current = readDisplays()
  if current == nil then
    return "failed"
  end
  local changed = displays.signature ~= nil and displays.signature ~= current.signature
  displays.valid_ids = current.valid_ids
  displays.signature = current.signature
  return changed and "changed" or "unchanged"
end

-- aerospace monitor ids and sketchybar display ids are different numbering
-- schemes and have historically disagreed (AeroSpace issue #336).  Measured on
-- this hardware under aerospace 0.21.3, `monitor-appkit-nsscreen-screens-id`
-- now matches sketchybar's arrangement id exactly on all three monitors, which
-- is what upstream recommends -- so that field is the primary source and
-- settings.monitor_name_to_sketchybar_id exists only as an escape hatch if
-- they ever drift apart again.
local function getSketchyMonitorIdFrom(objWithMonitorInfo)
  local mapped = settings.monitor_name_to_sketchybar_id[objWithMonitorInfo["monitor-name"] or ""]
  local id = tonumber(mapped)
      or tonumber(objWithMonitorInfo["monitor-appkit-nsscreen-screens-id"])
      or tonumber(objWithMonitorInfo["monitor-id"])
      or 1
  -- Unplugging renumbers everything, and aerospace will happily keep reporting
  -- a workspace on a monitor sketchybar no longer has.  An item assigned to a
  -- display that doesn't exist is silently never drawn, so land it on the main
  -- display instead of dropping the workspace off the bar entirely.
  if displays.signature ~= nil and not displays.valid_ids[id] then
    return 1
  end
  return id
end

local function sbarExecPromise(cmd)
  return Promise.new(function(resolve, failfunc)
    sbar.exec(cmd, function(result, exit_code)
      if exit_code ~= 0 then
        failfunc(string.format("Exit Code: %s Message: %s", tostring(exit_code), dump(result)))
      else
        resolve(result)
      end
    end)
  end)
end

local WORKSPACE_FORMAT = "%{workspace}%{monitor-appkit-nsscreen-screens-id}%{monitor-id}%{monitor-name}"
local WINDOW_FORMAT =
"%{window-id}%{app-name}%{window-title}%{workspace}%{monitor-id}%{monitor-appkit-nsscreen-screens-id}%{monitor-name}"

local function getAllWorkspaces()
  return sbarExecPromise("aerospace list-workspaces --all --format '" .. WORKSPACE_FORMAT .. "' --json")
end

local function getFocusedWorkspace()
  return sbarExecPromise("aerospace list-workspaces --focused --format '%{workspace}' --json")
end

-- One fork instead of three.  sbar.exec forks the whole lua process and then
-- popen()s a shell on top of that, so fetching visible/all/windows as three
-- separate promises cost six processes per update.  During a dock event those
-- pile up against an aerospace daemon that is single threaded and already
-- blocked re-laying-out every window, and the pile is what turns a display
-- change into a multi-minute stall.
--
-- The three documents are wrapped into one JSON array because SbarLua runs the
-- command output through cJSON and only hands us a lua table if the whole
-- response parses; there is no JSON decoder available on this side to stitch
-- delimited blobs back together.  `set -e` makes a failure in any one query
-- fail the command as a whole, which lands on the promise's reject path just
-- like a single failed exec did before.
local function getAerospaceSnapshot()
  return sbarExecPromise(table.concat({
    "set -e",
    "visible=$(aerospace list-workspaces --visible --monitor all --format '" .. WORKSPACE_FORMAT .. "' --json)",
    "all=$(aerospace list-workspaces --all --format '" .. WORKSPACE_FORMAT .. "' --json)",
    "windows=$(aerospace list-windows --all --format '" .. WINDOW_FORMAT .. "' --json)",
    "printf '[%s,%s,%s]' \"$visible\" \"$all\" \"$windows\"",
  }, "; "))
end

local function sendWindowToWorkspace(window_id, workspace_id)
  -- Window ids can go stale at any moment (aerospace intermittently loses
  -- track of Picture-in-Picture windows), so a failed move is routine here --
  -- log it rather than treating it like aerospace is down.
  return Promise.new(function(resolve, _)
    sbar.exec("aerospace move-node-to-workspace --window-id \"" .. window_id .. "\" \"" .. workspace_id .. "\"",
      function(result, exit_code)
        if exit_code ~= 0 then
          print("Failed to move window " .. tostring(window_id) .. " to workspace " .. tostring(workspace_id) ..
            ": " .. dump(result))
        end
        resolve(result)
      end)
  end)
end

-- Workspaces can show up that we didn't know about at init time (created after
-- startup, or a window reporting a workspace we've never seen).  We must never
-- index them blindly: a single error inside the state update promise chain
-- would leave the `updating` lock held forever and silently kill all updates.
local function ensureWorkspace(workspaces, workspaceid)
  if workspaces[workspaceid] == nil then
    workspaces[workspaceid] = {
      monitor = 0,
      active = false,
      empty = true,
      apps = {},
      appicons = ''
    }
  end
  return workspaces[workspaceid]
end

local function getCurrentState()
  local newstate = {
    workspaces = {},
    sticky_windows = {},
  }

  for workspaceid in pairs(spaces) do
    -- assume not visible and empty and we'll update
    ensureWorkspace(newstate.workspaces, workspaceid)
  end

  return getAerospaceSnapshot():thenCall(function(values)
    -- A non-table here means the combined output did not parse as JSON, so
    -- SbarLua handed back the raw string instead.  Fail loudly rather than
    -- letting ipairs() blow up somewhere less obvious.
    if type(values) ~= "table" or values[1] == nil then
      error("aerospace snapshot did not parse as JSON: " .. dump(values))
    end
    local visible, all, apps = values[1], values[2], values[3]
    -- Assign workspaces to monitors
    for _, workspace in ipairs(all) do
      ensureWorkspace(newstate.workspaces, workspace["workspace"])["monitor"] = getSketchyMonitorIdFrom(workspace)
    end

    -- Make sure visible workspaces are marked as active
    for _, workspace in ipairs(visible) do
      ensureWorkspace(newstate.workspaces, workspace["workspace"])["active"] = true
    end

    -- figure out what apps are where and set "empty" flag appropriately
    for _, window in ipairs(apps) do
      local workspacestate = ensureWorkspace(newstate.workspaces, window["workspace"])
      workspacestate["apps"][window["app-name"]] = true
      workspacestate["empty"] = false
      -- now handle sticky window state
      if sticky_window_titles[window["window-title"]] then
        table.insert(newstate.sticky_windows, window)
      end
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

-- The updating lock is a timestamp so it can't leak forever: if aerospace
-- hangs and an exec callback never fires, the lock would otherwise stay held
-- and every future update would be silently dropped until restart.
--
-- The timeout has to sit *past* SbarLua's own limit.  SbarLua arms alarm(60)
-- in every forked exec child, so a slow `aerospace` call either reports back
-- within 60s or is killed and never reports at all.  This used to be 15s,
-- which meant that while aerospace was wedged we released the lock and
-- launched a fresh batch of queries every 15s alongside children that were
-- still alive and still queued against the same single-threaded daemon --
-- four overlapping batches deep by the time the first one timed out.  That
-- snowball, not the display change itself, is what made docking take minutes.
-- At 75s there is only ever one batch in flight, and the release only happens
-- once the outstanding child is known to be dead.
local UPDATE_LOCK_TIMEOUT = 75 -- seconds; must exceed SbarLua's alarm(60)

local function updateLockIsHeld()
  if not state.updating then
    return false
  end
  if os.time() - state.updating > UPDATE_LOCK_TIMEOUT then
    print("Warning: state update lock held > " .. UPDATE_LOCK_TIMEOUT .. "s; its exec child is dead, releasing")
    return false
  end
  return true
end

-- Compare only the fields syncBarToGlobalState actually paints; when nothing
-- changed the repaint can be skipped (front_app_switched fires on every app
-- switch and usually changes nothing).
local function workspacesEqual(a, b)
  for workspaceid, wa in pairs(a) do
    local wb = b[workspaceid]
    if wb == nil
        or wa["monitor"] ~= wb["monitor"]
        or wa["active"] ~= wb["active"]
        or wa["empty"] ~= wb["empty"]
        or wa["appicons"] ~= wb["appicons"] then
      return false
    end
  end
  for workspaceid in pairs(b) do
    if a[workspaceid] == nil then
      return false
    end
  end
  return true
end

-- resolves with true when the workspace state changed since the last update
local function updateCurrentState()
  -- the caller (updateCurrentStateAndSync) checks the lock before calling
  state.updating = os.time()
  return getCurrentState():thenCall(function(newstate)
    -- IMPROVEMENT: maybe calculate diffs for a partial update in-place in existing global? Not sure on memory
    --              implications of the current approach though it should be more atomic-ish
    local changed = not workspacesEqual(state.workspaces, newstate.workspaces)
    state.workspaces = newstate.workspaces
    state.sticky_windows = newstate.sticky_windows
    state.updating = nil
    return changed
  end):catch(function(reason)
    -- If anything above errored we must release the lock, otherwise every
    -- future update is silently rejected and the bar (and sticky windows)
    -- freeze until restart.
    state.updating = nil
    onAerospaceError(reason)
    error(reason)
  end)
end

-- aerospace intermittently loses track of PiP windows, so a move can fail or
-- silently no-op and leave the window still looking misplaced on the next
-- state read -- which schedules the identical move again.  Each attempt is its
-- own fork, and each one can itself perturb window state, so without a backoff
-- a single untracked PiP window is enough to keep the update loop fed
-- indefinitely.  Remember when we last tried each window and leave it alone
-- for a while after.
local STICKY_RETRY_SECONDS = 10
local sticky_move_attempted_at = {} -- window-id -> os.time() of last attempt

local function moveStickyToCurrentWorkspace()
  if not state.focused_workspace or state.focused_workspace == "" then
    -- we don't know where the user is yet; moving windows would be a guess
    return
  end
  local now = os.time()
  local still_sticky = {}
  for _, window in ipairs(state.sticky_windows) do
    local window_id = window["window-id"]
    still_sticky[window_id] = true
    -- if it's on an active workspace on any monitor, just leave it
    local workspacestate = state.workspaces[window["workspace"]]
    if not (workspacestate and workspacestate["active"]) then
      local last_attempt = sticky_move_attempted_at[window_id]
      local backed_off = last_attempt ~= nil and now - last_attempt < STICKY_RETRY_SECONDS
      if not backed_off then
        sticky_move_attempted_at[window_id] = now
        -- if it isn't on an active workspace, then move it to the current
        -- focused workspace
        sendWindowToWorkspace(window_id, state.focused_workspace)
      end
    end
  end
  -- drop bookkeeping for windows that are gone, so this can't grow forever
  for window_id in pairs(sticky_move_attempted_at) do
    if not still_sticky[window_id] then
      sticky_move_attempted_at[window_id] = nil
    end
  end
end

local function updateCurrentStateAndSync()
  if updateLockIsHeld() then
    -- an update is already in flight and its snapshot may predate the event
    -- that got us here, so ask it to run again when it finishes instead of
    -- dropping this request
    state.update_pending = true
    return Promise.resolve(nil)
  end
  local function runPendingUpdate()
    if state.update_pending then
      state.update_pending = false
      return updateCurrentStateAndSync()
    end
  end
  return updateCurrentState()
      :thenCall(function(changed)
        moveStickyToCurrentWorkspace()
        -- skip the repaint when nothing changed, unless a quick highlight
        -- painted the bar outside of state and it needs to be trued up
        if changed or state.bar_dirty then
          state.bar_dirty = false
          syncBarToGlobalState()
        end
      end)
      -- run any coalesced request on the failure path too, or a rejection
      -- both drops that event and strands the pending flag
      :thenCall(runPendingUpdate, runPendingUpdate)
end

-- Trailing throttle in front of updateCurrentStateAndSync.  A dock event or a
-- burst of window moves fires dozens of triggers in a second and each one used
-- to launch its own snapshot; this collapses them to at most one update per
-- window.  Events that keep arriving keep it running rather than starving it,
-- so this rate-limits without ever going quiet while things are still moving.
--
-- Only one timer is ever in flight -- events during the wait just set the
-- dirty flag and the timer re-arms itself once when it fires.  (Stock SbarLua
-- never calls luaL_unref, which made one-timer-per-event an unbounded leak;
-- flake.nix now patches that, but one timer per burst is still the right
-- shape and keeps us honest if the patch is ever dropped.)
local UPDATE_DEBOUNCE_SECONDS = 0.25
local debounce_armed = false
local debounce_dirty = false
local onDebounceExpired

local function requestStateUpdate()
  if debounce_armed then
    debounce_dirty = true
    return
  end
  debounce_armed = true
  debounce_dirty = false
  sbar.delay(UPDATE_DEBOUNCE_SECONDS, onDebounceExpired)
end

onDebounceExpired = function()
  debounce_armed = false
  updateCurrentStateAndSync()
  if debounce_dirty then
    debounce_dirty = false
    requestStateUpdate()
  end
end

-- Docking is a burst, not an event.  SketchyBar funnels display
-- added/removed/moved/resized into one handler (bar_manager.c:762-768) and
-- macOS emits several of those per physical plug, each one destroying and
-- recreating every bar; upstream acknowledged this and never debounced it
-- (SketchyBar issue #336).  So we wait for the arrangement to go quiet before
-- touching anything, rather than chasing each event.
--
-- Unlike the state throttle above this is a true trailing debounce: we want to
-- act exactly once, after things settle, not at a steady rate during the storm.
--
-- display_change also fires whenever the *active* display changes -- every time
-- the mouse crosses monitors -- so the UUID signature comparison is what keeps
-- normal use from triggering resyncs.  That check is one mach roundtrip and no
-- forks, which is why it's safe to run on such a chatty event.
local DISPLAY_SETTLE_SECONDS = 2.0
-- A failed probe means sketchybar is still churning, so keep asking.  Bounded
-- so a genuinely wedged sketchybar (SketchyBar #776 can stall for minutes)
-- doesn't leave us re-arming timers forever.
local DISPLAY_MAX_RETRIES = 8

-- ...but that full budget is only worth spending when we might be missing a
-- change.  Just after a successful read we are almost certainly seeing echoes:
-- every event sketchybar processes calls bar_manager_poll_active_display
-- (event.c:379-381), which re-fires display_change whenever the active display
-- id differs from the one it last recorded -- and unplugging always changes
-- that, including in response to the mach messages from our own repaint.  Each
-- failed probe blocks lua for ~1s on the mach receive timeout, so grinding
-- through 8 of them burns most of a second-by-second budget right when we want
-- to be responsive again.  Probe once for echoes, don't grind.
local DISPLAY_ECHO_RETRIES = 1
local DISPLAY_ECHO_QUIET_SECONDS = 8
local display_last_read_at = 0
local display_settle_armed = false
local display_settle_dirty = false
local display_retries = 0
local onDisplaySettled

local function onDisplayChange()
  if display_settle_armed then
    display_settle_dirty = true
    return
  end
  display_settle_armed = true
  display_settle_dirty = false
  sbar.delay(DISPLAY_SETTLE_SECONDS, onDisplaySettled)
end

onDisplaySettled = function()
  display_settle_armed = false
  if display_settle_dirty then
    -- events still arriving; wait out another quiet window before acting
    display_settle_dirty = false
    onDisplayChange()
    return
  end

  local status = refreshDisplays()
  if status == "failed" then
    -- Spend the full budget only when we might actually be missing something.
    -- Within a few seconds of a good read this is almost certainly an echo of
    -- the change we already handled, and each probe costs ~1s of blocked lua.
    local echoing = os.time() - display_last_read_at < DISPLAY_ECHO_QUIET_SECONDS
    local budget = echoing and DISPLAY_ECHO_RETRIES or DISPLAY_MAX_RETRIES
    if display_retries < budget then
      display_retries = display_retries + 1
      print("displays not queryable yet, retry " .. display_retries .. "/" .. budget)
      onDisplayChange()
    else
      if not echoing then
        print("gave up re-reading displays after " .. budget .. " attempts")
      end
      display_retries = 0
    end
    return
  end

  display_last_read_at = os.time()
  display_retries = 0
  if status == "unchanged" then
    -- active display moved, but the same monitors are still attached
    return
  end

  print("monitor arrangement changed: " .. tostring(displays.signature))

  -- Paint from cached state right now, before asking aerospace anything.
  --
  -- Measured on a real dock: sketchybar takes ~10s to become queryable again,
  -- and aerospace another ~15s to answer a snapshot, because it is single
  -- threaded and busy re-laying-out every window (AeroSpace #104).  Chaining
  -- those serially is why the bar stayed blank for ~25s.  We don't need
  -- aerospace for this step: a workspace sitting on a monitor that no longer
  -- exists has to move no matter where aerospace eventually says it lives,
  -- since an item on a detached display is silently never drawn.  So re-home
  -- onto the live display set and repaint immediately; the snapshot below
  -- corrects the details once aerospace can answer.
  for _, workspacestate in pairs(state.workspaces) do
    local monitor = tonumber(workspacestate["monitor"])
    if monitor == nil or not displays.valid_ids[monitor] then
      workspacestate["monitor"] = 1
    end
  end
  -- Snap, don't tween.  sketchybar is still finishing its own bar rebuild here
  -- (that's why the probe above can fail), so a 10-frame animation for every
  -- workspace is pure extra work for a renderer that is already behind -- and
  -- nobody sees a smooth transition on a bar that isn't on screen yet.
  syncBarToGlobalState(false)

  -- Display ids may have renumbered even where the workspace state compares
  -- equal, so make sure the follow-up snapshot repaints regardless.
  state.bar_dirty = true
  requestStateUpdate()
end

local function onSystemWoke()
  -- Waking is the one case where the arrangement can change without a clean
  -- display_change: SketchyBar itself notes that "the system wake notification
  -- precedes the display layout changes" and queues a second wake 500ms later
  -- to compensate (bar_manager.c:1026-1038), and docking while the lid is shut
  -- lands entirely inside that gap.  Run the settle path so the arrangement is
  -- re-read either way, and request a state update regardless, since windows
  -- move around while we're asleep whether or not monitors did.
  onDisplayChange()
  requestStateUpdate()
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
    drawing = true, -- show immediately on quick-switch to a hidden workspace
    background = { border_color = selected and colors.grey or colors.bg2 }
  })
end


local function onActiveWorkspaceChange(env)
  local focused_workspace = env.FOCUSED_WORKSPACE
  local last_workspace = env.PREV_WORKSPACE

  -- breaking the rule about updating the global state outside of sync stuff
  -- (manual triggers may omit the env vars; keep the last known value then)
  if focused_workspace ~= nil and focused_workspace ~= "" then
    state.focused_workspace = focused_workspace
  end

  -- in certain circumstances, the change workspace event won't have the env vars
  -- example: when moving a workspace between monitors
  -- in that case, we just skip the quick update highlight stuff and go to a full system state sync
  -- also require actual bar items: state.workspaces can contain workspaces
  -- created after init, which have no space/bracket/padding items to animate
  if focused_workspace ~= nil and last_workspace ~= nil and state.workspaces and state.workspaces[last_workspace] and state.workspaces[focused_workspace] and spaces[focused_workspace] and spaces[last_workspace] then
    print("aerospace_workspace_change from " .. last_workspace .. " to " .. focused_workspace)

    local space = spaces[focused_workspace]
    local space_bracket = brackets[focused_workspace]
    local space_padding = space_paddings[focused_workspace]

    local prev_space = spaces[last_workspace]
    local prev_space_bracket = brackets[last_workspace]
    local prev_space_padding = space_paddings[last_workspace]

    state.bar_dirty = true
    sbar.animate("tanh", 10, function()
      -- highlight the newly focused workspace
      highlightWorkspace(space, space_padding, space_bracket, true)
      -- if the new workspace is on the same monitor, unhighlight the previous one
      if state.workspaces[last_workspace]["monitor"] == state.workspaces[focused_workspace]["monitor"] then
        highlightWorkspace(prev_space, prev_space_padding, prev_space_bracket, false)
      end
    end)
  end

  requestStateUpdate()
end

local function hideAerospaceError()
  if errorMessageItem ~= nil then
    errorMessageItem:set({
      drawing = false,
    })
  end
  requestStateUpdate()
end

local function initialize()
  sbar.add("event", "aerospace_started")
  sbar.add("event", "swap_menus_and_spaces")

  -- Learn the arrangement before any items are created, so the very first
  -- createWorkspaceItem already validates its display id instead of assigning
  -- workspaces to monitors that aren't attached.
  refreshDisplays()

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
  getAllWorkspaces():catch(function(reason)
    -- aerospace down at startup: show the error item, then continue with zero
    -- workspaces so the subscriptions below still register and the
    -- aerospace_started event can recover the bar later
    onAerospaceError(reason)
    return {}
  end):thenCall(function(workspaces)
    for _, workspace in ipairs(workspaces or {}) do
      createWorkspaceItem(workspace["workspace"], getSketchyMonitorIdFrom(workspace))
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
    space_window_observer:subscribe("space_windows_change", requestStateUpdate)

    space_window_observer:subscribe("system_woke", onSystemWoke)

    -- Fires on monitor connect/disconnect as well as active-display changes.
    -- The docs only mention the latter and issue #448 (asking for a display
    -- count event) was closed "not planned", which makes this look unusable --
    -- but the hotplug path really does reach subscribers:
    -- event_display_added/removed -> bar_manager_display_added/removed
    -- (bar_manager.c:762-768) -> bar_manager_display_changed ->
    -- bar_manager_handle_display_change (:778) -> custom_events_trigger(
    -- COMMAND_SUBSCRIBE_DISPLAY_CHANGE) (:1008).
    space_window_observer:subscribe("display_change", onDisplayChange)

    -- Deliberately NOT subscribed to front_app_switched.  It used to run a
    -- full state snapshot on every app switch as a liveness check on
    -- aerospace, but it fires constantly -- and hardest exactly when docking
    -- shuffles windows between monitors, which is when aerospace is least able
    -- to answer.  aerospace_workspace_change and space_windows_change already
    -- cover every case where the bar's contents actually change; liveness is
    -- reported by the error item instead.

    -- only displayed and updated when there's already been an error
    -- hideAerospaceError already triggers a full state update and sync
    errorMessageItem:subscribe("aerospace_started", hideAerospaceError)

    spaces_indicator:subscribe("swap_menus_and_spaces", function(env)
      local currently_on = spaces_indicator:query().icon.value == icons.switch.on
      spaces_indicator:set({
        icon = currently_on and icons.switch.off or icons.switch.on
      })
      state.menubar_on = currently_on

      sbar.animate("tanh", 10, function()
        for workspaceid, space in pairs(spaces) do
          -- state.workspaces may not have this id yet if the first sync
          -- hasn't completed; treat unknown as hidden
          local ws = state.workspaces[workspaceid]
          local vis = ws ~= nil and ((not currently_on and not ws.empty) or ws.active)
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
  end):thenCall(function()
    -- a failure here must not skip the first sync at the end of the chain
    return getFocusedWorkspace():catch(function() return nil end)
  end):thenCall(function(focused)
    -- learn where the user actually is before the first sticky-window sync;
    -- otherwise sticky windows get moved to a workspace that doesn't exist
    if focused and focused[1] then
      state.focused_workspace = focused[1]["workspace"]
    end
  end):thenCall(updateCurrentStateAndSync)
end

initialize()
