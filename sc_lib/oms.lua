-- oms.lua : заявки. Реальные - через QUIK (новая заявка "Только пассивная" в универсальном формате,
-- снятие - KILL_ORDER), виртуальные - через эмулятор биржи (paper.lua). Для циклов оба вида одинаковы:
-- события accepted / rejected / fill / cancelled / lost приходят в C.on_order_event.
--
-- Состояния заявки: "queued" (ждёт жетона) -> "sent" -> "active" -> "done".
-- done: cancelled / filled / rejected / lost. Исполнения (fill) считаются ТОЛЬКО по сделкам (OnTrade),
-- поэтому позиция не зависит от порядка прихода OnOrder / OnTrade.
return function(SC)
  local O = {}
  SC.O = O
  local U = SC.U
  local floor, min, max = math.floor, math.min, math.max

  O.by_tid = {}        -- TRANS_ID новой заявки -> order
  O.kill_tid = {}      -- TRANS_ID снятия -> order
  O.by_num = {}        -- номер заявки (строка) -> order
  O.live = {}          -- незавершённые заявки (id -> order)
  O.trades_seen = {}   -- номера сделок
  O.stats = { new = 0, kill = 0, rej_boc = 0, rej_other = 0, rej_local = 0, err_tx = 0, lost = 0, tx = 0 }
  O.reject_streak = 0
  O.pause_until = 0
  O.halt = nil         -- причина полной остановки (неверный формат транзакции и т.п.)
  O.reject_texts = {}
  O.await = {}         -- исполнены по таблице заявок, сделки ещё не пришли

  local next_local = 0
  local seq
  function O.next_tid()
    if not seq then
      local base = SC.cfg.TRANS_ID_BASE or 2000000000
      seq = base + floor(U.msk_sec()) * 1000
    end
    seq = seq + 1
    return seq
  end

  ------------------------------------------------------------------
  -- ЖЕТОНЫ (не больше MAX_TX_PER_SEC)
  ------------------------------------------------------------------
  local bucket = { tokens = 5, t = nil }
  local function refill(t)
    local rate = SC.cfg.MAX_TX_PER_SEC or 25
    if bucket.t then bucket.tokens = min(rate, bucket.tokens + (t - bucket.t) * rate) end
    bucket.t = t
  end
  function O.tokens(t) refill(t); return bucket.tokens end
  local function take(t, n)
    refill(t)
    if bucket.tokens >= n then bucket.tokens = bucket.tokens - n; return true end
    return false
  end

  ------------------------------------------------------------------
  -- ФОРМАТ НОВОЙ ЗАЯВКИ (универсальный, "Только пассивная")
  ------------------------------------------------------------------
  local function enc(s)
    if (SC.cfg.TX_ENCODING or "cp1251") == "cp1251" then return U.to_cp1251(s) end
    return tostring(s)
  end
  function O.build_new(inst, side, px, qty, tid)
    local X = SC.cfg.TX
    local t = {
      TRANS_ID = string.format("%d", tid),
      CLASSCODE = inst.class,
      ACTION = enc(X.ACTION),
    }
    t[enc(X.ACCOUNT)] = SC.cfg.ACCOUNT
    t[enc(X.SIDE)] = enc(side == "B" and X.BUY or X.SELL)
    t[enc(X.TYPE)] = enc(X.TYPE_LIMIT)
    t[enc(X.SEC)] = inst.sec
    t[enc(X.PRICE)] = inst:price_str(px)
    t[enc(X.QTY)] = U.qty_str(qty)
    t[enc(X.COND)] = enc(X.COND_PASSIVE)
    if (SC.cfg.CLIENT_CODE or "") ~= "" then t[enc(X.CLIENT_CODE)] = SC.cfg.CLIENT_CODE end
    for k, v in pairs(SC.cfg.TX_EXTRA or {}) do t[enc(k)] = enc(v) end
    return t
  end
  function O.build_kill(inst, key, tid)
    local t = { ACCOUNT = SC.cfg.ACCOUNT, CLASSCODE = inst.class, SECCODE = inst.sec,
                ACTION = "KILL_ORDER", ORDER_KEY = key, TRANS_ID = string.format("%d", tid) }
    if (SC.cfg.CLIENT_CODE or "") ~= "" then t.CLIENT_CODE = SC.cfg.CLIENT_CODE end
    return t
  end

  local function send(t)
    O.stats.tx = O.stats.tx + 1
    local ok, res = pcall(sendTransaction, t)
    if not ok then return "sendTransaction crashed: " .. tostring(res) end
    return res or ""
  end

  ------------------------------------------------------------------
  -- СОЗДАНИЕ / ОТПРАВКА
  ------------------------------------------------------------------
  local function event(o, kind, a, b)
    if SC.C and SC.C.on_order_event then SC.C.on_order_event(o, kind, a, b) end
  end

  local function finish(o, how, t)
    if o.state == "done" then return end
    o.state = "done"
    o.how = how
    o.t_done = t
    O.live[o.id] = nil
  end

  -- заявка: backend "real" | "virtual"
  function O.new_order(inst, backend, side, px, qty, cycle, role)
    next_local = next_local + 1
    local o = { id = next_local, inst = inst, backend = backend, side = side, px = px, qty = qty,
                filled = 0, state = "queued", cycle = cycle, role = role, t_new = U.now(),
                kill_tries = 0 }
    O.live[o.id] = o
    return o
  end

  local function send_new(o, t)
    local inst = o.inst
    if o.backend == "virtual" then
      o.state = "sent"; o.t_sent = t
      SC.V.place(o, t)
      return true
    end
    if not take(t, 1) then return false end
    o.tid = O.next_tid()
    O.by_tid[o.tid] = o
    o.state = "sent"; o.t_sent = t
    O.stats.new = O.stats.new + 1
    local res = send(O.build_new(inst, o.side, o.px, o.qty, o.tid))
    if res ~= "" then
      -- QUIK не принял транзакцию: почти всегда - неверные названия полей универсального формата
      local msg = U.from_cp1251(res)
      O.stats.rej_local = O.stats.rej_local + 1
      U.alert(string.format("[%s] sendTransaction REJECTED locally: %s", inst.sec, msg))
      finish(o, "rejected", t)
      o.reject = "local"
      O.halt = "QUIK не принял заявку (" .. msg .. "). Проверьте поля TX в настройках: tools/probe_passive.lua"
      event(o, "rejected", "local", msg)
      return true
    end
    U.dbg(string.format("[%s] NEW %s %s %d @ %s tid=%d (%s)", inst.sec, o.backend, o.side, o.qty,
      inst:price_str(o.px), o.tid, o.role or ""))
    return true
  end

  -- поставить (или поставить в очередь до жетона)
  function O.place(inst, backend, side, px, qty, cycle, role, t)
    local o = O.new_order(inst, backend, side, px, qty, cycle, role)
    send_new(o, t or U.now())
    return o
  end

  -- можно ли отправить n реальных транзакций прямо сейчас (для пары - 2)
  function O.can_send(t, n) refill(t); return bucket.tokens >= n end

  local function send_kill(o, t)
    if o.backend == "virtual" then
      o.kill_sent_t = t; o.kill_tries = o.kill_tries + 1
      SC.V.cancel(o, t)
      return true
    end
    if not o.key then return false end        -- номер ещё неизвестен: снимем, когда придёт ответ
    if not take(t, 1) then return false end
    local tid = O.next_tid()
    O.kill_tid[tid] = o
    o.kill_sent_t = t
    o.kill_tries = o.kill_tries + 1
    O.stats.kill = O.stats.kill + 1
    local res = send(O.build_kill(o.inst, o.key, tid))
    if res ~= "" then
      U.log(string.format("[%s] KILL send error key=%s: %s", o.inst.sec, o.key, U.from_cp1251(res)))
    end
    return true
  end

  -- снять заявку (идемпотентно)
  function O.cancel(o, t, why)
    if o.state == "done" then return end
    t = t or U.now()
    if o.state == "queued" then
      finish(o, "cancelled", t)
      event(o, "cancelled")
      return
    end
    if o.want_kill then return end
    o.want_kill = true
    o.kill_why = why
    if o.state == "active" or (o.state == "sent" and o.key) then send_kill(o, t) end
  end

  ------------------------------------------------------------------
  -- СОБЫТИЯ QUIK (реальные заявки)
  ------------------------------------------------------------------
  local function classify_reject(msg)
    local m = (msg or ""):lower()
    -- текст отказа "только пассивной" у брокеров разный: ищем характерные слова
    if m:find("пассив") or m:find("passive") or m:find("book or cancel") or m:find("boc") or m:find("встречн")
       or m:find("немедленн") or m:find("мейкер") or m:find("maker") then
      return "boc"
    end
    return "other"
  end
  O.classify_reject = classify_reject

  function O.on_reply(r, t)
    local tid = tonumber(r.trans_id)
    if not tid then return end
    local status = tonumber(r.status) or -1
    local msg = U.from_cp1251(r.result_msg or r.result_message or "")
    local o = O.by_tid[tid]
    if o then
      if status == 0 or status == 1 then return end            -- промежуточные
      if status == 3 then
        if r.order_num and tonumber(r.order_num) and tonumber(r.order_num) > 0 then
          o.num = r.order_num
          o.key = U.key_from_num(r.order_num) or U.key_from_text(msg, r.order_num)
          if o.key then O.by_num[o.key] = o end
        end
        if o.state == "sent" then
          o.state = "active"; o.t_active = t
          O.reject_streak = 0
          event(o, "accepted")
        end
        if o.want_kill and o.state == "active" and not o.kill_sent_t then send_kill(o, t) end
        return
      end
      -- отказ
      if o.state ~= "done" then
        local why = classify_reject(msg)
        o.reject = why
        o.reject_msg = msg
        if why == "boc" then O.stats.rej_boc = O.stats.rej_boc + 1
        else
          O.stats.rej_other = O.stats.rej_other + 1
          O.reject_streak = O.reject_streak + 1
          if O.reject_streak >= SC.cfg.MAX_REJECTS then
            O.pause_until = t + SC.cfg.REJECT_PAUSE_SEC
            U.alert(string.format("%d rejects in a row - pause %d s", O.reject_streak, SC.cfg.REJECT_PAUSE_SEC))
            O.reject_streak = 0
          end
        end
        if not O.reject_texts[msg] then
          O.reject_texts[msg] = true
          U.log(string.format("[%s] REJECT text (status %d, class %s): %s", o.inst.sec, status, why, msg))
        end
        finish(o, "rejected", t)
        event(o, "rejected", why, msg)
      end
      return
    end
    local ko = O.kill_tid[tid]
    if ko then
      if status == 0 or status == 1 then return end
      O.kill_tid[tid] = nil
      if status == 3 then
        ko.kill_ok_t = t
      else
        -- снять не удалось: чаще всего заявка уже исполнена (ошибочная транзакция - за них сбор биржи)
        O.stats.err_tx = O.stats.err_tx + 1
        ko.kill_err = msg
        U.log(string.format("[%s] KILL rejected key=%s: %s", ko.inst.sec, tostring(ko.key), msg))
        ko.need_lookup = true
      end
    end
  end

  local function passive_flag_check(o, row)
    if not SC.cfg.CHECK_PASSIVE_FLAG or O.passive_checked then return end
    local v = row.passive_only_order
    if v == nil then return end
    O.passive_checked = true
    local on = (v == true) or (tonumber(v) and tonumber(v) ~= 0) or (type(v) == "string" and v ~= "" and v ~= "0")
    U.log(string.format("[%s] orders.passive_only_order = %s", o.inst.sec, tostring(v)))
    if not on then
      O.halt = "у принятой заявки НЕ установлен признак 'только пассивная' (passive_only_order = " .. tostring(v) ..
               "). Названия полей TX не подходят вашему QUIK - см. tools/probe_passive.lua"
      U.alert(O.halt)
    end
  end

  -- строка таблицы заявок (OnOrder или поиск)
  function O.apply_row(o, row, t)
    if not o.key and row.order_num then
      o.num = row.order_num
      o.key = U.key_from_num(row.order_num)
      if o.key then O.by_num[o.key] = o end
    end
    passive_flag_check(o, row)
    local active = U.bit(row.flags, 0)
    local balance = U.num(row.balance)
    if active then
      if o.state == "sent" then
        o.state = "active"; o.t_active = t
        O.reject_streak = 0
        event(o, "accepted")
      end
      if o.want_kill and not o.kill_sent_t then send_kill(o, t) end
      return
    end
    if o.state == "done" then return end
    -- заявка больше не активна: исполнена или снята. Сколько исполнено по таблице:
    o.exec_by_table = o.qty - (balance or 0)
    local cancelled = U.bit(row.flags, 1)
    if o.state == "sent" and o.t_active == nil then
      o.t_active = t
      event(o, "accepted")
    end
    finish(o, cancelled and "cancelled" or "filled", t)
    if O.unsettled(o) > 0 then O.await[o.id] = { o = o, t = t } end
    if cancelled then event(o, "cancelled") end
    -- "filled" сам по себе событием не является: исполнения придут сделками
  end

  function O.on_order(row, t)
    local tid = tonumber(row.trans_id)
    local o = (tid and O.by_tid[tid])
    if not o then
      local k = U.key_from_num(row.order_num)
      o = k and O.by_num[k]
    end
    if o and o.backend == "real" then O.apply_row(o, row, t) end
  end

  function O.on_trade(tr, t)
    local tn = tostring(tr.trade_num)
    if O.trades_seen[tn] then return end
    local k = U.key_from_num(tr.order_num)
    local o = k and O.by_num[k]
    if not o then
      local tid = tonumber(tr.trans_id)
      o = tid and O.by_tid[tid]
      if o and k and not o.key then o.key = k; o.num = tr.order_num; O.by_num[k] = o end
    end
    if not o or o.backend ~= "real" then return end
    O.trades_seen[tn] = true
    local q = U.num(tr.qty) or 0
    local px = U.round(U.num(tr.price) / o.inst.tick)
    O.fill(o, q, px, t)
  end

  -- общее для реальных и виртуальных исполнений
  function O.fill(o, q, px, t)
    if q <= 0 then return end
    o.filled = o.filled + q
    o.t_fill = t
    if o.state == "sent" then o.state = "active"; o.t_active = o.t_active or t end
    if o.filled >= o.qty and o.state ~= "done" then finish(o, "filled", t) end
    event(o, "fill", q, px)
  end

  -- неучтённое исполнение: таблица заявок говорит "исполнено N", сделок пришло меньше
  function O.unsettled(o)
    if o.exec_by_table and o.exec_by_table > o.filled then return o.exec_by_table - o.filled end
    return 0
  end

  ------------------------------------------------------------------
  -- ПОИСК В ТАБЛИЦЕ ЗАЯВОК (страховка, если OnOrder не пришёл)
  ------------------------------------------------------------------
  function O.lookup(o, t)
    if o.backend ~= "real" or not getNumberOf then return end
    local n = getNumberOf("orders") or 0
    for i = n - 1, max(0, n - 2000), -1 do
      local row = getItem("orders", i)
      if row then
        local k = U.key_from_num(row.order_num)
        if (o.key and k == o.key) or (o.tid and tonumber(row.trans_id) == o.tid) then
          O.apply_row(o, row, t)
          return row
        end
      end
    end
  end

  ------------------------------------------------------------------
  -- ТАКТ: очередь, повторы снятия, потерянные заявки
  ------------------------------------------------------------------
  function O.tick(t)
    local cfg = SC.cfg
    -- таблица заявок говорит "исполнено", а сделок нет 10 с: учитываем по цене заявки (мейкер - своя цена)
    for id, w in pairs(O.await) do
      local u = O.unsettled(w.o)
      if u <= 0 then O.await[id] = nil
      elseif t - w.t > 10 then
        O.await[id] = nil
        U.alert(string.format("[%s] order %s: executed %d by orders table, no trades in 10 s - booked at order price",
          w.o.inst.sec, tostring(w.o.key), u))
        O.fill(w.o, u, w.o.px, t)
      end
    end
    for _, o in pairs(O.live) do
      if o.state == "queued" then
        send_new(o, t)
      elseif o.backend == "real" then
        if o.state == "sent" and t - o.t_sent > cfg.PENDING_LOST_SEC then
          local row = O.lookup(o, t)
          if not row and o.state == "sent" then
            O.stats.lost = O.stats.lost + 1
            U.alert(string.format("[%s] order tid=%d: no reply %d s - LOST", o.inst.sec, o.tid, cfg.PENDING_LOST_SEC))
            finish(o, "lost", t)
            event(o, "lost")
          end
        elseif o.want_kill and o.state ~= "done" then
          if not o.kill_sent_t then
            send_kill(o, t)
          elseif o.need_lookup or (t - o.kill_sent_t > cfg.KILL_TIMEOUT_SEC) then
            o.need_lookup = false
            local row = O.lookup(o, t)
            if o.state ~= "done" and row and U.bit(row.flags, 0) and t - o.kill_sent_t > cfg.KILL_TIMEOUT_SEC then
              if o.kill_tries <= cfg.KILL_RETRIES then send_kill(o, t)
              else U.log_every("killfail" .. o.id, 30, string.format("[%s] cannot cancel order %s", o.inst.sec, tostring(o.key))) end
            end
          end
        end
      end
    end
  end

  ------------------------------------------------------------------
  -- НАШИ ОБЪЁМЫ В СТАКАНЕ (реальные активные) - вычитаются из стакана
  ------------------------------------------------------------------
  function O.own_levels(inst)
    local r = { B = {}, S = {} }
    for _, o in pairs(O.live) do
      if o.inst == inst and o.backend == "real" and o.state == "active" then
        local rem = o.qty - o.filled
        if rem > 0 then r[o.side][o.px] = (r[o.side][o.px] or 0) + rem end
      end
    end
    return r
  end

  -- худший случай: сколько ещё может исполниться в каждую сторону (реальные)
  function O.open_qty(inst, backend)
    local b, s = 0, 0
    for _, o in pairs(O.live) do
      if o.inst == inst and o.backend == backend then
        local rem = o.qty - o.filled
        if o.side == "B" then b = b + rem else s = s + rem end
      end
    end
    return b, s
  end

  function O.all_live(inst, backend)
    local r = {}
    for _, o in pairs(O.live) do
      if (not inst or o.inst == inst) and (not backend or o.backend == backend) then r[#r + 1] = o end
    end
    return r
  end

  function O.cancel_all(why, backend)
    local t = U.now()
    for _, o in pairs(O.live) do
      if not backend or o.backend == backend then O.cancel(o, t, why) end
    end
  end

  return O
end
