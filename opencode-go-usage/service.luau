--!nonstrict
-- OpenCode Usage service — fetches https://opencode.ai/zen/go/v1/usage on an
-- interval and publishes parsed metrics to the plugin's shared state.
--
-- The API key is stored in the desktop keyring (Secret Service) via
-- `secret-tool`; it is never stored in plugin settings. Commands:
-- opencode_usage.cmd = "refresh" (panel refresh button).
-- opencode_usage.set_key = <key> (panel "save key"; consumed then cleared).
--
-- State published: opencode_usage.state =
--   {
--     unconfigured = bool,          -- no key configured
--     fetching = bool,
--     error = string?,              -- last fetch error (nil when ok)
--     lastUpdated = number?,        -- epoch seconds of last successful fetch
--     metrics = { { key, percent, status, resetsAt, resetsEpoch }, ... },
--   }

local API_URL = "https://opencode.ai/zen/go/v1/usage"
local STATE_KEY = "opencode_usage.state"
local CMD_KEY = "opencode_usage.cmd"
local SET_KEY = "opencode_usage.set_key"
local SECRET_SERVICE = "opencode-go-usage"
local SECRET_LABEL = "OpenCode Go API Key"

local state = {
  unconfigured = false,
  fetching = false,
  error = nil,
  lastUpdated = nil,
  metrics = nil,
}

-- Substitute `{name}` placeholders ourselves: some host versions render them
-- literally, so do not rely on the host's substitution.
local function trSubst(key, subst)
  local s = noctalia.tr(key)
  for name, value in pairs(subst) do
    s = string.gsub(s, "{" .. name .. "}", function() return tostring(value) end)
  end
  return s
end

-- Single-quote shell quoting (runAsync at plugin_api 19 is string-form only,
-- so every secret-tool invocation is a /bin/sh -c string).
local function shq(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function secretToolAvailable()
  return noctalia.commandExists("secret-tool")
end

-- Private dir for the short-lived key material. /dev/shm is 1777 (world-listable),
-- so use a per-user subdir made 0700 before any file lands.
local function keyTempDir()
  local base = "/dev/shm"
  if not noctalia.fileExists(base) then
    base = noctalia.pluginDataDir() or "/tmp"
  end
  return base .. "/noctalia-opencode-go-usage." .. tostring(noctalia.getenv("USER") or "user")
end

-- Ensure the temp dir is 0700, then run fn(dir). Mirrors gocryptfs withSecureTempDir.
local function withKeyTempDir(fn)
  local dir = keyTempDir()
  noctalia.mkdirAll(dir)
  noctalia.runAsync("chmod 700 " .. shq(dir), function()
    fn(dir)
  end, 5000)
end

-- Async keyring read. callback(key: string?, err: string?) — err is "missing"
-- (secret-tool absent) or nil. Lookup failure (no secret, locked keyring) is
-- indistinguishable and maps to key == nil (treated as unconfigured).
local function lookupKey(callback)
  if not secretToolAvailable() then
    callback(nil, "missing")
    return
  end
  noctalia.runAsync("secret-tool lookup service " .. shq(SECRET_SERVICE), function(result)
    if result ~= nil and result.exitCode == 0 and not result.timedOut and result.stdout ~= "" then
      callback(noctalia.string.trim(result.stdout), nil)
    else
      callback(nil, nil)
    end
  end, 15000)
end

-- Async keyring write. callback(ok: boolean, err: string?). The key is written to
-- a temp file (no trailing newline) under the 0700 dir and piped into
-- `secret-tool store` via `<`, so it never appears in argv/ps. Clears any prior
-- entry first (re-storing replaces).
local function storeKey(key, callback)
  if not secretToolAvailable() then
    callback(false, noctalia.tr("error.secret_tool_missing"))
    return
  end
  withKeyTempDir(function(dir)
    local tmp = dir .. "/key-" .. tostring(os.time())
    local written = noctalia.writeFile(tmp, key)
    if not written then
      callback(false, noctalia.tr("error.keyring_store_failed"))
      return
    end
    local cmd = "secret-tool clear service " .. shq(SECRET_SERVICE) .. " 2>/dev/null; "
      .. "secret-tool store --label=" .. shq(SECRET_LABEL)
      .. " service " .. shq(SECRET_SERVICE)
      .. " < " .. shq(tmp)
      .. "; EC=$?; rm -f " .. shq(tmp) .. "; exit $EC"
    noctalia.runAsync(cmd, function(result)
      noctalia.removeFile(tmp)
      local ok = result ~= nil and result.exitCode == 0 and not result.timedOut
      if ok then
        callback(true, nil)
      else
        callback(false, noctalia.tr("error.keyring_store_failed"))
      end
    end, 30000)
  end)
end

local function debugMode()
  return noctalia.getConfig("debug_mode") == true
end

-- Metrics driven by the panel's debug sliders (opencode_usage.debug), used
-- instead of the API when debug mode is on.
local function debugMetrics()
  local dbg = noctalia.state.get("opencode_usage.debug")
  local metrics = {}
  for _, keyName in ipairs({ "rolling", "weekly", "monthly" }) do
    local percent = 0
    if type(dbg) == "table" and type(dbg[keyName]) == "number" then
      percent = dbg[keyName]
    end
    table.insert(metrics, {
      key = keyName,
      percent = percent,
      status = "ok",
      resetsAt = nil,
      resetsEpoch = nil,
    })
  end
  return metrics
end

-- Seconds between local time and UTC (positive when local is ahead).
local function utcOffsetSeconds()
  local now = os.time()
  return os.difftime(now, os.time(os.date("!*t", now)))
end

-- "2026-08-12T14:43:15.859Z" -> UTC epoch seconds, or nil when unparseable.
local function isoToEpoch(iso)
  if type(iso) ~= "string" then
    return nil
  end
  local y, mo, d, h, mi, s = iso:match("^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)")
  if y == nil then
    return nil
  end
  local localEpoch = os.time({
    year = tonumber(y),
    month = tonumber(mo),
    day = tonumber(d),
    hour = tonumber(h),
    min = tonumber(mi),
    sec = tonumber(s),
    isdst = false,
  })
  return localEpoch - utcOffsetSeconds()
end

local function publish()
  noctalia.state.set(STATE_KEY, state)
end

local function fetchUsage()
  -- Debug mode wins over any in-flight request: publish slider data now.
  if debugMode() then
    state.fetching = false
    state.unconfigured = false
    state.error = nil
    state.metrics = debugMetrics()
    state.lastUpdated = os.time()
    publish()
    return
  end

  if state.fetching then
    return
  end

  state.unconfigured = false
  state.fetching = true
  state.error = nil
  publish()

  lookupKey(function(key, lookupErr)
    -- Debug mode took over mid-lookup: drop the stale result.
    if debugMode() then
      return
    end

    if lookupErr == "missing" then
      state.fetching = false
      state.error = noctalia.tr("error.secret_tool_missing")
      publish()
      return
    end

    if key == nil or key == "" then
      state.fetching = false
      state.unconfigured = true
      state.error = nil
      publish()
      return
    end

    noctalia.http({
      url = API_URL,
      headers = {
        "Authorization: Bearer " .. key,
        "Accept: application/json",
      },
    }, function(res)
      state.fetching = false

      -- Debug mode took over mid-flight: drop the stale response.
      if debugMode() then
        return
      end

      if not res.ok then
        state.error = noctalia.tr("error.offline")
        publish()
        return
      end

      if res.status == 401 then
        state.error = noctalia.tr("error.invalid_key")
        publish()
        return
      end

      if res.status ~= 200 then
        state.error = trSubst("error.http", { status = tostring(res.status) })
        publish()
        return
      end

      local parsed, parseErr = noctalia.json.decode(res.body)
      if parsed == nil or type(parsed) ~= "table" or type(parsed.usage) ~= "table" then
        state.error = parseErr or noctalia.tr("error.parse")
        publish()
        return
      end

      local metrics = {}
      for _, keyName in ipairs({ "rolling", "weekly", "monthly" }) do
        local entry = parsed.usage[keyName]
        local row = { key = keyName }
        if type(entry) == "table" then
          row.percent = tonumber(entry.percent) or 0
          row.status = entry.status or "unknown"
          row.resetsAt = entry.resetsAt
          row.resetsEpoch = isoToEpoch(entry.resetsAt)
        else
          row.percent = nil
          row.status = "unknown"
          row.resetsAt = nil
          row.resetsEpoch = nil
        end
        table.insert(metrics, row)
      end

      state.metrics = metrics
      state.error = nil
      state.lastUpdated = os.time()
      publish()
    end)
  end)
end

local function armInterval()
  local refreshMinutes = tonumber(noctalia.getConfig("refresh_minutes")) or 15
  noctalia.setUpdateInterval(math.max(1, refreshMinutes) * 60 * 1000)
end

function update()
  armInterval()
  fetchUsage()
end

-- Settings changed (refresh interval, thresholds, debug mode, ...): re-arm and
-- re-fetch so a new cadence applies immediately.
function onConfigChanged()
  armInterval()
  fetchUsage()
end

-- Manual refresh (panel refresh button).
noctalia.state.watch(CMD_KEY, function(cmd)
  if cmd == "refresh" then
    fetchUsage()
  end
  noctalia.state.set(CMD_KEY, nil)
end)

-- Panel "save key" command: store the secret, then re-lookup and re-fetch.
noctalia.state.watch(SET_KEY, function(key)
  noctalia.state.set(SET_KEY, nil)
  if type(key) ~= "string" or key == "" then
    return
  end
  storeKey(key, function(ok, err)
    if ok then
      fetchUsage()
    else
      state.error = err or noctalia.tr("error.keyring_store_failed")
      state.unconfigured = false
      publish()
    end
  end)
end)

-- Debug slider changes from the panel: republish (short-circuits to the debug
-- path when debug mode is on).
noctalia.state.watch("opencode_usage.debug", function()
  if debugMode() then
    fetchUsage()
  end
end)

fetchUsage()
