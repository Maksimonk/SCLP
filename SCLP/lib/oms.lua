-- oms.lua : orders. One state machine per order, keyed by our TRANS_ID.
--
--   SENT ──reply 3/15 or active row──> ACTIVE ──row inactive──> FILLED | CANCELLED
--     │                                  └─ partial fills keep it ACTIVE
--     ├─reply 4,5,6,10,11,13,14,16──> REJECTED
--     └─reply 2/12 (link error / timeout): state UNKNOWN on the exchange -> looked up in the orders table, never
--       assumed rejected (the order may be live); no row within PENDING_LOST_SEC -> LOST + alert
--
-- Fills are counted ONLY from OnTrade (deduplicated by trade number), so the position does not depend on the
-- order in which OnOrder/OnTrade arrive. A finished order whose row says "executed N" while fewer trades arrived
-- waits 10 s for them, then the rest is booked at the order price.
--
-- Transaction formats (see README "Пассивное исполнение"):
--   "boc"   - universal format with "Условие исполнения = Только пассивная" (exchange Book-or-Cancel). Verified on
--             FORTS with this broker: rejects come as [GW][82]. The fixed format has no BoC value (ARQA, 06.2026).
--   "limit" - fixed format NEW_ORDER TYPE=L (queue). No exchange guarantee: passivity rests on the pre-trade
--             book check only. Used where BoC is not confirmed (equities by default).
--   taker   - fixed format TYPE=L, EXECUTION_CONDITION=KILL_BALANCE (IOC). PANIC flatten only.
return function(X)
  local O = {}
  X.O = O
  local U = X.U
  local floor, min, max = math.floor, math.min, math.max

  O.by_tid, O.by_key, O.kill_by_tid, O.live, O.trades_seen, O.await = {}, {}, {}, {}, {}, {}
  O.foreign_kill = {}
  O.st = { sent = 0, accepted = 0, rejected = 0, rej_boc = 0, rej_cross = 0, rej_other = 0, local_err = 0,
           cancels = 0, cancelled = 0, filled = 0, fills = 0, fill_qty = 0, kill_err = 0, lost = 0,
           taker_suspect = 0, taker_orders = 0, uncertain = 0 }
  O.sent_times = {}       -- send times for the rolling orders-per-minute counter
  O.halt = nil

  ------------------------------------------------------------------
  -- TRANS_ID: 1 800 000 000 + seconds since MSK midnight * 100 + counter. Below 2^31, above forQUIK
  -- (< ~1.0e9), below scalp.lua (>= 2.0e9). Unique across restarts within a day while the average rate < 100 tx/s.
  ------------------------------------------------------------------
  local BASE, SPAN = 1800000000, 10000000
  local seq
  function O.next_tid()
    if not seq then seq = BASE + floor(U.msk_sec()) * 100 end
    seq = seq + 1
    return seq
  end
  function O.is_own_tid(tid)
    tid = tonumber(tid)
    return tid ~= nil and tid > BASE and tid < BASE + SPAN
  end
  -- an order/trade row placed by SCLP: our TRANS_ID range or our tag in brokerref
  function O.is_ours(row)
    if O.is_own_tid(row.trans_id) then return true end
    local tag = X.cfg.ORDER_TAG or ""
    return tag ~= "" and tostring(row.brokerref or ""):find(tag, 1, true) ~= nil
  end

  ------------------------------------------------------------------
  -- RATE LIMIT (token bucket, MAX_TX_PER_SEC; MOEX login base throughput is 30 tx/s)
  ------------------------------------------------------------------
  local bucket = { tokens = 5, t = nil }
  local function take(t)
    local rate = X.cfg.MAX_TX_PER_SEC or 20
    if bucket.t then bucket.tokens = min(rate, bucket.tokens + (t - bucket.t) * rate) end
    bucket.t = t
    if bucket.tokens >= 1 then bucket.tokens = bucket.tokens - 1; return true end
    return false
  end

  function O.orders_last_min(t)
    local s = O.sent_times
    local i = 1
    while s[i] and s[i] < t - 60 do i = i + 1 end
    if i > 1 then
      local keep = {}
      for j = i, #s do keep[#keep + 1] = s[j] end
      O.sent_times = keep
      s = keep
    end
    return #s
  end

  ------------------------------------------------------------------
  -- TRANSACTIONS
  ------------------------------------------------------------------
  local function enc(s) return U.to_cp1251(s) end
  function O.account(class) return (X.cfg.ACCOUNTS or {})[class] or X.cfg.ACCOUNT or "" end
  -- regular orders are always Book-or-Cancel; "taker" (IOC) is used only by PANIC
  function O.mode() return "boc" end
  O.passive_checked = {}       -- [class] = true after passive_only_order was confirmed

  function O.build_boc(inst, side, px, qty, tid)
    local F = U.merge(X.cfg.TX, (X.cfg.TX_BY_CLASS or {})[inst.class])
    local t = { TRANS_ID = string.format("%d", tid), CLASSCODE = inst.class, ACTION = enc(F.ACTION) }
    t[enc(F.ACCOUNT)] = O.account(inst.class)
    t[enc(F.SIDE)] = enc(side == "B" and F.BUY or F.SELL)
    t[enc(F.TYPE)] = enc(F.TYPE_LIMIT)
    t[enc(F.SEC)] = inst.sec
    t[enc(F.PRICE)] = inst:px_str(px)
    t[enc(F.QTY)] = string.format("%d", qty)
    t[enc(F.COND)] = enc(F.COND_PASSIVE)
    if (X.cfg.CLIENT_CODE or "") ~= "" then t[enc(F.CLIENT_CODE)] = X.cfg.CLIENT_CODE end
    -- tag in the universal format only if the broker's field name is known (an unknown field = local reject)
    if F.COMMENT and (X.cfg.ORDER_TAG or "") ~= "" then t[enc(F.COMMENT)] = X.cfg.ORDER_TAG end
    return t
  end

  function O.build_limit(inst, side, px, qty, tid, cond)
    local t = { ACCOUNT = O.account(inst.class), CLASSCODE = inst.class, SECCODE = inst.sec, ACTION = "NEW_ORDER",
                TYPE = "L", OPERATION = side, PRICE = inst:px_str(px), QUANTITY = string.format("%d", qty),
                TRANS_ID = string.format("%d", tid) }
    if cond then t.EXECUTION_CONDITION = cond end
    if (X.cfg.CLIENT_CODE or "") ~= "" then t.CLIENT_CODE = X.cfg.CLIENT_CODE end
    if (X.cfg.ORDER_TAG or "") ~= "" then t.COMMENT = X.cfg.ORDER_TAG end       -- shows up in orders.brokerref
    return t
  end

  function O.build_kill(class, sec, key, tid)
    local t = { ACCOUNT = O.account(class), CLASSCODE = class, SECCODE = sec, ACTION = "KILL_ORDER",
                ORDER_KEY = key, TRANS_ID = string.format("%d", tid) }
    if (X.cfg.CLIENT_CODE or "") ~= "" then t.CLIENT_CODE = X.cfg.CLIENT_CODE end
    return t
  end

  local function send(t)
    local ok, res = pcall(sendTransaction, t)
    if not ok then return "sendTransaction crashed: " .. tostring(res) end
    return res or ""
  end

  ------------------------------------------------------------------
  -- EVENTS -> trader / metrics (set by sclp.lua)
  ------------------------------------------------------------------
  local function emit(name, ...) local f = X.ev and X.ev[name]; if f then f(...) end end

  local function settled(o) return not (o.exec_by_table and o.exec_by_table > o.filled) end

  local function finish(o, how, t)
    if o.done then return end
    o.done = true
    o.state = how
    o.t_done = t
    O.live[o.id] = nil
    if how == "CANCELLED" then O.st.cancelled = O.st.cancelled + 1 end
    if how == "FILLED" then O.st.filled = O.st.filled + 1 end
    if settled(o) then emit("done", o, t) else O.await[o.id] = { o = o, t = t } end
  end

  ------------------------------------------------------------------
  -- NEW ORDER
  -- opt: taker (IOC), t_key (key press time), src ("key"|"tp"|"requote"|"flat"|"panic"), offset, px0, parent
  ------------------------------------------------------------------
  local next_id = 0
  function O.place(inst, side, px, qty, opt, t)
    opt = opt or {}
    t = t or U.now()
    if O.halt and not opt.taker then return nil, "halt" end
    if not take(t) then return nil, "лимит транзакций в секунду" end
    next_id = next_id + 1
    local tid = O.next_tid()
    local mode = opt.taker and "taker" or O.mode(inst)
    local o = { id = next_id, tid = tid, inst = inst, side = side, px = px, qty = qty, filled = 0, state = "SENT",
                src = opt.src or "key", mode = mode, t_key = opt.t_key, offset = opt.offset, px0 = opt.px0 or px,
                parent = opt.parent, t_send0 = t }
    local tx
    if mode == "taker" then tx = O.build_limit(inst, side, px, qty, tid, "KILL_BALANCE")
    else tx = O.build_boc(inst, side, px, qty, tid) end
    local res = send(tx)
    o.t_send = U.now()
    O.st.sent = O.st.sent + 1
    if mode == "taker" then O.st.taker_orders = O.st.taker_orders + 1 end
    O.sent_times[#O.sent_times + 1] = t
    if res ~= "" then
      -- QUIK refused the transaction locally (wrong field names / parameters): nothing reached the exchange
      local msg = U.from_cp1251(res)
      O.st.local_err = O.st.local_err + 1
      o.done, o.state, o.reject_msg, o.t_done = true, "REJECTED", msg, t
      U.alert(string.format("[%s] QUIK rejected the transaction locally: %s", inst.sec, msg), 3)
      if mode == "boc" then
        O.halt = "QUIK не принял заявку «Только пассивная» (" .. msg .. "): проверьте поля TX в sclp_config.lua"
      end
      emit("reject", o, msg, "local")
      return nil, msg
    end
    O.by_tid[tid] = o
    O.live[o.id] = o
    U.log(string.format("[%s] NEW %s %d @ %s tid=%d src=%s mode=%s", inst.sec, side == "B" and "BUY" or "SELL",
      qty, inst:px_str(px), tid, o.src, mode))
    return o
  end

  local function send_kill(o, t)
    if not o.key then return false end           -- number unknown yet: sent when the reply brings it
    if not take(t) then return false end
    local tid = O.next_tid()
    O.kill_by_tid[tid] = o
    o.kill_sent_t = t
    o.kill_tries = (o.kill_tries or 0) + 1
    O.st.cancels = O.st.cancels + 1
    local res = send(O.build_kill(o.inst.class, o.inst.sec, o.key, tid))
    if res ~= "" then U.log(string.format("[%s] KILL send error key=%s: %s", o.inst.sec, o.key, U.from_cp1251(res))) end
    return true
  end

  -- cancel (idempotent)
  function O.cancel(o, why, t)
    if o.done or o.want_kill then return end
    t = t or U.now()
    o.want_kill = true
    o.kill_why = why
    send_kill(o, t)
  end

  function O.cancel_where(inst, pred, why, t)
    local n = 0
    for _, o in pairs(O.live) do
      if o.inst == inst and not o.want_kill and (not pred or pred(o)) then O.cancel(o, why, t); n = n + 1 end
    end
    return n
  end

  ------------------------------------------------------------------
  -- QUIK CALLBACK EVENTS (queued by sclp.lua, processed in the main loop)
  ------------------------------------------------------------------
  function O.classify(msg)
    local m = (msg or ""):lower()
    -- broker of this user (02.10.2026): "[GW][82] Заявка Book-or-Cancel не может быть выставлена/переставлена,
    -- т.к. она приводит к немедленному исполнению."
    if m:find("%[82%]") or m:find("book%-or%-cancel") or m:find("book or cancel") or m:find("пассивн")
       or m:find("немедленн") or m:find("встречн") then return "boc" end
    if m:find("кросс") or m:find("cross") then return "cross" end
    return "other"
  end

  function O.on_reply(r, t)
    local tid = tonumber(r.trans_id)
    if not tid then return end
    local status = tonumber(r.status) or -1
    if status == 0 or status == 1 then return end
    local msg = U.from_cp1251(r.result_msg or "")
    local o = O.by_tid[tid]
    if o then
      o.t_reply = o.t_reply or r.t
      if status == 3 or status == 15 then
        o.uncertain = nil
        local key = U.key_from_num(r.order_num)
        if key and key ~= "0" and not o.key then o.key = key; O.by_key[key] = o end
        if o.state == "SENT" and not o.done then
          o.state = "ACTIVE"; o.t_active = o.t_active or r.t
          O.st.accepted = O.st.accepted + 1
          emit("accept", o, t)
        end
        if o.want_kill and not o.kill_sent_t and not o.done then send_kill(o, t) end
      elseif status == 2 or status == 12 then
        -- link error / timeout: the order may or may not be on the exchange - find it in the orders table
        if not o.done then
          o.uncertain = msg
          o.lookup_at = t + 1
          O.st.uncertain = O.st.uncertain + 1
          U.alert(string.format("[%s] tid=%d: reply status %d (%s) - order state unknown, checking orders table",
            o.inst.sec, tid, status, msg), 2)
        end
      elseif not o.done then
        local cls = (status == 13) and "cross" or O.classify(msg)
        o.reject_msg, o.reject_cls = msg, cls
        O.st.rejected = O.st.rejected + 1
        if cls == "boc" then O.st.rej_boc = O.st.rej_boc + 1
        elseif cls == "cross" then O.st.rej_cross = O.st.rej_cross + 1
        else O.st.rej_other = O.st.rej_other + 1 end
        U.log(string.format("[%s] REJECT tid=%d status=%d class=%s: %s", o.inst.sec, tid, status, cls, msg))
        finish(o, "REJECTED", t)
        emit("reject", o, msg, cls)
      end
      return
    end
    local ko = O.kill_by_tid[tid]
    if ko then
      O.kill_by_tid[tid] = nil
      if status == 3 or status == 15 then
        ko.kill_ok_t = t
      else
        O.st.kill_err = O.st.kill_err + 1       -- usually already filled; an "erroneous transaction" for MOEX
        ko.kill_err = msg
        ko.lookup_at = t                        -- check the row right away
        U.log(string.format("[%s] KILL rejected key=%s: %s", ko.inst.sec, tostring(ko.key), msg))
      end
    end
  end

  local function passive_flag_check(o, row)
    if o.mode ~= "boc" or O.passive_checked[o.inst.class] or X.cfg.CHECK_PASSIVE_FLAG == false then return end
    local v = row.passive_only_order
    if v == nil then return end
    O.passive_checked[o.inst.class] = true
    local on = (v == true) or (tonumber(v) and tonumber(v) ~= 0) or (type(v) == "string" and v ~= "" and v ~= "0")
    U.log(string.format("[%s] orders.passive_only_order = %s", o.inst.sec, tostring(v)))
    if not on then
      O.halt = "у принятой заявки НЕ установлен признак «Только пассивная» (passive_only_order = " .. tostring(v) ..
               "). Поля TX не подходят вашему QUIK - SCLP/tools/probe_passive.lua"
      U.alert(O.halt, 3)
      O.cancel_where(o.inst, nil, "halt")
    end
  end

  function O.apply_row(o, row, t)
    local key = U.key_from_num(row.order_num)
    if key and key ~= "0" and not o.key then o.key = key; O.by_key[key] = o end
    passive_flag_check(o, row)
    local active = U.bit(row.flags, 0)
    local balance = U.num(row.balance) or 0
    local exec = o.qty - balance
    o.row_seen = true
    o.uncertain = nil
    if active then
      if o.state == "SENT" then
        o.state = "ACTIVE"; o.t_active = o.t_active or t
        O.st.accepted = O.st.accepted + 1
        emit("accept", o, t)
      end
      if o.want_kill and not o.kill_sent_t then send_kill(o, t) end
      return
    end
    if o.done then return end
    o.exec_by_table = exec
    if o.state == "SENT" then O.st.accepted = O.st.accepted + 1; o.t_active = o.t_active or t end
    finish(o, U.bit(row.flags, 1) and "CANCELLED" or "FILLED", t)
  end

  function O.on_order(row, t)
    local tid = tonumber(row.trans_id)
    local o = tid and O.by_tid[tid]
    if not o then
      local k = U.key_from_num(row.order_num)
      o = k and O.by_key[k]
    end
    if o then O.apply_row(o, row, t) end
  end

  function O.on_trade(tr, t)
    local tn = U.key_from_num(tr.trade_num) or tostring(tr.trade_num)
    if O.trades_seen[tn] then return end
    local k = U.key_from_num(tr.order_num)
    local o = k and O.by_key[k]
    if not o then
      local tid = tonumber(tr.trans_id)
      o = tid and O.by_tid[tid]
      if o and k and not o.key then o.key = k; O.by_key[k] = o end
    end
    if not o then return end
    O.trades_seen[tn] = o.inst.key
    local q = U.num(tr.qty) or 0
    local px = floor(U.num(tr.price) / o.inst.tick + 0.5)
    -- a maker fill happens at our limit price; a better price means our order crossed the book
    if o.mode ~= "taker" and ((o.side == "B" and px < o.px) or (o.side == "S" and px > o.px)) then o.taker_suspect = true end
    O.fill(o, q, px, t, tn)
  end

  function O.fill(o, q, px, t, tn)
    if q <= 0 then return end
    o.filled = o.filled + q
    o.t_fill = o.t_fill or t
    O.st.fills = O.st.fills + 1
    O.st.fill_qty = O.st.fill_qty + q
    if o.taker_suspect and not o.taker_counted then
      o.taker_counted = true
      O.st.taker_suspect = O.st.taker_suspect + 1
      U.alert(string.format("[%s] order tid=%d %s @ %s executed as TAKER (crossed the book)", o.inst.sec, o.tid,
        o.side, o.inst:px_str(o.px)), 3)
    end
    if o.state == "SENT" then o.state = "ACTIVE"; o.t_active = o.t_active or t end
    emit("fill", o, q, px, t, tn)
    if o.filled >= o.qty and not o.done then finish(o, "FILLED", t)
    elseif o.done and O.await[o.id] and settled(o) then O.await[o.id] = nil; emit("done", o, t) end
  end

  ------------------------------------------------------------------
  -- ORDERS TABLE LOOKUP (insurance when a callback was lost)
  ------------------------------------------------------------------
  function O.lookup(o, t)
    if not getNumberOf then return nil end
    local n = getNumberOf("orders") or 0
    for i = n - 1, max(0, n - 3000), -1 do
      local row = getItem("orders", i)
      if row and ((o.tid and tonumber(row.trans_id) == o.tid) or (o.key and U.key_from_num(row.order_num) == o.key)) then
        O.apply_row(o, row, t)
        return row
      end
    end
    return nil
  end

  -- active rows of the instrument on our account: { row, own = bool }
  function O.active_rows(inst)
    local r = {}
    if not getNumberOf then return r end
    local acc = O.account(inst.class)
    local n = getNumberOf("orders") or 0
    for i = 0, n - 1 do
      local row = getItem("orders", i)
      if row and row.sec_code == inst.sec and U.bit(row.flags, 0)
         and (acc == "" or row.account == nil or row.account == acc) then
        r[#r + 1] = row
      end
    end
    return r
  end

  -- PANIC: cancel an order we did not place (manual / other scripts), at most once per second
  function O.kill_row(inst, row, t)
    local key = U.key_from_num(row.order_num)
    if not key then return false end
    local own = O.by_key[key] or O.by_tid[tonumber(row.trans_id) or -1]
    if own then O.cancel(own, "panic", t); return true end
    if t - (O.foreign_kill[key] or -1e9) < 1 then return true end
    if not take(t) then return false end
    O.foreign_kill[key] = t
    O.st.cancels = O.st.cancels + 1
    local res = send(O.build_kill(inst.class, inst.sec, key, O.next_tid()))
    if res ~= "" then U.log("[" .. inst.sec .. "] PANIC kill error " .. key .. ": " .. U.from_cp1251(res)) end
    return true
  end

  ------------------------------------------------------------------
  -- TICK: unknown states, kill retries, late trades, memory
  ------------------------------------------------------------------
  local t_gc = 0
  local function gc(t)
    if t - t_gc < 30 then return end
    t_gc = t
    local keep = X.cfg.GC_KEEP_SEC or 1800
    local function old(o) return o.done and t - (o.t_done or t) > keep and not O.await[o.id] end
    for k, o in pairs(O.by_tid) do if old(o) then O.by_tid[k] = nil end end
    for k, o in pairs(O.by_key) do if old(o) then O.by_key[k] = nil end end
    for k, o in pairs(O.kill_by_tid) do if old(o) then O.kill_by_tid[k] = nil end end
    for k, ts in pairs(O.foreign_kill) do if t - ts > 60 then O.foreign_kill[k] = nil end end
  end

  function O.tick(t)
    local cfg = X.cfg
    gc(t)
    for id, w in pairs(O.await) do
      local o = w.o
      if settled(o) then O.await[id] = nil; emit("done", o, t)
      elseif t - w.t > 10 then
        O.await[id] = nil
        local rest = o.exec_by_table - o.filled
        U.alert(string.format("[%s] tid=%d: executed %d by orders table, no trades in 10 s - booked at order price",
          o.inst.sec, o.tid, rest), 2)
        O.fill(o, rest, o.px, t)
        emit("done", o, t)
      end
    end
    for _, o in pairs(O.live) do
      if o.state == "SENT" and (o.uncertain or t - o.t_send0 > (cfg.PENDING_LOST_SEC or 10)) then
        if not o.lookup_at or t >= o.lookup_at then
          o.lookup_at = t + 1
          local row = O.lookup(o, t)
          if not row and t - o.t_send0 > (cfg.PENDING_LOST_SEC or 10) then
            O.st.lost = O.st.lost + 1
            U.alert(string.format("[%s] order tid=%d: no reply and no row in %d s - LOST. Check the orders table!",
              o.inst.sec, o.tid, cfg.PENDING_LOST_SEC or 10), 3)
            finish(o, "LOST", t)
          end
        end
      elseif o.want_kill and not o.done then
        if not o.kill_sent_t then
          if o.key then send_kill(o, t) end
        elseif (o.lookup_at and t >= o.lookup_at) or t - o.kill_sent_t > (cfg.KILL_TIMEOUT_SEC or 3) then
          o.lookup_at = nil
          local row = O.lookup(o, t)
          if not o.done and row and U.bit(row.flags, 0) and t - o.kill_sent_t > (cfg.KILL_TIMEOUT_SEC or 3) then
            if (o.kill_tries or 0) <= (cfg.KILL_RETRIES or 3) then send_kill(o, t)
            else U.log_every("killfail" .. o.id, 30, string.format("[%s] cannot cancel order %s", o.inst.sec, tostring(o.key))) end
          end
        end
      end
    end
  end

  ------------------------------------------------------------------
  -- RESTART: re-attach an order found in the orders table (sv - its saved record, may be nil)
  ------------------------------------------------------------------
  function O.adopt(inst, row, sv, t)
    next_id = next_id + 1
    local tid = tonumber(row.trans_id)
    if not tid or tid == 0 then tid = sv and sv.tid end
    local key = U.key_from_num(row.order_num)
    local qty = U.num(row.qty) or (sv and sv.qty) or 0
    local o = { id = next_id, tid = tid, key = key, inst = inst, side = U.bit(row.flags, 2) and "S" or "B",
                px = floor(U.num(row.price) / inst.tick + 0.5), qty = qty, filled = (sv and sv.filled) or 0,
                state = "ACTIVE", src = (sv and sv.src) or "adopted", mode = (sv and sv.mode) or O.mode(inst),
                offset = sv and sv.offset, px0 = (sv and sv.px0), parent = sv and sv.parent,
                t_send0 = (sv and sv.t_send) or t, t_send = (sv and sv.t_send) or t, t_active = t, row_seen = true,
                adopted = true }
    o.px0 = o.px0 or o.px
    if tid then O.by_tid[tid] = o end
    if key then O.by_key[key] = o end
    O.live[o.id] = o
    return o
  end

  -- saved records of the live orders of an instrument
  function O.export(inst)
    local r = {}
    for _, o in ipairs(O.working(inst)) do
      r[#r + 1] = { tid = o.tid, key = o.key, side = o.side, px = o.px, qty = o.qty, filled = o.filled, src = o.src,
                    mode = o.mode, offset = o.offset, px0 = o.px0, parent = o.parent, t_send = o.t_send }
    end
    return r
  end
  -- counted trade numbers of an instrument, the newest 5000 (enough for any session, bounded file size)
  function O.export_trades(inst)
    local r = {}
    for tn, k in pairs(O.trades_seen) do if k == inst.key then r[#r + 1] = tn end end
    table.sort(r, function(a, b) if #a ~= #b then return #a > #b end return a > b end)
    for i = #r, 5001, -1 do r[i] = nil end
    return r
  end
  -- new day: session counters restart; trades_seen is kept (the trading day spans midnight on FORTS)
  function O.new_day()
    for k in pairs(O.st) do O.st[k] = 0 end
    O.sent_times = {}
  end

  ------------------------------------------------------------------
  -- QUERIES
  ------------------------------------------------------------------
  -- our resting volume per price (SENT counts too: QUIK often shows the order in the book before the reply)
  function O.own_levels(inst)
    local r = { B = {}, S = {} }
    for _, o in pairs(O.live) do
      if o.inst == inst and o.mode ~= "taker" then
        local rem = o.qty - o.filled
        if rem > 0 then
          r[o.side][o.px] = (r[o.side][o.px] or 0) + rem
          if o.side == "S" and (not r.min_sell or o.px < r.min_sell) then r.min_sell = o.px end
          if o.side == "B" and (not r.max_buy or o.px > r.max_buy) then r.max_buy = o.px end
        end
      end
    end
    return r
  end

  function O.working(inst, side, src)
    local r = {}
    for _, o in pairs(O.live) do
      if o.inst == inst and (not side or o.side == side) and (not src or o.src == src) then r[#r + 1] = o end
    end
    table.sort(r, function(a, b) return a.id < b.id end)
    return r
  end

  function O.working_qty(inst, side, src)
    local q = 0
    for _, o in ipairs(O.working(inst, side, src)) do q = q + (o.qty - o.filled) end
    return q
  end

  function O.any_live(inst)
    for _, o in pairs(O.live) do if not inst or o.inst == inst then return true end end
    return false
  end

  return O
end
