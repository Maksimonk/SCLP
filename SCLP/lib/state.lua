-- state.lua : restart safety. Persistence of orders / open legs / settings / metrics and recovery on start.
--
-- WHERE STATE LIVES
--   sclp_settings_<ACCOUNT>.lua            settings window values, active instrument, instruments with open legs,
--                                          session counters, daily-loss stop
--   sclp_state_<ACCOUNT>_<CLASS>_<SEC>.lua per instrument: live orders, open lots (unmatched fills, FIFO) with the
--                                          linked take-profit TRANS_ID, trade numbers already counted today,
--                                          intraday metrics
--   Both are Lua tables, loaded with load(text, ..., "t", {}) (no globals, no code from the file can run QUIK API).
--   Written atomically: <file>.tmp is written and closed, the previous file becomes <file>.bak (rolling backup),
--   then .tmp is renamed into place. Reading tries <file>, <file>.tmp, <file>.bak; a truncated file does not
--   parse, so a crash in the middle of a write can never be loaded as valid state.
--   Writes are event driven (new order, reply, fill, cancel, reject, settings change): events only set a dirty
--   flag, the main loop writes once per iteration AFTER the hotkey's transaction is already sent.
--
-- RECOVERY (QUIK tables are the truth, the file is only a hint)
--   1. load the file (missing/corrupt -> exchange data only, warning);
--   2. orders table: saved orders still active -> re-attached to the state machine; saved orders finished while
--      the script was off -> their trades are booked below; active orders with our TRANS_ID range or our tag in
--      brokerref that the file does not know -> adopted and flagged; manual orders are never touched;
--   3. trades table: every trade of our orders whose number is not in the saved "counted" set is booked
--      (FIFO matching against the open lots) - duplicates after a reconnect are ignored by trade number;
--   4. computed position vs real position (futures_client_holding / depo_limits). Mismatch -> trading blocked,
--      the window asks: A,A - adopt the exchange position, P,P - PANIC-close the exchange position;
--   5. take-profits of open lots that lost their order are placed again (passive only) once the book is valid;
--   6. everything is written to the recovery report window and to the log.
return function(X)
  local S = {}
  X.S = S
  local U = X.U
  local floor = math.floor

  local function safe(s) return (tostring(s or ""):gsub("[^%w_%-]", "_")) end
  function S.path_of(class, sec)
    return U.path("sclp_state_" .. safe((X.cfg.ACCOUNTS or {})[class] or X.cfg.ACCOUNT) .. "_" .. safe(class) .. "_" .. safe(sec) .. ".lua")
  end
  function S.inst_path(inst) return S.path_of(inst.class, inst.sec) end
  function S.settings_path() return U.path("sclp_settings_" .. safe(X.cfg.ACCOUNT) .. ".lua") end

  ------------------------------------------------------------------
  -- FILE I/O
  ------------------------------------------------------------------
  function S.write(path, tbl)
    tbl.complete = true
    local f = io.open(path .. ".tmp", "w")
    if not f then return false end
    f:write("return ", U.serialize(tbl), "\n")
    f:close()
    os.remove(path .. ".bak")
    os.rename(path, path .. ".bak")              -- fails harmlessly on the first write
    local ok = os.rename(path .. ".tmp", path)
    return ok and true or false
  end

  -- returns table, file it came from | nil, "missing" | "corrupt"
  function S.read(path)
    local any = false
    for _, p in ipairs({ path, path .. ".tmp", path .. ".bak" }) do
      local txt = U.read_file(p)
      if txt then
        any = true
        local fn
        if setfenv and loadstring then                -- Lua 5.1
          fn = loadstring(txt, "=" .. p)
          if fn then setfenv(fn, {}) end
        else
          fn = load(txt, "=" .. p, "t", {})          -- text only, empty environment
        end
        if fn then
          local ok, v = pcall(fn)
          if ok and type(v) == "table" and v.complete then return v, p end
        end
      end
    end
    return nil, any and "corrupt" or "missing"
  end

  ------------------------------------------------------------------
  -- DIRTY FLAGS + FLUSH (called by the main loop once per iteration)
  ------------------------------------------------------------------
  local dirty_inst, dirty_settings = {}, false
  function S.mark(inst)
    inst = inst or X.inst
    if inst then dirty_inst[inst.key] = inst end
  end
  function S.mark_settings() dirty_settings = true end

  function S.save_inst(inst, t)
    local m = X.M.get(inst)
    local orders = X.O.export(inst)
    local ok = S.write(S.inst_path(inst), {
      version = 1, account = X.O.account(inst.class), class = inst.class, sec = inst.sec,
      day = U.date("%Y%m%d", t), saved_at = t, orders = orders, metrics = X.M.export_one(inst),
      trades = X.O.export_trades(inst),
    })
    if not ok then U.log_every("state_write", 60, "STATE WRITE FAILED: " .. S.inst_path(inst)) end
    -- the settings file keeps the list of instruments that still have open legs or orders
    dirty_settings = true                          -- session counters live in the settings file
    local open = (m.pos ~= 0 or #orders > 0) and { pos = m.pos, orders = #orders, sec = inst.sec, class = inst.class } or nil
    X.st.open_insts[inst.key] = open
  end

  function S.save_settings(t)
    local st = {}
    for k, v in pairs(X.st) do st[k] = v end
    st.version, st.day, st.saved_at = 1, U.date("%Y%m%d", t), t
    st.counters = X.O.st
    st.day_stop = X.R.day_stop
    if not S.write(S.settings_path(), st) then U.log_every("settings_write", 60, "SETTINGS WRITE FAILED") end
  end

  function S.flush(t)
    for k, inst in pairs(dirty_inst) do dirty_inst[k] = nil; S.save_inst(inst, t) end
    if dirty_settings then dirty_settings = false; S.save_settings(t) end
  end

  -- settings at start: saved values over config defaults
  function S.load_settings(t)
    local sv = S.read(S.settings_path())
    if not sv then return nil end
    local today = sv.day == U.date("%Y%m%d", t)
    for _, k in ipairs({ "inst_text", "inst_key", "offset", "qty", "tp", "tp_last", "requote", "skew", "max_pos", "max_loss" }) do
      if sv[k] ~= nil then X.st[k] = sv[k] end
    end
    X.st.open_insts = type(sv.open_insts) == "table" and sv.open_insts or {}
    if today then
      for k, v in pairs(sv.counters or {}) do if X.O.st[k] ~= nil and type(v) == "number" then X.O.st[k] = v end end
      if sv.day_stop then X.R.day_stop = true end
    end
    return sv
  end

  ------------------------------------------------------------------
  -- QUIK TABLES
  ------------------------------------------------------------------
  local function rows_of(name, inst)
    local r = {}
    if not getNumberOf then return r end
    local n = getNumberOf(name) or 0
    for i = 0, n - 1 do
      local row = getItem(name, i)
      if row and row.sec_code == inst.sec and (row.class_code == nil or row.class_code == inst.class) then r[#r + 1] = row end
    end
    return r
  end

  -- real position in lots: FORTS futures_client_holding.totalnet, equities depo_limits.currentbal / lot.
  -- returns pos, avg price index (or nil) | nil if it cannot be read
  function S.real_pos(inst)
    if not getNumberOf then return nil end
    if inst.forts then
      local p, row = X.R.broker_pos(inst)
      local avg = row and U.num(row.avrposnprice)
      return p, (avg and avg > 0) and avg / inst.tick or nil
    end
    local n = getNumberOf("depo_limits")
    if not n then return nil end
    local best
    for i = 0, n - 1 do
      local r = getItem("depo_limits", i)
      if r and r.sec_code == inst.sec and ((X.cfg.CLIENT_CODE or "") == "" or r.client_code == X.cfg.CLIENT_CODE)
         and (not best or (tonumber(r.limit_kind) or 0) > (tonumber(best.limit_kind) or 0)) then best = r end
    end
    if not best then return 0 end
    local avg = U.num(best.awg_position_price)
    return floor((U.num(best.currentbal) or 0) / inst.lot + 0.5), (avg and avg > 0) and avg / inst.tick or nil
  end

  -- QUIK fills its tables gradually after a (re)connect: wait until connected and the orders table stops growing
  local settle = { n = -1, t = 0 }
  function S.tables_ready(t)
    if not X.R.connected() then return false end
    if t - (X.t_start or t) < (X.cfg.STARTUP_SETTLE_SEC or 3) then return false end
    if t - (X.t_start or t) > 20 then return true end
    local n = (getNumberOf and (getNumberOf("orders") or 0) + (getNumberOf("trades") or 0)) or 0
    if n ~= settle.n then settle.n, settle.t = n, t; return false end
    return t - settle.t >= 1
  end

  local function trade_num_less(a, b)
    if #a ~= #b then return #a < #b end
    return a < b
  end

  ------------------------------------------------------------------
  -- RECOVERY of one instrument (start of the script, or switching to an instrument). Returns report lines.
  ------------------------------------------------------------------
  function S.recover(inst, t)
    local rep = {}
    local function say(s) rep[#rep + 1] = s; U.log("RECOVERY [" .. inst.sec .. "] " .. s) end
    local O, M = X.O, X.M
    local path = S.inst_path(inst)
    local sv, src = S.read(path)
    local today = U.date("%Y%m%d", t)
    if not sv then
      if src == "corrupt" then say("ФАЙЛ СОСТОЯНИЯ ПОВРЕЖДЁН - восстановление только по данным QUIK")
      else say("файла состояния нет - восстановление только по данным QUIK") end
    elseif src ~= path then
      say("основной файл повреждён, взят " .. (src:match("%.bak$") and "резервный (.bak)" or "временный (.tmp)"))
    end
    local same_day = sv and sv.day == today
    if sv and not same_day then say("новый день (файл от " .. tostring(sv.day) .. "): статистика сброшена, открытые позиции перенесены") end
    M.import_one(inst, sv and sv.metrics, same_day, t)
    -- counted trade numbers are kept across days: the FORTS trading day starts in the previous evening, so after a
    -- night restart the trades table still holds yesterday-evening trades that were already counted
    for _, tn in ipairs((sv and sv.trades) or {}) do O.trades_seen[tn] = inst.key end

    -- 1. orders
    local by_key, by_tid, used = {}, {}, {}
    local rows = rows_of("orders", inst)
    for _, row in ipairs(rows) do
      local k = U.key_from_num(row.order_num)
      if k then by_key[k] = row end
      local tid = tonumber(row.trans_id)
      if tid and tid > 0 then by_tid[tid] = row end
    end
    local saved_by_key = {}
    local n_att, n_fin, n_gone, n_adopt = 0, 0, 0, 0
    for _, so in ipairs((sv and sv.orders) or {}) do
      local row = (so.key and by_key[so.key]) or (so.tid and by_tid[so.tid])
      local d = string.format("%s %d @ %s (%s)", so.side == "B" and "покупка" or "продажа", so.qty or 0,
        so.px and inst:px_str(so.px) or "?", so.src or "?")
      if row then
        used[row] = true
        local k = U.key_from_num(row.order_num)
        if k then saved_by_key[k] = so end
        if U.bit(row.flags, 0) then
          O.adopt(inst, row, so, t)
          n_att = n_att + 1
          say("заявка снова под управлением: " .. d)
        else
          n_fin = n_fin + 1
          say("заявка завершилась без скрипта: " .. d .. " - " .. (U.bit(row.flags, 1) and "снята" or "исполнена") ..
            string.format(", исполнено %d", (U.num(row.qty) or 0) - (U.num(row.balance) or 0)))
        end
      else
        n_gone = n_gone + 1
        say("заявки из файла нет в таблице QUIK (прошлая сессия / снята): " .. d)
      end
    end
    local n_manual = 0
    for _, row in ipairs(rows) do
      if not used[row] and U.bit(row.flags, 0) then
        if O.is_ours(row) then
          O.adopt(inst, row, nil, t)
          n_adopt = n_adopt + 1
          say(string.format("НАЙДЕНА заявка SCLP, которой нет в файле: %s %s @ %s - подхвачена (не переставляется, C - снять)",
            U.bit(row.flags, 2) and "продажа" or "покупка", tostring(row.balance), tostring(row.price)))
        else
          n_manual = n_manual + 1
        end
      end
    end
    if n_manual > 0 then say(string.format("ручных/чужих активных заявок: %d - SCLP их не трогает", n_manual)) end

    -- 2. trades made while the script was off (idempotent by trade number)
    local trs = rows_of("trades", inst)
    table.sort(trs, function(a, b) return trade_num_less(U.key_from_num(a.trade_num) or "", U.key_from_num(b.trade_num) or "") end)
    local n_off = 0
    for _, tr in ipairs(trs) do
      local tn = U.key_from_num(tr.trade_num)
      local k = U.key_from_num(tr.order_num)
      if tn and not O.trades_seen[tn] then
        local o = k and O.by_key[k]
        local so = k and saved_by_key[k]
        if o or so or O.is_ours(tr) then
          local side = U.bit(tr.flags, 2) and "S" or "B"
          local q = U.num(tr.qty) or 0
          local px = floor(U.num(tr.price) / inst.tick + 0.5)
          O.trades_seen[tn] = inst.key
          if o then
            O.fill(o, q, px, t, tn)
          else
            M.on_fill(inst, { side = side, mode = (so and so.mode) or O.mode(inst), src = (so and so.src) or "offline", tid = tonumber(tr.trans_id) },
              q, px, t, { tn = tn })
          end
          n_off = n_off + 1
          say(string.format("исполнение без скрипта: %s %d @ %s (сделка %s)", side == "B" and "покупка" or "продажа",
            q, inst:px_str(px), tn))
        end
      end
    end

    -- 3. position check
    local m = M.get(inst)
    local real, ravg = S.real_pos(inst)
    if real == nil then
      say(string.format("реальную позицию прочитать нельзя - сверьте вручную: SCLP считает %+d", m.pos))
    elseif real ~= m.pos then
      X.block = { kind = "mismatch", key = inst.key, computed = m.pos, real = real, avg = ravg }
      say(string.format("РАСХОЖДЕНИЕ ПОЗИЦИИ: SCLP %+d, QUIK %+d. Торговля заблокирована. A,A - принять позицию QUIK; P,P - PANIC (закрыть позицию QUIK)",
        m.pos, real))
      U.alert(string.format("[%s] position mismatch after restart: SCLP %+d, QUIK %+d - trading blocked", inst.sec, m.pos, real), 3)
    else
      say(string.format("позиция сходится с QUIK: %+d", real))
    end
    if #m.lots > 0 then
      local l = {}
      for _, lot in ipairs(m.lots) do
        l[#l + 1] = string.format("%s%d @ %s%s", lot.sgn > 0 and "+" or "-", lot.qty, inst:px_str(lot.px), lot.tp and " (есть TP)" or "")
      end
      say("открытые ноги (FIFO): " .. table.concat(l, ", "))
    end
    if (X.st.tp or 0) > 0 and m.pos ~= 0 then X.pending_tp = true end
    say(string.format("итог: под управлением %d, завершились %d, не найдены %d, подхвачены без файла %d, исполнений без скрипта %d",
      n_att, n_fin, n_gone, n_adopt, n_off))
    S.mark(inst)
    return rep
  end

  -- mismatch resolution: book the difference at the broker's average price (or mid) and unblock
  function S.adopt_exchange(t)
    local b, inst = X.block, X.inst
    if not (b and b.kind == "mismatch" and inst and b.key == inst.key) then return end
    local real, ravg = S.real_pos(inst)
    real = real or b.real
    local diff = real - X.M.get(inst).pos
    X.M.adopt_external(inst, diff, ravg or (inst.bk.valid and inst.bk.mid) or nil)
    X.block = nil
    X.pending_tp = (X.st.tp or 0) > 0
    U.alert(string.format("[%s] exchange position %+d adopted (difference %+d)", inst.sec, real, diff), 2)
    X.say(string.format("Принята позиция QUIK %+d", real), "warn")
    S.mark(inst)
  end

  -- other instruments that still had open legs/orders when the script stopped
  function S.other_open(active_key)
    local r = {}
    for key, v in pairs(X.st.open_insts or {}) do
      if key ~= active_key and type(v) == "table" then
        r[#r + 1] = string.format("ВНИМАНИЕ: по %s остались позиция %+d / заявок %d - SCLP их сейчас не ведёт (переключитесь на него)",
          tostring(v.sec or key), v.pos or 0, v.orders or 0)
      end
    end
    return r
  end

  return S
end
