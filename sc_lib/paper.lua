-- paper.lua : эмулятор биржи для виртуальных заявок (MODE = "PAPER" и сетапы "paper").
-- Модель: заявка доходит до биржи через PAPER_LATENCY_SEC и в этот момент проверяется по НАСТОЯЩЕМУ
-- стакану как "только пассивная": пересекла бы встречную - отказ. Иначе встаёт в очередь: впереди весь
-- видимый объём уровня (если уровень уже был). Исполнение - по сделкам ленты по нашей цене (сначала
-- съедается очередь впереди) или сквозь нашу цену, либо если стакан ушёл сквозь нашу цену.
-- Снятие тоже доходит с задержкой: исполнение до этого момента - настоящее.
return function(SC)
  local V = {}
  SC.V = V
  local U = SC.U
  local min = math.min

  local pending = {}     -- {at, kind = "place"|"cancel", o}
  local trade_no = 0

  function V.place(o, t)
    pending[#pending + 1] = { at = t + o.inst.P.PAPER_LATENCY_SEC, kind = "place", o = o }
  end
  function V.cancel(o, t)
    pending[#pending + 1] = { at = t + o.inst.P.PAPER_LATENCY_SEC, kind = "cancel", o = o }
  end

  local function level_qty(levels, px)
    for _, l in ipairs(levels or {}) do if l.p == px then return l.q end end
    return 0
  end

  local function fill(o, q, t)
    q = min(q, o.qty - o.filled)
    if q <= 0 then return end
    trade_no = trade_no + 1
    SC.O.fill(o, q, o.px, t)
  end

  local function arrive(o, t)
    if o.state ~= "sent" then return end
    local inst = o.inst
    local raw = inst.raw
    local bb = raw and raw.bids[1] and raw.bids[1].p
    local ba = raw and raw.asks[1] and raw.asks[1].p
    local cross = (o.side == "B" and ba and o.px >= ba) or (o.side == "S" and bb and o.px <= bb)
    if o.taker then                              -- жёсткий стоп: исполнение по лучшей встречной, остаток снят
      o.state = "active"; o.t_active = t
      SC.C.on_order_event(o, "accepted")
      if cross then
        SC.O.fill(o, o.qty - o.filled, (o.side == "B") and ba or bb, t)
      end
      if o.state ~= "done" then
        o.state = "done"; o.how = "cancelled"; o.t_done = t
        SC.O.live[o.id] = nil
        SC.C.on_order_event(o, "cancelled")
      end
      return
    end
    if cross then
      o.state = "done"; o.how = "rejected"; o.reject = "boc"; o.t_done = t
      SC.O.live[o.id] = nil
      SC.O.stats.v_rej_boc = (SC.O.stats.v_rej_boc or 0) + 1
      SC.C.on_order_event(o, "rejected", "boc", "paper: would cross")
      return
    end
    o.state = "active"; o.t_active = t
    o.queue = 0
    if inst.P.PAPER_QUEUE and raw then
      o.queue = level_qty(o.side == "B" and raw.bids or raw.asks, o.px)
    end
    SC.C.on_order_event(o, "accepted")
    if o.want_kill then V.cancel(o, t) end
  end

  local function do_cancel(o, t)
    if o.state == "done" then return end
    if o.state == "sent" then
      -- снятие догнало заявку до прихода: не встанет
      o.state = "done"; o.how = "cancelled"; o.t_done = t
      SC.O.live[o.id] = nil
      SC.C.on_order_event(o, "cancelled")
      return
    end
    o.state = "done"; o.how = "cancelled"; o.t_done = t
    SC.O.live[o.id] = nil
    SC.C.on_order_event(o, "cancelled")
  end

  function V.tick(t)
    if #pending == 0 then return end
    local keep, due = {}, {}
    for _, p in ipairs(pending) do
      if p.at <= t then due[#due + 1] = p else keep[#keep + 1] = p end
    end
    pending = keep
    table.sort(due, function(a, b) return a.at < b.at end)
    for _, p in ipairs(due) do
      if p.kind == "place" then arrive(p.o, p.at) else do_cancel(p.o, p.at) end
    end
  end

  local function active_virtual(inst)
    local r = {}
    for _, o in pairs(SC.O.live) do
      if o.backend == "virtual" and o.inst == inst and o.state == "active" then r[#r + 1] = o end
    end
    return r
  end

  -- сделка ленты (tr: p, q, side: -1 продавец-агрессор, +1 покупатель)
  function V.on_tape(inst, tr, t)
    for _, o in ipairs(active_virtual(inst)) do
      local hit = (o.side == "B" and tr.side == -1 and tr.p <= o.px) or (o.side == "S" and tr.side == 1 and tr.p >= o.px)
      if hit then
        if tr.p ~= o.px then
          fill(o, o.qty - o.filled, t)              -- прошли сквозь нашу цену
        else
          local avail = tr.q
          if o.queue > 0 then
            local d = min(o.queue, avail)
            o.queue = o.queue - d
            avail = avail - d
          end
          if avail > 0 then fill(o, avail, t) end
        end
      end
    end
  end

  -- стакан: встречная цена дошла до нашей (в реальности - сделка с нами) -> исполнены; уровень похудел -> очередь впереди короче
  function V.on_book(inst, t)
    local raw = inst.raw
    if not raw then return end
    local bb = raw.bids[1] and raw.bids[1].p
    local ba = raw.asks[1] and raw.asks[1].p
    for _, o in ipairs(active_virtual(inst)) do
      if o.side == "B" then
        if ba and ba <= o.px then fill(o, o.qty - o.filled, t)
        else o.queue = min(o.queue, level_qty(raw.bids, o.px)) end
      else
        if bb and bb >= o.px then fill(o, o.qty - o.filled, t)
        else o.queue = min(o.queue, level_qty(raw.asks, o.px)) end
      end
    end
  end

  return V
end
