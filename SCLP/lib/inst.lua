-- inst.lua : instrument lookup, validation and a parameter cache.
-- Input text: "SPBFUT BRX6", "SPBFUT.BRX6", "SPBFUT:BRX6", "BRX6" (class searched) or "BR" (nearest FORTS contract).
-- Static parameters (tick, decimals, lot) are read once; dynamic ones (step price, price limits, trading status)
-- are refreshed every PARAM_REFRESH_SEC instead of on every key press.
return function(X)
  local I = {}
  X.I = I
  local U = X.U
  local floor = math.floor

  local FORTS = { SPBFUT = true, SPBOPT = true }

  local function class_list(class)
    if not getClassSecurities then return "" end
    local ok, s = pcall(getClassSecurities, class)
    return ok and tostring(s or "") or ""
  end

  -- exact code first, then case-insensitive (FORTS short codes are mixed case: "SiZ6")
  local function find_code(class, code)
    local info = getSecurityInfo and getSecurityInfo(class, code)
    if info then return code end
    local up = code:upper()
    for c in class_list(class):gmatch("[^,]+") do
      if c:upper() == up then return c end
    end
    return nil
  end

  local function days_to(mat)
    mat = tonumber(mat)
    if not mat or mat <= 0 then return nil end
    local exp = os.time({ year = floor(mat / 10000), month = floor(mat / 100) % 100, day = mat % 100, hour = 18 })
    return (exp - U.now()) / 86400
  end

  -- "BR" -> nearest BR futures with more than EXPIRY_SKIP_DAYS to expiry (short code = base + month + year digit)
  local function nearest_future(class, base)
    local best, best_mat
    local ub = base:upper()
    for code in class_list(class):gmatch("[^,]+") do
      if #code == #base + 2 and code:sub(1, #base):upper() == ub then
        local info = getSecurityInfo(class, code)
        local mat = info and tonumber(info.mat_date)
        local dl = days_to(mat)
        if mat and dl and dl > (X.cfg.EXPIRY_SKIP_DAYS or 1) and (not best_mat or mat < best_mat) then
          best, best_mat = code, mat
        end
      end
    end
    return best
  end

  function I.parse(text)
    text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local class, code = text:match("^([%w_]+)[%s%.:/]+([%w_%-]+)$")
    if class then return class:upper(), code end
    if text:match("^[%w_%-]+$") then return nil, text end
    return nil, nil
  end

  -- returns inst or nil, error text
  function I.resolve(text)
    local class, code = I.parse(text)
    if not code then return nil, "формат: КЛАСС ТИКЕР (например SPBFUT BRX6) или ТИКЕР" end
    local found_class, found_code
    if class then
      found_code = find_code(class, code)
      found_class = found_code and class
      if not found_code and FORTS[class] then
        found_code = nearest_future(class, code)
        found_class = found_code and class
      end
    else
      for _, c in ipairs(X.cfg.CLASS_PRIORITY or { "SPBFUT" }) do
        found_code = find_code(c, code)
        if found_code then found_class = c; break end
      end
      if not found_code and getClassesList then
        local ok, list = pcall(getClassesList)
        for c in tostring(ok and list or ""):gmatch("[^,]+") do
          found_code = find_code(c, code)
          if found_code then found_class = c; break end
        end
      end
      if not found_code then
        found_code = nearest_future("SPBFUT", code)
        found_class = found_code and "SPBFUT"
      end
    end
    if not found_code then return nil, "инструмент не найден: " .. tostring(text) end
    return I.make(found_class, found_code)
  end

  function I.make(class, sec)
    local info = getSecurityInfo and getSecurityInfo(class, sec)
    if not info then return nil, "нет getSecurityInfo для " .. class .. " " .. sec end
    local tick = U.param(class, sec, "SEC_PRICE_STEP") or U.num(info.min_price_step)
    if not tick or tick <= 0 then return nil, "у " .. sec .. " не определён шаг цены" end
    local lot = U.num(info.lot_size) or U.param(class, sec, "LOTSIZE") or 1
    if lot <= 0 then lot = 1 end
    local inst = {
      class = class, sec = sec, key = class .. ":" .. sec,
      name = U.from_cp1251(info.short_name or info.name or sec),
      tick = tick, scale = tonumber(info.scale) or 2, lot = lot,
      forts = FORTS[class] or false, mat_date = tonumber(info.mat_date),
    }
    function inst:px_str(idx) return string.format("%." .. self.scale .. "f", idx * self.tick) end
    function inst:idx(price) return floor(price / self.tick + 0.5) end
    I.refresh(inst, U.now(), true)
    local dl = days_to(inst.mat_date)
    if inst.forts and dl and dl < 0 then return nil, sec .. ": контракт истёк" end
    return inst
  end

  -- step price, price limits, trading status
  function I.refresh(inst, t, force)
    if not force and t - (inst.t_refresh or 0) < (X.cfg.PARAM_REFRESH_SEC or 60) then return end
    inst.t_refresh = t
    local c, s = inst.class, inst.sec
    if inst.forts then
      local sp = U.param(c, s, "STEPPRICE")
      if sp and sp > 0 then inst.step_price = sp end
      inst.step_price = inst.step_price or (X.cfg.STEPPRICE_FALLBACK or {})[s]
      -- rubles per 1 tick per lot (contract)
      inst.point = inst.step_price or inst.tick
    else
      inst.point = inst.tick * inst.lot              -- quote currency (RUB for TQBR/TQTF) per tick per lot
    end
    local lo, hi = U.param(c, s, "PRICEMIN"), U.param(c, s, "PRICEMAX")
    inst.pmin = (lo and lo > 0) and math.ceil(lo / inst.tick - 1e-9) or nil
    inst.pmax = (hi and hi > 0) and floor(hi / inst.tick + 1e-9) or nil
    local _, st_img = U.param(c, s, "STATUS")
    local tv, ts_img = U.param(c, s, "TRADINGSTATUS")
    inst.status_text = (ts_img ~= "" and ts_img) or st_img or "?"
    inst.trading = I.status_ok(st_img, tv, ts_img)
  end

  -- true = trading, false = not trading, nil = unknown (do not block on unknown)
  -- (string.lower does not fold Cyrillic, so the first letter is left out of each pattern)
  function I.status_ok(st_img, ts_val, ts_img)
    local a, b = st_img or "", ts_img or ""
    if a:find("риостан", 1, true) or a:find("е торгуется", 1, true) or b:find("акрыт", 1, true)
       or b:find("риостан", 1, true) then return false end
    if b:find("ткрыт", 1, true) or a:find("оргуется", 1, true) then return true end
    if ts_val == 1 then return true end
    return nil
  end

  function I.in_limits(inst, px)
    if inst.pmin and px < inst.pmin then return false end
    if inst.pmax and px > inst.pmax then return false end
    return true
  end

  function I.describe(inst)
    return string.format("%s %s (шаг %s, лот %s%s)", inst.class, inst.sec, tostring(inst.tick), tostring(inst.lot),
      inst.forts and (", тик " .. U.fmt(inst.point, 2) .. " руб") or "")
  end

  return I
end
