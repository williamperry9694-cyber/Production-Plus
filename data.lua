local function sprite(name, file, size)
  return {
    type = "sprite",
    name = name,
    filename = "__production-plus__/graphics/" .. file,
    size = size,
    flags = { "gui-icon" },
  }
end

data:extend({
  sprite("pp-lock", "lock.png", 32),
  sprite("pp-unlock", "unlock.png", 32),
  sprite("pp-flip", "flip.png", 32),
  sprite("pp-white", "white.png", 8),
  sprite("pp-sort-asc", "sort-asc.png", 32),
  sprite("pp-sort-desc", "sort-desc.png", 32),
  sprite("pp-gear", "gear.png", 32),
})

local styles = data.raw["gui-style"].default
styles.pp_cell = {
  type = "frame_style",
  parent = "invisible_frame",
  padding = 0,
}
styles.pp_cell_selected = {
  type = "frame_style",
  parent = "pp_cell",
  graphical_set = {
    border = 1,
    filename = "__production-plus__/graphics/select.png",
    position = { 0, 0 },
    size = 8,
    scale = 1,
  },
}
-- Table rows: the same dark tile vanilla uses for statistics cells.
styles.pp_row = {
  type = "frame_style",
  parent = "invisible_frame",
  padding = 0,
  graphical_set = { base = { position = { 282, 17 }, corner_size = 8 } },
}

-- Dark page behind the rows, like statistics_scroll_pane (without its fixed cell tiling).
styles.pp_table_scroll = {
  type = "scroll_pane_style",
  parent = "scroll_pane",
  always_draw_borders = true,
  padding = 4,
  extra_padding_when_activated = 0,
  graphical_set = { base = { center = { position = { 42, 8 }, size = { 1, 1 } } } },
  background_graphical_set = { base = { center = { position = { 42, 8 }, size = { 1, 1 } } } },
}

-- Meter pieces, laid side by side: [track-left][red][divider][green][track-right].
-- Images are 13 x 13 (2 * corner_size + 1) like vanilla GUI tiles: corners stay, the middle stretches.
local function comp(file)
  return { base = { filename = "__production-plus__/graphics/" .. file, position = { 0, 0 }, corner_size = 6 } }
end
local function piece(name, file)
  styles[name] = {
    type = "frame_style",
    parent = "invisible_frame",
    padding = 0,
    height = 13,
    minimal_width = 0,
    graphical_set = comp(file),
  }
end
piece("pp_track_left", "track-left.png")
piece("pp_track_right", "track-right.png")
piece("pp_pill_red", "pill-red.png")
piece("pp_pill_green", "pill-green.png")
-- same pills with track-coloured corners, for when they end partway along the track
piece("pp_pill_red_inset", "pill-red-inset.png")
piece("pp_pill_green_inset", "pill-green-inset.png")
-- charge meter (fills from the left)
piece("pp_fill_green", "fill-green.png")
piece("pp_fill_red", "pill-red.png")
piece("pp_fill_green_full", "fill-green-full.png")
piece("pp_fill_red_full", "fill-red-full.png")
piece("pp_track_full", "track-full.png")
styles.pp_bar_mid = {
  type = "frame_style",
  parent = "invisible_frame",
  padding = 0,
  height = 13,
  width = 2,
  graphical_set = { base = { filename = "__production-plus__/graphics/mid.png", position = { 0, 0 }, size = { 2, 13 } } },
}
