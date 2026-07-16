local colors = require("sbar-config-libs/colors")
local settings = require("sbar-config-libs/settings")

-- Fleet widget: the icon+count in the bar shows how many Claude instances are
-- running / waiting / done (from `pai-fleet --counts`); clicking opens a popup
-- with a per-instance table (from `pai-fleet --rows`). Turns orange when any
-- instance needs attention, and hides itself when nothing is running.
--
-- Base command: uses the installed `pai-fleet`, falling back to the WIP build
-- under result/. Change PAI_FLEET / PAI_FLEET_FALLBACK if your commandName or
-- repo path differs.
local PAI_FLEET = "pai-fleet"
local PAI_FLEET_FALLBACK = "/Users/pwalsh/src/personal/nix-pai/result/bin/pai-fleet"
local function fleet_cmd(args)
  return string.format("%s %s 2>/dev/null || %s %s 2>/dev/null",
    PAI_FLEET, args, PAI_FLEET_FALLBACK, args)
end

local MONO = settings.font.numbers
local MAX_ROWS = 12
-- One printf-style layout string shared by the header and every row so columns
-- line up under a monospace font. Widths: project, title, age, ctx, mode.
local ROW_FMT = "%-14s  %-30s  %5s  %5s  %-8s"

local function trunc(s, n)
  s = tostring(s or "")
  if #s > n then return s:sub(1, n - 1) .. "…" end
  return s
end

local claude = sbar.add("item", "widgets.claude", {
  position = "right",
  update_freq = 3,
  -- Keep receiving `routine` ticks even while hidden (drawing = false), so the
  -- widget re-appears on its own when instances start again. Without this,
  -- hiding the item also stops its polling and it never comes back.
  updates = "on",
  icon = {
    string = "🤖",
    font = { size = 14.0 },
    padding_right = 4,
  },
  label = {
    string = "…",
    font = { family = MONO, style = settings.font.style_map["Bold"], size = 12.0 },
  },
  -- Anchor the popup's right edge under the icon so the (wide) rows grow
  -- leftward and stay on screen instead of running off the right edge.
  popup = { align = "right" },
})

-- Popup rows are pre-created once and shown/hidden on demand (cheaper and more
-- reliable than add/remove churn on every click).
local header = sbar.add("item", "widgets.claude.header", {
  position = "popup.widgets.claude",
  drawing = false,
  icon = { string = " ", font = { size = 12.0 }, padding_left = 8, padding_right = 6 },
  label = {
    string = string.format(ROW_FMT, "PROJECT", "TITLE", "AGE", "CTX", "MODE"),
    font = { family = MONO, style = settings.font.style_map["Bold"], size = 11.0 },
    color = colors.grey,
    align = "left",
    padding_right = 10,
  },
})

local empty = sbar.add("item", "widgets.claude.empty", {
  position = "popup.widgets.claude",
  drawing = false,
  icon = { drawing = false },
  label = {
    string = "No running Claude instances",
    font = { family = MONO, size = 12.0 },
    color = colors.grey,
    align = "left",
    padding_left = 8,
    padding_right = 10,
  },
})

local rows = {}
for i = 1, MAX_ROWS do
  rows[i] = sbar.add("item", "widgets.claude.row." .. i, {
    position = "popup.widgets.claude",
    drawing = false,
    icon = { string = "⚪", font = { size = 12.0 }, padding_left = 8, padding_right = 6 },
    label = {
      string = "",
      font = { family = MONO, style = settings.font.style_map["Regular"], size = 12.0 },
      align = "left",
      padding_right = 10,
    },
  })
end

-- Fill the popup from `pai-fleet --rows` (TAB-separated:
-- state, attention(0/1), project, mode, model, age, ctx, title).
local function populate()
  sbar.exec(fleet_cmd("--rows"), function(out)
    local list = {}
    for line in tostring(out):gmatch("[^\n]+") do
      local f = {}
      for field in (line .. "\t"):gmatch("([^\t]*)\t") do
        f[#f + 1] = field
      end
      list[#list + 1] = f
    end

    header:set({ drawing = true })

    if #list == 0 then
      empty:set({ drawing = true })
      for i = 1, MAX_ROWS do rows[i]:set({ drawing = false }) end
      return
    end
    empty:set({ drawing = false })

    local shown = math.min(#list, MAX_ROWS)
    for i = 1, MAX_ROWS do
      if i <= shown then
        local f = list[i]
        local state, attn = f[1] or "running", f[2] or "0"
        local project, mode = f[3] or "?", f[4] or "?"
        local age, ctx, title = f[6] or "", f[7] or "-", f[8] or ""

        local dot, col = "⚪", colors.grey
        if attn == "1" or state == "waiting" then
          dot, col = "🔴", colors.orange
        elseif state == "running" then
          dot, col = "🟢", colors.green
        end

        rows[i]:set({
          drawing = true,
          icon = { string = dot },
          label = {
            string = string.format(ROW_FMT, trunc(project, 14), trunc(title, 30), age, ctx, trunc(mode, 8)),
            color = col,
          },
        })
      else
        rows[i]:set({ drawing = false })
      end
    end
  end)
end

-- Bar icon + count.
local function refresh()
  sbar.exec(fleet_cmd("--counts"), function(out)
    local running, waiting, done = tostring(out):match("(%d+)%s+(%d+)%s+(%d+)")
    running = tonumber(running) or 0
    waiting = tonumber(waiting) or 0
    done = tonumber(done) or 0
    local total = running + waiting + done

    if total == 0 then
      claude:set({ drawing = false, popup = { drawing = false } })
      return
    end

    local label = tostring(running)
    if waiting > 0 then
      label = label .. " ⚠" .. waiting
    end

    local color = colors.green
    if waiting > 0 then
      color = colors.orange
    elseif running == 0 then
      color = colors.grey -- only finished instances remain
    end

    claude:set({ drawing = true, label = { string = label, color = color } })
  end)
end

claude:subscribe({ "routine", "system_woke", "forced" }, refresh)

-- Click toggles the details popup (repopulated each time it opens).
claude:subscribe("mouse.clicked", function(env)
  populate()
  claude:set({ popup = { drawing = "toggle" } })
end)

sbar.add("bracket", "widgets.claude.bracket", { claude.name }, {
  background = { color = colors.bg1 },
})

sbar.add("item", "widgets.claude.padding", {
  position = "right",
  width = settings.group_paddings,
})
