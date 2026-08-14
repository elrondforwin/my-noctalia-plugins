--!nonstrict
-- OpenCode Usage panel — a hero card per usage window (rolling / weekly /
-- monthly), each with a live "resets in …" countdown, an error banner, a
-- manual refresh, a masked input to store the API key in the desktop
-- keyring (Secret Service) when none is set, and a change-key toggle.

local STATE_KEY = "opencode_usage.state"

local state = nil
local apiKeyDraft = ""
local apiKeyInputRev = 0
local showKeyInput = false

local function tr(key)
  return noctalia.tr(key)
end

-- Substitute `{name}` placeholders ourselves: some host versions render them
-- literally, so do not rely on the host's substitution.
local function trSubst(key, subst)
  local s = noctalia.tr(key)
  for name, value in pairs(subst) do
    s = string.gsub(s, "{" .. name .. "}", function() return tostring(value) end)
  end
  return s
end

local function formatPercent(percent)
  if percent == nil then
    return "--"
  end
  return string.format("%d%%", math.floor(percent + 0.5))
end

local function localTime(epoch)
  if epoch == nil then
    return "--"
  end
  return noctalia.formatTime("%a %d %b, %H:%M", epoch)
end

-- Live "resets in Xh Ym" for the hero card (re-rendered every second).
local function countdown(epoch)
  if epoch == nil then
    return "--"
  end
  local diff = epoch - os.time()
  if diff <= 0 then
    return tr("panel.resets_now")
  end
  local h = math.floor(diff / 3600)
  local m = math.floor((diff % 3600) / 60)
  if h >= 24 then
    return string.format("%dd %dh", math.floor(h / 24), h % 24)
  elseif h > 0 then
    return string.format("%dh %dm", h, m)
  end
  return string.format("%dm", math.max(1, m))
end

-- Threshold coloring: warning at/above warn_threshold, error at/above
-- critical_threshold. nil = default color.
local function usageColor(percent)
  if percent == nil then
    return nil
  end
  local critical = tonumber(noctalia.getConfig("critical_threshold")) or 90
  local warn = tonumber(noctalia.getConfig("warn_threshold")) or 70
  if percent >= critical then
    return "error"
  elseif percent >= warn then
    return "warning"
  end
  return nil
end

local function debugEnabled()
  return noctalia.getConfig("debug_mode") == true
end

local function fetching()
  return state ~= nil and state.fetching == true
end

local function statusLabel(s)
  if s == "ok" then
    return tr("status.ok")
  end
  if s == nil or s == "" then
    return "unknown"
  end
  return tostring(s)
end

local function statusChip(s)
  local ok = s == "ok"
  return ui.row({ gap = 4, align = "center", fill = ok and "primary/0.15" or "surface_variant/0.5", radius = 6, paddingH = 6, paddingV = 2 }, {
    ui.label({ text = statusLabel(s), fontSize = 10, fontWeight = "medium", color = ok and "primary" or "on_surface_variant" }),
  })
end

local function heroCard(m)
  local color = usageColor(m.percent)
  local percentRow = {
    ui.label({ text = formatPercent(m.percent), fontSize = 30, fontWeight = "bold", color = color or "primary" }),
  }
  -- Resets info only when the API provided it (debug metrics have none).
  if m.resetsEpoch ~= nil then
    table.insert(percentRow, ui.column({ gap = 2, align = "end" }, {
      ui.label({ text = trSubst("panel.resets_in", { time = countdown(m.resetsEpoch) }), fontSize = 11, color = "on_surface", fontWeight = "medium" }),
      ui.label({ text = localTime(m.resetsEpoch), fontSize = 10, color = "on_surface_variant" }),
    }))
  end
  return ui.column({ gap = 8, fill = "surface_variant/0.35", radius = 12, padding = 14 }, {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({ text = tr("metric." .. m.key), fontSize = 14, fontWeight = "bold" }),
      statusChip(m.status),
    }),
    ui.row({ align = "end", justify = "space_between" }, percentRow),
    ui.progress({ progress = math.min(1, (m.percent or 0) / 100), fill = color or "primary", track = "on_surface/0.12", height = 8, radius = 4 }),
  })
end

-- Debug mode: sliders drive the percentages (no API key needed).
local debugValues = {}

local function debugSlider(keyName)
  local value = debugValues[keyName] or 0
  return ui.row({ gap = 8, align = "center" }, {
    ui.box({ width = 72 }, {
      ui.label({ text = tr("metric." .. keyName), fontSize = 12, color = "on_surface_variant" }),
    }),
    ui.slider({
      min = 0,
      max = 100,
      step = 1,
      value = value,
      flexGrow = 1,
      onChange = function(v)
        debugValues[keyName] = math.floor(tonumber(v) or 0)
        noctalia.state.set("opencode_usage.debug", debugValues)
      end,
    }),
    ui.label({ text = string.format("%d%%", debugValues[keyName]), fontSize = 12, fontWeight = "bold" }),
  })
end

local function debugSection()
  return ui.column({ gap = 8, fill = "surface_variant/0.3", radius = 10, padding = 12 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "bug", size = 14, color = "warning" }),
      ui.label({ text = tr("panel.debug_title"), fontSize = 12, fontWeight = "bold" }),
    }),
    ui.label({ text = tr("panel.debug_desc"), fontSize = 11, color = "on_surface_variant" }),
    debugSlider("rolling"),
    debugSlider("weekly"),
    debugSlider("monthly"),
  })
end

-- Masked key input + Save row, shared by the unconfigured card and the
-- change-key card.
local function keyInputRow()
  return ui.row({ gap = 8, align = "center" }, {
    ui.input({
      key = "api-key-" .. tostring(apiKeyInputRev),
      password = true,
      placeholder = tr("panel.key_input_placeholder"),
      flexGrow = 1,
      onChange = function(text) apiKeyDraft = text or "" end,
      onSubmit = "submitKey",
    }),
    ui.button({ text = tr("panel.save_key"), variant = "primary", onClick = "submitKeyButton" }),
  })
end

local function render()
  local body = {}
  local dbg = debugEnabled()
  local canChangeKey = not dbg and state ~= nil and state.unconfigured ~= true

  if not dbg and (state == nil or state.unconfigured == true) then
    table.insert(body, ui.column({ gap = 8, fill = "surface_variant/0.5", radius = 10, padding = 12 }, {
      ui.row({ gap = 8, align = "center" }, {
        ui.glyph({ name = "key", size = 16, color = "error" }),
        ui.label({ text = tr("panel.unconfigured_title"), fontWeight = "bold", color = "error", flexGrow = 1 }),
      }),
      ui.label({ text = tr("panel.unconfigured_desc"), fontSize = 12, color = "on_surface_variant" }),
      keyInputRow(),
    }))
  end

  if state ~= nil and state.error ~= nil then
    table.insert(body, ui.row({ gap = 8, align = "center", fill = "error/0.15", radius = 8, padding = 10 }, {
      ui.glyph({ name = "alert-circle", color = "error", size = 16 }),
      ui.label({ text = state.error, color = "error", fontSize = 12, flexGrow = 1 }),
    }))
  end

  if not dbg and showKeyInput then
    table.insert(body, ui.column({ gap = 8, fill = "surface_variant/0.3", radius = 10, padding = 12 }, {
      ui.row({ gap = 8, align = "center" }, {
        ui.glyph({ name = "key", size = 14, color = "primary" }),
        ui.label({ text = tr("panel.change_key_title"), fontSize = 12, fontWeight = "bold", flexGrow = 1 }),
      }),
      keyInputRow(),
    }))
  end

  if dbg then
    table.insert(body, debugSection())
  end

  if state ~= nil and state.error == nil and type(state.metrics) ~= "table" and state.unconfigured ~= true then
    table.insert(body, ui.row({ justify = "center", padding = 12 }, {
      ui.label({ text = "…", color = "on_surface_variant", fontSize = 16 }),
    }))
  end

  if state ~= nil and type(state.metrics) == "table" then
    for _, m in ipairs(state.metrics) do
      table.insert(body, heroCard(m))
    end
  end

  panel.render(ui.column({ flexGrow = 1, gap = 10, padding = 12 }, {
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.row({ gap = 8, align = "center" }, {
        ui.glyph({ name = "activity", size = 18, color = "primary" }),
        ui.label({ text = tr("panel.title"), fontSize = 16, fontWeight = "bold" }),
      }),
      ui.row({ gap = 4 }, {
        ui.button({ glyph = "key", variant = "ghost", tooltip = tr("panel.change_key"), visible = canChangeKey, onClick = "toggleKeyInput" }),
        ui.button({ glyph = "refresh", variant = "ghost", tooltip = tr("panel.refresh_tooltip"), enabled = not fetching(), onClick = "refreshNow" }),
        ui.button({ glyph = "close", variant = "ghost", onClick = "closePanel" }),
      }),
    }),
    ui.separator({}),
    ui.scroll({ flexGrow = 1, gap = 10 }, body),
    ui.label({
      text = (state ~= nil and state.lastUpdated ~= nil)
        and trSubst("panel.updated_at", { time = localTime(state.lastUpdated) })
        or "",
      fontSize = 10,
      color = "on_surface_variant",
    }),
  }))
end

-- Global handlers (resolved by string-name callbacks). render is a local
-- declared above, so these can call it.
function refreshNow()
  noctalia.state.set("opencode_usage.cmd", "refresh")
end

function saveKey(raw)
  raw = noctalia.string.trim(raw or "")
  if raw == "" then
    return
  end
  noctalia.state.set("opencode_usage.set_key", raw)
  apiKeyDraft = ""
  apiKeyInputRev = apiKeyInputRev + 1
  showKeyInput = false
  render()
end

function submitKey(value)
  saveKey(value)
end

function submitKeyButton()
  saveKey(apiKeyDraft)
end

function toggleKeyInput()
  showKeyInput = not showKeyInput
  render()
end

function closePanel()
  panel.close()
end

function onOpen(_context)
  state = noctalia.state.get(STATE_KEY)
  showKeyInput = false
  local stored = noctalia.state.get("opencode_usage.debug")
  if type(stored) == "table" then
    debugValues = stored
  else
    debugValues = {}
  end
  panel.setWantsSecondTicks(true) -- live countdown; host stops ticks on close
  render()
end

function onClose()
  panel.setWantsSecondTicks(false)
end

-- Fires every second while the panel is open: keeps the countdown live.
function update()
  render()
end

noctalia.state.watch(STATE_KEY, function(value)
  if type(value) == "table" then
    state = value
  else
    state = nil
  end
  render()
end)
