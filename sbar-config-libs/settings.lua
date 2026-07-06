return {
  paddings = 3,
  group_paddings = 5,

  icons = "sf-symbols", -- alternatively available: NerdFont

  -- Aerospace monitor ids and sketchybar monitor ids don't always line up
  -- (see https://github.com/nikitabobko/AeroSpace/issues/336); map monitor
  -- names to sketchybar display ids to override the default heuristics.
  monitor_name_to_sketchybar_id = {
    ["LG Ultra HD"] = "2",
    ["RODE_RCV"] = "3",
  },

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
