-- sclp.lua : SCLP - manual market making in QUIK with hotkeys and passive-only orders.
-- Start: QUIK -> Services -> Lua scripts -> add SCLP/sclp.lua -> Start. Settings: sclp_config.lua (+ lib/defaults.lua).
--
-- Architecture
--   QUIK callbacks (OnTransReply, OnOrder, OnTrade, table keys) run in QUIK's main thread: they only append the
--   event with its timestamp to a queue (and OnQuote sets a "book changed" flag). The script thread (main) drains
--   the queue, prices and sends orders, runs the order state machine, risk, metrics, UI and state persistence.
--   One writer of all state -> no data races; key -> transaction latency = queue wait (<= LOOP_MS + Windows timer).
--
--   lib/util.lua     time, CP1251, log, CSV        lib/inst.lua    instrument lookup/validation, parameter cache
--   lib/book.lua     Level II without own orders    lib/oms.lua     transactions, order state machine by TRANS_ID
--   lib/metrics.lua  FIFO lots, P&L, stats          lib/risk.lua    pre-trade checks, pauses, daily loss stop
--   lib/trader.lua   offset pricing, TP, flatten,   lib/state.lua   persistence + recovery after restart
--                    passive flatten, PANIC         lib/ui.lua      window, hotkeys, settings editor
SCLP = SCLP or {}
local X = SCLP
X.dir = X.dir or (getScriptPath and getScriptPath()) or "."
X.running = true

local function load_mod(name) return dofile(X.dir .. "/lib/" .. name .. ".lua")(X) end

------------------------------------------------------------------
-- CONFIG
------------------------------------------------------------------
local U = load_mod("util")
do
  local DEF = dofile(X.dir .. "/lib/defaults.lua")
  local user = X.config_override
  if not user then
    local ok, cfg = pcall(dofile, X.dir .. "/sclp_config.lua")
    user = (ok and type(cfg) == "table") and cfg or {}
    if not ok then X.cfg_error = tostring(cfg) end
  end
  X.cfg = U.merge(DEF, user)
end
for _, m in ipairs({ "inst", "book", "oms", "metrics", "risk", "trader", "state", "ui" }) do load_mod(m) end
local I, B, O, M, R, T, S, W = X.I, X.B, X.O, X.M, X.R, X.T, X.S, X.W

-- window settings (saved in sclp_settings_<ACCOUNT>.lua)
X.st = {
  inst_text = X.cfg.DEFAULT_INSTRUMENT, offset = math.max(0, X.cfg.OFFSET_TICKS or 0), qty = X.cfg.QTY, tp = X.cfg.TP_TICKS,
  tp_last = X.cfg.TP_TICKS_DEFAULT, requote = X.cfg.REQUOTE, skew = X.cfg.SKEW, tp_be = X.cfg.TP_NOT_BELOW_BE ~= false,
  max_loss = X.cfg.MAX_DAY_LOSS_RUB, open_insts = {},
}

------------------------------------------------------------------
-- MESSAGES
------------------------------------------------------------------
function X.say(text, level)
  X.last_msg = U.stamp():sub(1, 8) .. "  " .. tostring(text)
  U.log((level == "err" and "!! " or (level == "warn" and "! " or "")) .. "UI: " .. tostring(text))
  if level == "err" then W.flash("msg", W.CL.red, 1500) elseif level == "warn" then W.flash("msg", W.CL.yellow, 800) end
end
function X.flash_fill(side) W.flash("pos", side == "B" and W.CL.green or W.CL.red, 1000) end

------------------------------------------------------------------
-- EVENT QUEUE (callbacks -> main loop)
------------------------------------------------------------------
local Q, qh, qt = {}, 1, 0
function X.push(e) qt = qt + 1; Q[qt] = e end

local function mine(sec, tid) return O.is_own_tid(tid) or (X.inst ~= nil and sec == X.inst.sec) end

function OnQuote(class, sec)
  local inst = X.inst
  if inst and sec == inst.sec and class == inst.class then X.book_dirty = true end
end
function OnTransReply(r)
  X.push({ k = "reply", trans_id = r.trans_id, status = r.status, order_num = r.order_num,
           result_msg = r.result_msg, t = U.now() })
end
function OnOrder(o)
  if mine(o.sec_code, o.trans_id) then
    X.push({ k = "order", trans_id = o.trans_id, order_num = o.order_num, flags = o.flags, qty = o.qty,
             balance = o.balance, price = o.price, sec_code = o.sec_code, class_code = o.class_code,
             passive_only_order = o.passive_only_order, brokerref = o.brokerref, account = o.account, t = U.now() })
  end
end
function OnTrade(tr)
  if mine(tr.sec_code, tr.trans_id) then
    X.push({ k = "trade", trade_num = tr.trade_num, order_num = tr.order_num, trans_id = tr.trans_id, qty = tr.qty,
             price = tr.price, flags = tr.flags, sec_code = tr.sec_code, brokerref = tr.brokerref, t = U.now() })
  end
end
function OnConnected() X.push({ k = "conn", up = true, t = U.now() }) end
function OnDisconnected() X.push({ k = "conn", up = false, t = U.now() }) end
function OnStop()
  X.running = false
  return 5000
end

local function process_events(t)
  while qh <= qt do
    local e = Q[qh]
    Q[qh] = nil
    qh = qh + 1
    if e.k == "ui" then W.on_event(e, t)
    elseif e.k == "reply" then O.on_reply(e, t)
    elseif e.k == "order" then O.on_order(e, t)
    elseif e.k == "trade" then O.on_trade(e, t)
    elseif e.k == "conn" then
      U.log("QUIK " .. (e.up and "CONNECTED" or "DISCONNECTED"))
      if not e.up then X.say("Нет связи с сервером QUIK", "err") end
    end
    if e.k ~= "ui" and e.k ~= "conn" and X.inst then S.mark(X.inst) end
  end
  if qh > qt then Q, qh, qt = {}, 1, 0 end
end

-- order events from the OMS
X.ev = {
  accept = function(o) M.on_accept(o); S.mark(o.inst) end,
  fill = function(o, q, px, t, tn) T.on_fill(o, q, px, t, tn); S.mark(o.inst) end,
  done = function(o, t) T.on_done(o, t); S.mark(o.inst) end,
  reject = function(o, msg, cls) T.on_reject(o, msg, cls); S.mark(o.inst) end,
}

------------------------------------------------------------------
-- INSTRUMENT ACTIVATION (start, switch) -> recovery of its state
------------------------------------------------------------------
function X.activate(inst, text, t, at_start)
  X.inst = inst
  X.t_inst = t
  B.new(inst)
  if Subscribe_Level_II_Quotes then pcall(Subscribe_Level_II_Quotes, inst.class, inst.sec) end
  X.st.inst_text, X.st.inst_key = text, inst.key
  X.block, X.pending_tp = nil, false
  if X.panic and (X.panic.stage == "done" or X.panic.stage == "failed") then X.panic = nil end
  X.recovering = { at_start = at_start, t = t }
  S.mark_settings()
  U.log(string.format("=== instrument %s: tick %s, lot %s, point %s RUB, mode %s ===", inst.key, tostring(inst.tick),
    tostring(inst.lot), tostring(inst.point), O.mode(inst)))
end

local function run_recovery(t)
  local inst = X.inst
  local rep = S.recover(inst, t)
  for _, l in ipairs(S.other_open(inst.key)) do rep[#rep + 1] = l end
  for _, l in ipairs(X.start_notes or {}) do table.insert(rep, 1, l) end
  X.start_notes = nil
  local at_start = X.recovering.at_start
  X.recovering = nil
  if at_start or #rep > 2 then W.report(rep) end
  X.say(X.block and "РАСХОЖДЕНИЕ ПОЗИЦИИ - см. отчёт о восстановлении" or ("Восстановление " .. inst.sec .. " завершено"),
    X.block and "err" or nil)
end

function X.switch_instrument(text, t)
  local inst, err = I.resolve(text)
  if not inst then X.say(err, "err"); return end
  local cur = X.inst
  if cur and inst.key == cur.key then X.st.inst_text = text; X.say("Инструмент уже выбран: " .. inst.sec); return end
  if X.panic and X.panic.stage ~= "done" and X.panic.stage ~= "failed" then X.say("Идёт PANIC - переключение позже", "err"); return end
  if X.recovering then X.say("Идёт восстановление - переключение позже", "err"); return end
  if cur then
    if O.any_live(cur) then X.say("Сначала снимите заявки по " .. cur.sec .. " (C)", "err"); return end
    local pos = M.get(cur).pos
    if pos ~= 0 then
      local c = X.switch_confirm
      if not (c and c.key == inst.key and t - c.t < 15) then
        X.switch_confirm = { key = inst.key, t = t }
        X.say(string.format("По %s позиция %+d. Введите %s ещё раз в течение 15 с, чтобы переключиться (позиция останется в файле)",
          cur.sec, pos, inst.sec), "warn")
        return
      end
    end
    X.switch_confirm = nil
    S.mark(cur)
    S.flush(t)
  end
  X.activate(inst, text, t, false)
end

------------------------------------------------------------------
-- INIT / STEP / SHUTDOWN
------------------------------------------------------------------
function X.init()
  local t = U.now()
  X.t_start = t
  U.log("=== SCLP start: account " .. tostring(X.cfg.ACCOUNT) .. " ===")
  if X.cfg_error then U.alert("sclp_config.lua error: " .. X.cfg_error .. " - defaults used", 3) end
  if (X.cfg.ACCOUNT or "") == "" then U.alert("ACCOUNT is empty in sclp_config.lua", 3) end
  local sv = S.load_settings(t)
  X.start_notes = {}
  if not sv then X.start_notes[#X.start_notes + 1] = "файла настроек нет (первый запуск или повреждён) - настройки по умолчанию" end
  W.open()
  -- the instrument saved last (exact contract), so open legs on it are recovered even if the base now resolves elsewhere
  local inst, err
  if X.st.inst_key then
    local class, sec = X.st.inst_key:match("^([^:]+):(.+)$")
    if class then
      inst, err = I.make(class, sec)
      if not inst then
        local old = S.read(S.path_of(class, sec))
        local lots, ords = 0, 0
        for _, l in ipairs((old and old.metrics and old.metrics.lots) or {}) do lots = lots + (l.qty or 0) end
        ords = old and old.orders and #old.orders or 0
        X.start_notes[#X.start_notes + 1] = string.format("ВНИМАНИЕ: прежний инструмент %s недоступен (%s)%s", sec, tostring(err),
          (lots + ords > 0) and string.format(" - в его файле открытых ног %d лот., заявок %d: проверьте позицию у брокера вручную", lots, ords) or "")
      end
    end
  end
  if not inst then inst, err = I.resolve(X.st.inst_text or X.cfg.DEFAULT_INSTRUMENT) end
  if inst then X.activate(inst, X.st.inst_text, t, true)
  else
    X.say("Инструмент не выбран: " .. tostring(err) .. ". Двойной клик по строке «Инструмент»", "err")
    if #X.start_notes > 0 then W.report(X.start_notes) end
  end
end

local t_flush = 0
function X.step(t)
  process_events(t)
  local inst = X.inst
  if inst and X.recovering and (not X.recovering.at_start or S.tables_ready(t)) then run_recovery(t) end
  if inst then
    I.refresh(inst, t)
    if X.book_dirty or t - (inst.bk.t_read or 0) >= 0.5 then
      X.book_dirty = false
      B.read(inst, t)
    end
    if X.pending_tp and not X.block and not X.recovering and inst.bk.valid then
      X.pending_tp = false
      local n = T.restore_tps(t)
      if n > 0 then
        X.say("Восстановлено тейк-профитов: " .. n)
        W.report({ string.format("тейк-профиты открытых ног выставлены заново: %d (пассивно)", n) }, nil, true)
      end
    end
    if not X.recovering then T.tick(t); T.panic_verify(t) end
  end
  O.tick(t)
  R.tick(t)
  M.tick(t)
  W.tick(t)
  S.flush(t)
  if t - t_flush >= 1 then t_flush = t; U.flush() end
end

function X.shutdown()
  local t = U.now()
  local inst = X.inst
  if inst and X.cfg.CANCEL_ON_STOP then
    T.cancel_where(nil, "stop", t)
    local t_end = t + 3
    while U.now() < t_end and O.any_live(inst) do
      process_events(U.now())
      O.tick(U.now())
      if sleep and not X.clock then sleep(50) else break end
    end
  end
  if inst then
    local n = #O.working(inst)
    local pos = M.get(inst).pos
    if n > 0 or pos ~= 0 then
      U.alert(string.format("SCLP stopped: %s position %+d, %d order(s) left in the book - they are re-attached on the next start",
        inst.sec, pos, n), 2)
    end
    S.mark(inst)
  end
  M.final(t)
  S.mark_settings()
  S.flush(t)
  W.close()
  U.log("=== SCLP stop ===")
  U.close_all()
end

function main()
  local ok, err = pcall(X.init)
  if not ok then
    U.alert("init error: " .. tostring(err), 3)
    U.close_all()
    return
  end
  local errors = 0
  while X.running do
    local t = U.now()
    local ok2, err2 = pcall(X.step, t)
    if ok2 then errors = 0 else
      errors = errors + 1
      U.log_every("steperr", 5, "STEP ERROR: " .. tostring(err2))
      if errors > 100 then U.alert("too many errors - stopping (orders stay, state saved)", 3); X.running = false end
    end
    sleep(X.cfg.LOOP_MS or 2)
  end
  pcall(X.shutdown)
end
