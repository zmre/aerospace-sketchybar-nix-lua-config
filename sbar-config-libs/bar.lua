local colors = require("sbar-config-libs/colors")

-- Equivalent to the --bar domain
sbar.bar({
  height = 40,
  color = colors.bar.bg,
  display = "all",
  topmost = "window",
  padding_right = 2,
  padding_left = 2,
})
