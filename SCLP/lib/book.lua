-- book.lua : order book (Level II) of the active instrument.
-- Our own resting orders are subtracted ("net" book): quoting off the net best never pennies our own order,
-- and markouts/spread are measured on the market without us.
return function(X)
  local B = {}
  X.B = B
  local U = X.U
  local floor, exp, sqrt, min, max = math.floor, math.exp, math.sqrt, math.min, math.max

  function B.new(inst)
    inst.bk = { valid = false, mids = {}, mh = 1, var = nil, t_var = nil, mid_var = nil,
                spread_avg = nil, t_spread = nil, t_change = nil, t_read = nil }
  end

  -- returns the side without our volume, and the best price as QUIK shows it (our orders included)
  local function parse(arr, cnt, inst, desc, own)
    local out, shown = {}, nil
    if type(arr) ~= "table" then return out end
    local n = tonumber(cnt) or #arr
    local i0, i1, step = 1, n, 1
    if desc then i0, i1, step = n, 1, -1 end          -- QUIK: bids ascending (best last), offers ascending (best first)
    for i = i0, i1, step do
      local e = arr[i]
      if e then
        local p, q = U.num(e.price), U.num(e.quantity)
        if p and q and q > 0 then
          local idx = floor(p / inst.tick + 0.5)
          shown = shown or idx
          local mine = own and own[idx] or 0
          if q - mine > 0 then out[#out + 1] = { p = idx, q = q - mine } end
        end
      end
    end
    return out, shown
  end

  -- read the book now; returns bk (bk.valid = false if a side is empty or the book is crossed)
  function B.read(inst, t)
    local bk = inst.bk
    bk.t_read = t
    if not getQuoteLevel2 then bk.valid = false; return bk end
    local ok, q = pcall(getQuoteLevel2, inst.class, inst.sec)
    if not ok or type(q) ~= "table" then bk.valid = false; return bk end
    local own = X.O.own_levels(inst)
    local bids, sbb = parse(q.bid, q.bid_count, inst, true, own.B)
    local asks, sba = parse(q.offer, q.offer_count, inst, false, own.S)
    bk.shown_bb, bk.shown_ba = sbb, sba            -- best prices exactly as in the QUIK order book
    local b1, a1 = bids[1], asks[1]
    local sig = (b1 and b1.p or -1) .. ":" .. (b1 and b1.q or 0) .. ":" .. (a1 and a1.p or -1) .. ":" .. (a1 and a1.q or 0)
    if sig ~= bk.sig then bk.sig = sig; bk.t_change = t end
    bk.bids, bk.asks = bids, asks
    bk.own_min_sell, bk.own_max_buy = own.min_sell, own.max_buy
    if not b1 or not a1 or b1.p >= a1.p then
      bk.valid = false
      bk.bb, bk.ba = b1 and b1.p, a1 and a1.p
      return bk
    end
    bk.valid = true
    bk.bb, bk.bq, bk.ba, bk.aq = b1.p, b1.q, a1.p, a1.q
    bk.spread = a1.p - b1.p
    bk.mid = (a1.p + b1.p) / 2
    B.sample(inst, t)
    return bk
  end

  -- mid history (markouts), volatility (EWMA of squared 1 s mid changes) and average spread
  function B.sample(inst, t)
    local bk, P = inst.bk, X.cfg
    local m = bk.mids
    local last = m[#m]
    if not last or last.mid ~= bk.mid then m[#m + 1] = { t = t, mid = bk.mid } end
    -- drop history older than 120 s without shifting the array on every insert
    while bk.mh < #m and m[bk.mh].t < t - 120 do bk.mh = bk.mh + 1 end
    if bk.mh > 200 then
      local keep = {}
      for i = bk.mh, #m do keep[#keep + 1] = m[i] end
      bk.mids, bk.mh = keep, 1
    end
    if not bk.t_var then bk.t_var, bk.mid_var = t, bk.mid
    elseif t - bk.t_var >= 1 then
      local dt = t - bk.t_var
      local d = U.clamp(bk.mid - bk.mid_var, -30, 30)
      local a = 1 - exp(-dt / (P.VOL_TAU_SEC or 300))
      local x = d * d / dt
      bk.var = bk.var and (bk.var + a * (x - bk.var)) or x
      bk.t_var, bk.mid_var = t, bk.mid
    end
    if not bk.spread_avg then bk.spread_avg, bk.t_spread = bk.spread, t
    else
      local a = 1 - exp(-max(0, t - bk.t_spread) / (P.SPREAD_TAU_SEC or 300))
      bk.spread_avg = bk.spread_avg + max(a, 0.001) * (bk.spread - bk.spread_avg)
      bk.t_spread = t
    end
  end

  -- volatility, ticks per sqrt(second)
  function B.sigma(inst)
    local v = inst.bk and inst.bk.var
    return v and sqrt(v) or nil
  end

  function B.mid_at(inst, t)
    local bk = inst.bk
    local m = bk.mids
    for i = #m, bk.mh, -1 do
      if m[i].t <= t then return m[i].mid end
    end
    return m[bk.mh] and m[bk.mh].mid
  end

  -- best opposite price we may not touch: the others' best and our own opposite orders (self-cross)
  function B.passive_cap(inst, side)
    local bk = inst.bk
    if side == "B" then
      local cap = bk.ba and (bk.ba - 1)
      if bk.own_min_sell then cap = cap and min(cap, bk.own_min_sell - 1) or (bk.own_min_sell - 1) end
      return cap
    else
      local cap = bk.bb and (bk.bb + 1)
      if bk.own_max_buy then cap = cap and max(cap, bk.own_max_buy + 1) or (bk.own_max_buy + 1) end
      return cap
    end
  end

  return B
end
