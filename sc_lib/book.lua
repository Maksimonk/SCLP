-- book.lua : стакан, лента, сигналы, эпизоды "дырок" (журнал scalp_gaps).
-- Все цены внутри - целые индексы тиков (цена / шаг). Наши собственные реальные заявки
-- вычитаются из стакана ("чистый" стакан), чтобы робот не видел сам себя.
return function(SC)
  local K = {}
  SC.K = K
  local U = SC.U
  local exp, abs, floor, max, min = math.exp, math.abs, math.floor, math.max, math.min

  ------------------------------------------------------------------
  -- РАЗБОР getQuoteLevel2: bid по возрастанию (лучший - последний), offer по возрастанию (лучший - первый)
  ------------------------------------------------------------------
  local function parse_side(arr, cnt, tick, desc)
    local out = {}
    if type(arr) ~= "table" then return out end
    local n = tonumber(cnt) or #arr
    if desc then
      for i = n, 1, -1 do
        local e = arr[i]
        if e then
          local p, q = U.num(e.price), U.num(e.quantity)
          if p and q and q > 0 then out[#out + 1] = { p = U.round(p / tick), q = q } end
        end
      end
    else
      for i = 1, n do
        local e = arr[i]
        if e then
          local p, q = U.num(e.price), U.num(e.quantity)
          if p and q and q > 0 then out[#out + 1] = { p = U.round(p / tick), q = q } end
        end
      end
    end
    return out
  end

  local function net_side(levels, own)
    if not own or next(own) == nil then return levels end
    local out = {}
    for _, l in ipairs(levels) do
      local q = l.q - (own[l.p] or 0)
      if q > 0 then out[#out + 1] = { p = l.p, q = q } end
    end
    return out
  end

  local function same_book(a, b, n)
    if not a or not b then return false end
    for _, side in ipairs({ "bids", "asks" }) do
      local x, y = a[side], b[side]
      if #x ~= #y then return false end
      for i = 1, min(#x, n) do
        if x[i].p ~= y[i].p or x[i].q ~= y[i].q then return false end
      end
    end
    return true
  end

  function K.new_market(inst)
    inst.raw = nil            -- сырой стакан {bids, asks}
    inst.net = nil            -- без наших заявок
    inst.sig = { valid = false, ofi = 0, depth = nil }
    inst.tape = {}            -- последние сделки {t, p, q, side}
    inst.burst = { fast = 0, slow = 0, t = nil }
    inst.run = nil            -- текущая серия сделок одного агрессора
    inst.last_sweep = nil
    inst.ep = nil             -- текущий эпизод "дырки"
    inst.ep_pending = {}      -- закончившиеся эпизоды, ждут маркаутов
    inst.mids = {}            -- история середины {t, mid} (для маркаутов), 60 с
    inst.t_book_change = nil
    inst.t_book_read = nil
    inst.t_last_trade = nil
  end

  ------------------------------------------------------------------
  -- ИНТЕНСИВНОСТЬ СДЕЛОК (всплески)
  ------------------------------------------------------------------
  local function burst_decay(inst, t)
    local b, P = inst.burst, inst.P
    if b.t then
      local dt = max(0, t - b.t)
      b.fast = b.fast * exp(-dt / P.BURST_FAST_SEC)
      b.slow = b.slow * exp(-dt / P.BURST_SLOW_SEC)
    end
    b.t = t
  end
  function K.burst_ratio(inst, t)
    burst_decay(inst, t)
    local b, P = inst.burst, inst.P
    local rf = b.fast / P.BURST_FAST_SEC
    local rs = b.slow / P.BURST_SLOW_SEC
    if rs < 1 / P.BURST_SLOW_SEC * 5 then return 0 end   -- статистики мало
    return rf / rs
  end

  ------------------------------------------------------------------
  -- СИГНАЛЫ ПО ЧИСТОМУ СТАКАНУ
  ------------------------------------------------------------------
  local function compute(inst, t)
    local P, s, nb = inst.P, inst.sig, inst.net
    local prev = { bb = s.bb, ba = s.ba, bq = s.bq, aq = s.aq, valid = s.valid }
    local b1, a1 = nb.bids[1], nb.asks[1]
    if not b1 or not a1 or b1.p >= a1.p then
      s.valid = false
      return prev
    end
    s.valid = true
    s.bb, s.bq, s.ba, s.aq = b1.p, b1.q, a1.p, a1.q
    s.spread = a1.p - b1.p
    s.mid = (a1.p + b1.p) / 2
    s.imb1 = (b1.q - a1.q) / (b1.q + a1.q)
    s.micro = (a1.p * b1.q + b1.p * a1.q) / (b1.q + a1.q)     -- взвешенная середина
    -- многоуровневый дисбаланс: веса 1, 1/2, 1/4 ...
    local vb, va, w = 0, 0, 1
    for i = 1, P.BOOK_LEVELS do
      local b, a = nb.bids[i], nb.asks[i]
      if b then vb = vb + w * b.q end
      if a then va = va + w * a.q end
      w = w / 2
    end
    s.imbN = (vb + va > 0) and (vb - va) / (vb + va) or 0
    -- средняя глубина L1 (нормировка OFI и выносов)
    local d = (b1.q + a1.q) / 2
    if not s.depth then s.depth, s.t_depth = d, t
    else
      local a = 1 - exp(-max(0, t - (s.t_depth or t)) / P.DEPTH_TAU_SEC)
      s.depth = s.depth + max(a, 0.002) * (d - s.depth)
      s.t_depth = t
    end
    -- OFI (Cont-Kukanov-Stoikov): чистый приток объёма на лучших уровнях
    if prev.valid then
      local e = 0
      if s.bb >= prev.bb then e = e + s.bq end
      if s.bb <= prev.bb then e = e - prev.bq end
      if s.ba <= prev.ba then e = e - s.aq end
      if s.ba >= prev.ba then e = e + prev.aq end
      local dt = max(0, t - (s.t_ofi or t))
      s.ofi = (s.ofi or 0) * exp(-dt / P.OFI_TAU_SEC) + e
    else
      s.ofi = 0
    end
    s.t_ofi = t
    return prev
  end

  -- OFI на момент t (с затуханием), в средних глубинах L1. > 0 - давление покупателей.
  function K.ofi_norm(inst, t)
    local s = inst.sig
    if not s.valid or not s.depth or s.depth <= 0 then return 0 end
    local dt = max(0, t - (s.t_ofi or t))
    return (s.ofi or 0) * exp(-dt / inst.P.OFI_TAU_SEC) / s.depth
  end

  ------------------------------------------------------------------
  -- ЭПИЗОДЫ "ДЫРОК": спред >= GAP_MIN_SPREAD. Причина: вынос (сделки) или снятие заявок.
  ------------------------------------------------------------------
  local function traded_in(inst, t, side, lo, hi)
    -- объём агрессора side (-1 продавцы бьют в биды, +1 покупатели в аски) по ценам [lo, hi] за окно
    local v = 0
    local from = t - inst.P.CAUSE_LOOKBACK_SEC
    for i = #inst.tape, 1, -1 do
      local tr = inst.tape[i]
      if tr.t < from then break end
      if tr.side == side and tr.p >= lo and tr.p <= hi then v = v + tr.q end
    end
    return v
  end

  local function classify(inst, ep, t)
    local traded, removed = 0, 0
    for _, r in ipairs(ep.removed) do
      removed = removed + r.vol
      traded = traded + traded_in(inst, t, r.side, r.lo, r.hi)
    end
    ep.removed_vol, ep.traded_vol = removed, traded
    if removed <= 0 then ep.cause = "unknown"
    elseif traded >= inst.P.CAUSE_TRADE_FRAC * removed then ep.cause = "sweep"
    else ep.cause = "cancel" end
  end

  local function mid_at(inst, t)
    local m = inst.mids
    for i = #m, 1, -1 do
      if m[i].t <= t then return m[i].mid end
    end
    return m[1] and m[1].mid
  end

  local function start_episode(inst, prev, prev_net, t)
    local s, P = inst.sig, inst.P
    local ep = { t0 = t, mid0 = s.mid, spread0 = s.spread, max_spread = s.spread, removed = {}, side = "",
                 imb = s.imb1, burst = K.burst_ratio(inst, t), ref_move = SC.K.ref_move(inst, t), n_tr = 0 }
    if prev.valid and prev_net then
      if s.bb < prev.bb then            -- биды отступили: ушли уровни (bb, prev.bb]
        local vol = 0
        for _, l in ipairs(prev_net.bids) do if l.p > s.bb then vol = vol + l.q end end
        ep.removed[#ep.removed + 1] = { side = -1, lo = s.bb + 1, hi = prev.bb, vol = vol }
        ep.side = ep.side .. "B"
      end
      if s.ba > prev.ba then            -- аски отступили
        local vol = 0
        for _, l in ipairs(prev_net.asks) do if l.p < s.ba then vol = vol + l.q end end
        ep.removed[#ep.removed + 1] = { side = 1, lo = prev.ba, hi = s.ba - 1, vol = vol }
        ep.side = ep.side .. "S"
      end
    end
    classify(inst, ep, t)
    inst.ep = ep
  end

  local function end_episode(inst, t)
    local ep = inst.ep
    inst.ep = nil
    ep.t1 = t
    ep.mid1 = inst.sig.mid
    inst.gaps = inst.gaps or {}
    inst.gaps[ep.cause] = (inst.gaps[ep.cause] or 0) + 1
    inst.gap_dur = (inst.gap_dur or 0) + (t - ep.t0)
    inst.ep_pending[#inst.ep_pending + 1] = ep
  end

  function K.flush_episodes(inst, t, force)
    local keep = {}
    for _, ep in ipairs(inst.ep_pending) do
      if force or t >= ep.t0 + 30 then
        local function d(h)
          local m = mid_at(inst, ep.t0 + h)
          if not m or not ep.mid0 or t < ep.t0 + h then return "" end
          return U.fmt(m - ep.mid0, 1)
        end
        U.csv("scalp_gaps",
          "date,time,sec,spread0,max_spread,dur,cause,side,removed,traded,imb,burst,ref_move,dmid_end,dmid_1,dmid_5,dmid_30",
          table.concat({ U.date("%Y-%m-%d", ep.t0), U.date("%H:%M:%S", ep.t0) .. string.format(".%03d", floor((ep.t0 % 1) * 1000)),
            inst.sec, ep.spread0, ep.max_spread, U.fmt(ep.t1 - ep.t0, 3), ep.cause, ep.side,
            ep.removed_vol or 0, ep.traded_vol or 0, U.fmt(ep.imb, 2), U.fmt(ep.burst, 2), U.fmt(ep.ref_move, 1),
            U.fmt((ep.mid1 or ep.mid0) - ep.mid0, 1), d(1), d(5), d(30) }, ","))
      else
        keep[#keep + 1] = ep
      end
    end
    inst.ep_pending = keep
  end

  ------------------------------------------------------------------
  -- ЧТЕНИЕ СТАКАНА (на OnQuote и периодически)
  ------------------------------------------------------------------
  function K.read_book(inst, t)
    inst.t_book_read = t
    local ok, q = pcall(getQuoteLevel2, inst.class, inst.sec)
    if not ok or type(q) ~= "table" then return false end
    local raw = { bids = parse_side(q.bid, q.bid_count, inst.tick, true),
                  asks = parse_side(q.offer, q.offer_count, inst.tick, false) }
    local own = SC.O and SC.O.own_levels(inst) or {}
    local net = { bids = net_side(raw.bids, own.B), asks = net_side(raw.asks, own.S) }
    local changed = not same_book(raw, inst.raw, 10)
    if changed then inst.t_book_change = t end
    local net_changed = not same_book(net, inst.net, 10)
    inst.raw = raw
    local prev_net = inst.net
    inst.net = net
    if not net_changed and inst.sig.valid then return changed end
    local prev = compute(inst, t)
    local s = inst.sig
    if s.valid then
      local m = inst.mids
      if not m[#m] or m[#m].mid ~= s.mid then m[#m + 1] = { t = t, mid = s.mid } end
      while #m > 2 and m[2].t < t - 60 do table.remove(m, 1) end
      -- эпизод дырки
      local P = inst.P
      if inst.ep then
        if s.spread >= P.GAP_MIN_SPREAD then
          if s.spread > inst.ep.max_spread then inst.ep.max_spread = s.spread end
        else
          end_episode(inst, t)
        end
      elseif s.spread >= P.GAP_MIN_SPREAD then
        start_episode(inst, prev, prev_net, t)
      end
    end
    if SC.cfg.RECORD_MARKET and changed then K.record_book(inst, t) end
    return changed
  end

  ------------------------------------------------------------------
  -- ЛЕНТА
  ------------------------------------------------------------------
  function K.on_tape(inst, tr, t)
    local P = inst.P
    local p = U.round(U.num(tr.price) / inst.tick)
    local q = U.num(tr.qty) or 0
    local fl = tonumber(tr.flags) or 0
    local side = U.bit(fl, 0) and -1 or (U.bit(fl, 1) and 1 or 0)   -- бит 0 - продажа, бит 1 - покупка
    local s = inst.sig
    if s.valid and inst.raw and inst.raw.bids[1] and inst.raw.asks[1] then
      local lo, hi = inst.raw.bids[1].p - P.TAPE_OFFBOOK_TICKS, inst.raw.asks[1].p + P.TAPE_OFFBOOK_TICKS
      -- вынос проходит стакан - допускаем далеко только по ходу агрессора
      if (side == -1 and p > hi) or (side == 1 and p < lo) or (side == 0 and (p < lo or p > hi)) then return nil end
    end
    inst.t_last_trade = t
    local e = { t = t, p = p, q = q, side = side }
    local tape = inst.tape
    tape[#tape + 1] = e
    if #tape > 2000 or (tape[1] and tape[1].t < t - 30 and #tape > 50) then
      local cut = {}
      for i = 1, #tape do if tape[i].t >= t - 30 then cut[#cut + 1] = tape[i] end end
      inst.tape = cut
    end
    burst_decay(inst, t)
    inst.burst.fast = inst.burst.fast + 1
    inst.burst.slow = inst.burst.slow + 1
    -- серия одного агрессора -> вынос
    if side ~= 0 then
      local r = inst.run
      if r and r.side == side and t - r.t_last <= P.SWEEP_JOIN_SEC then
        r.t_last = t; r.vol = r.vol + q; r.n = r.n + 1
        if (side > 0 and p > r.p_ext) or (side < 0 and p < r.p_ext) then r.p_ext = p end
      else
        r = { side = side, t0 = t, t_last = t, p_first = p, p_ext = p, vol = q, n = 1 }
        inst.run = r
      end
      local levels = abs(r.p_ext - r.p_first) + 1
      local depth = s.depth or 1
      if levels >= P.SWEEP_MIN_LEVELS or r.vol >= P.SWEEP_VOL_K * depth then
        inst.last_sweep = { side = side, t = t, t0 = r.t0, levels = levels, vol = r.vol,
                            p_first = r.p_first, p_ext = r.p_ext,
                            big = levels >= P.FADE_MIN_LEVELS or r.vol >= P.FADE_VOL_K * depth }
      end
    end
    -- уточняем причину свежего эпизода (лента приходит позже стакана)
    local ep = inst.ep
    if ep then
      ep.n_tr = ep.n_tr + 1
      if t - ep.t0 <= 0.5 then classify(inst, ep, t) end
    end
    if SC.cfg.RECORD_MARKET then
      U.csv("rec_scalp_" .. inst.sec, "kind,t,a,b,c,d,levels",
        string.format("T,%.3f,%d,%s,%d", t, p, U.fmt(q, 0), side))
    end
    return e
  end

  function K.record_book(inst, t)
    local r = inst.raw
    local parts = {}
    for i = 1, 5 do local l = r.bids[i]; if l then parts[#parts + 1] = "b" .. l.p .. ":" .. U.fmt(l.q, 0) end end
    for i = 1, 5 do local l = r.asks[i]; if l then parts[#parts + 1] = "a" .. l.p .. ":" .. U.fmt(l.q, 0) end end
    local b1, a1 = r.bids[1], r.asks[1]
    U.csv("rec_scalp_" .. inst.sec, "kind,t,a,b,c,d,levels",
      string.format("B,%.3f,%s,%s,%s,%s,%s", t, b1 and b1.p or "", b1 and U.fmt(b1.q, 0) or "",
        a1 and a1.p or "", a1 and U.fmt(a1.q, 0) or "", table.concat(parts, " ")))
  end

  ------------------------------------------------------------------
  -- ОПОРНЫЙ ИНСТРУМЕНТ (BR для BM): только середина
  ------------------------------------------------------------------
  function K.read_ref(inst, t)
    local R = inst.ref
    if not R then return end
    R.t_read = t
    local mid
    if R.source ~= "last" then                     -- середина стакана опорного
      local ok, q = pcall(getQuoteLevel2, R.class, R.sec)
      if ok and type(q) == "table" then
        local bids = parse_side(q.bid, q.bid_count, R.tick, true)
        local asks = parse_side(q.offer, q.offer_count, R.tick, false)
        if bids[1] and asks[1] and bids[1].p < asks[1].p then mid = (bids[1].p + asks[1].p) / 2 * R.tick end
      end
    end
    if not mid and getParamEx then                 -- индекс (стакана нет) или пустой стакан: последняя цена
      local ok, p = pcall(getParamEx, R.class, R.sec, "LAST")
      if ok and p and tonumber(p.param_type) ~= 0 then mid = U.num(p.param_value) end
      if mid and mid <= 0 then mid = nil end
    end
    if not mid then R.valid = false; return end
    R.valid = true
    local m = R.mids
    if not m[#m] or m[#m].mid ~= mid then m[#m + 1] = { t = t, mid = mid } end
    while #m > 2 and m[2].t < t - 30 do table.remove(m, 1) end
  end

  -- движение опорного за REF_WINDOW_SEC в ПРОЦЕНТАХ, пересчитанное в тики инструмента (процент x его цена):
  -- так годится любая пара - GLDRUBF (руб/г) за GD ($/унция), IMOEXF за индексом IMOEX. nil - неизвестно
  function K.ref_move(inst, t, window)
    local R = inst.ref
    if not R or not R.valid or not R.t_read or t - R.t_read > inst.P.REF_STALE_SEC then return nil end
    local m = R.mids
    if #m == 0 then return nil end
    window = window or inst.P.REF_WINDOW_SEC
    local now = m[#m].mid
    local base = m[1].mid
    for i = #m, 1, -1 do
      if m[i].t <= t - window then base = m[i].mid; break end
      base = m[i].mid
    end
    -- максимальное отклонение в окне (не только конец - начало)
    local mx = 0
    for i = #m, 1, -1 do
      if m[i].t < t - window then break end
      local d = m[i].mid - base
      if abs(d) > abs(mx) then mx = d end
    end
    local d = now - base
    if abs(mx) > abs(d) then d = mx end
    local s = inst.sig
    if base <= 0 or not s.valid then return nil end
    return d / base * s.mid                         -- s.mid - цена инструмента в тиках
  end

  return K
end
