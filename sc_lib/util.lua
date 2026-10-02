-- util.lua : время, числа, кодировки, журналы, CSV.
return function(SC)
  local U = {}
  SC.U = U
  local floor = math.floor

  ------------------------------------------------------------------
  -- ВРЕМЯ. os.sysdate() (QLua) даёт миллисекунды. Нет его - секунды os.time() + доли os.clock().
  -- В тестах SC.clock подменяется (эмулятор).
  ------------------------------------------------------------------
  local day_key, day_epoch = nil, 0
  local fb_sec, fb_c0, fb_last = nil, 0, 0
  local function fallback_now()
    local s, c = os.time(), os.clock()
    if s ~= fb_sec then fb_sec, fb_c0 = s, c end
    local v = s + math.max(0, math.min(0.999, c - fb_c0))
    if v < fb_last then v = fb_last end
    fb_last = v
    return v
  end
  function U.now()
    if SC.clock then return SC.clock() end
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
    return fallback_now()
  end

  -- секунды от полуночи по МСК (время ПК + TZ_TO_MSK_HOURS)
  function U.msk_sec(t)
    t = t or U.now()
    local d = os.date("*t", floor(t))
    local s = d.hour * 3600 + d.min * 60 + d.sec + (t % 1) + (SC.cfg.TZ_TO_MSK_HOURS or 0) * 3600
    return s % 86400
  end
  function U.weekday(t)   -- 1 = воскресенье ... 7 = суббота (как os.date)
    return os.date("*t", floor(t or U.now())).wday
  end
  function U.date(fmt, t) return os.date(fmt, floor(t or U.now())) end
  function U.hms(s)
    local h, m, sec = tostring(s or ""):match("(%d+):(%d+):?(%d*)")
    if not h then return nil end
    return tonumber(h) * 3600 + tonumber(m) * 60 + (tonumber(sec) or 0)
  end

  ------------------------------------------------------------------
  -- ЧИСЛА
  ------------------------------------------------------------------
  function U.num(v)
    if type(v) == "number" then return v end
    if v == nil then return nil end
    local s = tostring(v):gsub(",", ".")
    return tonumber(s)
  end
  function U.round(x) return floor(x + 0.5) end
  function U.clamp(x, lo, hi)
    if x < lo then return lo end
    if x > hi then return hi end
    return x
  end
  function U.sign(x) if x > 0 then return 1 elseif x < 0 then return -1 end return 0 end
  function U.bit(flags, n) return floor((tonumber(flags) or 0) / 2 ^ n) % 2 == 1 end
  function U.qty_str(n) return string.format("%d", floor(n + 0.5)) end

  -- номер заявки -> ORDER_KEY. Номера FORTS 19-значные: в Lua 5.3+ целые точны.
  local TWO53 = 9007199254740992
  function U.key_from_num(n)
    if n == nil then return nil end
    local s = tostring(n)
    if s:match("^%d+$") then return s end
    n = tonumber(n)
    if n and n > 0 and n < TWO53 and n == floor(n) then return string.format("%.0f", n) end
    return nil
  end
  function U.key_from_text(msg, n)
    if type(msg) ~= "string" then return nil end
    n = tonumber(n)
    for d in msg:gmatch("%d+") do
      if #d >= 8 and (n == nil or n == 0 or tonumber(d) == n) then return d end
    end
    return nil
  end

  ------------------------------------------------------------------
  -- КОДИРОВКИ. QUIK работает в CP1251: русские названия полей транзакции нужно
  -- отправлять в CP1251, а тексты ответов QUIK (CP1251) переводить в UTF-8 для журнала.
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
        elseif cp == 0xAB then o = 0xAB elseif cp == 0xBB then o = 0xBB
        elseif cp == 0x2116 then o = 0xB9 end
        out[#out + 1] = string.char(o or 63)
        i = i + 2
      elseif b >= 0xE0 and b < 0xF0 and i + 2 <= n then
        local cp = (b - 0xE0) * 4096 + (s:byte(i + 1) - 0x80) * 64 + (s:byte(i + 2) - 0x80)
        local o = (cp == 0x2116) and string.char(0xB9) or ((cp == 0x2013 or cp == 0x2014 or cp == 0x2212) and "-" or "?")
        out[#out + 1] = o
        i = i + 3
      else out[#out + 1] = "?"; i = i + 1 end
    end
    return table.concat(out)
  end

  -- CP1251 -> UTF-8 (если строка уже UTF-8 - не трогаем)
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
  -- ЖУРНАЛ: scalp_ГГГГММДД.log рядом со скриптом (UTF-8). message() QUIK - только латиница.
  ------------------------------------------------------------------
  local logf, log_day = nil, nil
  local function path(name) return (SC.out_dir or SC.dir or ".") .. "/" .. name end
  U.path = path

  local function open_log()
    local day = U.date("%Y%m%d")
    if logf and log_day == day then return logf end
    if logf then logf:close() end
    log_day = day
    logf = io.open(path("scalp_" .. day .. ".log"), "a")
    return logf
  end
  local function stamp()
    local t = U.now()
    return os.date("%H:%M:%S", floor(t)) .. string.format(".%03d", floor((t % 1) * 1000))
  end
  function U.log(s)
    local f = open_log()
    local line = stamp() .. " " .. tostring(s)
    if f then f:write(line, "\n") end
    if SC.echo then SC.echo(line) end
  end
  function U.alert(s)
    U.log("!!! " .. tostring(s))
    if message and not SC.clock then
      pcall(message, "SCALP: " .. tostring(s):gsub("[\128-\255]", "?"), 3)
    end
  end
  local every = {}
  function U.log_every(key, sec, s)
    local t = U.now()
    if (every[key] or -1e9) + sec <= t then every[key] = t; U.log(s) end
  end
  function U.dbg(s) if SC.cfg and SC.cfg.DEBUG then U.log("[dbg] " .. tostring(s)) end end

  -- CSV: файл на день, заголовок при создании
  local csvs = {}
  function U.csv(name, header, row)
    local day = U.date("%Y%m%d")
    local c = csvs[name]
    if not c or c.day ~= day then
      if c and c.f then c.f:close() end
      local p = path(name .. "_" .. day .. ".csv")
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

  -- глубокое слияние таблиц настроек (массивы заменяются целиком)
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

  function U.fmt(x, d)
    if x == nil then return "" end
    if type(x) ~= "number" then return tostring(x) end
    return string.format("%." .. (d or 2) .. "f", x)
  end

  return U
end
