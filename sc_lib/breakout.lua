-- breakout.lua : ИМПУЛЬСНЫЕ СЕТАПЫ (вход ТЕЙКЕРОМ - с биржевым сбором). По умолчанию "paper".
--
--   MOMO    - Taker Momentum: скорость дельты d(dV)/dt по квантам CVD_QUANTUM_SEC (за MOMO_QUANTA квантов)
--             превысила MOMO_Z стандартных отклонений, середина подтверждает -> покупка/продажа по рынку.
--             Выход: тейк, тайм-стоп MOMO_HOLD_SEC, затухание скорости (z < MOMO_EXIT_Z), стоп по цене.
--   SQZ     - Volatility Breakout: адаптивный канал Кельтнера KAMA +- SQZ_KC_K * ATR на барах SQZ_BAR_SEC.
--             Сжатие (squeeze): полосы Боллинджера (SQZ_BB_K * sd) внутри канала Кельтнера. После сжатия цена
--             вышла за канал -> вход по рынку в сторону выхода. Выход: тейк SQZ_TP_ATR * ATR, возврат за центр
--             канала, тайм-стоп.
--   NEWS    - News / Opening Range Breakout с OCO: диапазон [low, high] за NEWS_RANGE_SEC до события (время из
--             NEWS_TIMES). От NEWS_FREEZE_SEC до события и NEWS_ACTIVE_SEC после взведены две связанные заявки
--             stop-limit: покупка при high + NEWS_BUF_TICKS и продажа при low - NEWS_BUF_TICKS, предельная цена -
--             с допуском проскальзывания NEWS_SLIP_TICKS (дальше - не исполняется). Сработала одна - вторая
--             снимается (One-Cancels-the-Other). Стоп-заявки QUIK медленные (200-2000 мс), поэтому триггер
--             отслеживает робот, а на биржу уходит лимитированная "снять остаток" с предельной ценой.
--             Время открытия сессии в NEWS_TIMES = Opening Range Breakout.
-- Все выходы из этих сетапов - ТЕЙКЕРОМ (через механизм жёсткого стопа), кроме тейка (пассивный).
return function(SC)
  local B = {}
  SC.BO = B
  local U = SC.U
  local abs, floor, ceil, max, min, sqrt = math.abs, math.floor, math.ceil, math.max, math.min, math.sqrt

  local function adverse(c)
    local s = c.inst.sig
    return (c.pos > 0) and (c.avg - s.mid) or (s.mid - c.avg)
  end

  local function taker_leg(inst, side, slip)
    local s = inst.sig
    local px = (side == "B") and (s.ba + slip) or (s.bb - slip)
    return { side = side, px = px, qty = inst.P.QUOTE_SIZE, taker = true }
  end

  ------------------------------------------------------------------
  -- MOMO: импульс по скорости дельты
  ------------------------------------------------------------------
  function B.momo_propose(inst, backend, t)
    local P, s = inst.P, inst.sig
    local name = "MOMO"
    local nope = SC.S.nope
    if not inst.A or inst.A.cv_n < P.CVD_MIN_N then return nil end
    local z = SC.A.cvd_z(inst)
    if abs(z) < P.MOMO_Z then return nil end
    if SC.S.since_end(inst, name, backend, t) < P.MOMO_COOLDOWN_SEC then return nope(inst, name, "cooldown") end
    local dir = (z > 0) and 1 or -1
    -- цена подтверждает: середина за MOMO_CONFIRM_SEC сдвинулась в сторону потока
    local m0
    for i = #inst.mids, 1, -1 do
      if inst.mids[i].t <= t - P.MOMO_CONFIRM_SEC then m0 = inst.mids[i].mid; break end
    end
    if not m0 or dir * (s.mid - m0) < P.MOMO_MIN_MOVE_TICKS then return nope(inst, name, "no_price_confirm") end
    if s.spread > P.MOMO_MAX_SPREAD then return nope(inst, name, "spread") end
    local side = (dir > 0) and "B" or "S"
    local sg = SC.A.sigma_or(inst)
    local tp = max(P.MOMO_TP_TICKS, floor(P.MOMO_TP_SIGMA * sg * sqrt(P.MOMO_HOLD_SEC) + 0.5))
    local stop = max(P.MOMO_STOP_TICKS, floor(P.MOMO_STOP_SIGMA * sg * sqrt(P.MOMO_HOLD_SEC) + 0.5))
    return {
      setup = name, pair = false, taker = true, exit_mode = "TP",
      legs = { taker_leg(inst, side, P.MOMO_SLIP_TICKS) },
      tp = function(c) return (c.pos > 0) and ceil(c.avg + tp - 1e-9) or floor(c.avg - tp + 1e-9) end,
      exit_check = function(c, tt)
        local age = tt - (c.t_pos or tt)
        if adverse(c) >= stop then return "stop" end
        if age >= P.MOMO_HOLD_SEC then return "time" end
        if age >= P.MOMO_MIN_HOLD_SEC and dir * SC.A.cvd_z(inst) < P.MOMO_EXIT_Z then return "fade" end
      end,
      info = { z = z, tp = tp, stop = stop },
    }
  end

  ------------------------------------------------------------------
  -- SQZ: бары, адаптивный центр (KAMA), ATR, полосы Боллинджера, сжатие
  ------------------------------------------------------------------
  local function bars(inst)
    inst.BO = inst.BO or { list = {}, cur = nil, kama = nil, atr = nil, sq = {}, fired = false }
    return inst.BO
  end

  local function close_bar(inst, b)
    local P, st = inst.P, bars(inst)
    local L = st.list
    local prev = L[#L]
    L[#L + 1] = b
    if #L > 300 then table.remove(L, 1) end
    -- ATR (Уайлдер)
    local tr = b.h - b.l
    if prev then tr = max(tr, abs(b.h - prev.c), abs(b.l - prev.c)) end
    st.atr = st.atr and (st.atr + (tr - st.atr) / P.SQZ_ATR_N) or tr
    -- KAMA (Кауфман): скорость центра зависит от эффективности движения
    local n = P.SQZ_EMA_N
    if not st.kama then st.kama = b.c
    elseif #L > n then
      local change = abs(b.c - L[#L - n].c)
      local vol = 0
      for i = #L - n + 1, #L do vol = vol + abs(L[i].c - L[i - 1].c) end
      local er = (vol > 0) and change / vol or 0
      local fast, slow = 2 / (2 + 1), 2 / (30 + 1)
      local sc = (er * (fast - slow) + slow) ^ 2
      st.kama = st.kama + sc * (b.c - st.kama)
    else
      st.kama = st.kama + 2 / (n + 1) * (b.c - st.kama)
    end
    -- полосы Боллинджера внутри канала Кельтнера -> сжатие
    local sq = false
    if #L >= n then
      local m = 0
      for i = #L - n + 1, #L do m = m + L[i].c end
      m = m / n
      local v = 0
      for i = #L - n + 1, #L do v = v + (L[i].c - m) ^ 2 end
      local sd = sqrt(v / n)
      sq = (P.SQZ_BB_K * sd) < (P.SQZ_KC_K * st.atr)
    end
    st.sq[#st.sq + 1] = sq
    if #st.sq > 50 then table.remove(st.sq, 1) end
    if sq then st.fired = false end                       -- новое сжатие - можно снова входить
  end

  function B.tick(inst, t)
    local s = inst.sig
    if not s.valid then return end
    local P = inst.P
    if (P.SETUPS.SQZ or "off") == "off" then return end
    local st = bars(inst)
    local idx = floor(t / P.SQZ_BAR_SEC)
    local b = st.cur
    if b and b.idx ~= idx then close_bar(inst, b); b = nil end
    if not b then b = { idx = idx, o = s.mid, h = s.mid, l = s.mid, c = s.mid }; st.cur = b end
    b.h, b.l, b.c = max(b.h, s.mid), min(b.l, s.mid), s.mid
  end

  local function squeezed_recently(st, n)
    for i = #st.sq, max(1, #st.sq - n + 1), -1 do if st.sq[i] then return true end end
    return false
  end

  function B.sqz_propose(inst, backend, t)
    local P, s = inst.P, inst.sig
    local name = "SQZ"
    local st = bars(inst)
    if #st.list < P.SQZ_EMA_N or not st.atr or st.atr <= 0 then return nil end
    if st.fired or not squeezed_recently(st, P.SQZ_LOOKBACK) then return nil end
    local up, dn = st.kama + P.SQZ_KC_K * st.atr, st.kama - P.SQZ_KC_K * st.atr
    local side
    if s.mid > up then side = "B" elseif s.mid < dn then side = "S" else return nil end
    if SC.S.since_end(inst, name, backend, t) < P.SQZ_COOLDOWN_SEC then return SC.S.nope(inst, name, "cooldown") end
    st.fired = true
    local atr, center = st.atr, st.kama
    local tp = max(1, floor(P.SQZ_TP_ATR * atr + 0.5))
    return {
      setup = name, pair = false, taker = true, exit_mode = "TP",
      legs = { taker_leg(inst, side, P.SQZ_SLIP_TICKS) },
      tp = function(c) return (c.pos > 0) and ceil(c.avg + tp - 1e-9) or floor(c.avg - tp + 1e-9) end,
      exit_check = function(c, tt)
        local m = c.inst.sig.mid
        if (c.pos > 0 and m < center) or (c.pos < 0 and m > center) then return "back_in_channel" end
        if adverse(c) >= max(P.SQZ_STOP_ATR * atr, 1) then return "stop" end
        if tt - (c.t_pos or tt) >= P.SQZ_HOLD_SEC then return "time" end
      end,
      info = { atr = atr, center = center - s.mid, tp = tp },
    }
  end

  ------------------------------------------------------------------
  -- NEWS: диапазон до события и OCO-пробой
  ------------------------------------------------------------------
  -- время события сегодня (с полуночи МСК) или nil; "HH:MM:SS" - каждый день, "YYYY-MM-DD HH:MM:SS" - только в эту дату
  local function event_sec(e, t)
    local d, hms = tostring(e):match("^(%d%d%d%d%-%d%d%-%d%d)%s+(.+)$")
    if d and d ~= U.date("%Y-%m-%d", t) then return nil end
    return U.hms(hms or e)
  end

  function B.news_propose(inst, backend, t)
    local P, s = inst.P, inst.sig
    local name = "NEWS"
    local list = P.NEWS_TIMES or {}
    if #list == 0 then return nil end
    inst.NEWS = inst.NEWS or {}
    local now = U.msk_sec(t)
    local day = U.date("%Y%m%d", t)
    for _, e in ipairs(list) do
      local T = event_sec(e, t)
      if T then
        local key = day .. "|" .. tostring(e) .. "|" .. backend
        local ev = inst.NEWS[key]
        if not ev and now >= T - P.NEWS_RANGE_SEC and now < T + P.NEWS_ACTIVE_SEC then
          ev = { lo = nil, hi = nil, done = false }
          inst.NEWS[key] = ev
        end
        if ev and not ev.done then
          if now < T - P.NEWS_FREEZE_SEC then
            ev.lo = ev.lo and min(ev.lo, s.bb) or s.bb            -- строим диапазон
            ev.hi = ev.hi and max(ev.hi, s.ba) or s.ba
          elseif now >= T + P.NEWS_ACTIVE_SEC then
            ev.done = true
          elseif ev.lo and ev.hi and (ev.hi - ev.lo) >= P.NEWS_MIN_RANGE_TICKS then
            local trig_b, trig_s = ev.hi + P.NEWS_BUF_TICKS, ev.lo - P.NEWS_BUF_TICKS
            local side, lim
            if s.ba >= trig_b then side, lim = "B", trig_b + P.NEWS_SLIP_TICKS
            elseif s.bb <= trig_s then side, lim = "S", trig_s - P.NEWS_SLIP_TICKS end
            if side then
              ev.done = true                                       -- OCO: вторая сторона снята
              local width, mid_r = ev.hi - ev.lo, (ev.hi + ev.lo) / 2
              local tp = max(1, floor(P.NEWS_TP_K * width + 0.5))
              U.log(string.format("[%s] NEWS %s: range %s..%s, %s trigger, limit %s (slippage tolerance)", inst.sec,
                tostring(e), inst:price_str(ev.lo), inst:price_str(ev.hi), side == "B" and "BUY" or "SELL", inst:price_str(lim)))
              return {
                setup = name, pair = false, taker = true, exit_mode = "TP",
                legs = { { side = side, px = lim, qty = P.QUOTE_SIZE, taker = true } },
                tp = function(c) return (c.pos > 0) and ceil(c.avg + tp - 1e-9) or floor(c.avg - tp + 1e-9) end,
                exit_check = function(c, tt)
                  local m = c.inst.sig.mid
                  if (c.pos > 0 and m <= mid_r) or (c.pos < 0 and m >= mid_r) then return "back_in_range" end
                  if tt - (c.t_pos or tt) >= P.NEWS_HOLD_SEC then return "time" end
                end,
                info = { lo = ev.lo - s.mid, hi = ev.hi - s.mid, width = width },
              }
            end
          end
        end
      end
    end
    for k in pairs(inst.NEWS) do if k:sub(1, 8) ~= day then inst.NEWS[k] = nil end end
    return nil
  end

  return B
end
