-- cycle.lua : торговый цикл "вход -> позиция -> выход", одинаковый для реальных и виртуальных заявок.
--
--   ENTRY  - стоят входные заявки (у PAIR - две: bid и ask). Отказ биржи по любой ноге (стала бы тейкером)
--            -> остальные ноги сразу снимаются. Условия сетапа испортились -> снимаются все.
--   POS    - есть позиция. Входные заявки в сторону набора снимаются; заявка в сторону закрытия (у PAIR -
--            вторая нога) становится выходом. Выход только пассивный, цена - по фазам (TP/DECAY/HOLD/BE/STOP).
--            Выход переставляется только после ПОДТВЕРЖДЁННОГО снятия старого (двойного исполнения нет).
--   CLOSE  - позиция 0, снимаем остатки. DONE - всё снято, всё учтено.
return function(SC)
  local C = {}
  SC.C = C
  local U = SC.U
  local floor, ceil, abs, max, min = math.floor, math.ceil, math.abs, math.max, math.min

  C.list = {}          -- активные циклы
  local next_id = 0

  local function live_orders(c)
    local r = {}
    for _, o in ipairs(c.orders) do if o.state ~= "done" then r[#r + 1] = o end end
    return r
  end
  C.live_orders = live_orders

  local function unsettled(c)
    local u = 0
    for _, o in ipairs(c.orders) do u = u + SC.O.unsettled(o) end
    return u
  end

  ------------------------------------------------------------------
  -- ОТКРЫТИЕ ЦИКЛА
  -- spec = { setup, backend, legs = {{side, px, qty}, ...}, pair = bool, tp = функция(c) -> цена тейка,
  --          info = {...} (для журнала) }
  ------------------------------------------------------------------
  function C.open(inst, spec, t)
    next_id = next_id + 1
    local c = { id = next_id, inst = inst, setup = spec.setup, backend = spec.backend, t0 = t,
                state = "ENTRY", orders = {}, legs = {}, pos = 0, avg = nil, realized = 0, traded = 0,
                pair = spec.pair, tp_fn = spec.tp, info = spec.info or {}, fills = {}, phase = nil,
                n_filled_legs = 0 }
    C.list[#C.list + 1] = c
    for _, l in ipairs(spec.legs) do
      local o = SC.O.place(inst, spec.backend, l.side, l.px, l.qty, c, "entry", t)
      c.orders[#c.orders + 1] = o
      c.legs[#c.legs + 1] = o
    end
    SC.ST.on_open(c)
    U.dbg(string.format("[%s] CYCLE %d open %s/%s legs=%d", inst.sec, c.id, c.setup, c.backend, #spec.legs))
    return c
  end

  function C.cancel_all(c, t, why)
    for _, o in ipairs(live_orders(c)) do SC.O.cancel(o, t, why) end
    if why and not c.cancel_why then c.cancel_why = why end
  end

  ------------------------------------------------------------------
  -- ПОЗИЦИЯ
  ------------------------------------------------------------------
  local function apply_fill(c, side, q, px, t)
    local sgn = (side == "B") and 1 or -1
    local pos = c.pos
    if pos == 0 or U.sign(pos) == sgn then
      local n = abs(pos)
      c.avg = ((c.avg or px) * n + px * q) / (n + q)
      c.pos = pos + sgn * q
    else
      local close = min(q, abs(pos))
      c.realized = c.realized + (px - c.avg) * close * U.sign(pos)   -- в тиках * лоты
      c.pos = pos + sgn * q
      local rest = q - close
      if c.pos == 0 then
        c.avg_closed = c.avg
      elseif rest > 0 then
        c.avg = px                                        -- переворот (не должен случаться)
      end
    end
    c.traded = c.traded + q
  end

  local function exit_side(c) return (c.pos > 0) and "S" or "B" end

  ------------------------------------------------------------------
  -- СОБЫТИЯ ЗАЯВОК
  ------------------------------------------------------------------
  function C.on_order_event(o, kind, a, b)
    local c = o.cycle
    if not c then return end
    local t = U.now()
    if kind == "rejected" then
      o.reject = o.reject or a
      if o.role == "entry" then
        c.rejects = (c.rejects or 0) + 1
        c.reject_kind = a
        -- ПРАВИЛО ПАРЫ: одна нога не может стать мейкером -> вторую сразу снимаем
        if c.state == "ENTRY" then C.cancel_all(c, t, "reject_" .. tostring(a)) end
      end
      if o == c.exit then c.exit = nil; c.exit_rejected_t = t end
    elseif kind == "fill" then
      local q, px = a, b
      local before = c.pos
      apply_fill(c, o.side, q, px, t)
      c.fills[#c.fills + 1] = { t = t, side = o.side, q = q, px = px, role = o.role }
      SC.ST.on_fill(c, o, q, px, t)
      SC.fills_log = SC.fills_log or {}
      table.insert(SC.fills_log, { t = t, sec = c.inst.sec, side = o.side, q = q, px = c.inst:price_str(px),
        setup = c.setup, backend = c.backend, role = o.role, pos = c.pos + 0,
        net = (c.pos == 0) and SC.R.cycle_rub(c) or nil, ticks = (c.pos == 0) and c.realized or nil })
      if #SC.fills_log > 50 then table.remove(SC.fills_log, 1) end
      SC.fills_seq = (SC.fills_seq or 0) + 1
      if o.role == "entry" and not o.counted_leg then o.counted_leg = true; c.n_filled_legs = c.n_filled_legs + 1 end
      if c.state == "ENTRY" and c.pos ~= 0 then
        c.state = "POS"
        c.t_pos = t
        c.entry_side = o.side
        -- вторая нога пары (в сторону закрытия) становится выходом; ноги в сторону набора снимаем
        for _, x in ipairs(live_orders(c)) do
          if x.side == exit_side(c) and not c.exit then
            c.exit = x; x.role = "exit"; c.t_exit = t
          elseif x.side ~= exit_side(c) and x ~= o then
            SC.O.cancel(x, t, "add_side")
          end
        end
        -- свою же ногу (остаток после частичного исполнения) тоже снимаем: набираем не больше, чем исполнилось
        if o.state ~= "done" then SC.O.cancel(o, t, "partial_rest") end
        c.tp_px = c.tp_fn and c.tp_fn(c) or nil
        if c.exit and c.tp_px and c.exit.px ~= c.tp_px then
          -- висячая нога стоит не там, где нужен тейк (например, мельче минимального) - выход переставит
          c.exit_wrong = true
        end
      elseif c.state == "POS" and c.pos ~= 0 and U.sign(c.pos) ~= U.sign(before) and before ~= 0 then
        U.alert(string.format("[%s] cycle %d: position flipped %d -> %d", c.inst.sec, c.id, before, c.pos))
        c.t_pos = t
        c.tp_px = nil
      end
      if c.pos == 0 and c.state == "POS" then
        c.state = "CLOSE"
        c.t_close = t
        C.cancel_all(c, t)
      end
    elseif kind == "cancelled" or kind == "lost" then
      if kind == "lost" then c.lost = true end
      if o == c.exit then c.exit = nil end
    end
    C.check_done(c, t)
  end

  function C.check_done(c, t)
    if c.state == "DONE" then return end
    if #live_orders(c) > 0 or unsettled(c) > 0 then return end
    if c.pos ~= 0 then
      if c.state == "ENTRY" then c.state = "POS"; c.t_pos = c.t_pos or t end
      return
    end
    c.state = "DONE"
    c.t_done = t
    SC.ST.on_done(c)
    SC.R.on_cycle_done(c, t)
  end

  ------------------------------------------------------------------
  -- ЦЕНА ВЫХОДА
  ------------------------------------------------------------------
  -- самая близкая к рынку пассивная цена закрытия
  local function best_passive(c)
    local s = c.inst.sig
    if c.pos > 0 then return s.bb + 1 else return s.ba - 1 end
  end

  function C.exit_price(c, t)
    local inst, P, s = c.inst, c.inst.P, c.inst.sig
    local long = c.pos > 0
    local age = t - (c.t_pos or t)
    local avg = c.avg
    local adverse = long and (avg - s.mid) or (s.mid - avg)
    if adverse >= P.STOP_TICKS then
      c.t_adv = c.t_adv or t
    else
      c.t_adv = nil
    end
    local phase
    if c.stop_since or c.force_stop or (c.t_adv and t - c.t_adv >= P.STOP_CONFIRM_SEC) or age >= P.MAX_HOLD_SEC then
      phase = "STOP"
      c.stop_since = c.stop_since or t          -- STOP не отменяется, даже если цена вернулась
    elseif age < P.TP_HOLD_SEC and c.tp_px then phase = "TP"
    elseif age < P.BE_SEC then phase = "DECAY"
    elseif age < P.SCRATCH_SEC then phase = "HOLD"
    else phase = "BE" end
    local px
    if phase == "STOP" then
      px = best_passive(c)
    else
      local tp_dist = c.tp_px and abs(c.tp_px - avg) or P.MIN_PROFIT_TICKS
      local want
      if phase == "TP" then want = tp_dist
      elseif phase == "DECAY" then
        local f = (age - P.TP_HOLD_SEC) / max(0.001, P.BE_SEC - P.TP_HOLD_SEC)
        want = tp_dist + (P.MIN_PROFIT_TICKS - tp_dist) * U.clamp(f, 0, 1)
        if want < P.MIN_PROFIT_TICKS then want = P.MIN_PROFIT_TICKS end
      elseif phase == "HOLD" then want = P.MIN_PROFIT_TICKS
      else want = 0 end
      if long then px = ceil(avg + want - 1e-9) else px = floor(avg - want + 1e-9) end
      -- рынок ушёл за цель в нашу сторону: ставим ближе к рынку (лучше цели), но пассивно
      local bp = best_passive(c)
      if long and px < bp then px = bp end
      if (not long) and px > bp then px = bp end
    end
    return px, phase
  end

  ------------------------------------------------------------------
  -- ТАКТ ЦИКЛА
  ------------------------------------------------------------------
  function C.tick(c, t)
    local inst, P = c.inst, c.inst.P
    if c.state == "DONE" then return end
    if c.state == "ENTRY" then
      local why = SC.S.entry_check(c, t)
      if why then C.cancel_all(c, t, why) end
      C.check_done(c, t)
      return
    end
    if c.state == "CLOSE" then
      C.cancel_all(c, t)
      C.check_done(c, t)
      return
    end
    -- POS
    if not inst.sig.valid then return end
    if SC.R.force_exit(inst, c, t) then c.force_stop = true end
    local px, phase = C.exit_price(c, t)
    if phase ~= c.phase then
      U.dbg(string.format("[%s] cycle %d phase %s -> %s px=%d", inst.sec, c.id, tostring(c.phase), phase, px))
      c.phase = phase
    end
    local qty = abs(c.pos)
    local side = exit_side(c)
    -- лишние заявки: всё, что в сторону набора, и любой выход сверх одного
    for _, o in ipairs(live_orders(c)) do
      if o ~= c.exit and not o.want_kill then SC.O.cancel(o, t, "extra") end
    end
    local e = c.exit
    if e and e.state ~= "done" then
      if e.want_kill then return end
      local rem = e.qty - e.filled
      local need_move = (e.side ~= side) or (rem ~= qty) or c.exit_wrong
      if not need_move and e.px ~= px then
        local interval = (phase == "STOP") and P.EXIT_REQUOTE_SEC or 1.0
        if phase == "TP" and e.px == c.tp_px then interval = 1e9 end
        -- выход лучше нужного для нас (например, висячая нога пары) не трогаем, пока фаза TP
        if t - (c.t_exit or c.t0) >= interval then need_move = true end
      end
      if need_move then
        c.exit_wrong = nil
        SC.O.cancel(e, t, "requote")
      end
      return
    end
    c.exit = nil
    if unsettled(c) > 0 then return end              -- ждём сделки по уже исполненному
    for _, o in ipairs(live_orders(c)) do return end  -- ждём подтверждения снятия всего лишнего
    if c.exit_rejected_t and t - c.exit_rejected_t < 0.3 then return end   -- отказ выхода = рынок ушёл в нашу сторону
    local o = SC.O.place(inst, c.backend, side, px, qty, c, "exit", t)
    c.orders[#c.orders + 1] = o
    c.exit = o
    c.t_exit = t
  end

  function C.tick_all(t)
    local keep = {}
    for _, c in ipairs(C.list) do
      C.tick(c, t)
      if c.state ~= "DONE" then keep[#keep + 1] = c end
    end
    C.list = keep
  end

  function C.active(inst, backend, setup)
    local r = {}
    for _, c in ipairs(C.list) do
      if (not inst or c.inst == inst) and (not backend or c.backend == backend) and (not setup or c.setup == setup) then
        r[#r + 1] = c
      end
    end
    return r
  end

  function C.position(inst, backend)
    local p = 0
    for _, c in ipairs(C.list) do
      if c.inst == inst and c.backend == backend then p = p + c.pos end
    end
    return p
  end

  -- принять позицию, которую робот не открывал (перезапуск / сверка с брокером): закрывается пассивно
  function C.adopt(inst, qty, avg, t, why)
    next_id = next_id + 1
    local c = { id = next_id, inst = inst, setup = "ADOPT", backend = "real", t0 = t, state = "POS",
                orders = {}, legs = {}, pos = qty, avg = avg, realized = 0, traded = 0, info = { why = why },
                fills = {}, t_pos = t, n_filled_legs = 0 }
    c.tp_px = qty > 0 and ceil(avg + inst.P.MIN_PROFIT_TICKS) or floor(avg - inst.P.MIN_PROFIT_TICKS)
    C.list[#C.list + 1] = c
    U.alert(string.format("[%s] adopted position %d @ %s (%s) - closing passively", inst.sec, qty,
      inst:price_str(avg), why))
    return c
  end

  return C
end
