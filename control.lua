-- Production Plus 0.2.0
-- Redirects the vanilla production window to a replacement with a Net view,
-- built from the game's own GUI styles. Graphs are drawn with LuaRendering on a
-- hidden surface and shown through camera elements.

local WINDOW = "pp_window"
local UNIVERSE = "__universe__"
local GRAPH_SURFACE = "pp-graphs"

-- Vanilla production graph geometry (core/prototypes/style.lua)
local GRAPH_W, GRAPH_H = 556, 200          -- px
local M_LEFT, M_BOTTOM, M_TOP, M_RIGHT = 36, 24, 12, 40   -- right margin holds line-end icons
local MAX_SERIES = 18
local AUTO_SERIES = 8
local PX = 1 / 32                          -- tiles per px at zoom 1

local SCALES = {
  { key = "five_seconds",            label = "5s",    minutes = 5 / 60, axis = 5,    unit = "s" },
  { key = "one_minute",              label = "1m",    minutes = 1,      axis = 60,   unit = "s" },
  { key = "ten_minutes",             label = "10m",   minutes = 10,     axis = 10,   unit = "m" },
  { key = "one_hour",                label = "1h",    minutes = 60,     axis = 60,   unit = "m" },
  { key = "ten_hours",               label = "10h",   minutes = 600,    axis = 10,   unit = "h" },
  { key = "fifty_hours",             label = "50h",   minutes = 3000,   axis = 50,   unit = "h" },
  { key = "two_hundred_fifty_hours", label = "250h",  minutes = 15000,  axis = 250,  unit = "h" },
  { key = "one_thousand_hours",      label = "1000h", minutes = 60000,  axis = 1000, unit = "h" },
  { key = "all",                     label = "All" },
}
local SCALE_BY_KEY = {}
for _, s in ipairs(SCALES) do SCALE_BY_KEY[s.key] = s end

-- Vanilla graph line colours, in order.
local LINE_COLORS = {}
for i, c in ipairs({
  { 0, 109, 255 }, { 255, 100, 0 }, { 80, 178, 14 }, { 204, 25, 40 }, { 212, 158, 27 }, { 232, 0, 213 },
  { 0, 159, 173 }, { 133, 69, 40 }, { 137, 0, 161 }, { 83, 117, 59 }, { 224, 127, 126 }, { 142, 106, 169 },
  { 98, 172, 101 }, { 73, 123, 155 }, { 134, 129, 78 }, { 133, 104, 49 }, { 208, 104, 0 }, { 145, 75, 75 },
}) do
  LINE_COLORS[i] = { r = c[1] / 255, g = c[2] / 255, b = c[3] / 255 }
end
local CLR = {
  GRAPH_BG = { r = 0.05, g = 0.05, b = 0.05 },
  GRID = { r = 0.15, g = 0.15, b = 0.15 },
  ZERO = { r = 0.4, g = 0.4, b = 0.4 },
  LABEL = { r = 100 / 255, g = 100 / 255, b = 100 / 255 },
  BAR_IDLE = { r = 0.5, g = 0.5, b = 0.5 },
  COLOR_RED = { 1, 0.45, 0.4 },
  COLOR_GREEN = { 0.45, 1, 0.45 },
  COLOR_GREY = { 0.6, 0.6, 0.6 },
  WHITE = { 1, 1, 1 },
  SELECTED_TEXT = { 0.16, 0.11, 0.02 },
}
CLR.NET_COLORS = { [0] = CLR.COLOR_GREY, [1] = CLR.COLOR_RED, [2] = CLR.COLOR_GREEN }

local EPS = 1e-6

local PANELS = { "production", "consumption", "net" }

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

local function init_storage()
  storage.players = storage.players or {}
  storage.open = storage.open or {}
end

local function new_panel_state() return { quality = "separate", picks = nil, locked = false, flipped = false, order = nil } end

local function get_state(player_index)
  init_storage()
  local st = storage.players[player_index]
  if not st then
    st = {
      view = "columns",
      mode = "number",
      kind = "items",
      scale = "one_minute",
      surface = nil,
      allow_vanilla = false,
      closed_tick = nil,
    }
    storage.players[player_index] = st
  end
  st.panels = st.panels or {}
  for _, k in ipairs(PANELS) do st.panels[k] = st.panels[k] or new_panel_state() end
  st.graphs = st.graphs or {}
  st.views = st.views or {}
  st.selected = nil -- 0.1.0 leftover
  return st
end

-- Saved-data format. Bump DATA_FORMAT whenever stored state changes shape (even within
-- the same mod version): the next tick closes open windows, resets everything that is
-- rebuilt anyway (windows, graphs, scans) and validates what the player chose.
local DATA_FORMAT = 5

local function valid_key(kind, key)
  if type(key) ~= "string" then return false end
  local name, q = key:match("^(.*)|([^|]*)$")
  if not name then return false end
  if kind == "fluids" then return prototypes.fluid[name] ~= nil end
  if not prototypes.item[name] then return false end
  return q == "*" or prototypes.quality[q] ~= nil
end

local function valid_quality_choice(q)
  return q == "separate" or q == "merged" or (type(q) == "string" and prototypes.quality[q] ~= nil)
end

local function migrate()
  init_storage()
  -- windows, anchors and drawings are rebuilt on demand
  for _, player in pairs(game.players) do
    local w = player.gui.screen[WINDOW]
    if w and w.valid then w.destroy() end
    local rel = player.gui.relative.pp_anchor
    if rel and rel.valid then rel.destroy() end
  end
  pcall(rendering.clear, "production-plus")
  storage.open = {}
  -- prototypes may have changed: translate again when needed
  storage.tr, storage.tr_queue, storage.tr_ids = nil, nil, nil

  for index, st in pairs(storage.players) do
    -- transient state: always rebuilt
    st.graphs, st.views, st.power_view = {}, {}, nil
    st.buf, st.buf_sig, st.render, st.selected = nil, nil, nil, nil
    st.raw_list, st.raw_map, st.slice, st.discovered = nil, nil, nil, nil
    st.hover, st.graph_n, st.surface_names = nil, nil, nil
    st.allow_vanilla, st.closed_tick = false, nil

    -- choices: keep, but only if still valid
    if st.view ~= "columns" and st.view ~= "table" then st.view = "columns" end
    if st.mode ~= "number" and st.mode ~= "percent" then st.mode = "number" end
    if st.kind ~= "items" and st.kind ~= "fluids" and st.kind ~= "power" then st.kind = "items" end
    if not SCALE_BY_KEY[st.scale] then st.scale = "one_minute" end
    if st.surface and st.surface ~= UNIVERSE and not game.surfaces[st.surface] then st.surface = nil end
    if type(st.search) ~= "string" or st.search == "" then st.search = nil end
    if type(st.tsort) ~= "table" or not st.tsort.col then st.tsort = nil end

    local panels = type(st.panels) == "table" and st.panels or {}
    for _, k in ipairs(PANELS) do
      local p = type(panels[k]) == "table" and panels[k] or {}
      local np = new_panel_state()
      np.locked = p.locked == true
      np.flipped = p.flipped == true
      np.quality = valid_quality_choice(p.quality) and p.quality or "separate"
      if type(p.picks) == "table" then
        np.picks = {}
        for _, key in ipairs(p.picks) do
          if valid_key("items", key) or valid_key("fluids", key) then np.picks[#np.picks + 1] = key end
        end
        if #np.picks == 0 then np.picks = nil end
      end
      panels[k] = np
    end
    st.panels = panels

    if type(st.pins) == "table" then
      local pins = {}
      for _, kind in ipairs({ "items", "fluids" }) do
        local list = {}
        for _, key in ipairs(type(st.pins[kind]) == "table" and st.pins[kind] or {}) do
          if valid_key(kind, key) then list[#list + 1] = key end
        end
        pins[kind] = list
      end
      st.pins = pins
    else
      st.pins = nil
    end

    if type(st.power) == "table" then
      local names = type(st.power.names) == "table" and st.power.names or {}
      st.power = { names = names, show_idle = st.power.show_idle == true }
    else
      st.power = nil
    end
    get_state(index)
  end
  storage.anchors_dirty = true
  storage.format = DATA_FORMAT
end

script.on_configuration_changed(migrate)

---------------------------------------------------------------------------
-- Graph surface
---------------------------------------------------------------------------

local function graph_surface()
  local s = game.surfaces[GRAPH_SURFACE]
  if not (s and s.valid) then
    s = game.create_surface(GRAPH_SURFACE, { width = 1, height = 1 })
    s.always_day = true
    for _, force in pairs(game.forces) do
      pcall(function() force.set_surface_hidden(s, true) end)
    end
  end
  return s
end

script.on_event(defines.events.on_force_created, function(e)
  local s = game.surfaces[GRAPH_SURFACE]
  if s then pcall(function() e.force.set_surface_hidden(s, true) end) end
end)

-- Each player/panel gets its own patch of the graph surface.
local function graph_origin(player_index, slot)
  return { x = 0, y = (player_index * 8 + slot) * 10 }
end


---------------------------------------------------------------------------
-- Surfaces
---------------------------------------------------------------------------

local function surface_caption(surface)
  if surface.platform then return surface.platform.name end
  if surface.planet then return surface.planet.prototype.localised_name end
  return surface.localised_name or surface.name
end

local function listed_surfaces(player)
  local list = {}
  for _, s in pairs(game.surfaces) do
    if s.valid and s.name ~= GRAPH_SURFACE then
      if s.planet then
        list[#list + 1] = s
      elseif s.platform and s.platform.force == player.force then
        list[#list + 1] = s
      end
    end
  end
  local here = player.surface
  local found = false
  for _, s in ipairs(list) do if s == here then found = true break end end
  if not found and here.name ~= GRAPH_SURFACE then table.insert(list, 1, here) end
  return list
end

local function resolve_surface(player, st)
  if st.surface == UNIVERSE then return nil end
  local s = st.surface and game.surfaces[st.surface]
  if s and s.valid then return s end
  st.surface = nil
  return player.surface
end

local function stats_list(player, st)
  local force = player.force
  local surfaces
  if st.surface == UNIVERSE then
    surfaces = {}
    for _, s in pairs(game.surfaces) do
      if s.valid and s.name ~= GRAPH_SURFACE then surfaces[#surfaces + 1] = s end
    end
  else
    surfaces = { resolve_surface(player, st) }
  end
  local out = {}
  for _, s in ipairs(surfaces) do
    if st.kind == "items" then
      out[#out + 1] = force.get_item_production_statistics(s)
    else
      out[#out + 1] = force.get_fluid_production_statistics(s)
    end
  end
  return out
end

---------------------------------------------------------------------------
-- Data
---------------------------------------------------------------------------

local function scale_minutes(scale)
  if scale.key == "all" then return math.max(game.tick, 1) / 3600 end
  return scale.minutes
end

local function read_count(stats, id, category, scale)
  if scale.key == "all" then
    if category == "input" then return stats.get_input_count(id) end
    return stats.get_output_count(id)
  end
  return stats.get_flow_count {
    name = id,
    category = category,
    precision_index = defines.flow_precision_index[scale.key],
    count = true,
  }
end

local function row_key(name, quality) return name .. "|" .. (quality or "*") end

-- Raw rows: one per (name, quality). Counts over the window + rates per minute.
local function collect(player, st, stats)
  local scale = SCALE_BY_KEY[st.scale]
  local minutes = scale_minutes(scale)
  local rows, order = {}, {}

  for _, s in ipairs(stats) do
    local keys = {}
    if st.kind == "items" then
      for _, counts in ipairs({ s.input_quality_counts, s.output_quality_counts }) do
        for q, names in pairs(counts) do
          for n in pairs(names) do keys[row_key(n, q)] = { n, q } end
        end
      end
    else
      for _, counts in ipairs({ s.input_counts, s.output_counts }) do
        for n in pairs(counts) do keys[row_key(n, nil)] = { n, nil } end
      end
    end
    for key, nq in pairs(keys) do
      local n, q = nq[1], nq[2]
      local proto = st.kind == "items" and prototypes.item[n] or prototypes.fluid[n]
      if proto then
        local id = q and { name = n, quality = q } or n
        local row = rows[key]
        if not row then
          row = { name = n, quality = q, pn = 0, cn = 0 }
          rows[key] = row
          order[#order + 1] = row
        end
        row.pn = row.pn + read_count(s, id, "input", scale)
        row.cn = row.cn + read_count(s, id, "output", scale)
      end
    end
  end

  local out = {}
  for _, row in ipairs(order) do
    if row.pn > EPS or row.cn > EPS then
      row.p, row.c = row.pn / minutes, row.cn / minutes
      row.net, row.nn = row.p - row.c, row.pn - row.cn
      row.key = row_key(row.name, row.quality)
      out[#out + 1] = row
    end
  end
  return out
end

-- Apply a panel's quality filter: "separate", "merged", or a quality name.
local function apply_quality(rows, qsel, kind)
  if kind ~= "items" or qsel == "separate" then return rows end
  local out = {}
  if qsel == "merged" then
    local by = {}
    for _, r in ipairs(rows) do
      local m = by[r.name]
      if not m then
        m = { name = r.name, quality = nil, merged = true, pn = 0, cn = 0, p = 0, c = 0 }
        by[r.name] = m
        out[#out + 1] = m
      end
      m.pn, m.cn, m.p, m.c = m.pn + r.pn, m.cn + r.cn, m.p + r.p, m.c + r.c
    end
    for _, m in ipairs(out) do
      m.net, m.nn = m.p - m.c, m.pn - m.cn
      m.key = row_key(m.name, nil)
    end
    return out
  end
  for _, r in ipairs(rows) do
    if r.quality == qsel then out[#out + 1] = r end
  end
  return out
end

local function panel_list(panel, rows)
  local list = {}
  if panel == "production" then
    for _, r in ipairs(rows) do if r.pn > EPS then list[#list + 1] = r end end
    table.sort(list, function(a, b) return a.p > b.p end)
  elseif panel == "consumption" then
    for _, r in ipairs(rows) do if r.cn > EPS then list[#list + 1] = r end end
    table.sort(list, function(a, b) return a.c > b.c end)
  else
    for _, r in ipairs(rows) do if r.pn > EPS or r.cn > EPS then list[#list + 1] = r end end
    table.sort(list, function(a, b) return a.net < b.net end)
  end
  return list
end

local function zero_row(key, kind)
  local name, q = key:match("^(.*)|([^|]*)$")
  return {
    name = name, quality = (q ~= "*") and q or nil, merged = (q == "*" and kind == "items"),
    key = key, pn = 0, cn = 0, p = 0, c = 0, net = 0, nn = 0,
  }
end

-- Re-read the window counts for a set of raw keys (hot rows).
local function reread(st, stats, set)
  local scale = SCALE_BY_KEY[st.scale]
  local minutes = scale_minutes(scale)
  for key in pairs(set) do
    local r = st.raw_map[key]
    if r then
      local id = r.quality and { name = r.name, quality = r.quality } or r.name
      local pn, cn = 0, 0
      for _, s in ipairs(stats) do
        pn = pn + read_count(s, id, "input", scale)
        cn = cn + read_count(s, id, "output", scale)
      end
      r.pn, r.cn = pn, cn
      r.p, r.c = pn / minutes, cn / minutes
      r.net, r.nn = r.p - r.c, pn - cn
    end
  end
end

-- Sorted list for a panel, honouring flip and lock.
-- Map a pinned key to this panel's quality filter.
local function pin_key_for(key, qsel, kind)
  if kind ~= "items" or qsel == "separate" then return key end
  local name = key:match("^(.*)|[^|]*$")
  if qsel == "merged" then return name .. "|*" end
  return name .. "|" .. qsel
end

-- Sort keys for the Table view's Item column: in-game order (group, subgroup, item, quality).
local item_order_cache = {}
local function item_order(kind, name, quality)
  local ck = kind .. "|" .. name
  local base = item_order_cache[ck]
  if not base then
    local proto = kind == "items" and prototypes.item[name] or prototypes.fluid[name]
    if proto then
      base = (proto.group and proto.group.order or "") .. "|" .. (proto.subgroup and proto.subgroup.order or "") .. "|" .. (proto.order or "") .. "|" .. name
    else
      base = "~|" .. name
    end
    item_order_cache[ck] = base
  end
  local lvl = quality and prototypes.quality[quality] and prototypes.quality[quality].level or 0
  return base .. "|" .. string.format("%03d", lvl)
end

local function table_sorter(st)
  local ts = st.tsort or { col = "net", asc = true }
  local kind = st.kind
  local function val(r)
    if ts.col == "item" then return item_order(kind, r.name, r.quality)
    elseif ts.col == "p" then return r.p
    elseif ts.col == "c" then return r.c
    elseif ts.col == "pct" then return r.p > EPS and r.net / r.p or -1e18
    else return r.net end
  end
  return function(a, b)
    local x, y = val(a), val(b)
    if x == y then return a.key < b.key end
    if ts.asc then return x < y end
    return x > y
  end
end

local function order_list_inner(panel, prows, pstate, kind, sorter)
  local list
  if sorter then
    list = {}
    for _, r in ipairs(prows) do if r.pn > EPS or r.cn > EPS then list[#list + 1] = r end end
    table.sort(list, sorter)
  else
    list = panel_list(panel, prows)
  end
  if pstate.flipped and not sorter then
    local rev = {}
    for i = #list, 1, -1 do rev[#rev + 1] = list[i] end
    list = rev
  end
  if not pstate.locked then return list end
  if not pstate.order then
    pstate.order = {}
    for i, r in ipairs(list) do pstate.order[i] = r.key end
    return list
  end
  local by = {}
  for _, r in ipairs(prows) do by[r.key] = r end
  local out, seen = {}, {}
  for _, k in ipairs(pstate.order) do
    out[#out + 1] = by[k] or zero_row(k, kind)
    seen[k] = true
  end
  for _, r in ipairs(list) do
    if not seen[r.key] then
      out[#out + 1] = r
      pstate.order[#pstate.order + 1] = r.key
    end
  end
  return out
end

-- Full panel order: pinned items first (in pin order, 0 if inactive), then the rest.
local function order_list(panel, prows, pstate, kind, pins, sorter)
  local list = order_list_inner(panel, prows, pstate, kind, sorter)
  if not pins or #pins == 0 then return list, {} end
  local by = {}
  for _, r in ipairs(prows) do by[r.key] = r end
  local out, pinned = {}, {}
  for _, k in ipairs(pins) do
    local pk = pin_key_for(k, pstate.quality, kind)
    if not pinned[pk] then
      pinned[pk] = true
      out[#out + 1] = by[pk] or zero_row(pk, kind)
    end
  end
  for _, r in ipairs(list) do
    if not pinned[r.key] then out[#out + 1] = r end
  end
  return out, pinned
end

-- Which rows are graphed in a panel, in colour order.
local function graphed(pstate, list)
  local out = {}
  if pstate.picks then
    local by = {}
    for _, r in ipairs(list) do by[r.key] = r end
    for _, k in ipairs(pstate.picks) do
      if by[k] then out[#out + 1] = by[k] end
    end
  else
    -- Stable default lines: an item keeps its line (and colour slot) while it stays in the
    -- top AUTO_SERIES + 4, so small ranking changes don't swap lines in and out.
    local keep_within = AUTO_SERIES + 4
    local rank = {}
    for i = 1, math.min(keep_within, #list) do rank[list[i].key] = i end
    local by = {}
    for _, r in ipairs(list) do by[r.key] = r end
    local used = {}
    for _, k in ipairs(pstate.auto or {}) do
      if #out < AUTO_SERIES and rank[k] and not used[k] then
        out[#out + 1] = by[k]
        used[k] = true
      end
    end
    for i = 1, math.min(AUTO_SERIES, #list) do
      if #out >= AUTO_SERIES then break end
      local r = list[i]
      if not used[r.key] then
        out[#out + 1] = r
        used[r.key] = true
      end
    end
    local keys = {}
    for i, r in ipairs(out) do keys[i] = r.key end
    pstate.auto = keys
  end
  return out
end

---------------------------------------------------------------------------
-- Translated names (for search and CSV). Requested once per player, in batches.
---------------------------------------------------------------------------

local TR_PER_TICK = 200

local function tr_key(kind, name) return (kind == "fluids" and "f:" or "i:") .. name end

local function queue_translations(player)
  storage.tr = storage.tr or {}
  storage.tr_queue = storage.tr_queue or {}
  storage.tr_ids = storage.tr_ids or {}
  if storage.tr[player.index] or storage.tr_queue[player.index] then return end
  storage.tr[player.index] = {}
  local q = {}
  for name in pairs(prototypes.item) do q[#q + 1] = { "items", name } end
  for name in pairs(prototypes.fluid) do q[#q + 1] = { "fluids", name } end
  storage.tr_queue[player.index] = { list = q, i = 1 }
end

local function translation_step()
  if not storage.tr_queue then return end
  for index, q in pairs(storage.tr_queue) do
    local player = game.get_player(index)
    if not (player and player.connected) then
      -- resumes when they reconnect
    else
      storage.tr_ids[index] = storage.tr_ids[index] or {}
      local last = math.min(#q.list, q.i + TR_PER_TICK - 1)
      local strings, keys = {}, {}
      for k = q.i, last do
        local kind, name = q.list[k][1], q.list[k][2]
        local proto = kind == "items" and prototypes.item[name] or prototypes.fluid[name]
        if proto then
          strings[#strings + 1] = proto.localised_name
          keys[#keys + 1] = tr_key(kind, name)
        end
      end
      if #strings > 0 then
        local ids = player.request_translations(strings)
        for k, id in ipairs(ids or {}) do storage.tr_ids[index][id] = keys[k] end
      end
      q.i = last + 1
      if q.i > #q.list then storage.tr_queue[index] = nil end
    end
  end
  if not next(storage.tr_queue) then storage.tr_queue = nil end
end

script.on_event(defines.events.on_string_translated, function(e)
  local ids = storage.tr_ids and storage.tr_ids[e.player_index]
  local key = ids and ids[e.id]
  if not key then return end
  ids[e.id] = nil
  if e.translated and storage.tr[e.player_index] then
    storage.tr[e.player_index][key] = string.lower(e.result)
  end
end)

script.on_event(defines.events.on_player_locale_changed, function(e)
  if storage.tr then storage.tr[e.player_index] = nil end
  if storage.tr_queue then storage.tr_queue[e.player_index] = nil end
end)

local function translated(player_index, kind, name)
  local t = storage.tr and storage.tr[player_index]
  return t and t[tr_key(kind, name)]
end

local function matches_search(player_index, st, name)
  local q = st.search
  if not q or q == "" then return true end
  if string.find(name, q, 1, true) then return true end
  local t = translated(player_index, st.kind, name)
  return t ~= nil and string.find(t, q, 1, true) ~= nil
end

---------------------------------------------------------------------------
-- Formatting
---------------------------------------------------------------------------

local function commas(v)
  local s = string.format("%.1f", math.abs(v))
  local int, frac = s:match("^(%d+)(%.%d+)$")
  int = int:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
  return int .. frac
end

local function short(v)
  local a = math.abs(v)
  local sign = v < 0 and "-" or ""
  if a >= 1e6 then return sign .. string.format(a >= 1e7 and "%.0fM" or "%.1fM", a / 1e6) end
  if a >= 1e3 then return sign .. string.format(a >= 1e4 and "%.0fk" or "%.1fk", a / 1e3) end
  if a >= 10 or a == 0 then return sign .. string.format("%.0f", a) end
  return sign .. string.format("%.1f", a)
end

local function fmt_amount(v) return commas(v) .. "/m" end

local function si_units(v, unit)
  local a = math.abs(v)
  local prefixes = { { 1e12, "T" }, { 1e9, "G" }, { 1e6, "M" }, { 1e3, "k" } }
  for _, p in ipairs(prefixes) do
    if a >= p[1] then return string.format("%.1f %s%s", v / p[1], p[2], unit) end
  end
  return string.format("%.0f %s", v, unit)
end
local function fmt_power(w) return si_units(w, "W") end
local function fmt_energy(j) return si_units(j, "J") end

local function fmt_duration(sec)
  sec = math.floor(sec + 0.5)
  local h, m, x = math.floor(sec / 3600), math.floor((sec % 3600) / 60), sec % 60
  if h > 0 then return string.format("%d:%02d:%02d", h, m, x) end
  return string.format("%d:%02d", m, x)
end

local function fmt_net(v)
  if math.abs(v) < 0.05 then return "0.0/m" end
  return (v > 0 and "+" or "-") .. commas(v) .. "/m"
end

local function fmt_share(v, total)
  if total <= EPS then return "0.0%" end
  return string.format("%.1f%%", v / total * 100)
end

local function fmt_net_percent(row)
  if row.p <= EPS then return "—" end
  local pct = row.net / row.p * 100
  if math.abs(pct) < 0.05 then return "0.0%" end
  return string.format("%s%.1f%%", pct > 0 and "+" or "-", math.abs(pct))
end

local function net_color(row)
  if math.abs(row.net) < 0.05 or (row.p > EPS and math.abs(row.net / row.p) < 0.0005) then
    return CLR.COLOR_GREY
  end
  return row.net < 0 and CLR.COLOR_RED or CLR.COLOR_GREEN
end

local function display_name(st, row)
  local proto = st.kind == "items" and prototypes.item[row.name] or prototypes.fluid[row.name]
  local name = proto and proto.localised_name or row.name
  if row.quality and row.quality ~= "normal" and prototypes.quality[row.quality] then
    return { "", name, " (", prototypes.quality[row.quality].localised_name, ")" }
  end
  return name
end

local function row_tooltip(st, row)
  return {
    "", { "", "[font=default-bold]", display_name(st, row), "[/font]" },
    "\n", { "production-plus.produced" }, ": ", fmt_amount(row.p),
    "\n", { "production-plus.consumed" }, ": ", fmt_amount(row.c),
    "\n", { "production-plus.net" }, ": ", fmt_net(row.net), "  (", fmt_net_percent(row), ")",
  }
end

---------------------------------------------------------------------------
-- Graph drawing
---------------------------------------------------------------------------

local function axis_label(v)
  local a = math.abs(v)
  local sign = v < 0 and "-" or ""
  if a >= 1e3 then
    local k = a / 1e3
    return sign .. (k >= 10 and string.format("%.0fk", k) or string.format("%.1fk", k))
  end
  if a >= 10 or a == 0 then return sign .. string.format("%.0f", a) end
  return sign .. string.format("%.1f", a)
end

---------------------------------------------------------------------------
-- Graph engine
-- One point per 2 samples, smoothed over 10% of the visible range (matches
-- vanilla's look). Lines are drawn once; the camera pans every tick so the
-- graph glides. A rolling buffer of raw sample counts means only the newest
-- samples are read from the API.
---------------------------------------------------------------------------

local CAMERA_ZOOM = 0.8   -- measured: camera tile size already includes UI scale (x1.25)
local SAMPLES = 300
local GROUP = 2           -- samples per drawn point
local POINTS = SAMPLES / GROUP
local SMOOTH = 30         -- samples in the moving average (10% of range)
local TICKS_PER_SAMPLE = {
  five_seconds = 1, one_minute = 12, ten_minutes = 120, one_hour = 720,
  ten_hours = 7200, fifty_hours = 36000, two_hundred_fifty_hours = 180000,
  one_thousand_hours = 720000,
}
local function gdx(g) return (g.w - M_RIGHT - M_LEFT) / (POINTS - 1) end

local function graph_key(st)
  if st.kind == "power" then return "one_minute" end   -- power graph is sampled by the mod at 1m resolution
  return st.scale == "all" and "one_thousand_hours" or st.scale
end

-- Filled in by the Power tab: returns { production_W, demand_W } for a custom series.
local power_sample
local function tps(st) return TICKS_PER_SAMPLE[graph_key(st)] end

local function sample_minutes(st)
  return SCALE_BY_KEY[graph_key(st)].minutes / SAMPLES
end

local function buffers(st)
  local sig = graph_key(st) .. "|" .. tostring(st.surface) .. "|" .. st.kind
  if st.buf_sig ~= sig then
    st.buf = {}
    st.buf_sig = sig
  end
  return st.buf
end

local function sample_ids(st, desc)
  if st.kind ~= "items" then return { desc.name } end
  if desc.merged then
    local ids = {}
    for q in pairs(prototypes.quality) do ids[#ids + 1] = { name = desc.name, quality = q } end
    return ids
  end
  return { { name = desc.name, quality = desc.quality } }
end

-- Bring one buffer up to sample n. Reads only what's new (plus the in-progress sample).
local function read_buffer(st, stats, desc, n)
  local bufs = buffers(st)
  local b = bufs[desc.bkey]
  if not b then
    b = { data = {} }
    bufs[desc.bkey] = b
  end
  if desc.custom then
    -- sampled by the mod (no history in the game's statistics for this)
    if b.head ~= n then
      b.data[n] = power_sample(st, desc)
      if b.head then
        for m = b.head - SAMPLES - SMOOTH - GROUP - 2, n - SAMPLES - SMOOTH - GROUP - 1 do b.data[m] = nil end
      end
      b.head = n
    end
    return
  end
  local k
  if not b.head or n - b.head >= SAMPLES - 2 then
    k = SAMPLES
  else
    k = math.min(SAMPLES, n - b.head + 2)
  end
  local idx = defines.flow_precision_index[graph_key(st)]
  local ids = sample_ids(st, desc)
  for i = 1, k do
    local ii, oo = 0, 0
    for _, s in ipairs(stats) do
      for _, id in ipairs(ids) do
        ii = ii + s.get_flow_count { name = id, category = "input", precision_index = idx, sample_index = i, count = true }
        oo = oo + s.get_flow_count { name = id, category = "output", precision_index = idx, sample_index = i, count = true }
      end
    end
    b.data[n - i + 1] = { ii, oo }
  end
  if b.head then
    local keep_from = n - SAMPLES - SMOOTH - GROUP
    for m = b.head - SAMPLES - SMOOTH - GROUP - k, keep_from - 1 do b.data[m] = nil end
  end
  b.head = n
end

-- Smoothed rate per minute ending at sample m (custom series: smoothed raw value, nil without data).
local function sample_value(b, m, panel, mps, desc)
  local sum, cnt = 0, 0
  local data = b.data
  local field = desc and desc.field
  for j = 0, SMOOTH - 1 do
    local d = data[m - j]
    if d then
      cnt = cnt + 1
      if field then sum = sum + d[field]
      elseif panel == "production" then sum = sum + d[1]
      elseif panel == "consumption" then sum = sum + d[2]
      else sum = sum + d[1] - d[2] end
    end
  end
  if cnt == 0 then return (desc and desc.custom) and nil or 0 end
  if desc and desc.custom then return sum / cnt end
  return sum / (cnt * mps)
end

local function nice_step(raw)
  if raw <= 0 then return 1 end
  local mag = 10 ^ math.floor(math.log(raw, 10))
  for _, f in ipairs({ 1, 2, 2.5, 5, 10 }) do
    if raw <= f * mag then return f * mag end
  end
  return 10 * mag
end

local function destroy_graph_objects(g)
  for _, s in ipairs(g.statics or {}) do
    if s.obj.valid then s.obj.destroy() end
  end
  for _, segs in pairs(g.segs or {}) do
    for _, o in pairs(segs) do if o.valid then o.destroy() end end
  end
  for _, ic in pairs(g.icons or {}) do
    for _, o in pairs(ic.objs) do if o.valid then o.destroy() end end
  end
  g.statics, g.segs, g.vals, g.icons = {}, {}, {}, {}
end

local function clear_graphs(st)
  for _, g in pairs(st.graphs or {}) do destroy_graph_objects(g) end
  st.graphs = {}
end

-- q may be fractional (for panning).
local function world_x(g, o, q)
  return o.x + (M_LEFT + (q - g.base) * gdx(g)) * PX
end

local function ypx(g, v)
  local y0, y1 = M_TOP, GRAPH_H - M_BOTTOM
  local lo = g.signed and -g.ymax or 0
  local f = (v - lo) / (g.ymax - lo)
  if f < 0 then f = 0 elseif f > 1 then f = 1 end
  return y1 - f * (y1 - y0)
end

-- Line style: normal, highlighted (hovered) or dimmed (something else hovered).
local function seg_style(g, si)
  local base = LINE_COLORS[si]
  local hk = g.hover
  if not hk then return base, 1 end
  local desc = g.descs[si]
  if desc and desc.key == hk then return base, 2.5 end
  return { r = base.r * 0.3, g = base.g * 0.3, b = base.b * 0.3 }, 1
end

local ICON_PX = 20
local ICON_GAP = 6        -- leader length before the icon
local ICON_SPACING = 21   -- min vertical distance between icons

local function icon_sprite(st, desc)
  if desc.sprite then
    return helpers.is_valid_sprite_path(desc.sprite) and desc.sprite or "utility/questionmark"
  end
  local p = (st.kind == "items" and "item/" or "fluid/") .. desc.name
  return helpers.is_valid_sprite_path(p) and p or "utility/questionmark"
end

-- Create the icon objects (sprite, optional quality badge, leader) for each series.
local function create_icons(st, g, surface, players)
  g.icons = {}
  local scale = ICON_PX / 32   -- icons render one tile (32 px) per scale unit
  for si, desc in ipairs(g.descs) do
    local objs = {}
    objs.lead = rendering.draw_line { color = LINE_COLORS[si], width = 1, from = { 0, 0 }, to = { 0, 0 }, surface = surface, players = players }
    objs.spr = rendering.draw_sprite { sprite = icon_sprite(st, desc), target = { 0, 0 }, x_scale = scale, y_scale = scale, surface = surface, players = players }
    if desc.quality and desc.quality ~= "normal" and helpers.is_valid_sprite_path("quality/" .. desc.quality) then
      objs.q = rendering.draw_sprite { sprite = "quality/" .. desc.quality, target = { 0, 0 }, x_scale = scale * 0.5, y_scale = scale * 0.5, surface = surface, players = players }
    end
    g.icons[si] = { objs = objs, y = 0, ly = 0 }
  end
end

-- Recompute icon heights from each line's newest value; push apart to avoid overlap.
local function layout_icons(g, o, qh)
  local order = {}
  for si, ic in pairs(g.icons) do
    local v = g.vals[si] and g.vals[si][qh] or 0
    ic.ly = ypx(g, v)
    order[#order + 1] = si
  end
  table.sort(order, function(a, b) return g.icons[a].ly < g.icons[b].ly end)
  local top, bottom = ICON_PX / 2, GRAPH_H - M_BOTTOM
  local last = -1e9
  for _, si in ipairs(order) do
    local ic = g.icons[si]
    local y = math.max(ic.ly, last + ICON_SPACING, top)
    ic.y = y
    last = y
  end
  -- if pushed past the bottom, shift the stack up
  if last > bottom then
    local shift = last - bottom
    for _, si in ipairs(order) do g.icons[si].y = math.max(top, g.icons[si].y - shift) end
  end
  for si, ic in pairs(g.icons) do
    local lead = ic.objs.lead
    if lead.valid then lead.from = { world_x(g, o, qh), o.y + ic.ly * PX } end
  end
end

local function place_statics(g, o, now_q)
  local vl = world_x(g, o, now_q) - (g.w - M_RIGHT) * PX
  local function at(p) return { vl + p[1] * PX, o.y + p[2] * PX } end
  local x1 = g.w - M_RIGHT
  for _, ic in pairs(g.icons or {}) do
    local objs = ic.objs
    if objs.lead.valid then objs.lead.to = at({ x1 + ICON_GAP, ic.y }) end
    if objs.spr.valid then objs.spr.target = at({ x1 + ICON_GAP + ICON_PX / 2 + 2, ic.y }) end
    if objs.q and objs.q.valid then objs.q.target = at({ x1 + ICON_GAP + 2 + ICON_PX / 4, ic.y + ICON_PX / 4 }) end
  end
  for _, s in ipairs(g.statics) do
    local obj = s.obj
    if obj.valid then
      if s.t == "rect" then
        obj.left_top = at(s.a)
        obj.right_bottom = at(s.b)
      elseif s.t == "line" then
        obj.from = at(s.a)
        obj.to = at(s.b)
      else
        obj.target = at(s.a)
      end
    end
  end
  if g.cam and g.cam.valid then
    g.cam.position = { vl + g.w * PX / 2, o.y + GRAPH_H * PX / 2 }
  end
end

local function draw_segment(g, o, si, q, surface, players)
  local vals = g.vals[si]
  local a, b = vals[q - 1], vals[q]
  if not (a and b) then return end
  local color, width = seg_style(g, si)
  g.segs[si][q] = rendering.draw_line {
    color = color, width = width,
    from = { world_x(g, o, q - 1), o.y + ypx(g, a) * PX },
    to = { world_x(g, o, q), o.y + ypx(g, b) * PX },
    surface = surface, players = players,
  }
end

-- Point q uses the newest sample in its group, capped at the current sample n.
local function compute_vals(st, g, from_q, to_q, n)
  local mps = sample_minutes(st)
  local bufs = buffers(st)
  for si, desc in ipairs(g.descs) do
    local b = bufs[desc.bkey]
    g.vals[si] = g.vals[si] or {}
    if b then
      for q = from_q, to_q do
        g.vals[si][q] = sample_value(b, math.min(q * GROUP + GROUP - 1, n), g.panel, mps, desc)
      end
    end
  end
end

local function window_max(g, qh)
  local max = 0
  for si in ipairs(g.descs) do
    local vals = g.vals[si]
    if vals then
      for q = qh - POINTS + 1, qh do
        local v = vals[q]
        if v then
          v = math.abs(v)
          if v > max then max = v end
        end
      end
    end
  end
  return max
end

local function now_q(st)
  return game.tick / (tps(st) * GROUP)
end

local function full_draw(player, st, slot, g, n)
  destroy_graph_objects(g)
  local o = graph_origin(player.index, slot)
  local surface = graph_surface()
  local players = { player }
  local qh = math.floor(n / GROUP)
  g.base = qh - (POINTS - 1)
  compute_vals(st, g, qh - POINTS + 1, qh, n)

  local raw = window_max(g, qh)
  local steps = 6
  local step = nice_step(raw * 1.25 / (g.signed and steps / 2 or steps))
  local count = math.max(1, math.ceil(raw * 1.25 / step))
  g.ymax = step * count

  local x0, x1 = M_LEFT, g.w - M_RIGHT
  local y0, y1 = M_TOP, GRAPH_H - M_BOTTOM
  local function static(t, a, b, obj) g.statics[#g.statics + 1] = { t = t, a = a, b = b, obj = obj } end
  local P = { 0, 0 }

  -- Background as a sprite on a low layer: shapes (lines, rectangles) always draw
  -- above sprites, so a rectangle here would hide the line-end icons.
  static("text", { g.w / 2, GRAPH_H / 2 }, nil,
    rendering.draw_sprite { sprite = "pp-white", tint = CLR.GRAPH_BG, target = P, render_layer = "floor",
      x_scale = g.w / 8, y_scale = GRAPH_H / 8, surface = surface, players = players })

  local lo = g.signed and -count or 0
  for i = lo, count do
    local v = i * step
    local y = ypx(g, v)
    static("line", { x0, y }, { x1, y },
      rendering.draw_line { color = (g.signed and i == 0) and CLR.ZERO or CLR.GRID, width = 1, from = P, to = P, surface = surface, players = players })
    static("text", { x0 - 4, y }, nil,
      rendering.draw_text { text = (g.unit == "W" and fmt_power or axis_label)(v), color = CLR.LABEL, target = P, alignment = "right", vertical_alignment = "middle", scale = 0.8, surface = surface, players = players })
  end

  local scale = SCALE_BY_KEY[st.kind == "power" and "one_minute" or st.scale]
  local axis = scale.axis or 1000
  for i = 0, 10 do
    local x = x0 + (x1 - x0) * i / 10
    static("line", { x, y0 }, { x, y1 },
      rendering.draw_line { color = CLR.GRID, width = 1, from = P, to = P, surface = surface, players = players })
    local t = axis * (1 - i / 10)
    local txt = (t == math.floor(t)) and string.format("%d", t) or string.format("%.1f", t)
    static("text", { x, y1 + 4 }, nil,
      rendering.draw_text { text = txt, color = CLR.LABEL, target = P, alignment = "center", vertical_alignment = "top", scale = 0.8, surface = surface, players = players })
  end

  for si in ipairs(g.descs) do
    g.segs[si] = {}
    for q = qh - POINTS + 2, qh do draw_segment(g, o, si, q, surface, players) end
  end
  create_icons(st, g, surface, players)
  layout_icons(g, o, qh)
  g.head = n
  g.qhead = qh
  g.dirty = false
  place_statics(g, o, now_q(st))
end

local function incremental_draw(player, st, slot, g, n)
  local qh = math.floor(n / GROUP)
  if qh - g.base > 3000 then return full_draw(player, st, slot, g, n) end
  local o = graph_origin(player.index, slot)
  -- the point for the previous head's group may have changed too
  local start = math.max(g.qhead, qh - POINTS + 1)
  compute_vals(st, g, start, qh, n)

  -- growth: only the new values can push past the axis; shrink: full scan every 15th update
  local grew = false
  for si in ipairs(g.descs) do
    local vals = g.vals[si]
    if vals then
      for q = start, qh do
        local v = vals[q]
        if v and math.abs(v) > g.ymax then grew = true end
      end
    end
  end
  if grew then return full_draw(player, st, slot, g, n) end
  g.upd = (g.upd or 0) + 1
  if g.upd % 15 == 0 and window_max(g, qh) < g.ymax * 0.25 then return full_draw(player, st, slot, g, n) end

  local surface = graph_surface()
  local players = { player }
  local first_visible = qh - POINTS + 2
  for si in ipairs(g.descs) do
    local segs, vals = g.segs[si], g.vals[si]
    for q = g.qhead - POINTS - 1, first_visible - 1 do
      local obj = segs[q]
      if obj then
        if obj.valid then obj.destroy() end
        segs[q] = nil
      end
      if q < first_visible - 1 then vals[q] = nil end
    end
    for q = math.max(start, first_visible), qh do
      local obj = segs[q]
      local a, b = vals[q - 1], vals[q]
      if obj and obj.valid and a and b then
        -- move the existing segment instead of recreating it
        obj.from = { world_x(g, o, q - 1), o.y + ypx(g, a) * PX }
        obj.to = { world_x(g, o, q), o.y + ypx(g, b) * PX }
      else
        if obj and obj.valid then obj.destroy() end
        segs[q] = nil
        draw_segment(g, o, si, q, surface, players)
      end
    end
  end
  layout_icons(g, o, qh)
  g.head = n
  g.qhead = qh
end

-- Restyle every existing segment after a hover change.
local function apply_hover(st, key)
  st.hover = key
  for _, g in pairs(st.graphs) do
    if g.hover ~= key then
      g.hover = key
      for si, segs in pairs(g.segs or {}) do
        local color, width = seg_style(g, si)
        for _, obj in pairs(segs) do
          if obj.valid then
            obj.color = color
            obj.width = width
          end
        end
        local ic = g.icons and g.icons[si]
        if ic and ic.objs.lead.valid then ic.objs.lead.color = color end
      end
    end
  end
end

-- Called every tick for open windows: pans every 2 ticks, reads/draws on new samples.
-- New series load their 300-sample history a few per tick to avoid spikes.
local FULL_READS_PER_TICK = 1

local function needs_full_read(st, desc, n)
  if desc.custom then return false end
  local b = buffers(st)[desc.bkey]
  return not (b and b.head) or n - b.head >= SAMPLES - 2
end

local function graph_tick(player, st, force)
  if force == "open" then
    -- the list just did its full read this tick: draw empty graphs, load history from the next tick
    for _, g in pairs(st.graphs) do g.dirty = true end
    return
  end
  local n = math.floor(game.tick / tps(st))
  local any_dirty = false
  for _, g in pairs(st.graphs) do if g.dirty then any_dirty = true end end

  if force or any_dirty or st.graph_n ~= n then
    st.graph_n = n
    local stats = stats_list(player, st)
    local done, budget = {}, FULL_READS_PER_TICK
    for _, g in pairs(st.graphs) do
      for _, desc in ipairs(g.descs) do
        if not done[desc.bkey] then
          local full = needs_full_read(st, desc, n)
          if not full or budget > 0 then
            if full then budget = budget - 1 end
            read_buffer(st, stats, desc, n)
            done[desc.bkey] = true
          end
        end
      end
    end
    for slot, g in pairs(st.graphs) do
      if g.cam and g.cam.valid then
        local ready = true
        for _, desc in ipairs(g.descs) do
          if not done[desc.bkey] then ready = false break end
        end
        if ready then
          if g.dirty or not g.head or n < g.head then
            full_draw(player, st, slot, g, n)
          elseif n > g.head then
            incremental_draw(player, st, slot, g, n)
          end
        end
      end
    end
  end

  -- glide: move only when the graph has shifted by about a pixel
  local nq
  for slot, g in pairs(st.graphs) do
    if g.base and g.cam and g.cam.valid then
      if not g.pan_every then
        local ticks_per_point = tps(st) * GROUP
        g.pan_every = math.max(2, math.min(120, math.floor(ticks_per_point / gdx(g))))
      end
      if force or (game.tick + slot) % g.pan_every == 0 then
        nq = nq or now_q(st)
        place_statics(g, graph_origin(player.index, slot), nq)
      end
    end
  end
end

-- Set which rows a graph shows; marks it for a redraw if that changed.
local function set_series(st, slot, panel, rows_graphed)
  local g = st.graphs[slot]
  if not g then return end
  local descs, parts = {}, {}
  for i, r in ipairs(rows_graphed) do
    local bkey = r.merged and (r.name .. "|merged") or r.key
    descs[i] = { bkey = bkey, key = r.key, name = r.name, quality = r.quality, merged = r.merged }
    parts[i] = bkey
  end
  local sig = table.concat(parts, ",")
  if sig ~= g.sig then
    g.descs, g.sig, g.dirty, g.panel = descs, sig, true, panel
    g.hover = st.hover
  end
end

---------------------------------------------------------------------------
-- GUI building blocks
---------------------------------------------------------------------------

local HOT_ROWS = 20        -- rows per panel refreshed every LIST_INTERVAL
local LIST_INTERVAL = 10   -- ticks between hot-row refreshes
local FULL_INTERVAL = 60   -- ticks between full refreshes (re-sort, all rows)

local function window_mode(player)
  local s = settings.get_player_settings(player)["pp-window-mode"]
  return s and s.value or "plus"
end

local function toggle_button(parent, caption, tags, on, tooltip)
  local b = parent.add { type = "button", caption = caption, tags = tags, tooltip = tooltip }
  b.toggled = on
  b.style.minimal_width = 0
  return b
end

local function reset_sprite()
  if helpers.is_valid_sprite_path("utility/reset") then return "utility/reset" end
  return "utility/refresh"
end

local function quality_dropdown(parent, st, panel)
  if st.kind ~= "items" then return end
  local items = { { "production-plus.quality-separate" }, { "production-plus.quality-merged" } }
  local values = { "separate", "merged" }
  local sel = 1
  for name, q in pairs(prototypes.quality) do
    if not q.hidden then
      items[#items + 1] = { "", "[quality=" .. name .. "] ", q.localised_name }
      values[#values + 1] = name
    end
  end
  for i, v in ipairs(values) do if v == st.panels[panel].quality then sel = i end end
  parent.add { type = "drop-down", items = items, selected_index = sel, tags = { pp = "quality", panel = panel, values = values } }
end

local function icon_toggle(parent, sprite, tags, on, tooltip)
  local b = parent.add { type = "sprite-button", style = "tool_button", sprite = sprite, tags = tags, tooltip = tooltip }
  b.toggled = on
  return b
end

local function panel_header(parent, st, panel, title, no_flip)
  local p = st.panels[panel]
  local h = parent.add { type = "flow", direction = "horizontal" }
  h.style.vertical_align = "center"
  h.style.horizontal_spacing = 8
  h.style.padding = { 4, 8, 4, 12 }
  h.add { type = "label", caption = title, style = "caption_label" }
  local push = h.add { type = "empty-widget" }
  push.style.horizontally_stretchable = true
  icon_toggle(h, p.locked and "pp-lock" or "pp-unlock", { pp = "lock", panel = panel }, p.locked, { "production-plus.lock-tooltip" })
  if not no_flip then
    icon_toggle(h, "pp-flip", { pp = "flip", panel = panel }, p.flipped, { "production-plus.flip-tooltip" })
  end
  quality_dropdown(h, st, panel)
  h.add {
    type = "sprite-button", style = "tool_button_red", sprite = reset_sprite(),
    tooltip = { "production-plus.reset-tooltip" }, tags = { pp = "reset", panel = panel },
  }
end

local function add_camera(parent, player, st, slot, panel, width)
  width = width or GRAPH_W
  local o = graph_origin(player.index, slot)
  local cam = parent.add {
    type = "camera", name = "pp_cam_" .. slot,
    position = { o.x + width * PX / 2, o.y + GRAPH_H * PX / 2 },
    surface_index = graph_surface().index,
    zoom = CAMERA_ZOOM,
  }
  cam.style.width = width
  cam.style.height = GRAPH_H
  st.graphs[slot] = { cam = cam, w = width, panel = panel, signed = (panel == "net"), descs = {}, dirty = true,
    statics = {}, segs = {}, vals = {} }
  return cam
end

---------------------------------------------------------------------------
-- Cells. Each cell keeps a shadow of what it shows; writes happen only on change.
---------------------------------------------------------------------------

-- Common: icon identity (only when the row's item changes).
local function set_identity(sh, b, st, r, panel)
  if sh.key == r.key then return end
  sh.key = r.key
  local sprite = (st.kind == "items" and "item/" or "fluid/") .. r.name
  b.sprite = helpers.is_valid_sprite_path(sprite) and sprite or "utility/questionmark"
  b.quality = (r.quality and r.quality ~= "normal") and r.quality or nil
  b.tooltip = { "production-plus.cell-tooltip", display_name(st, r) }
  b.tags = { pp = "pick", panel = panel, key = r.key }
end

local function set_caption(sh, field, el, text)
  if sh[field] ~= text then sh[field] = text; el.caption = text end
end

local function set_font(sh, field, el, color, ci)
  if sh[field] ~= ci then sh[field] = ci; el.style.font_color = color end
end

local function color_index(row)
  if math.abs(row.net) < 0.05 or (row.p > EPS and math.abs(row.net / row.p) < 0.0005) then return 0 end
  return row.net < 0 and 1 or 2
end

-- Columns view cell: [icon w/ total] [bar] [rate]
local function new_cell(t)
  local box = t.add { type = "frame", style = "pp_cell" }
  local cell = box.add { type = "flow", direction = "horizontal" }
  cell.style.width = 270
  cell.style.height = 48
  cell.style.vertical_align = "center"
  cell.style.horizontal_spacing = 8
  cell.style.left_padding = 4
  local b = cell.add { type = "sprite-button", style = "slot_button", raise_hover_events = true }
  local bar = cell.add { type = "progressbar", value = 0 }
  bar.style.width = 110
  bar.style.color = CLR.BAR_IDLE
  local l = cell.add { type = "label" }
  l.style.width = 90
  l.style.horizontal_align = "right"
  return { el = box, b = b, bar = bar, l = l }
end


local function set_selected(sh, sel)
  if sh.sel == sel then return end
  sh.sel = sel
  sh.el.style = sel and "pp_cell_selected" or (sh.base or "pp_cell")
  sh.fc, sh.tfc = nil, nil -- force text colours to be re-applied
end

local function fill_cell(sh, st, r, panel, max, color_by_key, totals, hl)
  local b, bar, l = sh.b, sh.bar, sh.l
  set_identity(sh, b, st, r, panel)
  local sel = hl[r.key] == true
  set_selected(sh, sel)

  local v, count
  if panel == "production" then v, count = r.p, r.pn
  elseif panel == "consumption" then v, count = r.c, r.cn
  else v, count = r.net, r.nn end

  local ns = short(count)
  if sh.num ~= ns then sh.num = ns; b.number = count end

  local bv = max > 0 and math.min(math.abs(v) / max, 1) or 0
  bv = math.floor(bv * 200 + 0.5) / 200
  if sh.bv ~= bv then sh.bv = bv; bar.value = bv end

  local ci = color_by_key[r.key] or 0
  if sh.bc ~= ci then sh.bc = ci; bar.style.color = ci > 0 and LINE_COLORS[ci] or CLR.BAR_IDLE end

  local text
  if st.mode == "percent" then
    if panel == "production" then text = fmt_share(r.p, totals.p)
    elseif panel == "consumption" then text = fmt_share(r.c, totals.c)
    else text = fmt_net_percent(r) end
  else
    text = panel == "net" and fmt_net(r.net) or fmt_amount(v)
  end
  set_caption(sh, "cap", l, text)
  if sel then
    set_font(sh, "fc", l, CLR.SELECTED_TEXT, -1)
  elseif panel == "net" then
    local nci = color_index(r)
    set_font(sh, "fc", l, CLR.NET_COLORS[nci], nci)
  else
    set_font(sh, "fc", l, CLR.WHITE, 3)
  end
end

-- Table view row: [icon + name] [produced] [consumed] [net]
-- Table view geometry
-- Same footprint as the Columns view (3 x 556 px panels + 2 x 12 px gaps; header 36 + graph 200 + list 560).
local TG = {}   -- Table / Power view geometry (same footprint as the Columns view)
TG.TABLE_W, TG.TABLE_H = 1692, 796
TG.COL_NUM, TG.COL_PCT, TG.COL_BAR, TG.COL_GAP = 120, 90, 220, 12
TG.SCROLLBAR_W = 12
TG.ROW_LEFT_PAD, TG.ROW_RIGHT_PAD = 4, 14
-- table content width = pane width - pane padding (2 x 4) - scrollbar
TG.ROW_INNER_W = TG.TABLE_W - 8 - TG.SCROLLBAR_W - TG.ROW_LEFT_PAD - TG.ROW_RIGHT_PAD
TG.COL_ITEM = TG.ROW_INNER_W - (TG.COL_NUM * 3 + TG.COL_PCT + TG.COL_BAR) - 5 * TG.COL_GAP
TG.BAR_HALF = TG.COL_BAR / 2
TG.METER_ROOM = TG.BAR_HALF - 1   -- each side of the 2 px divider
-- table content width = pane width - pane padding (2 x 4) - scrollbar

-- Table view row: [icon swatch name] [produced] [consumed] [net] [net %] [deficit|surplus meter]
local function new_table_row(t)
  local box = t.add { type = "frame", style = "pp_row" }
  box.style.horizontally_stretchable = true
  local row = box.add { type = "flow", direction = "horizontal" }
  row.style.vertical_align = "center"
  row.style.horizontal_spacing = TG.COL_GAP
  row.style.left_padding = TG.ROW_LEFT_PAD
  row.style.right_padding = TG.ROW_RIGHT_PAD
  row.style.height = 48
  row.style.horizontally_stretchable = true
  local cell = row.add { type = "flow", direction = "horizontal" }
  cell.style.vertical_align = "center"
  cell.style.horizontal_spacing = 8
  cell.style.width = TG.COL_ITEM
  local b = cell.add { type = "sprite-button", style = "slot_button", raise_hover_events = true }
  local sw = cell.add { type = "progressbar", value = 1 }
  sw.style.width = 12
  sw.style.height = 4
  sw.style.bar_width = 4
  sw.visible = false
  local name = cell.add { type = "label" }
  local function num(w)
    local l = row.add { type = "label" }
    l.style.width = w
    l.style.horizontal_align = "right"
    return l
  end
  local l1, l2, l3, l4 = num(TG.COL_NUM), num(TG.COL_NUM), num(TG.COL_NUM), num(TG.COL_PCT)
  -- meter: [track-left][red][divider][green][track-right], all 13 px tall, centred together
  local meter = row.add { type = "flow", direction = "horizontal" }
  meter.style.width = TG.COL_BAR
  meter.style.horizontal_spacing = 0
  meter.style.vertical_align = "center"
  local tl = meter.add { type = "frame", style = "pp_track_left" }
  tl.style.width = TG.METER_ROOM
  local red = meter.add { type = "frame", style = "pp_pill_red" }
  red.visible = false
  meter.add { type = "frame", style = "pp_bar_mid" }
  local green = meter.add { type = "frame", style = "pp_pill_green" }
  green.visible = false
  local tr = meter.add { type = "frame", style = "pp_track_right" }
  tr.style.width = TG.METER_ROOM
  return { el = box, base = "pp_row", b = b, sw = sw, name = name, l1 = l1, l2 = l2, l3 = l3, l4 = l4,
    tl = tl, tr = tr, red = red, green = green }
end

local function fill_table_row(sh, st, r, max, color_by_key, totals, hl)
  local changed = sh.key ~= r.key
  set_identity(sh, sh.b, st, r, "net")
  local sel = hl[r.key] == true
  if sh.sel ~= sel then sh.nc = nil end
  set_selected(sh, sel)
  if changed then sh.name.caption = display_name(st, r) end

  local ns = short(r.nn)
  if sh.num ~= ns then sh.num = ns; sh.b.number = r.nn end

  -- colour swatch for graphed items
  local ci = color_by_key[r.key] or 0
  if sh.sc ~= ci then
    sh.sc = ci
    sh.sw.visible = ci > 0
    if ci > 0 then sh.sw.style.color = LINE_COLORS[ci] end
  end

  -- text colours
  if sh.nc ~= sel then
    sh.nc = sel
    local tc = sel and CLR.SELECTED_TEXT or CLR.WHITE
    sh.name.style.font_color = tc
    sh.l1.style.font_color = tc
    sh.l2.style.font_color = tc
    sh.l4.style.font_color = sel and CLR.SELECTED_TEXT or CLR.COLOR_GREY
  end

  if st.mode == "percent" then
    set_caption(sh, "c1", sh.l1, fmt_share(r.p, totals.p))
    set_caption(sh, "c2", sh.l2, fmt_share(r.c, totals.c))
  else
    set_caption(sh, "c1", sh.l1, fmt_amount(r.p))
    set_caption(sh, "c2", sh.l2, fmt_amount(r.c))
  end
  set_caption(sh, "c3", sh.l3, fmt_net(r.net))
  set_caption(sh, "c4", sh.l4, fmt_net_percent(r))
  if sel then
    set_font(sh, "fc", sh.l3, CLR.SELECTED_TEXT, -1)
  else
    local nci = color_index(r)
    set_font(sh, "fc", sh.l3, CLR.NET_COLORS[nci], nci)
  end

  -- deficit (left, red) | surplus (right, green), growing out of the divider
  local side = r.net < 0 and max.neg or max.pos
  local f = side > 0 and math.min(math.abs(r.net) / side, 1) or 0
  local w = math.floor(f * TG.METER_ROOM + 0.5)
  if w > 0 and w < 7 then w = 7 end                         -- smallest bar that keeps its round end
  if w > TG.METER_ROOM - 7 and w > 0 then w = TG.METER_ROOM end   -- don't leave a sliver of track
  local bkey = r.net < 0 and -w or w
  if sh.bk ~= bkey then
    sh.bk = bkey
    local wr = r.net < 0 and w or 0
    local wg = r.net > 0 and w or 0
    sh.red.visible = wr > 0
    if wr > 0 then
      sh.red.style = wr < TG.METER_ROOM and "pp_pill_red_inset" or "pp_pill_red"
      sh.red.style.width = wr
    end
    sh.tl.visible = TG.METER_ROOM - wr > 0
    if TG.METER_ROOM - wr > 0 then sh.tl.style.width = TG.METER_ROOM - wr end
    sh.green.visible = wg > 0
    if wg > 0 then
      sh.green.style = wg < TG.METER_ROOM and "pp_pill_green_inset" or "pp_pill_green"
      sh.green.style.width = wg
    end
    sh.tr.visible = TG.METER_ROOM - wg > 0
    if TG.METER_ROOM - wg > 0 then sh.tr.style.width = TG.METER_ROOM - wg end
  end
end

---------------------------------------------------------------------------
-- Views
---------------------------------------------------------------------------

local function build_panel(parent, player, st, panel, slot, title)
  local f = parent.add { type = "frame", name = "pp_panel_" .. panel, direction = "vertical", style = "inside_deep_frame" }
  panel_header(f, st, panel, title)
  add_camera(f, player, st, slot, panel)
  local sp = f.add { type = "scroll-pane", name = "pp_sp", style = "statistics_scroll_pane", vertical_scroll_policy = "auto-and-reserve-space", horizontal_scroll_policy = "never" }
  sp.style.height = 560
  local t = sp.add { type = "table", name = "pp_t", column_count = 2 }
  t.style.horizontal_spacing = 8
  t.style.vertical_spacing = 8
  st.views[slot] = { panel = panel, table = t, cells = {}, keys = {}, max = 0, kind = "cell" }
end

local TABLE_COLS = {
  { col = "item", key = "item", width = nil, align = "left" },
  { col = "p", key = "produced", width = TG.COL_NUM },
  { col = "c", key = "consumed", width = TG.COL_NUM },
  { col = "net", key = "net", width = TG.COL_NUM },
  { col = "pct", key = "net-percent", width = TG.COL_PCT },
}

local function build_table(parent, player, st)
  st.tsort = st.tsort or { col = "net", asc = true }
  local f = parent.add { type = "frame", name = "pp_panel_table", direction = "vertical", style = "inside_deep_frame" }
  f.style.width = TG.TABLE_W
  f.style.height = TG.TABLE_H
  panel_header(f, st, "net", { "production-plus.net" }, true)
  add_camera(f, player, st, 4, "net", TG.TABLE_W)

  local header = f.add { type = "flow", direction = "horizontal" }
  header.style.horizontal_spacing = TG.COL_GAP
  header.style.padding = { 8, 0, 4, 4 + TG.ROW_LEFT_PAD }
  header.style.height = 32
  header.style.horizontally_stretchable = true
  for _, c in ipairs(TABLE_COLS) do
    local active = st.tsort.col == c.col
    local arrow = active and (st.tsort.asc and " [img=pp-sort-asc]" or " [img=pp-sort-desc]") or ""
    local l = header.add {
      type = "label", style = "caption_label",
      caption = { "", { "production-plus." .. c.key }, arrow },
      tooltip = { "production-plus.sort-tooltip" },
      tags = { pp = "sort", col = c.col },
    }
    l.style.width = c.width or TG.COL_ITEM
    if c.width then l.style.horizontal_align = "right" end
    if not active then l.style.font_color = { 0.85, 0.85, 0.85 } end
  end
  local mh = header.add { type = "flow", direction = "horizontal" }
  mh.style.width = TG.COL_BAR
  mh.style.horizontal_spacing = 0
  local function hl(caption, width, align)
    local l = mh.add { type = "label", caption = caption, style = "caption_label" }
    l.style.width = width
    l.style.horizontal_align = align
    l.style.font_color = { 0.85, 0.85, 0.85 }
  end
  hl({ "production-plus.deficit" }, TG.METER_ROOM - 4, "right")
  hl("|", 10, "center")                      -- centred on the meter's divider
  hl({ "production-plus.surplus" }, TG.METER_ROOM - 4, "left")

  local sp = f.add { type = "scroll-pane", style = "pp_table_scroll", vertical_scroll_policy = "auto-and-reserve-space", horizontal_scroll_policy = "never" }
  sp.style.height = TG.TABLE_H - 36 - 200 - 32
  sp.style.width = TG.TABLE_W
  local t = sp.add { type = "table", column_count = 1 }
  t.style.vertical_spacing = 8
  t.style.horizontally_stretchable = true
  st.views[4] = { panel = "net", table = t, cells = {}, keys = {}, max = 0, kind = "row" }
end

-- Render rows [1..limit] of a view from its key list.
-- Render rows [from..limit] of a view. New rows cost the most, so at most `budget.n`
-- are created per tick; the rest are added on the following ticks (view.pending).
local function render_view(st, view, by_key, limit, from, budget)
  local panel = view.panel
  local totals = view.totals
  local color_by_key = view.colors
  local cells = view.cells
  local hl = view.hl
  local maxes = view.kind == "row" and view.maxes
  local n = #view.keys
  local upto = math.min(limit or n, n)
  view.pending = nil
  for i = from or 1, upto do
    local key = view.keys[i]
    local r = by_key[key] or zero_row(key, st.kind)
    local sh = cells[i]
    if not sh then
      if budget then
        if budget.n <= 0 then view.pending = true break end
        budget.n = budget.n - 1
      end
      sh = view.kind == "cell" and new_cell(view.table) or new_table_row(view.table)
      cells[i] = sh
    end
    if view.kind == "cell" then
      fill_cell(sh, st, r, panel, view.max, color_by_key, totals, hl)
    else
      fill_table_row(sh, st, r, maxes, color_by_key, totals, hl)
    end
  end
end

local function drop_extra_cells(view)
  local cells = view.cells
  for i = #cells, #view.keys + 1, -1 do
    if cells[i].el.valid then cells[i].el.destroy() end
    cells[i] = nil
  end
end

local function by_key_of(rows)
  local m = {}
  for _, r in ipairs(rows) do m[r.key] = r end
  return m
end

local function totals_of(rows)
  local t = { p = 0, c = 0 }
  for _, r in ipairs(rows) do t.p = t.p + r.p; t.c = t.c + r.c end
  return t
end

---------------------------------------------------------------------------
-- Refresh: full (re-read everything, re-sort, all rows) or hot (top rows only)
---------------------------------------------------------------------------

local SLICES = 6              -- every row is re-read once per SLICES * LIST_INTERVAL ticks
local DISCOVER_INTERVAL = 600 -- look for newly produced items every 10 s
local CREATE_PER_TICK = 40    -- new list rows per tick (spreads the cost of opening)

-- Raw keys behind the top rows of every view (merged rows expand to all their qualities).
local function hot_raw_keys(st)
  local set = {}
  local by_name
  for _, view in pairs(st.views) do
    for i = 1, math.min(HOT_ROWS, #view.keys) do
      local key = view.keys[i]
      if st.raw_map[key] then
        set[key] = true
      else
        local name = key:match("^(.*)|%*$")
        if name then
          if not by_name then
            by_name = {}
            for _, r in ipairs(st.raw_list) do
              local t = by_name[r.name]
              if not t then t = {}; by_name[r.name] = t end
              t[#t + 1] = r.key
            end
          end
          for _, k in ipairs(by_name[name] or {}) do set[k] = true end
        end
      end
    end
  end
  return set
end

-- Add rows for items that started being produced/consumed since the last look.
local function discover_keys(st, stats)
  local map, list = st.raw_map, st.raw_list
  local function add(n, q)
    local k = row_key(n, q)
    if map[k] then return end
    local proto = st.kind == "items" and prototypes.item[n] or prototypes.fluid[n]
    if not proto then return end
    local r = { name = n, quality = q, key = k, pn = 0, cn = 0, p = 0, c = 0, net = 0, nn = 0 }
    map[k] = r
    list[#list + 1] = r
    st.fresh = st.fresh or {}
    st.fresh[k] = true
  end
  for _, s in ipairs(stats) do
    if st.kind == "items" then
      for _, counts in ipairs({ s.input_quality_counts, s.output_quality_counts }) do
        for q, names in pairs(counts) do
          for n in pairs(names) do add(n, q) end
        end
      end
    else
      for _, counts in ipairs({ s.input_counts, s.output_counts }) do
        for n in pairs(counts) do add(n, nil) end
      end
    end
  end
end

-- Rows for one view, cached per quality filter for the duration of one refresh.
local function view_rows(st, pstate, cache)
  local q = st.kind == "items" and pstate.quality or "separate"
  local c = cache[q]
  if not c then
    local rows = apply_quality(st.raw_list, q, st.kind)
    c = { rows = rows, by_key = (rows == st.raw_list) and st.raw_map or by_key_of(rows) }
    cache[q] = c
  end
  return c
end

-- mode: "full"  re-read everything, re-sort, render every row (open / clicks)
--       "sort"  re-sort and render every row from the values read so far (every 60 ticks)
--       "hot"   re-read the top rows plus one slice of the rest, render the top rows (every 10 ticks)
local function refresh(player, mode)
  if mode == true then mode = "full" elseif mode == false or mode == nil then mode = "hot" end
  local st = get_state(player.index)
  if not next(st.views) then return end
  local stats = stats_list(player, st)

  if mode == "full" or not st.raw_list then
    st.raw_list = collect(player, st, stats)
    st.raw_map = by_key_of(st.raw_list)
    st.slice, st.discovered, st.fresh = 0, game.tick, nil
    mode = "full"
  else
    local set = hot_raw_keys(st)
    st.slice = ((st.slice or 0) + 1) % SLICES
    local list = st.raw_list
    for i = st.slice + 1, #list, SLICES do set[list[i].key] = true end
    if st.fresh then
      for k in pairs(st.fresh) do set[k] = true end
      st.fresh = nil
    end
    reread(st, stats, set)
    if mode == "sort" and game.tick - (st.discovered or 0) >= DISCOVER_INTERVAL then
      discover_keys(st, stats)
      st.discovered = game.tick
    end
  end

  local resort = mode ~= "hot"
  local searching = resort and st.search and st.search ~= ""
  local percent = st.mode == "percent"
  local cache = {}
  local budget = { n = CREATE_PER_TICK }
  for slot, view in pairs(st.views) do
    local pstate = st.panels[view.panel]
    local c = view_rows(st, pstate, cache)
    local prows, by_key = c.rows, c.by_key
    if percent then
      if not c.totals then c.totals = totals_of(prows) end
      view.totals = c.totals
    else
      view.totals = view.totals or { p = 0, c = 0 }
    end
    view.by_key = by_key
    if resort or not view.colors then
      if searching then
        local kept = {}
        for _, r in ipairs(prows) do
          if matches_search(player.index, st, r.name) then kept[#kept + 1] = r end
        end
        prows = kept
      end
      st.pins = st.pins or {}
      local pins = st.pins[st.kind]
      if searching and pins then
        local kept = {}
        for _, k in ipairs(pins) do
          if matches_search(player.index, st, k:match("^(.*)|[^|]*$")) then kept[#kept + 1] = k end
        end
        pins = kept
      end
      local list, pinned = order_list(view.panel, prows, pstate, st.kind, pins,
        view.kind == "row" and table_sorter(st) or nil)
      view.pinned = pinned
      local hl = {}
      for k in pairs(pinned) do hl[k] = true end
      if pstate.picks and #pstate.picks == 1 then hl[pstate.picks[1]] = true end
      view.hl = hl
      local g = graphed(pstate, list)
      view.colors = {}
      for i, r in ipairs(g) do view.colors[r.key] = i end
      set_series(st, slot, view.panel, g)
      local keys, max = {}, 0
      for i, r in ipairs(list) do
        keys[i] = r.key
        local v = view.panel == "production" and r.p or view.panel == "consumption" and r.c or math.abs(r.net)
        if v > max then max = v end
      end
      view.keys, view.max = keys, max
      view.maxes = { neg = max, pos = max }
      -- top rows now; the rest catch up over the next ticks (continue_views)
      render_view(st, view, by_key, math.min(HOT_ROWS, #keys), 1, budget)
      view.cursor = view.pending and (#view.cells + 1) or (HOT_ROWS + 1)
      if view.cursor > #keys then view.cursor = nil; drop_extra_cells(view) end
    else
      render_view(st, view, by_key, HOT_ROWS)
    end
  end
end

-- After a re-sort, update (and create) the remaining rows a chunk per tick.
local UPDATE_PER_TICK = 120
local function continue_views(st)
  local budget
  for _, view in pairs(st.views) do
    if view.cursor and view.by_key then
      budget = budget or { n = CREATE_PER_TICK }
      local from = view.cursor
      local upto = math.min(#view.keys, from + UPDATE_PER_TICK - 1)
      render_view(st, view, view.by_key, upto, from, budget)
      view.cursor = view.pending and (#view.cells + 1) or (upto + 1)
      if view.cursor > #view.keys then
        view.cursor = nil
        drop_extra_cells(view)
      end
    end
  end
end

local build_window   -- defined in the Window section

---------------------------------------------------------------------------
-- Power tab: every electric network on the surface in one list
---------------------------------------------------------------------------

local PW = {}   -- Power tab settings
PW.SCAN_INTERVAL = 3600      -- rescan networks every 60 s while the tab is open
PW.POLES_PER_TICK = 400      -- the scan is spread over ticks
PW.SLOT = 5
PW.ALL = "__all__"
PW.MINIMAP = 200
PW.NUM, PW.SAT, PW.STORE, PW.CHARGE, PW.EMPTY, PW.BTNS = 120, 110, 150, 180, 90, 96
PW.NAME = TG.ROW_INNER_W - (PW.NUM * 2 + PW.SAT + PW.STORE + PW.CHARGE + PW.EMPTY + PW.BTNS) - 7 * TG.COL_GAP
PW.FORMAT = 3                -- bump when the saved network data changes shape
PW.COMPASS = { "E", "SE", "S", "SW", "W", "NW", "N", "NE" }
PW.CLUSTER_CELL = 32         -- tiles; entities in touching cells form one cluster
PW.OUTLINE_TTL = 600
PW.CACHE_TICKS = 12          -- network statistics are read at most once per graph sample
PW.LIST_INTERVAL = 30        -- ticks between Power list refreshes



local function power_state(st)
  st.power = st.power or {}
  local ps = st.power
  if ps.format ~= PW.FORMAT then
    -- data from an older build: drop the network list and scan again (names are kept)
    ps.nets, ps.scan, ps.scan_started, ps.sel, ps.renaming = {}, nil, nil, nil, nil
    ps.hist, ps.rate = {}, {}
    ps.format = PW.FORMAT
  end
  ps.nets = ps.nets or {}
  ps.names = ps.names or {}
  ps.hist = ps.hist or {}
  ps.rate = ps.rate or {}
  return ps
end

local function power_surfaces(player, st)
  if st.surface == UNIVERSE then
    local list = {}
    for _, s in pairs(game.surfaces) do
      if s.valid and s.name ~= GRAPH_SURFACE then list[#list + 1] = s end
    end
    return list
  end
  return { resolve_surface(player, st) }
end

local function start_power_scan(player, st)
  local ps = power_state(st)
  local poles = {}
  for _, s in ipairs(power_surfaces(player, st)) do
    for _, p in ipairs(s.find_entities_filtered { type = "electric-pole", force = player.force }) do
      poles[#poles + 1] = p
    end
  end
  ps.scan = { poles = poles, i = 1, sub = {}, found = {} }
  ps.scan_started = game.tick
end

-- Entity names that produce / consume on a network, biggest first (from its statistics).
local function flow_names(net)
  local prod, cons = {}, {}
  local ok = pcall(function()
    for name, v in pairs(net.statistics.output_counts) do prod[#prod + 1] = { name, v } end
    for name, v in pairs(net.statistics.input_counts) do cons[#cons + 1] = { name, v } end
  end)
  if not ok then return {}, {} end
  local function names(list)
    table.sort(list, function(a, b) return a[2] > b[2] end)
    local out = {}
    for i, e in ipairs(list) do out[i] = e[1] end
    return out
  end
  return names(prod), names(cons)
end

local function power_scan_step(st)
  local ps = st.power
  local sc = ps and ps.scan
  if not sc then return end
  local poles = sc.poles
  local last = math.min(#poles, sc.i + PW.POLES_PER_TICK - 1)
  for k = sc.i, last do
    local p = poles[k]
    if p.valid then
      local id = p.electric_network_id
      if id then
        local f = sc.sub[id]
        if not f then
          local sub = p.electric_network
          local net = sub and sub.valid and sub.parent_network
          if net and net.valid then
            local key = id
            for _, s2 in ipairs(net.sub_networks) do if s2.id < key then key = s2.id end end
            f = { key = tostring(key), net = net, surface = p.surface.index, subs = {} }
            sc.found[#sc.found + 1] = f
            for _, s2 in ipairs(net.sub_networks) do sc.sub[s2.id] = f; f.subs[s2.id] = true end
            f.subs[id] = true
            sc.sub[id] = f
          end
        end
        if f then
          -- bounding box of the network's poles
          local pos = p.position
          if not f.x1 then
            f.x1, f.y1, f.x2, f.y2 = pos.x, pos.y, pos.x, pos.y
          else
            if pos.x < f.x1 then f.x1 = pos.x end
            if pos.y < f.y1 then f.y1 = pos.y end
            if pos.x > f.x2 then f.x2 = pos.x end
            if pos.y > f.y2 then f.y2 = pos.y end
          end
        end
      end
    end
  end
  sc.i = last + 1
  if sc.i > #poles then
    for _, f in ipairs(sc.found) do
      f.prod_names, f.cons_names = flow_names(f.net)
      f.cx, f.cy = (f.x1 + f.x2) / 2, (f.y1 + f.y2) / 2
    end
    ps.nets = sc.found
    ps.scan = nil
  end
end

local function find_net(ps, key)
  for _, n in ipairs(ps.nets) do
    if n.key == key then return n end
  end
end

-- Actual production / consumption in watts: the network's own statistics over the
-- last 5 s (same data as vanilla's power window). Cached per tick.
local function power_values(n)
  if n.vt and game.tick - n.vt < PW.CACHE_TICKS then return n.vp, n.vd, n.vs, n.ve, n.vc end
  local net = n.net
  local stats = net.statistics
  local idx = defines.flow_precision_index.five_seconds
  local p, d = 0, 0
  for _, name in ipairs(n.prod_names or {}) do
    p = p + stats.get_flow_count { name = name, category = "output", precision_index = idx, count = true }
  end
  for _, name in ipairs(n.cons_names or {}) do
    d = d + stats.get_flow_count { name = name, category = "input", precision_index = idx, count = true }
  end
  p, d = p / 5, d / 5
  local f = net.flow_last_tick
  local sat = nil
  if d > 0 then
    sat = f.consumption_satisfaction or 1
    if sat > 1.0001 then sat = sat / 100 end
  end
  n.vt, n.vp, n.vd, n.vs, n.ve, n.vc = game.tick, p, d, sat, f.accumulator_energy or 0, f.accumulator_capacity or 0
  return p, d, sat, n.ve, n.vc
end

power_sample = function(st, desc)
  local ps = st.power
  if not ps then return { 0, 0 } end
  local p, d = 0, 0
  for _, n in ipairs(ps.nets) do
    if n.net.valid and (desc.net_key == PW.ALL or n.key == desc.net_key) then
      local np, nd = power_values(n)
      p, d = p + np, d + nd
    end
  end
  return { p, d }
end


local function net_place(player, n)
  if not n.cx then return { "production-plus.net-unknown" } end
  local ok, spawn = pcall(function() return player.force.get_spawn_position(game.surfaces[n.surface]) end)
  spawn = ok and spawn or { x = 0, y = 0 }
  local dx, dy = n.cx - spawn.x, n.cy - spawn.y
  local dist = math.sqrt(dx * dx + dy * dy)
  if dist < 64 then return { "production-plus.net-spawn" } end
  local a = (math.atan2 or math.atan)(dy, dx)   -- y grows south
  local i = math.floor((a / (2 * math.pi)) * 8 + 0.5) % 8 + 1
  local d = dist >= 1000 and string.format("%.1f km", dist / 1000) or string.format("%d m", math.floor(dist / 10 + 0.5) * 10)
  return PW.COMPASS[i] .. " · " .. d
end

local function net_icons(n)
  local parts = {}
  local p = n.prod_names and n.prod_names[1]
  local c = n.cons_names and n.cons_names[1]
  if p and prototypes.entity[p] then parts[#parts + 1] = "[entity=" .. p .. "]" end
  if c and prototypes.entity[c] then
    if #parts > 0 then parts[#parts + 1] = " → " end
    parts[#parts + 1] = "[entity=" .. c .. "]"
  end
  return table.concat(parts)
end

local function net_label(player, ps, n)
  local place = ps.names[n.key] or net_place(player, n)
  local icons = net_icons(n)
  if icons == "" then return place end
  return { "", place, "    ", icons }
end

local function pick_sprite(...)
  for _, p in ipairs({ ... }) do
    if helpers.is_valid_sprite_path(p) then return p end
  end
  return "utility/questionmark"
end

-- Charge meter: [fill (round left)][track (round right)], or a full / empty piece.
local function set_charge(sh, f)
  local key = f and math.floor(f * 200 + 0.5) or -1
  if sh.ck == key then return end
  sh.ck = key
  if not f then
    sh.fill.visible = false
    sh.track.visible = true
    sh.track.style = "pp_track_full"
    sh.track.style.width = PW.CHARGE
    return
  end
  local w = math.floor(f * PW.CHARGE + 0.5)
  if w > 0 and w < 7 then w = 7 end
  if w >= PW.CHARGE - 6 then w = PW.CHARGE end
  local low = f < 0.2
  sh.fill.visible = w > 0
  if w > 0 then
    if w == PW.CHARGE then
      sh.fill.style = low and "pp_fill_red_full" or "pp_fill_green_full"
    else
      sh.fill.style = low and "pp_fill_red" or "pp_fill_green"
    end
    sh.fill.style.width = w
  end
  sh.track.visible = w < PW.CHARGE
  if w < PW.CHARGE then
    sh.track.style = w == 0 and "pp_track_full" or "pp_track_right"
    sh.track.style.width = PW.CHARGE - w
  end
end

local function new_power_row(t)
  local box = t.add { type = "frame", style = "pp_row" }
  box.style.horizontally_stretchable = true
  local row = box.add { type = "flow", direction = "horizontal" }
  row.style.vertical_align = "center"
  row.style.horizontal_spacing = TG.COL_GAP
  row.style.left_padding = TG.ROW_LEFT_PAD
  row.style.right_padding = TG.ROW_RIGHT_PAD
  row.style.height = 48
  local cell = row.add { type = "flow", direction = "horizontal" }
  cell.style.width = PW.NAME
  cell.style.vertical_align = "center"
  local name = cell.add { type = "label" }
  name.style.font = "default-bold"
  name.style.maximal_width = PW.NAME
  local function num(w)
    local l = row.add { type = "label" }
    l.style.width = w
    l.style.horizontal_align = "right"
    return l
  end
  local lp, ld, ls, le = num(PW.NUM), num(PW.NUM), num(PW.SAT), num(PW.STORE)
  local meter = row.add { type = "flow", direction = "horizontal" }
  meter.style.width = PW.CHARGE
  meter.style.horizontal_spacing = 0
  meter.style.vertical_align = "center"
  local fill = meter.add { type = "frame", style = "pp_fill_green" }
  fill.visible = false
  local track = meter.add { type = "frame", style = "pp_track_full" }
  track.style.width = PW.CHARGE
  local lt = num(PW.EMPTY)
  local btns = row.add { type = "flow", direction = "horizontal" }
  btns.style.width = PW.BTNS
  btns.style.horizontal_spacing = 4
  local mp = btns.add { type = "sprite-button", style = "tool_button", tooltip = { "production-plus.net-producers-tooltip" } }
  local mc = btns.add { type = "sprite-button", style = "tool_button", tooltip = { "production-plus.net-consumers-tooltip" } }
  local ren = btns.add { type = "sprite-button", style = "tool_button",
    sprite = pick_sprite("utility/rename_icon", "utility/rename_icon_small_white", "utility/edit"), tooltip = { "production-plus.net-rename-tooltip" } }
  -- everything except the two buttons selects the row
  local clickable = { box, row, cell, name, lp, ld, ls, le, meter, fill, track, lt, btns }
  return { el = box, base = "pp_row", cell = cell, name = name, lp = lp, ld = ld, ls = ls, le = le, lt = lt,
    fill = fill, track = track, mp = mp, mc = mc, ren = ren, clickable = clickable }
end

local function fill_power_row(player, sh, st, r, sel)
  local ps = st.power
  local key = r.n.key
  if sh.key ~= key then
    sh.key = key
    for _, el in ipairs(sh.clickable) do
      if el.valid then el.tags = { pp = "net_sel", key = key } end
    end
    sh.mp.tags = { pp = "net_find", key = key, what = "producers" }
    sh.mc.tags = { pp = "net_find", key = key, what = "consumers" }
    sh.ren.tags = { pp = "net_rename", key = key }
    sh.label = nil
  end
  local pn = r.n.prod_names and r.n.prod_names[1]
  local cn = r.n.cons_names and r.n.cons_names[1]
  local ikey = tostring(pn) .. "|" .. tostring(cn)
  if sh.ikey ~= ikey then
    sh.ikey = ikey
    sh.mp.sprite = pick_sprite(pn and ("entity/" .. pn) or "", "item/steam-engine", "utility/map")
    sh.mc.sprite = pick_sprite(cn and ("entity/" .. cn) or "", "item/small-electric-pole", "utility/map")
  end
  -- rename field
  if ps.renaming == key then
    if not (sh.tf and sh.tf.valid) then
      sh.name.visible = false
      sh.tf = sh.cell.add { type = "textfield", text = ps.names[key] or "", tags = { pp = "net_name", key = key } }
      sh.tf.style.width = PW.NAME - 20
      sh.tf.focus()
    end
  elseif sh.tf then
    if sh.tf.valid then sh.tf.destroy() end
    sh.tf = nil
    sh.name.visible = true
    sh.label = nil
  end
  local lkey = (ps.names[key] or "") .. "|" .. tostring(r.n.cx) .. "|" .. tostring(r.n.prod_names and r.n.prod_names[1]) .. "|" .. tostring(r.n.cons_names and r.n.cons_names[1])
  if sh.label ~= lkey then
    sh.label = lkey
    local label = net_label(player, ps, r.n)
    sh.name.caption = label
    local tip = { "production-plus.net-select-tooltip", label }
    for _, el in ipairs(sh.clickable) do
      if el.valid then el.tooltip = tip end
    end
  end

  if sh.sel ~= sel then
    sh.sel = sel
    sh.el.style = sel and "pp_cell_selected" or "pp_row"
    local tc = sel and CLR.SELECTED_TEXT or CLR.WHITE
    for _, l in ipairs({ sh.name, sh.lp, sh.ld, sh.le }) do l.style.font_color = tc end
    sh.fc, sh.tc = nil, nil
  end
  set_caption(sh, "c1", sh.lp, fmt_power(r.p))
  set_caption(sh, "c2", sh.ld, fmt_power(r.d))
  set_caption(sh, "c3", sh.ls, r.sat and string.format("%.1f%%", r.sat * 100) or "—")
  local sci = sel and -1 or (r.sat == nil and 0 or (r.sat < 0.995 and 1 or 2))
  set_font(sh, "fc", sh.ls, sci == -1 and CLR.SELECTED_TEXT or CLR.NET_COLORS[sci], sci)
  set_caption(sh, "c4", sh.le, r.cap > 0 and fmt_energy(r.e) or "—")
  set_charge(sh, r.cap > 0 and math.min(r.e / r.cap, 1) or nil)
  set_caption(sh, "c5", sh.lt, r.tte and fmt_duration(r.tte) or "—")
  local tci = sel and -1 or ((r.tte and r.tte < 600) and 1 or 0)
  set_font(sh, "tc", sh.lt, tci == -1 and CLR.SELECTED_TEXT or CLR.NET_COLORS[tci], tci)
end

-- Rows for every network; idle ones (no production, no demand) are split off.
local function power_rows(st)
  local ps = st.power
  local rows, idle = {}, 0
  for i, n in ipairs(ps.nets) do
    if n.net.valid then
      local p, d, sat, e, cap = power_values(n)
      local h = ps.hist[n.key]
      if not h or game.tick - h.t >= 60 then
        if h and game.tick > h.t then ps.rate[n.key] = (e - h.e) / ((game.tick - h.t) / 60) end
        ps.hist[n.key] = { e = e, t = game.tick }
      end
      local rate = ps.rate[n.key] or 0
      local tte = (rate < -1 and e > 0) and (e / -rate) or nil
      local is_idle = p < 1 and d < 1 and cap == 0
      if is_idle then idle = idle + 1 end
      if not is_idle or ps.show_idle then
        rows[#rows + 1] = { n = n, idx = i, p = p, d = d, sat = sat, e = e, cap = cap, tte = tte, idle = is_idle,
          bad = (sat ~= nil and sat < 0.995) or (tte ~= nil and tte < 600) }
      end
    end
  end
  table.sort(rows, function(a, b)
    if a.idle ~= b.idle then return b.idle end
    if a.bad ~= b.bad then return a.bad end
    if a.d ~= b.d then return a.d > b.d end
    return a.n.key < b.n.key
  end)
  return rows, idle
end

local function power_refresh(player, st)
  local pv = st.power_view
  if not (pv and pv.table and pv.table.valid) then return end
  if not pv.idle then
    -- window built by an older version of the mod: rebuild it
    st.power_view = nil
    build_window(player)
    return
  end
  local ps = power_state(st)
  if ps.sel and not find_net(ps, ps.sel) and not ps.scan then ps.sel = nil end
  local rows, idle = power_rows(st)

  -- graph: production vs demand of the selected network, or of all networks
  local g = st.graphs[PW.SLOT]
  if g then
    local key = ps.sel or PW.ALL
    local sig = "power|" .. key
    if g.sig ~= sig then
      g.descs = {
        { custom = true, bkey = sig .. "|p", key = sig .. "|p", net_key = key, field = 1,
          sprite = pick_sprite("item/steam-engine", "item/solar-panel") },
        { custom = true, bkey = sig .. "|d", key = sig .. "|d", net_key = key, field = 2,
          sprite = pick_sprite("item/small-electric-pole", "item/medium-electric-pole") },
      }
      g.sig, g.dirty, g.panel = sig, true, "power"
    end
  end

  -- list
  local cells = pv.rows
  for i, r in ipairs(rows) do
    local sh = cells[i]
    if not sh then sh = new_power_row(pv.table); cells[i] = sh end
    fill_power_row(player, sh, st, r, r.n.key == ps.sel)
  end
  for i = #cells, #rows + 1, -1 do
    if cells[i].el.valid then cells[i].el.destroy() end
    cells[i] = nil
  end

  -- header status: count, idle toggle, graph caption
  if pv.status and pv.status.valid then
    local scanning = ps.scan ~= nil
    local skey = tostring(scanning) .. "|" .. #rows .. "|" .. idle .. "|" .. tostring(ps.show_idle)
    if pv.skey ~= skey then
      pv.skey = skey
      pv.status.caption = scanning and { "production-plus.power-scanning" }
        or { "production-plus.power-count", #rows - (ps.show_idle and idle or 0) }
      if pv.idle and pv.idle.valid then
        pv.idle.visible = idle > 0
        pv.idle.caption = ps.show_idle and { "production-plus.power-idle-hide", idle } or { "production-plus.power-idle-show", idle }
      end
    end
  end
  if pv.gcap and pv.gcap.valid then
    local n = ps.sel and find_net(ps, ps.sel)
    local ckey = n and ("n" .. n.key .. (ps.names[n.key] or "")) or "all"
    if pv.ckey ~= ckey then
      pv.ckey = ckey
      pv.gcap.caption = n and { "production-plus.power-graph-one", net_label(player, ps, n) } or { "production-plus.power-graph-all" }
    end
  end
end

-- Map button: centre and zoom on the network, outline it for 10 s (only for you).
local function show_net_on_map(player, st, key)
  local ps = power_state(st)
  local n = find_net(ps, key)
  if not (n and n.x1) then return end
  local surface = game.surfaces[n.surface]
  pcall(function()
    player.set_controller { type = defines.controllers.remote, position = { n.cx, n.cy }, surface = surface }
  end)
  pcall(function()
    local res = player.display_resolution
    local w, h = (n.x2 - n.x1) + 40, (n.y2 - n.y1) + 40
    local z = math.min(res.width / (32 * w), res.height / (32 * h))
    player.zoom = math.max(0.05, math.min(1, z))
  end)
  local color = { 1, 0.78, 0.35 }
  local lt, rb = { n.x1 - 3, n.y1 - 3 }, { n.x2 + 3, n.y2 + 3 }
  for _, mode in ipairs({ "game", "chart" }) do
    pcall(function()
      rendering.draw_rectangle { color = color, width = 4, filled = false, left_top = lt, right_bottom = rb,
        surface = surface, players = { player }, time_to_live = 600, render_mode = mode }
      rendering.draw_text { text = net_label(player, ps, n), color = color, target = { n.x1 - 3, n.y1 - 6 },
        scale = 4, surface = surface, players = { player }, time_to_live = 600, render_mode = mode, scale_with_zoom = true }
    end)
  end
end

-- Producer / consumer buttons: find that network's producers (or consumers) in its area,
-- group them into clusters, outline every cluster for 10 s and centre on one.
-- Clicking the same button again moves to the next cluster. Runs only on click.

local function find_clusters(player, n, what)
  local names = {}
  for _, name in ipairs((what == "producers" and n.prod_names or n.cons_names) or {}) do
    if prototypes.entity[name] then names[#names + 1] = name end
  end
  if #names == 0 or not n.x1 then return {} end
  local surface = game.surfaces[n.surface]
  local found = surface.find_entities_filtered {
    area = { { n.x1 - 16, n.y1 - 16 }, { n.x2 + 16, n.y2 + 16 } }, name = names, force = player.force,
  }
  -- bucket by cell
  local cells = {}
  for _, e in ipairs(found) do
    local id = e.electric_network_id
    if id and n.subs and n.subs[id] then
      local bb = e.bounding_box
      local cx, cy = math.floor(e.position.x / PW.CLUSTER_CELL), math.floor(e.position.y / PW.CLUSTER_CELL)
      local k = cx .. "," .. cy
      local c = cells[k]
      if not c then c = { x = cx, y = cy, list = {} }; cells[k] = c end
      c.list[#c.list + 1] = bb
    end
  end
  -- flood-fill touching cells into clusters
  local clusters, seen = {}, {}
  for k, c in pairs(cells) do
    if not seen[k] then
      local cl = { count = 0 }
      local stack = { c }
      seen[k] = true
      while #stack > 0 do
        local cur = table.remove(stack)
        for _, bb in ipairs(cur.list) do
          cl.count = cl.count + 1
          local lt, rb = bb.left_top, bb.right_bottom
          if not cl.x1 then
            cl.x1, cl.y1, cl.x2, cl.y2 = lt.x, lt.y, rb.x, rb.y
          else
            cl.x1, cl.y1 = math.min(cl.x1, lt.x), math.min(cl.y1, lt.y)
            cl.x2, cl.y2 = math.max(cl.x2, rb.x), math.max(cl.y2, rb.y)
          end
        end
        for dx = -1, 1 do
          for dy = -1, 1 do
            local nk = (cur.x + dx) .. "," .. (cur.y + dy)
            if cells[nk] and not seen[nk] then
              seen[nk] = true
              stack[#stack + 1] = cells[nk]
            end
          end
        end
      end
      clusters[#clusters + 1] = cl
    end
  end
  table.sort(clusters, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    if a.x1 ~= b.x1 then return a.x1 < b.x1 end
    return a.y1 < b.y1
  end)
  return clusters
end

local function show_cluster_on_map(player, st, key, what)
  local ps = power_state(st)
  local n = find_net(ps, key)
  if not n then return end
  local clusters = find_clusters(player, n, what)
  if #clusters == 0 then
    player.print { "production-plus.net-none-found", { "production-plus.net-" .. what } }
    return
  end
  -- step through clusters on repeated clicks
  ps.cycle = ps.cycle or {}
  local ck = key .. "|" .. what
  local i = ((ps.cycle[ck] or 0) % #clusters) + 1
  ps.cycle[ck] = i
  local cur = clusters[i]
  local surface = game.surfaces[n.surface]

  -- clear the previous outlines
  for _, obj in ipairs(ps.outlines or {}) do if obj.valid then obj.destroy() end end
  ps.outlines = {}
  local color = what == "producers" and { 1, 0.6, 0.2 } or { 0.35, 0.65, 1 }
  local function keep(obj) ps.outlines[#ps.outlines + 1] = obj end
  for ci, cl in ipairs(clusters) do
    local active = ci == i
    for _, mode in ipairs({ "game", "chart" }) do
      pcall(function()
        keep(rendering.draw_rectangle { color = color, width = active and 6 or 2, filled = false,
          left_top = { cl.x1 - 1, cl.y1 - 1 }, right_bottom = { cl.x2 + 1, cl.y2 + 1 },
          surface = surface, players = { player }, time_to_live = PW.OUTLINE_TTL, render_mode = mode })
        if active then
          keep(rendering.draw_text { text = { "production-plus.net-cluster-label", { "production-plus.net-" .. what }, i, #clusters, cl.count },
            color = color, target = { cl.x1 - 1, cl.y1 - 4 }, scale = 3, surface = surface, players = { player },
            time_to_live = PW.OUTLINE_TTL, render_mode = mode, scale_with_zoom = true })
        end
      end)
    end
  end
  local cx, cy = (cur.x1 + cur.x2) / 2, (cur.y1 + cur.y2) / 2
  pcall(function()
    player.set_controller { type = defines.controllers.remote, position = { cx, cy }, surface = surface }
  end)
  pcall(function()
    local res = player.display_resolution
    local w, h = (cur.x2 - cur.x1) + 30, (cur.y2 - cur.y1) + 30
    local z = math.min(res.width / (32 * w), res.height / (32 * h))
    player.zoom = math.max(0.05, math.min(1, z))
  end)
end

local POWER_COLS = {
  { key = "network", width = PW.NAME, align = "left" },
  { key = "power-production", width = PW.NUM },
  { key = "power-demand", width = PW.NUM },
  { key = "power-satisfaction", width = PW.SAT },
  { key = "power-stored", width = PW.STORE },
  { key = "power-charge", width = PW.CHARGE, align = "center" },
  { key = "power-empty-in", width = PW.EMPTY },
}

local function build_power(parent, player, st)
  local ps = power_state(st)
  local f = parent.add { type = "frame", name = "pp_panel_power", direction = "vertical", style = "inside_deep_frame" }
  f.style.width = TG.TABLE_W
  f.style.height = TG.TABLE_H

  local h = f.add { type = "flow", direction = "horizontal" }
  h.style.vertical_align = "center"
  h.style.horizontal_spacing = 8
  h.style.padding = 4
  h.style.left_padding = 12
  h.style.height = 36
  h.add { type = "label", caption = { "production-plus.power-title" }, style = "caption_label" }
  local gcap = h.add { type = "label" }
  gcap.style.font_color = CLR.COLOR_GREY
  local push = h.add { type = "empty-widget" }
  push.style.horizontally_stretchable = true
  local idle = h.add { type = "label", tags = { pp = "power_idle" }, tooltip = { "production-plus.power-idle-tooltip" } }
  idle.style.font_color = { 0.55, 0.75, 1 }
  idle.visible = false
  local status = h.add { type = "label" }
  status.style.font_color = CLR.COLOR_GREY
  h.add { type = "sprite-button", style = "tool_button", sprite = pick_sprite("utility/refresh", "utility/reset"),
    tooltip = { "production-plus.power-rescan-tooltip" }, tags = { pp = "power_rescan" } }

  -- graph row: [minimap of the selected network] [graph]
  local n = ps.sel and find_net(ps, ps.sel)
  local grow = f.add { type = "flow", direction = "horizontal" }
  grow.style.horizontal_spacing = 0
  local gw = TG.TABLE_W
  if n and n.cx then
    local span = math.max(n.x2 - n.x1, n.y2 - n.y1) + 32
    local mm = grow.add {
      type = "minimap", position = { n.cx, n.cy }, surface_index = n.surface,
      zoom = math.max(0.05, math.min(4, PW.MINIMAP / (span * 1.2))),
      tags = { pp = "net_map", key = n.key }, tooltip = { "production-plus.net-map-tooltip" },
    }
    mm.style.width = PW.MINIMAP
    mm.style.height = GRAPH_H
    gw = TG.TABLE_W - PW.MINIMAP
  end
  add_camera(grow, player, st, PW.SLOT, "power", gw)
  st.graphs[PW.SLOT].unit = "W"

  local header = f.add { type = "flow", direction = "horizontal" }
  header.style.horizontal_spacing = TG.COL_GAP
  header.style.padding = 4
  header.style.top_padding = 8
  header.style.left_padding = 4 + TG.ROW_LEFT_PAD
  header.style.height = 32
  for _, c in ipairs(POWER_COLS) do
    local l = header.add { type = "label", caption = { "production-plus." .. c.key }, style = "caption_label" }
    l.style.width = c.width
    l.style.horizontal_align = c.align or "right"
    l.style.font_color = { 0.85, 0.85, 0.85 }
  end

  local sp = f.add { type = "scroll-pane", style = "pp_table_scroll", vertical_scroll_policy = "auto-and-reserve-space", horizontal_scroll_policy = "never" }
  sp.style.height = TG.TABLE_H - 36 - GRAPH_H - 32
  sp.style.width = TG.TABLE_W
  local t = sp.add { type = "table", column_count = 1 }
  t.style.vertical_spacing = 8
  t.style.horizontally_stretchable = true
  st.power_view = { table = t, rows = {}, status = status, idle = idle, gcap = gcap }

  if not ps.scan and (not next(ps.nets) or not ps.scan_started or game.tick - ps.scan_started > PW.SCAN_INTERVAL) then
    start_power_scan(player, st)
    -- small factories: finish right away so the list isn't empty
    if #ps.scan.poles <= PW.POLES_PER_TICK * 2 then
      power_scan_step(st)
      power_scan_step(st)
    end
  end
end

---------------------------------------------------------------------------
-- CSV export
---------------------------------------------------------------------------

local function csv_field(v)
  local s = tostring(v)
  if s:find('[,"\n]') then s = '"' .. s:gsub('"', '""') .. '"' end
  return s
end

local function export_csv(player, st)
  local lines = {}
  local function add(...)
    local parts = {}
    for i, v in ipairs({ ... }) do parts[i] = csv_field(v) end
    lines[#lines + 1] = table.concat(parts, ",")
  end
  if st.kind == "power" then
    local ps = power_state(st)
    add("network", "production_w", "demand_w", "satisfaction", "stored_j", "capacity_j", "empty_in_s")
    for _, r in ipairs(power_rows(st)) do
      local label = ps.names[r.n.key] or string.format("network at %.0f,%.0f", r.n.cx or 0, r.n.cy or 0)
      add(label, string.format("%.0f", r.p), string.format("%.0f", r.d), r.sat and string.format("%.4f", r.sat) or "",
        string.format("%.0f", r.e), string.format("%.0f", r.cap), r.tte and string.format("%.0f", r.tte) or "")
    end
  else
    if not st.raw_list then return end
    local rows = apply_quality(st.raw_list, st.panels.net.quality, st.kind)
    add("name", "display_name", "quality", "produced_per_min", "consumed_per_min", "net_per_min", "net_percent")
    local sorted = {}
    for _, r in ipairs(rows) do
      if matches_search(player.index, st, r.name) then sorted[#sorted + 1] = r end
    end
    table.sort(sorted, function(a, b) return a.net < b.net end)
    for _, r in ipairs(sorted) do
      add(r.name, translated(player.index, st.kind, r.name) or r.name, r.quality or "",
        string.format("%.2f", r.p), string.format("%.2f", r.c), string.format("%.2f", r.net),
        r.p > EPS and string.format("%.2f", r.net / r.p * 100) or "")
    end
  end
  local surface = resolve_surface(player, st)
  local where = surface and surface.name or "universe"
  local scale = st.kind == "power" and "now" or SCALE_BY_KEY[st.scale].label
  local file = string.format("production-plus/%s_%s_%s_%d.csv", where, st.kind, scale, game.tick)
  helpers.write_file(file, table.concat(lines, "\n") .. "\n", false, player.index)
  player.print { "production-plus.csv-written", file }
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------

build_window = function(player)
  local st = get_state(player.index)
  local old = player.gui.screen[WINDOW]
  local location = old and old.valid and old.location
  if old and old.valid then old.destroy() end
  clear_graphs(st)
  st.views = {}
  st.power_view = nil
  st.raw_list, st.raw_map = nil, nil
  st.hover = nil

  local frame = player.gui.screen.add { type = "frame", name = WINDOW, direction = "vertical" }
  if location then frame.location = location else frame.auto_center = true end

  -- Title bar: [Columns] ==== title ==== [Table] [x]
  local bar = frame.add { type = "flow", direction = "horizontal" }
  bar.drag_target = frame
  bar.style.horizontal_spacing = 8
  bar.style.vertical_align = "center"
  toggle_button(bar, { "production-plus.columns" }, { pp = "view", view = "columns" },
    st.view == "columns", { "production-plus.columns-tooltip" })
  local d1 = bar.add { type = "empty-widget", style = "draggable_space_header" }
  d1.style.horizontally_stretchable = true
  d1.style.height = 24
  d1.drag_target = frame
  local surface = resolve_surface(player, st)
  local where = surface and surface_caption(surface) or { "production-plus.universe" }
  local title = bar.add { type = "label", caption = { "production-plus.title", where }, style = "frame_title" }
  title.drag_target = frame
  local d2 = bar.add { type = "empty-widget", style = "draggable_space_header" }
  d2.style.horizontally_stretchable = true
  d2.style.height = 24
  d2.drag_target = frame
  toggle_button(bar, { "production-plus.table" }, { pp = "view", view = "table" },
    st.view == "table", { "production-plus.table-tooltip" })
  bar.add { type = "sprite-button", style = "frame_action_button", sprite = "utility/close", tags = { pp = "close" } }

  -- Time scales + controls on one row
  local row = frame.add { type = "flow", direction = "horizontal" }
  row.style.vertical_align = "center"
  row.style.horizontal_spacing = 4
  row.style.top_margin = 4
  local power = st.kind == "power"
  for _, s in ipairs(SCALES) do
    local b = toggle_button(row, s.label, { pp = "scale", scale = s.key }, st.scale == s.key and not power)
    b.style.width = 96
    b.enabled = not power
  end
  local push = row.add { type = "empty-widget" }
  push.style.horizontally_stretchable = true
  -- search
  local search = row.add { type = "textfield", name = "pp_search", text = st.search or "", tags = { pp = "search" },
    tooltip = { "production-plus.search-tooltip" } }
  search.style.width = 200
  search.enabled = not power
  local clear = row.add { type = "sprite-button", style = "tool_button", sprite = "utility/close",
    tooltip = { "production-plus.search-clear-tooltip" }, tags = { pp = "search_clear" } }
  clear.enabled = not power
  row.add { type = "button", caption = { "production-plus.csv" }, tooltip = { "production-plus.csv-tooltip" }, tags = { pp = "csv" } }.style.minimal_width = 0
  local pb = toggle_button(row, "%", { pp = "mode", mode = "percent" }, st.mode == "percent" and not power, { "production-plus.percent-tooltip" })
  pb.enabled = not power
  local nb = toggle_button(row, "#", { pp = "mode", mode = "number" }, st.mode == "number" and not power, { "production-plus.number-tooltip" })
  nb.enabled = not power
  local list = listed_surfaces(player)
  local items, names, selected = { { "production-plus.universe" } }, { UNIVERSE }, 1
  for _, s in ipairs(list) do
    items[#items + 1] = surface_caption(s)
    names[#names + 1] = s.name
    if surface and s == surface then selected = #items end
  end
  st.surface_names = names
  row.add { type = "drop-down", items = items, selected_index = selected, tags = { pp = "surface" } }
  if window_mode(player) ~= "plus-only" then
    row.add { type = "button", caption = { "production-plus.vanilla-view" }, tooltip = { "production-plus.vanilla-view-tooltip" }, tags = { pp = "vanilla" } }
  end

  -- Items / Fluids as real tabs
  local tp = frame.add { type = "tabbed-pane", name = "pp_tabs", tags = { pp = "kind" } }
  tp.style.top_margin = 8
  local body
  local sel_index = 1
  for i, k in ipairs({ "items", "fluids", "power" }) do
    local tab = tp.add { type = "tab", caption = { "production-plus." .. k } }
    local content
    if st.kind == k then
      content = tp.add { type = "flow", name = "pp_body", direction = "vertical" }
      body = content
      sel_index = i
    else
      content = tp.add { type = "empty-widget", name = "pp_empty_" .. k }
    end
    tp.add_tab(tab, content)
  end
  tp.selected_tab_index = sel_index

  if power then
    build_power(body, player, st)
  elseif st.view == "columns" then
    local panels = body.add { type = "flow", name = "pp_panels", direction = "horizontal" }
    panels.style.horizontal_spacing = 12
    build_panel(panels, player, st, "production", 1, { "production-plus.production" })
    build_panel(panels, player, st, "consumption", 2, { "production-plus.consumption" })
    build_panel(panels, player, st, "net", 3, { "production-plus.net" })
  else
    build_table(body, player, st)
  end

  queue_translations(player)
  if power then power_refresh(player, st) else refresh(player, true) end
  graph_tick(player, st, "open")
  storage.open[player.index] = true
  player.opened = frame
end

local function close_window(player)
  local frame = player.gui.screen[WINDOW]
  if frame and frame.valid then frame.destroy() end
  local st = get_state(player.index)
  clear_graphs(st)
  st.views = {}
  st.power_view = nil
  storage.open[player.index] = nil
end

---------------------------------------------------------------------------
-- Button on the vanilla window
---------------------------------------------------------------------------

local ANCHOR = "pp_anchor"

local function update_anchor(player)
  local rel = player.gui.relative
  local existing = rel[ANCHOR]
  local want = window_mode(player) ~= "plus-only"
  if want and not existing then
    local f = rel.add {
      type = "frame", name = ANCHOR, style = "frame",
      anchor = { gui = defines.relative_gui_type.production_gui, position = defines.relative_gui_position.top },
    }
    f.style.padding = 4
    f.add { type = "button", caption = { "production-plus.open-plus" }, tooltip = { "production-plus.open-plus-tooltip" }, tags = { pp = "to_plus" } }
  elseif not want and existing then
    existing.destroy()
  end
end

local function update_all_anchors()
  for _, player in pairs(game.players) do update_anchor(player) end
end

script.on_event(defines.events.on_player_created, function(e)
  update_anchor(game.get_player(e.player_index))
end)

script.on_event(defines.events.on_runtime_mod_setting_changed, function(e)
  if e.setting ~= "pp-window-mode" or not e.player_index then return end
  local player = game.get_player(e.player_index)
  if not player then return end
  update_anchor(player)
  if player.gui.screen[WINDOW] then build_window(player) end
end)

---------------------------------------------------------------------------
-- Redirect
---------------------------------------------------------------------------

script.on_event(defines.events.on_gui_opened, function(e)
  if e.gui_type ~= defines.gui_type.production then return end
  local player = game.get_player(e.player_index)
  if not player then return end
  local st = get_state(e.player_index)
  local mode = window_mode(player)

  if mode ~= "plus-only" and st.allow_vanilla then
    st.allow_vanilla = false
    return
  end
  st.allow_vanilla = false
  if mode == "vanilla" then return end

  player.opened = nil
  if st.closed_tick == game.tick then return end
  build_window(player)
end)

script.on_event(defines.events.on_gui_closed, function(e)
  local el = e.element
  if not (el and el.valid and el.name == WINDOW) then return end
  local st = get_state(e.player_index)
  st.closed_tick = game.tick
  el.destroy()
  clear_graphs(st)
  st.views = {}
  st.power_view = nil
  storage.open[e.player_index] = nil
end)

---------------------------------------------------------------------------
-- Input
---------------------------------------------------------------------------

local function reset_orders(st)
  for _, k in ipairs(PANELS) do st.panels[k].order = nil end
end

script.on_event(defines.events.on_gui_click, function(e)
  local el = e.element
  if not (el and el.valid) then return end
  local tags = el.tags
  local action = tags and tags.pp
  if not action then return end
  local player = game.get_player(e.player_index)
  local st = get_state(e.player_index)

  if action == "close" then
    player.opened = nil
    close_window(player)
  elseif action == "vanilla" then
    if window_mode(player) == "plus-only" then return end
    st.allow_vanilla = true
    player.opened = nil
    close_window(player)
    local ok = pcall(function() player.opened = defines.gui_type.production end)
    if not ok then
      st.allow_vanilla = false
      player.print { "production-plus.vanilla-failed" }
    end
  elseif action == "to_plus" then
    player.opened = nil
    build_window(player)
  elseif action == "view" then
    st.view = tags.view
    build_window(player)
  elseif action == "mode" then
    st.mode = tags.mode
    build_window(player)
  elseif action == "scale" then
    st.scale = tags.scale
    build_window(player)
  elseif action == "reset" then
    st.panels[tags.panel].picks = nil
    refresh(player, true)
    graph_tick(player, st, true)
  elseif action == "pick" and e.shift then
    st.pins = st.pins or {}
    local pins = st.pins[st.kind] or {}
    st.pins[st.kind] = pins
    local found = false
    for i, k in ipairs(pins) do
      if k == tags.key then table.remove(pins, i) found = true break end
    end
    if not found then pins[#pins + 1] = tags.key end
    refresh(player, true)
    graph_tick(player, st, true)
  elseif action == "pick" then
    local p = st.panels[tags.panel]
    if p.picks and #p.picks == 1 and p.picks[1] == tags.key then
      p.picks = nil
    else
      p.picks = { tags.key }
    end
    refresh(player, true)
    graph_tick(player, st, true)
  elseif action == "search_clear" then
    st.search = nil
    local f = player.gui.screen[WINDOW]
    local tf = f and f.valid and f.children[2] and f.children[2].pp_search
    if tf then tf.text = "" end
    refresh(player, true)
    graph_tick(player, st, true)
  elseif action == "csv" then
    export_csv(player, st)
  elseif action == "power_rescan" then
    start_power_scan(player, st)
    power_refresh(player, st)
  elseif action == "net_sel" then
    local ps = power_state(st)
    if ps.renaming then return end
    ps.sel = (ps.sel ~= tags.key) and tags.key or nil   -- click again to deselect
    build_window(player)                                 -- minimap / graph width depend on selection
  elseif action == "net_map" then
    show_net_on_map(player, st, tags.key)
  elseif action == "net_find" then
    show_cluster_on_map(player, st, tags.key, tags.what)
  elseif action == "power_idle" then
    local ps = power_state(st)
    ps.show_idle = not ps.show_idle
    power_refresh(player, st)
  elseif action == "net_rename" then
    local ps = power_state(st)
    ps.renaming = (ps.renaming ~= tags.key) and tags.key or nil
    power_refresh(player, st)
  elseif action == "sort" then
    local ts = st.tsort or { col = "net", asc = true }
    if ts.col == tags.col then
      ts.asc = not ts.asc
    else
      ts.col = tags.col
      ts.asc = (tags.col == "item" or tags.col == "net" or tags.col == "pct")
    end
    st.tsort = ts
    st.panels.net.order = nil
    build_window(player)
  elseif action == "lock" then
    local p = st.panels[tags.panel]
    p.locked = not p.locked
    p.order = nil
    build_window(player)
  elseif action == "flip" then
    local p = st.panels[tags.panel]
    p.flipped = not p.flipped
    if p.locked and p.order then
      local rev = {}
      for i = #p.order, 1, -1 do rev[#rev + 1] = p.order[i] end
      p.order = rev
    end
    build_window(player)
  end
end)

script.on_event(defines.events.on_gui_selected_tab_changed, function(e)
  local el = e.element
  if not (el and el.valid and el.name == "pp_tabs") then return end
  local player = game.get_player(e.player_index)
  local st = get_state(e.player_index)
  local kind = ({ "items", "fluids", "power" })[el.selected_tab_index] or "items"
  if kind ~= st.kind then
    st.kind = kind
    for _, k in ipairs(PANELS) do
      local old = st.panels[k]
      st.panels[k] = new_panel_state()
      st.panels[k].locked, st.panels[k].flipped = old.locked, old.flipped
    end
    build_window(player)
  end
end)

script.on_event(defines.events.on_gui_selection_state_changed, function(e)
  local el = e.element
  if not (el and el.valid and el.tags) then return end
  local player = game.get_player(e.player_index)
  local st = get_state(e.player_index)
  if el.tags.pp == "surface" then
    local name = st.surface_names and st.surface_names[el.selected_index]
    if name == UNIVERSE then
      st.surface = UNIVERSE
    elseif name == player.surface.name then
      st.surface = nil
    else
      st.surface = name
    end
    for _, k in ipairs(PANELS) do st.panels[k].picks = nil end
    reset_orders(st)
    build_window(player)
  elseif el.tags.pp == "quality" then
    local p = st.panels[el.tags.panel]
    p.quality = el.tags.values[el.selected_index] or "separate"
    p.picks = nil
    p.order = nil
    refresh(player, true)
    graph_tick(player, st, true)
  end
end)

script.on_event(defines.events.on_gui_text_changed, function(e)
  local el = e.element
  if not (el and el.valid and el.tags and el.tags.pp == "search") then return end
  local player = game.get_player(e.player_index)
  local st = get_state(e.player_index)
  local q = string.lower(el.text or "")
  q = q:gsub("^%s+", ""):gsub("%s+$", "")
  st.search = q ~= "" and q or nil
  refresh(player, true)
  graph_tick(player, st, true)
end)

script.on_event(defines.events.on_gui_confirmed, function(e)
  local el = e.element
  if not (el and el.valid and el.tags and el.tags.pp == "net_name") then return end
  local player = game.get_player(e.player_index)
  local st = get_state(e.player_index)
  local ps = power_state(st)
  local text = (el.text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  ps.names[el.tags.key] = text ~= "" and text or nil
  ps.renaming = nil
  power_refresh(player, st)
end)

script.on_event(defines.events.on_gui_hover, function(e)
  local el = e.element
  if not (el and el.valid and el.tags and el.tags.pp == "pick") then return end
  apply_hover(get_state(e.player_index), el.tags.key)
end)

script.on_event(defines.events.on_gui_leave, function(e)
  local el = e.element
  if not (el and el.valid and el.tags and el.tags.pp == "pick") then return end
  local st = get_state(e.player_index)
  if st.hover == el.tags.key then apply_hover(st, nil) end
end)

---------------------------------------------------------------------------
-- Live update (only while open)
---------------------------------------------------------------------------

-- /pp-perf: print how long the mod takes per tick (lists vs graphs), averaged over 5 s.
local PERF = {}   -- not saved: only used to print timings
local function perf_new()
  local function p() local x = game.create_profiler(true); return x end
  return { list = p(), graph = p(), lsum = p(), gsum = p(), n = 0 }
end
commands.add_command("pp-perf", { "production-plus.perf-help" }, function(cmd)
  local player = cmd.player_index and game.get_player(cmd.player_index)
  if not player then return end
  if PERF[player.index] then
    PERF[player.index] = nil
    player.print { "production-plus.perf-off" }
  else
    PERF[player.index] = perf_new()
    player.print { "production-plus.perf-on" }
  end
end)

script.on_event(defines.events.on_tick, function(e)
  if storage.format ~= DATA_FORMAT then migrate() end
  if storage.anchors_dirty then
    storage.anchors_dirty = nil
    update_all_anchors()
  end
  translation_step()
  local open = storage.open
  if not (open and next(open)) then return end
  for index in pairs(open) do
    local player = game.get_player(index)
    if not (player and player.connected and player.gui.screen[WINDOW]) then
      open[index] = nil
      if player then
        local st = get_state(index)
        clear_graphs(st)
        st.views = {}
      end
    else
      local st = get_state(index)
      local perf = PERF[index]
      -- stagger players so they don't all refresh on the same tick
      local t = e.tick + index
      if perf then perf.list.restart() end
      if st.kind == "power" then
        local ps = power_state(st)
        if ps.scan then
          power_scan_step(st)
        elseif ps.scan_started and e.tick - ps.scan_started >= PW.SCAN_INTERVAL then
          start_power_scan(player, st)
        end
        if t % PW.LIST_INTERVAL == 0 then power_refresh(player, st) end
      else
        continue_views(st)
        if t % FULL_INTERVAL == 0 then
          refresh(player, "sort")
        elseif t % LIST_INTERVAL == 0 then
          refresh(player, "hot")
        end
      end
      if perf then perf.list.stop(); perf.graph.restart() end
      graph_tick(player, st, false)
      if perf then
        perf.graph.stop()
        perf.lsum.add(perf.list)
        perf.gsum.add(perf.graph)
        perf.n = perf.n + 1
        if perf.n >= 300 then
          perf.lsum.divide(perf.n)
          perf.gsum.divide(perf.n)
          player.print { "production-plus.perf-report", perf.lsum, perf.gsum }
          perf.lsum.reset()
          perf.gsum.reset()
          perf.n = 0
        end
      end
    end
  end
end)

script.on_init(function()
  init_storage()
  storage.format = DATA_FORMAT
  update_all_anchors()
end)
