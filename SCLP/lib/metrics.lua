-- metrics.lua : position, P&L (gross / net of fees), trade statistics, latency, markouts, CSV journal.
--
-- Position and P&L use average-cost accounting on OUR fills only. A "trade" for win rate / profit factor is every
-- fill that reduces the position (the closed part is matched against the average entry price).
--   realized net   = realized gross - fees of the closed lots (entry fee pro rata + exit fee)
--   unrealized net = (mid - avg) * pos - entry fee still carried - estimated exit fee (maker, at mid)
--   equity         = realized net + unrealized net   (drawdown and P&L per hour are measured on it)
-- Markout of a fill = how far the market mid moved in our favour N seconds later, in ticks (+ good, - adverse
-- selection). Mid is taken from the book without our own orders.
return function(X)
  local M = {}
  X.M = M
  local U = X.U
  local abs, min, max, floor = math.abs, math.min, math.max, math.floor

  M.by_key = {}
  local pend = {}          -- fills waiting for markouts

  function M.get(inst)
    local m = M.by_key[inst.key]
    if not m then
      m = { key = inst.key, sec = inst.sec, lots = {}, pos = 0, avg = nil, open_fee = 0, realized = 0, fees = 0,
            n = 0, wins = 0, losses = 0, sum_win = 0, sum_loss = 0, max_abs_pos = 0, peak = 0, max_dd = 0,
            bought = 0, sold = 0, t0 = U.now(), mk = { 0, 0, 0 }, mk_n = 0, last_eq = 0 }
      M.by_key[inst.key] = m
    end
    return m
  end

  ------------------------------------------------------------------
  -- FEES (rubles). Fill in your tariff in sclp_config.lua -> FEES. Maker = passive order, taker = PANIC IOC.
  ------------------------------------------------------------------
  function M.fee(inst, q, px, taker)
    local F = (X.cfg.FEES or {})[inst.class] or (X.cfg.FEES or {}).default or {}
    local notional = abs(px) * (inst.point or 0) * q                 -- rubles
    local f = (F.BROKER_RUB or 0) * q + notional * (F.BROKER_PCT or 0) / 100
    if taker then f = f + (F.EXCH_TAKER_RUB or 0) * q + notional * (F.EXCH_TAKER_PCT or 0) / 100
    else f = f + (F.EXCH_MAKER_RUB or 0) * q + notional * (F.EXCH_MAKER_PCT or 0) / 100 end
    return f
  end

  ------------------------------------------------------------------
  -- FILLS: FIFO lots. m.lots holds the unmatched (open) fills, all on one side: { sgn, px, qty, fee_unit, tn, t, tp }.
  -- A closing fill is matched against the oldest lots first; whatever is left opens a new lot.
  ------------------------------------------------------------------
  local function record_trade(m, net)
    m.n = m.n + 1
    if net > 0 then m.wins = m.wins + 1; m.sum_win = m.sum_win + net
    elseif net < 0 then m.losses = m.losses + 1; m.sum_loss = m.sum_loss - net end
  end

  function M.recalc(m)
    local pos, cost, fee = 0, 0, 0
    for _, l in ipairs(m.lots) do
      pos = pos + l.sgn * l.qty
      cost = cost + l.px * l.qty
      fee = fee + l.fee_unit * l.qty
    end
    m.pos, m.open_fee = pos, fee
    m.avg = (pos ~= 0) and cost / abs(pos) or nil
    if abs(pos) > m.max_abs_pos then m.max_abs_pos = abs(pos) end
  end

  -- returns realized net of the closed part (nil if the fill only opened) and the lot it opened (or nil).
  -- opt.fee overrides the fee (0 for an adopted external position), opt.tn is the trade number.
  function M.on_fill(inst, o, q, px, t, opt)
    opt = opt or {}
    local m = M.get(inst)
    local sgn = (o.side == "B") and 1 or -1
    local taker = (o.mode == "taker") or o.taker_suspect
    local fee = opt.fee or M.fee(inst, q, px, taker)
    m.fees = m.fees + fee
    if sgn > 0 then m.bought = m.bought + q else m.sold = m.sold + q end
    local closed_net
    local left = q
    while left > 0 and m.lots[1] and m.lots[1].sgn ~= sgn do
      local lot = m.lots[1]
      local c = min(left, lot.qty)
      local gross = (px - lot.px) * c * lot.sgn * (inst.point or 0)
      m.realized = m.realized + gross
      closed_net = (closed_net or 0) + gross - lot.fee_unit * c - fee * c / q
      lot.qty = lot.qty - c
      left = left - c
      if lot.qty <= 0 then table.remove(m.lots, 1) end
    end
    if closed_net then record_trade(m, closed_net) end
    local lot
    if left > 0 then
      lot = { sgn = sgn, px = px, qty = left, fee_unit = fee / q, tn = opt.tn, t = t }
      m.lots[#m.lots + 1] = lot
    end
    M.recalc(m)
    if o.mode ~= "external" then
      local bk = inst.bk or {}
      pend[#pend + 1] = { t = t, inst = inst, sgn = sgn, px = px, q = q, o = o, mid0 = bk.mid, spread = bk.spread,
                          sigma = X.B.sigma(inst), pos = m.pos, avg = m.avg, net = closed_net, fee = fee,
                          taker = taker }
    end
    return closed_net, lot
  end

  -- break-even price (tick index, fractional) of closing q lots on `side` against the oldest open lots (FIFO):
  -- entry fees of those lots + the maker fee of the closing fill are covered. nil if there is nothing to close.
  function M.breakeven(inst, side, q)
    local m = M.get(inst)
    local sgn = (side == "S") and 1 or -1                  -- a sell closes long lots
    local left, cost, fee = q, 0, 0
    for _, l in ipairs(m.lots) do
      if left <= 0 or l.sgn ~= sgn then break end
      local c = math.min(left, l.qty)
      cost, fee, left = cost + l.px * c, fee + l.fee_unit * c, left - c
    end
    local n = q - left
    if n <= 0 or not inst.point or inst.point <= 0 then return nil end
    local px = cost / n
    local exit_fee = M.fee(inst, n, px, false)
    return px + sgn * (fee + exit_fee) / (n * inst.point)
  end

  -- position change that SCLP did not trade (manual trades, downtime gaps): booked at px without fee
  function M.adopt_external(inst, diff, px)
    if diff == 0 then return end
    local bk = inst.bk or {}
    px = px or bk.mid or M.get(inst).avg
    if not px then return end
    M.on_fill(inst, { side = diff > 0 and "B" or "S", mode = "external" }, abs(diff), px, U.now(), { fee = 0 })
    U.log(string.format("[%s] external position %+d adopted @ %s", inst.sec, diff, inst:px_str(px)))
  end

  -- new trading day: intraday statistics restart, open lots (and their entry fees) carry over
  function M.new_day(t)
    for _, m in pairs(M.by_key) do
      m.realized, m.n, m.wins, m.losses, m.sum_win, m.sum_loss = 0, 0, 0, 0, 0, 0
      m.fees = m.open_fee or 0
      m.peak, m.max_dd, m.bought, m.sold, m.t0, m.mk, m.mk_n, m.last_eq = 0, 0, 0, 0, t, { 0, 0, 0 }, 0, 0
      m.max_abs_pos = abs(m.pos)
    end
  end

  ------------------------------------------------------------------
  -- VALUATION
  ------------------------------------------------------------------
  function M.values(inst)
    local m = M.get(inst)
    local bk = inst.bk or {}
    local ug, exit_fee = 0, 0
    if m.pos ~= 0 and m.avg and bk.valid then
      ug = (bk.mid - m.avg) * m.pos * (inst.point or 0)
      exit_fee = M.fee(inst, abs(m.pos), bk.mid, false)
    end
    local real_net = m.realized - (m.fees - m.open_fee)
    local unreal_net = ug - m.open_fee - exit_fee
    return { real_gross = m.realized, real_net = real_net, unreal_gross = ug, unreal_net = unreal_net,
             equity = real_net + unreal_net, fees = m.fees, exposure = abs(m.pos) * (bk.mid or m.avg or 0) * (inst.point or 0) }
  end

  -- session totals over all instruments traded today
  function M.total_equity()
    local e = 0
    for _, m in pairs(M.by_key) do e = e + (m.last_eq or 0) end
    return e
  end

  ------------------------------------------------------------------
  -- LATENCY (ms): ring of the last 200 samples per kind
  ------------------------------------------------------------------
  M.lat = { key_send = {}, send_reply = {}, send_active = {} }
  function M.lat_add(kind, ms)
    if not ms or ms < 0 then return end
    local r = M.lat[kind]
    r[#r + 1] = ms
    if #r > 200 then table.remove(r, 1) end
  end
  function M.lat_stats(kind)
    local r = M.lat[kind]
    if #r == 0 then return nil end
    local s, a = 0, {}
    for i, v in ipairs(r) do s = s + v; a[i] = v end
    table.sort(a)
    return r[#r], s / #r, a[math.max(1, math.ceil(0.95 * #a))]
  end

  function M.on_send(o)
    if o.t_key then M.lat_add("key_send", (o.t_send - o.t_key) * 1000) end
  end
  function M.on_accept(o)
    if o.t_reply then M.lat_add("send_reply", (o.t_reply - o.t_send) * 1000) end
    if o.t_active and o.t_active ~= o.t_reply then M.lat_add("send_active", (o.t_active - o.t_send) * 1000) end
  end

  ------------------------------------------------------------------
  -- JOURNAL
  ------------------------------------------------------------------
  local function ms(a, b) return (a and b) and string.format("%.0f", (b - a) * 1000) or "" end

  function M.on_order_done(o)
    local inst = o.inst
    U.csv("sclp_orders", "date,time,sec,tid,side,price,qty,filled,src,mode,state,key_to_send_ms,send_to_reply_ms," ..
      "send_to_active_ms,life_ms,avg_fill_price,reject",
      table.concat({ U.date("%Y-%m-%d", o.t_send0), U.stamp(o.t_send0), inst.sec, o.tid, o.side, inst:px_str(o.px), o.qty,
        o.filled, o.src, o.mode, o.state, ms(o.t_key, o.t_send), ms(o.t_send, o.t_reply), ms(o.t_send, o.t_active),
        ms(o.t_send, o.t_done), (o.filled > 0 and o.cost) and U.fmt(o.cost / o.filled * inst.tick, inst.scale + 2) or "",
        ((o.reject_msg or ""):gsub("[,\r\n]", " ")) }, ","))
  end

  local HDR = "date,time,sec,side,qty,price,src,mode,tid,order_price,spread_ticks,sigma_ticks,mid,pos_after,avg_after," ..
              "realized_net_rub,fee_rub,taker,key_to_send_ms,send_to_reply_ms,mk1,mk2,mk3"
  local function flush_marks(t, force)
    local H = X.cfg.MARKOUT_SEC or { 1, 5, 30 }
    local keep = {}
    for _, f in ipairs(pend) do
      if force or t >= f.t + H[#H] then
        local inst, mk = f.inst, {}
        for i, h in ipairs(H) do
          local mid = (t >= f.t + h) and X.B.mid_at(inst, f.t + h) or nil
          mk[i] = mid and f.sgn * (mid - f.px) or nil
        end
        local m = M.get(inst)
        if mk[#H] then
          m.mk_n = m.mk_n + 1
          for i = 1, #H do m.mk[i] = (m.mk[i] or 0) + (mk[i] or 0) end
        end
        local o = f.o
        U.csv("sclp_fills", HDR, table.concat({ U.date("%Y-%m-%d", f.t), U.stamp(f.t), inst.sec, f.sgn > 0 and "B" or "S",
          f.q, inst:px_str(f.px), o.src, o.mode, o.tid, inst:px_str(o.px), f.spread or "", U.fmt(f.sigma, 3),
          f.mid0 and U.fmt(f.mid0 * inst.tick, inst.scale + 1) or "", f.pos, f.avg and U.fmt(f.avg * inst.tick, inst.scale + 2) or "",
          U.fmt(f.net, 2), U.fmt(f.fee, 2), f.taker and 1 or 0, ms(o.t_key, o.t_send), ms(o.t_send, o.t_reply),
          U.fmt(mk[1], 1), U.fmt(mk[2], 1), U.fmt(mk[3], 1) }, ","))
      else
        keep[#keep + 1] = f
      end
    end
    pend = keep
  end

  local t_snap = 0
  function M.tick(t)
    flush_marks(t)
    for _, m in pairs(M.by_key) do
      local inst = (X.inst and X.inst.key == m.key) and X.inst or nil
      if inst then
        local v = M.values(inst)
        m.last_eq = v.equity
        if v.equity > m.peak then m.peak = v.equity end
        if m.peak - v.equity > m.max_dd then m.max_dd = m.peak - v.equity end
      end
    end
    if X.inst and t - t_snap >= (X.cfg.SNAPSHOT_SEC or 60) then
      t_snap = t
      local inst = X.inst
      local m, v, st = M.get(inst), M.values(inst), X.O.st
      U.csv("sclp_session", "date,time,sec,pos,avg,equity_net,real_net,unreal_net,fees,trades,win_rate,max_dd,sent,fills,cancels,rejects,otr,spread,sigma",
        table.concat({ U.date("%Y-%m-%d", t), U.stamp(t), inst.sec, m.pos, m.avg and U.fmt(m.avg * inst.tick, inst.scale + 2) or "",
          U.fmt(v.equity, 2), U.fmt(v.real_net, 2), U.fmt(v.unreal_net, 2), U.fmt(v.fees, 2), m.n,
          m.n > 0 and U.fmt(m.wins / m.n, 3) or "", U.fmt(m.max_dd, 2), st.sent, st.fills, st.cancels, st.rejected,
          U.fmt(M.otr(), 2), inst.bk and inst.bk.spread or "", U.fmt(X.B.sigma(inst), 3) }, ","))
    end
  end
  function M.final(t) flush_marks(t, true) end

  -- order-to-trade ratio: (new orders + cancels) per fill
  function M.otr()
    local st = X.O.st
    return (st.sent + st.cancels) / max(1, st.fills)
  end

  function M.markouts(inst)
    local m = M.get(inst)
    if m.mk_n == 0 then return nil end
    return m.mk[1] / m.mk_n, m.mk[2] / m.mk_n, m.mk[3] / m.mk_n, m.mk_n
  end

  -- persistable part of one instrument (open lots + intraday statistics)
  function M.export_one(inst)
    local m = M.get(inst)
    return { lots = m.lots, realized = m.realized, fees = m.fees, n = m.n, wins = m.wins, losses = m.losses,
             sum_win = m.sum_win, sum_loss = m.sum_loss, max_abs_pos = m.max_abs_pos, peak = m.peak, max_dd = m.max_dd,
             bought = m.bought, sold = m.sold, t0 = m.t0, mk = m.mk, mk_n = m.mk_n, last_eq = m.last_eq }
  end
  -- restore one instrument. same_day = false: only the open lots carry over, intraday statistics restart
  function M.import_one(inst, s, same_day, t)
    local m = M.get(inst)
    m.lots = {}
    for _, l in ipairs((s and s.lots) or {}) do
      if (l.qty or 0) > 0 then
        m.lots[#m.lots + 1] = { sgn = l.sgn, px = l.px, qty = l.qty, fee_unit = l.fee_unit or 0, tn = l.tn, t = l.t, tp = l.tp }
      end
    end
    if s and same_day then
      for _, f in ipairs({ "realized", "fees", "n", "wins", "losses", "sum_win", "sum_loss", "max_abs_pos", "peak",
                           "max_dd", "bought", "sold", "t0", "mk", "mk_n", "last_eq" }) do
        if s[f] ~= nil then m[f] = s[f] end
      end
    end
    M.recalc(m)
    if not same_day then m.fees = m.open_fee; m.t0 = t end
  end

  return M
end
