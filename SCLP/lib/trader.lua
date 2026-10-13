-- trader.lua : what the keys do. Passive pricing, take-profit, passive flatten, PANIC.
-- Orders are not moved by the script, with ONE exception (R toggles it): an order that CLOSES the position follows the
-- market by its offset rule, but never to a price where the close would lose money (break-even = FIFO entry price of
-- the lots it closes + entry and exit fees). Opening orders and take-profits always stay where you put them.
--
-- OFFSET (ticks, signed) is applied to OUR OWN side of the book, measured on the book WITHOUT our orders:
--   BUY  price = best bid + offset        SELL price = best ask - offset
--   offset >= 0 only: 0 joins the best level, > 0 improves inside the spread.
-- Then the price is capped so the order can never take liquidity:
--   BUY  <= best ask - 1  and  < our lowest sell        SELL >= best bid + 1  and  > our highest buy
-- (the second half prevents a cross-trade with ourselves, which MOEX rejects and counts as an erroneous transaction).
-- Why the own side: anchoring a sell on the bid (bid + offset) makes offset 0 a taker and offset 1 a join or an
-- improvement depending on the spread width - the same key would mean different things on every tick.
-- With the own-side anchor offset keeps one meaning (queue position relative to the competition) and a too large
-- offset degrades gracefully to "most aggressive passive price".
return function(X)
  local T = {}
  X.T = T
  local U = X.U
  local abs, min, max = math.abs, math.min, math.max

  local function opp(side) return side == "B" and "S" or "B" end
  local function reduce_src(src) return src == "tp" or src == "flat" end

  ------------------------------------------------------------------
  -- PRICING
  ------------------------------------------------------------------
  function T.skew(inst)
    if not X.st.skew then return 0 end
    return U.round((X.cfg.SKEW_TICKS_PER_LOT or 0.5) * X.M.get(inst).pos)
  end

  -- passive price for a side: px, note | nil, reason
  function T.price(inst, side, offset)
    local bk = inst.bk
    if not bk.valid then return nil, "нет стакана" end
    offset = math.max(0, offset or 0)                          -- never behind the best price
    local px = (side == "B") and (bk.bb + offset) or (bk.ba - offset)
    px = px - T.skew(inst)
    local cap = X.B.passive_cap(inst, side)
    local note
    if side == "B" and px > cap then px, note = cap, "прижата к аск-1" end
    if side == "S" and px < cap then px, note = cap, "прижата к бид+1" end
    if inst.pmax and side == "B" and px > inst.pmax then px = inst.pmax end
    if inst.pmin and side == "S" and px < inst.pmin then px = inst.pmin end
    if not X.I.in_limits(inst, px) then return nil, "цена вне лимитов биржи" end
    return px, note
  end

  -- most aggressive passive price (passive flatten)
  function T.edge_price(inst, side)
    if not inst.bk.valid then return nil end
    local px = X.B.passive_cap(inst, side)
    if not X.I.in_limits(inst, px) then return nil end
    return px
  end

  -- final guard right before sending: the order must rest
  local function passive_ok(inst, side, px)
    local cap = X.B.passive_cap(inst, side)
    if not cap then return false end
    if side == "B" then return px <= cap end
    return px >= cap
  end

  ------------------------------------------------------------------
  -- ORDERS FROM KEYS
  ------------------------------------------------------------------
  local last_key = {}
  function T.key_order(side, t_key, t)
    local inst = X.inst
    if not inst then X.say("Сначала выберите инструмент"); return end
    local cd = (X.cfg.KEY_COOLDOWN_MS or 250) / 1000
    if t_key - (last_key[side] or -1e9) < cd then return end             -- key auto-repeat
    last_key[side] = t_key
    X.B.read(inst, t)                                                    -- freshest book for pricing
    local qty, offset = X.st.qty, X.st.offset
    local ok, why = X.R.can_open(inst, side, qty, t)
    if not ok then X.say((side == "B" and "Покупка" or "Продажа") .. " не отправлена: " .. why, "warn"); return end
    local px, note = T.price(inst, side, offset)
    if not px then X.say("Заявка не отправлена: " .. note, "warn"); return end
    if not passive_ok(inst, side, px) then
      X.say("Заявка стала бы тейкерской - не отправлена", "warn")
      return
    end
    local o, err = X.O.place(inst, side, px, qty, { src = "key", t_key = t_key, offset = offset, px0 = px }, t)
    if not o then X.say("Не отправлена: " .. tostring(err), "warn"); return end
    X.M.on_send(o)
    X.say(string.format("%s %d @ %s (%s%+d)%s", side == "B" and "ПОКУПКА" or "ПРОДАЖА", qty, inst:px_str(px),
      side == "B" and "бид" or "аск", side == "B" and offset or -offset, note and (", " .. note) or ""))
  end

  -- passive flatten: one closing order at the most aggressive passive price (not moved afterwards)
  function T.flatten_passive(t)
    local inst = X.inst
    if not inst then return end
    X.B.read(inst, t)
    local pos = X.M.get(inst).pos
    if pos == 0 then X.say("Позиция 0 - закрывать нечего"); return end
    local side = pos > 0 and "S" or "B"
    -- orders that would add to the position go first
    T.cancel_where(function(o) return o.side == opp(side) end, "flatten", t)
    local need = abs(pos) - X.O.working_qty(inst, side)
    if need <= 0 then X.say("Закрывающие заявки уже стоят"); return end
    local ok, why = X.R.can_reduce(inst, t)
    if not ok then X.say("Закрытие не отправлено: " .. why, "warn"); return end
    local px = T.edge_price(inst, side)
    if not px then X.say("Закрытие: нет цены", "warn"); return end
    local o = X.O.place(inst, side, px, need, { src = "flat", px0 = px }, t)
    if o then X.say(string.format("ЗАКРЫТИЕ пассивно %s %d @ %s", side == "B" and "покупка" or "продажа", need, inst:px_str(px))) end
  end

  ------------------------------------------------------------------
  -- CANCELS
  ------------------------------------------------------------------
  function T.cancel_where(pred, why, t)
    local inst = X.inst
    if not inst then return 0 end
    local n = 0
    for _, o in ipairs(X.O.working(inst)) do
      if not pred or pred(o) then
        o.replace = nil
        if not o.want_kill then X.O.cancel(o, why, t); n = n + 1 end
      end
    end
    return n
  end

  function T.cancel_side(side, t)
    local n = T.cancel_where(function(o) return o.side == side and o.mode ~= "taker" end, "user", t)
    X.say(string.format("Снято %s: %d", side == "B" and "покупок" or "продаж", n))
  end
  function T.cancel_all(t)
    local n = T.cancel_where(function(o) return o.mode ~= "taker" end, "user", t)
    X.say("Снято заявок: " .. n)
  end

  ------------------------------------------------------------------
  -- ORDER EVENTS
  ------------------------------------------------------------------
  function T.on_fill(o, q, px, t, tn)
    local inst = o.inst
    local net, lot = X.M.on_fill(inst, o, q, px, t, { tn = tn })
    local p = X.panic
    if p and o.src == "panic" and p.left then p.left = p.left + (o.side == "B" and q or -q) end
    X.flash_fill(o.side)
    X.say(string.format("ИСПОЛНЕНО %s %d @ %s%s", o.side == "B" and "покупка" or "продажа", q, inst:px_str(px),
      net and string.format(", закрыто %+.2f руб", net) or ""))
    if lot and o.src == "key" and (X.st.tp or 0) > 0 and inst == X.inst then
      T.place_tp(inst, o.side, lot, t)
    end
  end

  -- take-profit for an open lot: opposite passive order N ticks from the lot price, linked to the lot (lot.tp),
  -- never more than the open position
  function T.place_tp(inst, fill_side, lot, t)
    local side = opp(fill_side)
    local q, px = lot.qty, lot.px
    local pos = X.M.get(inst).pos
    if (side == "S" and pos <= 0) or (side == "B" and pos >= 0) then return end
    local closing = 0
    for _, w in ipairs(X.O.working(inst, side)) do
      if reduce_src(w.src) then closing = closing + (w.qty - w.filled) end
    end
    q = min(q, abs(pos) - closing)
    if q <= 0 then return end
    if not X.R.can_reduce(inst, t) then return end
    local tp = X.st.tp
    -- lot price may be off the tick grid (adopted position at the broker's average): round away from the market
    local want = (side == "S") and math.ceil(px + tp - 1e-9) or math.floor(px - tp + 1e-9)
    local cap = X.B.passive_cap(inst, side)
    if cap and ((side == "S" and want < cap) or (side == "B" and want > cap)) then want = cap end   -- market ran past TP
    if not X.I.in_limits(inst, want) then return end
    local tpo = X.O.place(inst, side, want, q, { src = "tp", parent = lot.tn, px0 = want }, t)
    if tpo then
      lot.tp = tpo.tid
      U.log(string.format("[%s] TP %s %d @ %s for lot @ %s", inst.sec, side, q, inst:px_str(want), inst:px_str(px)))
    end
    return tpo
  end

  -- after a restart: open lots whose take-profit order is gone get a new one (passive-only, capped by position)
  function T.restore_tps(t)
    local inst = X.inst
    if not inst or (X.st.tp or 0) <= 0 or not inst.bk.valid then return 0 end
    local live = {}
    for _, o in ipairs(X.O.working(inst)) do if o.tid then live[o.tid] = true end end
    local n = 0
    for _, lot in ipairs(X.M.get(inst).lots) do
      if not (lot.tp and live[lot.tp]) then
        lot.tp = nil
        if T.place_tp(inst, lot.sgn > 0 and "B" or "S", lot, t) then n = n + 1 end
      end
    end
    return n
  end

  -- target of a closing order: offset rule (or the most aggressive passive price for F), floored at break-even
  local function close_target(inst, o, q)
    local side = o.side
    local px = (o.src == "flat") and T.edge_price(inst, side) or T.price(inst, side, o.offset or 0)
    if not px then return nil end
    local be = X.M.breakeven(inst, side, q)
    if not be then return nil end
    if side == "S" then px = math.max(px, math.ceil(be - 1e-9)) else px = math.min(px, math.floor(be + 1e-9)) end
    if not X.I.in_limits(inst, px) or not passive_ok(inst, side, px) then return nil end
    return px
  end

  local function closing(inst, side)
    local pos = X.M.get(inst).pos
    return (side == "S" and pos > 0) or (side == "B" and pos < 0), abs(pos)
  end

  local function requote(inst, t)
    local min_life = (X.cfg.REQUOTE_MIN_LIFE_MS or 300) / 1000
    for _, o in ipairs(X.O.working(inst)) do
      local is_close, pos = closing(inst, o.side)
      if is_close and (o.src == "key" or o.src == "flat") and o.state == "ACTIVE" and not o.want_kill
         and t - (o.t_active or o.t_send) >= min_life then
        local target = close_target(inst, o, math.min(o.qty - o.filled, pos))
        if target and target ~= o.px then
          o.replace = true
          X.O.cancel(o, "requote", t)
        end
      end
    end
  end

  function T.on_done(o, t)
    X.M.on_order_done(o)
    local p = X.panic
    if p and p.order == o then p.order = nil end
    if not o.replace then return end
    o.replace = nil
    local inst = o.inst
    local is_close, pos = closing(inst, o.side)
    local rem = math.min(o.qty - o.filled, pos)
    if not is_close or rem <= 0 or inst ~= X.inst or not X.st.requote then return end
    if not X.R.can_reduce(inst, t) then return end
    X.B.read(inst, t)
    local px = close_target(inst, o, rem)
    if not px then return end
    local n = X.O.place(inst, o.side, px, rem, { src = o.src, offset = o.offset, px0 = o.px0 }, t)
    if n then U.log(string.format("[%s] REQUOTE close %s %s -> %s (break-even %s)", inst.sec, o.side, inst:px_str(o.px),
      inst:px_str(px), U.fmt(X.M.breakeven(inst, o.side, rem) * inst.tick, inst.scale + 2))) end
  end

  function T.on_reject(o, msg, cls)
    if o.src == "panic" then X.say("PANIC: отказ - " .. msg, "err"); return end
    if cls == "boc" then
      X.say("Отказ биржи: заявка стала бы тейкерской (BoC) - не исполнена", "warn")
    else
      X.say("Отказ: " .. msg, "err")
    end
  end

  ------------------------------------------------------------------
  -- MAINTENANCE: take-profit orders never exceed the open position
  ------------------------------------------------------------------
  local function hygiene(inst, t)
    local pos = X.M.get(inst).pos
    for _, side in ipairs({ "B", "S" }) do
      local closing = (side == "S" and pos > 0) or (side == "B" and pos < 0)
      local list, total = {}, 0
      for _, w in ipairs(X.O.working(inst, side)) do
        if reduce_src(w.src) and not w.want_kill then list[#list + 1] = w; total = total + (w.qty - w.filled) end
      end
      if not closing then
        for _, w in ipairs(list) do w.replace = nil; X.O.cancel(w, "position closed", t) end
      else
        for i = #list, 1, -1 do                       -- newest first while closing orders exceed the position
          if total <= abs(pos) then break end
          local w = list[i]
          total = total - (w.qty - w.filled)
          X.O.cancel(w, "exceeds position", t)
        end
      end
    end
  end

  function T.tick(t)
    local inst = X.inst
    if not inst then return end
    if X.panic then T.panic_tick(t) end
    hygiene(inst, t)
    if X.st.requote and inst.bk.valid and not (X.panic and X.panic.stage ~= "done") then requote(inst, t) end
  end

  ------------------------------------------------------------------
  -- PANIC: cancel every active order of the instrument on the account, then flatten with IOC limit orders.
  -- The ONLY non-passive orders of the tool. Position target is fixed once (broker position by default) and
  -- decremented by our IOC fills, so a lagging position table can never make us overshoot.
  ------------------------------------------------------------------
  -- opt.position = "broker" flattens the exchange position (used to resolve a restart mismatch)
  function T.panic(reason, t, opt)
    local inst = X.inst
    if not inst then return end
    if X.panic and X.panic.stage ~= "done" and X.panic.stage ~= "failed" then return end
    X.panic = { stage = "cancel", t0 = t, reason = reason, attempts = 0,
                position = (opt and opt.position) or X.cfg.PANIC_POSITION or "own" }
    X.paused = true
    U.alert(string.format("[%s] PANIC (%s): cancelling all orders and flattening", inst.sec, reason), 3)
    X.say("PANIC: снимаю все заявки и закрываю позицию", "err")
    T.panic_tick(t)
  end

  local function panic_cancel(inst, t)
    local left = 0
    for _, o in ipairs(X.O.working(inst)) do
      if o.mode ~= "taker" then o.replace = nil; X.O.cancel(o, "panic", t); left = left + 1 end
    end
    if (X.cfg.PANIC_KILL_SCOPE or "own") == "account" then
      for _, row in ipairs(X.O.active_rows(inst)) do X.O.kill_row(inst, row, t); left = left + 1 end
    end
    return left
  end

  function T.panic_tick(t)
    local p, inst = X.panic, X.inst
    if not p or not inst or p.stage == "done" or p.stage == "failed" then return end
    local cfg = X.cfg
    if p.stage == "cancel" then
      local left = panic_cancel(inst, t)
      if left > 0 and t - p.t0 < (cfg.PANIC_CANCEL_WAIT_SEC or 2) then return end
      if left > 0 then U.log(string.format("[%s] PANIC: %d order(s) still active, flattening anyway", inst.sec, left)) end
      local m = X.M.get(inst)
      local target = m.pos
      if p.position == "broker" then
        local b = X.R.broker_pos(inst)
        if b and b ~= m.pos then
          U.alert(string.format("[%s] PANIC: broker position %+d, SCLP position %+d - flattening the broker position",
            inst.sec, b, m.pos), 3)
          X.M.adopt_external(inst, b - m.pos)
          target = b
        end
        if b then X.block = nil end                  -- the exchange position is what PANIC closes now
      end
      p.left, p.stage, p.t_flat = target, "flatten", t
      U.log(string.format("[%s] PANIC: position to flatten %+d", inst.sec, target))
    end
    if p.stage == "flatten" then
      if p.left == 0 and not p.order then
        p.stage, p.t_end = "done", t
        X.say("PANIC завершён: позиция 0. H - продолжить торговлю", "warn")
        U.alert(string.format("[%s] PANIC done in %.1f s", inst.sec, t - p.t0), 2)
        return
      end
      if p.order then return end
      if p.attempts >= (cfg.PANIC_MAX_ATTEMPTS or 10) then
        p.stage = "failed"
        U.alert(string.format("[%s] PANIC FAILED: %+d lot(s) still open after %d IOC attempts - CLOSE MANUALLY",
          inst.sec, p.left, p.attempts), 3)
        X.say("PANIC НЕ ЗАКРЫЛ ПОЗИЦИЮ - закройте вручную!", "err")
        return
      end
      if t - (p.t_last or -1e9) < (cfg.PANIC_RETRY_SEC or 0.3) then return end
      X.B.read(inst, t)
      local bk = inst.bk
      local side = p.left > 0 and "S" or "B"
      local slip = cfg.PANIC_SLIP_TICKS or 20
      local px
      if side == "S" then px = bk.bb and (bk.bb - slip) or inst.pmin
      else px = bk.ba and (bk.ba + slip) or inst.pmax end
      if not px then U.log_every("panic_px", 5, "[" .. inst.sec .. "] PANIC: no opposite side in the book, waiting"); return end
      if inst.pmin and px < inst.pmin then px = inst.pmin end
      if inst.pmax and px > inst.pmax then px = inst.pmax end
      p.t_last = t
      p.attempts = p.attempts + 1
      local o = X.O.place(inst, side, px, abs(p.left), { taker = true, src = "panic" }, t)
      p.order = o
      if o then U.log(string.format("[%s] PANIC IOC %s %d @ %s (attempt %d)", inst.sec, side, abs(p.left), inst:px_str(px), p.attempts)) end
    end
  end

  -- broker check a few seconds after PANIC
  function T.panic_verify(t)
    local p, inst = X.panic, X.inst
    if not (p and p.stage == "done" and inst and not p.verified and t - p.t_end >= 3) then return end
    p.verified = true
    local b = X.R.broker_pos(inst)
    if b and b ~= 0 then
      U.alert(string.format("[%s] after PANIC the broker still shows position %+d (not SCLP's or not yet updated) - check manually",
        inst.sec, b), 3)
      X.say(string.format("После PANIC у брокера позиция %+d - проверьте вручную", b), "err")
    end
  end

  return T
end
