return {
  paddings = 3,
  group_paddings = 5,

  icons = "sf-symbols", -- alternatively available: NerdFont

  -- Escape hatch for when aerospace monitor ids and sketchybar display ids
  -- disagree (see https://github.com/nikitabobko/AeroSpace/issues/336): maps a
  -- monitor name to the sketchybar display id to force for it.
  --
  -- Empty on purpose.  This used to pin LG Ultra HD -> 2 and RODE_RCV -> 3, but
  -- measured on aerospace 0.21.3 while docked, aerospace's
  -- monitor-appkit-nsscreen-screens-id already agrees with sketchybar's
  -- arrangement id on every monitor:
  --
  --   LG UltraFine (main)   appkit 1   arrangement 1   3200x1800 @ (0,0)
  --   LG Ultra HD (left)    appkit 2   arrangement 2   2160x3840 @ (-2160,-1080)
  --   RODE_RCV (right)      appkit 3   arrangement 3   1920x1080 @ (3200,-325)
  --
  -- So the overrides were producing exactly what the fallback already computes,
  -- while being hardcoded to one arrangement and going stale the moment
  -- monitors are unplugged or rearranged.  aerospaces.lua now validates every
  -- id against the live `sketchybar --query displays` set instead.  If the two
  -- numbering schemes ever drift apart again, add the monitor back here.
  monitor_name_to_sketchybar_id = {},

  -- This is a font configuration for SF Pro and SF Mono (installed manually/via brew)
  font = require("sbar-config-libs/helpers.default_font"),

  -- Alternatively, this is a font config for JetBrainsMono Nerd Font
  -- font = {
  --   text = "JetBrainsMono Nerd Font", -- Used for text
  --   numbers = "JetBrainsMono Nerd Font", -- Used for numbers
  --   style_map = {
  --     ["Regular"] = "Regular",
  --     ["Semibold"] = "Medium",
  --     ["Bold"] = "SemiBold",
  --     ["Heavy"] = "Bold",
  --     ["Black"] = "ExtraBold",
  --   },
  -- },
}
