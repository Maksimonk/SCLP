-- util.lua : time, numbers, CP1251 <-> UTF-8, log, CSV, serialization.
-- All prices inside SCLP are integer tick indexes (price / tick); strings are built only at the edge.
return function(X)
  local U = {}
  X.U = U
  local floor = math.floor

  ------------------------------------------------------------------
  -- TIME. os.sysdate() (QLua) has milliseconds; tests replace X.clock.
  ------------------------------------------------------------------
  local day_key, day_epoch = nil, 0
  function U.now()
    if X.clock then return X.clock() end
    local sd = os.sysdate
    if sd then
      local d = sd()
      local key = d.year * 10000 + d.month * 100 + d.day
      if key ~= day_key then
        day_key = key
        day_epoch = os.time({ year = d.year, month = d.month, day = d.day, hour = 0, min = 0, sec = 0 })
      end
      return day_epoch + d.hour * 3600 + d.min * 60 + d.sec + (d.ms or 0) / 1000
    end
    return os.time() + (os.clock() % 1)
  end

  -- seconds since Moscow midnight (PC clock + TZ_TO_MSK_HOURS)
  function U.msk_sec(t)
    t = t or U.now()
    local d = os.date("*t", floor(t))
    local s = d.hour * 3600 + d.min * 60 + d.sec + (t % 1) + ((X.cfg and X.cfg.TZ_TO_MSK_HOURS) or 0) * 3600
    return s % 86400
  end
  function U.weekday(t) return os.date("*t", floor(t or U.now())).wday end   -- 1 = Sunday ... 7 = Saturday
  function U.date(fmt, t) return os.date(fmt, floor(t or U.now())) end
  function U.hms(s)
    local h, m, sec = tostring(s or ""):match("(%d+):(%d+):?(%d*)")
    if not h then return nil end
    return tonumber(h) * 3600 + tonumber(m) * 60 + (tonumber(sec) or 0)
  end
  function U.stamp(t)
    t = t or U.now()
    return os.date("%H:%M:%S", floor(t)) .. string.format(".%03d", floor((t % 1) * 1000))
  end

  ------------------------------------------------------------------
  -- NUMBERS
  ------------------------------------------------------------------
  function U.num(v)
    if type(v) == "number" then return v end
    if v == nil then return nil end
    return tonumber((tostring(v):gsub(",", ".")))
  end
  function U.round(x) return floor(x + 0.5) end
  function U.clamp(x, lo, hi) if x < lo then return lo elseif x > hi then return hi end return x end
  function U.sign(x) if x > 0 then return 1 elseif x < 0 then return -1 end return 0 end
  function U.bit(flags, n) return floor((tonumber(flags) or 0) / 2 ^ n) % 2 == 1 end
  function U.fmt(x, d)
    if x == nil then return "" end
    if type(x) ~= "number" then return tostring(x) end
    return string.format("%." .. (d or 2) .. "f", x)
  end
  function U.money(v)
    v = v or 0
    if math.abs(v) < 10000 then return string.format("%+.2f", v) end
    return string.format("%+.0f", v)
  end

  -- order/trade number -> ORDER_KEY string (FORTS numbers are 19 digits: exact as Lua 5.3+ integers)
  function U.key_from_num(n)
    if n == nil then return nil end
    local s = tostring(n)
    if s:match("^%d+$") then return s end
    n = tonumber(n)
    if n and n > 0 and n < 9007199254740992 and n == floor(n) then return string.format("%.0f", n) end
    return nil
  end

  ------------------------------------------------------------------
  -- ENCODINGS. QUIK expects CP1251 for Russian field names of the universal transaction format and
  -- for table captions; its reply texts come in CP1251 and are converted to UTF-8 for the log.
  ------------------------------------------------------------------
  function U.to_cp1251(s)
    s = tostring(s)
    if not s:find("[\128-\255]") then return s end
    local out, i, n = {}, 1, #s
    while i <= n do
      local b = s:byte(i)
      if b < 128 then out[#out + 1] = string.char(b); i = i + 1
      elseif b >= 0xC0 and b < 0xE0 and i + 1 <= n then
        local cp = (b - 0xC0) * 64 + (s:byte(i + 1) - 0x80)
        local o
        if cp >= 0x410 and cp <= 0x44F then o = cp - 0x410 + 0xC0
        elseif cp == 0x401 then o = 0xA8 elseif cp == 0x451 then o = 0xB8
        elseif cp == 0xAB or cp == 0xBB or cp == 0xB0 or cp == 0xB1 or cp == 0xD7 then o = cp end
        out[#out + 1] = string.char(o or 63)
        i = i + 2
      elseif b >= 0xE0 and b < 0xF0 and i + 2 <= n then
        local cp = (b - 0xE0) * 4096 + (s:byte(i + 1) - 0x80) * 64 + (s:byte(i + 2) - 0x80)
        local o = "?"
        if cp == 0x2116 then o = string.char(0xB9)
        elseif cp == 0x2013 or cp == 0x2014 or cp == 0x2212 then o = "-"
        elseif cp == 0x2026 then o = "..."
        elseif cp == 0x2191 then o = "^" elseif cp == 0x2193 then o = "v"
        elseif cp == 0x2190 then o = "<" elseif cp == 0x2192 then o = ">" end
        out[#out + 1] = o
        i = i + 3
      else out[#out + 1] = "?"; i = i + 1 end
    end
    return table.concat(out)
  end

  local function is_utf8(s)
    local i, n = 1, #s
    while i <= n do
      local b = s:byte(i)
      if b < 0x80 then i = i + 1
      elseif b >= 0xC2 and b < 0xE0 then
        local c = s:byte(i + 1); if not c or c < 0x80 or c > 0xBF then return false end; i = i + 2
      elseif b >= 0xE0 and b < 0xF0 then
        local c1, c2 = s:byte(i + 1), s:byte(i + 2)
        if not c2 or c1 < 0x80 or c1 > 0xBF or c2 < 0x80 or c2 > 0xBF then return false end; i = i + 3
      else return false end
    end
    return true
  end
  local function utf8char(cp)
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then return string.char(0xC0 + floor(cp / 64), 0x80 + cp % 64) end
    return string.char(0xE0 + floor(cp / 4096), 0x80 + floor(cp / 64) % 64, 0x80 + cp % 64)
  end
  function U.from_cp1251(s)
    if s == nil then return "" end
    s = tostring(s)
    if not s:find("[\128-\255]") or is_utf8(s) then return s end
    local out = {}
    for i = 1, #s do
      local b = s:byte(i)
      if b < 0x80 then out[#out + 1] = string.char(b)
      elseif b >= 0xC0 then out[#out + 1] = utf8char(0x410 + b - 0xC0)
      elseif b == 0xA8 then out[#out + 1] = utf8char(0x401)
      elseif b == 0xB8 then out[#out + 1] = utf8char(0x451)
      elseif b == 0xB9 then out[#out + 1] = utf8char(0x2116)
      elseif b == 0xAB or b == 0xBB then out[#out + 1] = utf8char(b)
      elseif b == 0x96 or b == 0x97 then out[#out + 1] = "-"
      else out[#out + 1] = "?" end
    end
    return table.concat(out)
  end

  ------------------------------------------------------------------
  -- FILES: sclp_YYYYMMDD.log (UTF-8) and daily CSVs next to the script. Buffered, flushed by the main loop.
  ------------------------------------------------------------------
  function U.path(name) return (X.out_dir or X.dir or ".") .. "/" .. name end

  local logf, log_day
  local function open_log()
    local day = U.date("%Y%m%d")
    if logf and log_day == day then return logf end
    if logf then logf:close() end
    log_day = day
    logf = io.open(U.path("sclp_" .. day .. ".log"), "a")
    return logf
  end
  function U.log(s)
    local f = open_log()
    local line = U.stamp() .. " " .. tostring(s)
    if f then f:write(line, "\n") end
    if X.echo then X.echo(line) end
  end
  -- alert: log + QUIK message window (QUIK can be set to play a sound on messages). Icon 1 info, 2 warn, 3 error.
  function U.alert(s, icon)
    U.log("!!! " .. tostring(s))
    X.last_msg = tostring(s)
    if message and not X.clock then pcall(message, "SCLP: " .. U.to_cp1251(tostring(s)), icon or 2) end
  end
  local every = {}
  function U.log_every(key, sec, s)
    local t = U.now()
    if (every[key] or -1e9) + sec <= t then every[key] = t; U.log(s) end
  end

  local csvs = {}
  function U.csv(name, header, row)
    local day = U.date("%Y%m%d")
    local c = csvs[name]
    if not c or c.day ~= day then
      if c and c.f then c.f:close() end
      local p = U.path(name .. "_" .. day .. ".csv")
      local exists = io.open(p, "r")
      if exists then exists:close() end
      local f = io.open(p, "a")
      if f and not exists then f:write(header, "\n") end
      c = { f = f, day = day }
      csvs[name] = c
    end
    if c.f then c.f:write(row, "\n") end
  end
  function U.flush()
    if logf then logf:flush() end
    for _, c in pairs(csvs) do if c.f then c.f:flush() end end
  end
  function U.close_all()
    if logf then logf:close(); logf = nil end
    for _, c in pairs(csvs) do if c.f then c.f:close() end end
    csvs = {}
  end

  function U.read_file(p)
    local f = io.open(p, "r")
    if not f then return nil end
    local s = f:read("*a"); f:close()
    return s
  end
  function U.write_file_atomic(p, s)
    local f = io.open(p .. ".tmp", "w")
    if not f then return false end
    f:write(s); f:close()
    os.remove(p)
    return os.rename(p .. ".tmp", p)
  end

  function U.serialize(v)
    local ty = type(v)
    if ty == "number" then
      if v ~= v or v == math.huge or v == -math.huge then return "0" end
      if math.type and math.type(v) == "integer" then return string.format("%d", v) end
      return string.format("%.10g", v)
    elseif ty == "string" then return string.format("%q", v)
    elseif ty == "boolean" then return tostring(v)
    elseif ty == "table" then
      local parts = {}
      for k, x in pairs(v) do
        local tx = type(x)
        if tx ~= "function" and tx ~= "userdata" then
          local key = (type(k) == "string" and k:match("^[%a_][%w_]*$")) and k or ("[" .. U.serialize(k) .. "]")
          parts[#parts + 1] = key .. " = " .. U.serialize(x)
        end
      end
      return "{ " .. table.concat(parts, ", ") .. " }"
    end
    return "nil"
  end

  -- shallow-by-default merge: nested string-keyed tables are merged, arrays are replaced
  function U.merge(base, over)
    local r = {}
    for k, v in pairs(base or {}) do r[k] = v end
    for k, v in pairs(over or {}) do
      if type(v) == "table" and type(r[k]) == "table" and #v == 0 and next(v) ~= nil then
        r[k] = U.merge(r[k], v)
      else
        r[k] = v
      end
    end
    return r
  end

  function U.param(class, sec, name)
    if not getParamEx then return nil end
    local ok, p = pcall(getParamEx, class, sec, name)
    if ok and p and tonumber(p.param_type) and tonumber(p.param_type) ~= 0 then
      return U.num(p.param_value), U.from_cp1251(p.param_image or "")
    end
    return nil
  end

  return U
end
