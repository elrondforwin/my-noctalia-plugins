--!nonstrict
-- OpenCode Usage bar widget — shows the percent of the configured metric
-- (plugin setting `metric`), with details in the tooltip. Click opens the
-- detail panel.
--
-- Widget settings: `label` (prefix text, empty = percent only), `show_glyph`
-- and `glyph` (decorative icon). Unconfigured (no key): "Set key".
-- First fetch in flight: "…". Fetch error: "!" in error color.

local STATE_KEY = "opencode_usage.state"
local METRIC_KEYS = { "rolling", "weekly", "monthly" }

local state = nil

local function metricConfig()
  local metric = noctalia.getConfig("metric")
  if type(metric) == "string" and table.find(METRIC_KEYS, metric) ~= nil then
    return metric
  end
  return "monthly"
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
  return noctalia.formatTime("%H:%M", epoch)
end

local function findMetric(key)
  if type(state) ~= "table" or type(state.metrics) ~= "table" then
    return nil
  end
  for _, m in ipairs(state.metrics) do
    if m.key == key then
      return m
    end
  end
  return nil
end

-- Threshold coloring: warning at/above warn_threshold, error at/above
-- critical_threshold, default color below. nil = default color.
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

local function tooltipRows(metric, metricKey)
  local rows = {}
  table.insert(rows, { key = noctalia.tr("tooltip.metric"), value = noctalia.tr("metric." .. metricKey) })
  if state.error ~= nil then
    table.insert(rows, { key = noctalia.tr("tooltip.error"), value = state.error })
  elseif metric ~= nil then
    table.insert(rows, { key = noctalia.tr("tooltip.used"), value = formatPercent(metric.percent) })
    table.insert(rows, { key = noctalia.tr("tooltip.status"), value = tostring(metric.status) })
    table.insert(rows, { key = noctalia.tr("tooltip.resets"), value = localTime(metric.resetsEpoch) })
  end
  table.insert(rows, { key = noctalia.tr("tooltip.updated"), value = localTime(state.lastUpdated) })
  return rows
end

local function render()
  local text = nil
  local textColor = nil
  local tooltip = nil

  if state == nil then
    -- Not loaded yet.
    text = "…"
    tooltip = noctalia.tr("title")
  elseif state.unconfigured then
    text = noctalia.tr("widget.set_key")
    textColor = "error"
    tooltip = {
      { key = noctalia.tr("tooltip.status"), value = noctalia.tr("status.unconfigured") },
      { key = noctalia.tr("tooltip.action"), value = noctalia.tr("widget.click_hint") },
    }
  elseif type(state.metrics) ~= "table" then
    -- First fetch in flight, or it failed before any data arrived.
    if state.error ~= nil then
      text = "!"
      textColor = "error"
      tooltip = tooltipRows(nil, metricConfig())
    else
      text = "…"
      tooltip = noctalia.tr("title")
    end
  else
    local metricKey = metricConfig()
    local metric = findMetric(metricKey)

    if state.error ~= nil then
      text = "!"
      textColor = "error"
    else
      text = formatPercent(metric and metric.percent or nil)
      textColor = usageColor(metric and metric.percent or nil)
    end
    tooltip = tooltipRows(metric, metricKey)
  end

  local children = {}
  if text ~= nil then
    if noctalia.getConfig("show_glyph") == true then
      local glyph = noctalia.getConfig("glyph")
      if type(glyph) == "string" and glyph ~= "" then
        table.insert(children, ui.glyph({ name = glyph, size = 14, color = textColor or "on_surface" }))
      end
    end
    local label = noctalia.getConfig("label")
    local labelText = (type(label) == "string" and label ~= "") and (label .. " " .. text) or text
    local labelProps = { text = labelText, fontWeight = "bold" }
    if textColor ~= nil then
      labelProps.color = textColor
    end
    table.insert(children, ui.label(labelProps))
  end

  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 6, align = "center" }, children))
  if tooltip ~= nil then
    barWidget.setTooltip(tooltip)
  end
end

-- Slow tick: re-reads widget config (label/glyph) so a settings change shows
-- up without waiting for the next state publish from the service.
function update()
  noctalia.setUpdateInterval(60000)
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

function onClick()
  noctalia.togglePanel("elrond/opencode-go-usage:panel")
end

state = noctalia.state.get(STATE_KEY)
render()
