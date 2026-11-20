data:extend({
  -- Both are changed from the gear button inside the window, not from this menu.
  -- Stored as per-player settings so they follow the player across saves.
  {
    type = "string-setting",
    name = "pp-window-mode",
    setting_type = "runtime-per-user",
    default_value = "plus",
    allowed_values = { "plus", "vanilla", "plus-only" },
    order = "a",
    hidden = true,
  },
  {
    type = "int-setting",
    name = "pp-graph-scale",
    setting_type = "runtime-per-user",
    default_value = 100,
    minimum_value = 50,
    maximum_value = 300,
    order = "b",
    hidden = true,
  },
})
