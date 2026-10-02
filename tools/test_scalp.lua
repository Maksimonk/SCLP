-- test_scalp.lua : сценарные тесты скальпера на эмуляторе (без QUIK).
-- Запуск из папки проекта:  lua tools/test_scalp.lua   (Lua 5.3+)
local DIR = arg and arg[0] and arg[0]:match("^(.*)/tools/") or "."
local OUT = os.getenv("SCALP_TEST_OUT") or (DIR .. "/tools/test_out")
os.execute('mkdir -p "' .. OUT .. '" 2>/dev/null || mkdir "' .. OUT .. '"')

local passed, failed = 0, 0
local function check(cond, msg)
  if cond then passed = passed + 1 else failed = failed + 1; print("  FAIL: " .. msg) end
end

local function base_cfg(over)
  local c = {
    MODE = "LIVE", ACCOUNT = "TEST01", HEARTBEAT_SEC = 3600, SHOW_TABLE = false,
    SESSIONS = { { "09:00:30", "23:49:00", true, 1800, 600 } }, SESSIONS_WEEKEND = {},
    DEFAULTS = { MAX_POS = 2, QUOTE_SIZE = 1, EXIT_HOLD_EOD = false, MAX_REAL_CYCLES = 1 },
    INSTRUMENTS = { { BASE = "BM", REF = { BASE = "BR" }, SETUPS = { PAIR = "live", TIGHT = "off", FADE = "paper", WALL = "off" } } },
  }
  for k, v in pairs(over or {}) do c[k] = v end
  return c
end

local function fresh(cfg, keep_state)
  if not keep_state then os.remove(OUT .. "/scalp_state.txt") end
  SC = { dir = DIR, out_dir = OUT, config_override = cfg }
  SC.clock = function() return SIM.t end
  dofile(DIR .. "/tools/sim_quik.lua")
  dofile(DIR .. "/scalp.lua")
  SIM.add_sec("BMX6", 0.01, 2, 0.8, 20261102)
  SIM.add_sec("BMV6", 0.01, 2, 0.8, 20261001)     -- истёк: не должен быть выбран
  SIM.add_sec("BRX6", 0.01, 2, 8.0, 20261030)
  -- спред 1 тик: 70.00 / 70.01
  SIM.book("BMX6", { { 7000, 10 }, { 6999, 12 }, { 6998, 15 }, { 6997, 10 }, { 6996, 20 } },
                   { { 7001, 10 }, { 7002, 12 }, { 7003, 15 }, { 7004, 10 }, { 7005, 20 } })
  SIM.book("BRX6", { { 7050, 50 } }, { { 7051, 50 } })
  SC.init()
  SIM.run(5)   -- прогрев
end

local function real_orders(active_only) return SIM.robot_orders("BMX6", active_only) end
local function cyc(setup, backend)
  local r = SC.C.active(SC.by_sec.BMX6, backend, setup)
  return r[1]
end
local function agg(setup, backend) return SC.ST.agg["BMX6|" .. setup .. "|" .. backend] or {} end

-- открыть "тихую" дырку: аски 70.01 и 70.02 сняты -> спред 70.00 / 70.03
local function quiet_gap()
  SIM.set("BMX6", "S", 7001, 0)
  SIM.set("BMX6", "S", 7002, 0)
end

------------------------------------------------------------------
print("TEST 1: contract choice, cp1251 transaction, pair in a quiet gap, round trip +1 tick")
fresh(base_cfg())
check(SC.by_sec.BMX6 ~= nil and SC.by_sec.BMV6 == nil, "nearest non-expired contract BMX6 chosen")
quiet_gap()
SIM.run(0.05)
local sent = SIM.sent
check(#sent == 2, "two transactions sent (pair), got " .. #sent)
local cp = SC.U.to_cp1251
if sent[1] then
  check(sent[1].ACTION == cp("Ввод заявки"), "universal format ACTION in cp1251")
  check(sent[1][cp("Условие исполнения")] == cp("Только пассивная"), "passive-only condition set")
  check(sent[1].EXECUTION_CONDITION == nil, "no fixed-format EXECUTION_CONDITION")
end
SIM.run(0.2)
local os_ = real_orders(true)
check(#os_ == 2, "both legs resting, got " .. #os_)
local bid, ask
for _, o in ipairs(os_) do if o.side == "B" then bid = o else ask = o end end
check(bid and bid.px == 7001, "bid leg at 70.01")
check(ask and ask.px == 7002, "ask leg at 70.02")
-- продавец бьёт в наш бид
SIM.trade("BMX6", -1, 7001, 1)
SIM.run(0.1)
local c = cyc("PAIR", "real")
check(c and c.state == "POS" and c.pos == 1, "position +1 after bid fill")
check(c and c.exit and c.exit.px == 7002, "ask leg became the take-profit")
SIM.trade("BMX6", 1, 7002, 1)
SIM.run(0.2)
local a = agg("PAIR", "real")
check(a.wins == 1 and math.abs(a.ticks - 1) < 1e-9, "round trip +1 tick, got wins=" .. tostring(a.wins) .. " ticks=" .. tostring(a.ticks))
check((SIM.taker_fills or 0) == 0, "no taker fills")

------------------------------------------------------------------
print("TEST 2: one leg rejected as would-be taker -> partner cancelled at once")
fresh(base_cfg())
quiet_gap()
SIM.run(0.03)                     -- заявки ушли, до биржи ещё ~70 мс
SIM.mkt.BMX6.bids[7002] = 5       -- кто-то встал бидом 70.02 -> наш аск 70.02 пересечёт
SIM.run(0.5)
check((SIM.boc_rejects or 0) == 1, "exchange rejected one leg (BoC)")
local act = real_orders(true)
check(#act == 0, "partner leg cancelled, active robot orders: " .. #act)
local kills = 0
for _, t in ipairs(SIM.sent) do if t.ACTION == "KILL_ORDER" then kills = kills + 1 end end
check(kills >= 1, "KILL_ORDER sent for partner")
check(SC.C.position(SC.by_sec.BMX6, "real") == 0, "no position")

------------------------------------------------------------------
print("TEST 3: one leg filled, market runs away -> passive exit phases -> STOP, never crossing")
fresh(base_cfg())
quiet_gap()
SIM.run(0.3)
SIM.trade("BMX6", -1, 7001, 1)
SIM.run(0.2)
c = cyc("PAIR", "real")
check(c and c.pos == 1, "long 1")
-- рынок проваливается: биды 69.90, аски 69.92
SIM.book("BMX6", { { 6990, 10 }, { 6989, 10 } }, { { 6992, 10 }, { 6993, 10 } })
local max_live_exit, crossed = 0, false
for _ = 1, 300 do
  SIM.run(0.05)
  local n = 0
  for _, o in ipairs(real_orders(true)) do
    if o.side == "S" then
      n = n + 1
      local bb = SIM.best("BMX6", "B")
      if bb and o.px <= bb then crossed = true end
    end
  end
  if n > max_live_exit then max_live_exit = n end
end
c = cyc("PAIR", "real")
check(c and c.phase == "STOP", "STOP phase reached, got " .. tostring(c and c.phase))
check(max_live_exit <= 1, "never more than one live exit order, max " .. max_live_exit)
check(not crossed, "exit never at/through best bid")
local ex = nil
for _, o in ipairs(real_orders(true)) do if o.side == "S" then ex = o end end
check(ex and ex.px == 6991, "STOP exit at best bid + 1 tick (69.91), got " .. tostring(ex and ex.px))
SIM.trade("BMX6", 1, 6991, 1)
SIM.run(0.3)
a = agg("PAIR", "real")
check(a.losses == 1 and math.abs(a.ticks + 10) < 1e-9, "loss -10 ticks, got " .. tostring(a.ticks))
check(SC.C.position(SC.by_sec.BMX6, "real") == 0, "flat after exit")
check((SIM.taker_fills or 0) == 0, "no taker fills")
check((SIM.kill_errors or 0) == 0, "no erroneous kills (order not found)")

------------------------------------------------------------------
print("TEST 4: gap made by a sweep -> no pair; big sweep -> virtual FADE buy")
fresh(base_cfg())
SIM.trade("BMX6", -1, 6996, 60)  -- пролив 70.00 -> 69.96 (5 уровней), биды съедены
SIM.run(0.1)
check(#real_orders(false) == 0, "no real pair after a sweep gap")
local ep = SC.by_sec.BMX6.ep
check(ep and ep.cause == "sweep", "gap classified as sweep, got " .. tostring(ep and ep.cause))
local f = cyc("FADE", "virtual")
check(f ~= nil, "virtual FADE cycle opened")
if f then check(f.legs[1].side == "B", "FADE buys after a sell sweep") end

------------------------------------------------------------------
print("TEST 5: imbalance turns against the pair -> both legs cancelled")
fresh(base_cfg())
quiet_gap()
SIM.run(0.3)
check(#real_orders(true) == 2, "pair resting")
SIM.set("BMX6", "B", 7000, 200)   -- огромный бид: дисбаланс ~ +0.9
SIM.run(0.5)
check(#real_orders(true) == 0, "pair cancelled on imbalance")
c = SC.C.list[1]
check(SC.C.position(SC.by_sec.BMX6, "real") == 0, "no position")

------------------------------------------------------------------
print("TEST 6: PAPER mode - virtual pair, fills from the tape, nothing sent to QUIK")
fresh(base_cfg({ MODE = "PAPER" }))
quiet_gap()
SIM.run(0.3)
check(#SIM.sent == 0, "no transactions in PAPER")
c = cyc("PAIR", "virtual")
check(c ~= nil and #SC.C.live_orders(c) == 2, "virtual pair active")
SIM.trade("BMX6", -1, 7000, 3)    -- продавец ниже нашего виртуального бида 70.01 -> исполнение
SIM.run(0.1)
c = cyc("PAIR", "virtual")
check(c and c.pos == 1, "virtual long 1")
SIM.set("BMX6", "B", 7002, 4)     -- встречный бид дошёл до нашей виртуальной продажи 70.02
SIM.run(0.2)
a = agg("PAIR", "virtual")
check(a.wins == 1, "virtual round trip won")

------------------------------------------------------------------
print("TEST 7: wrong transaction field names -> QUIK rejects locally -> HALT")
local cfg7 = base_cfg()
cfg7.TX = { COND = "Тип по остатку" }
fresh(cfg7)
quiet_gap()
SIM.run(0.5)
check(SC.O.halt ~= nil, "halted")
local n7 = #SIM.sent
SIM.set("BMX6", "S", 7003, 0)
SIM.set("BMX6", "S", 7004, 0)
SIM.run(2)
local news = 0
for i = n7 + 1, #SIM.sent do if SIM.sent[i].ACTION ~= "KILL_ORDER" then news = news + 1 end end
check(news == 0, "no new orders after halt")

------------------------------------------------------------------
print("TEST 8: QUIK says passive flag NOT set on accepted order -> HALT")
fresh(base_cfg())
SIM.passive_flag = 0
quiet_gap()
SIM.run(0.5)
check(SC.O.halt ~= nil, "halted on passive_only_order = 0")
check(#real_orders(true) == 0, "orders cancelled after halt")

------------------------------------------------------------------
print("TEST 9: session tail (23:45) - no new entries")
fresh(base_cfg())
SIM.t = os.time({ year = 2026, month = 10, day = 7, hour = 23, min = 45, sec = 0 })
SIM.run(1)
quiet_gap()
SIM.run(0.5)
check(#real_orders(false) == 0, "no orders in session tail")

------------------------------------------------------------------
print("TEST 10: reference instrument moving -> no pair")
fresh(base_cfg())
SIM.book("BRX6", { { 7055, 50 } }, { { 7056, 50 } })   -- BR +5 тиков
SIM.run(0.1)
quiet_gap()
SIM.run(0.3)
check(#real_orders(false) == 0, "no pair while BR moves")

------------------------------------------------------------------
print("TEST 11: partial fill of a 2-lot pair leg -> exit sized to the position")
local cfg11 = base_cfg()
cfg11.DEFAULTS = { MAX_POS = 2, QUOTE_SIZE = 2, EXIT_HOLD_EOD = false }
fresh(cfg11)
quiet_gap()
SIM.run(0.3)
SIM.trade("BMX6", -1, 7001, 1)    -- исполнен 1 из 2
SIM.run(0.5)
c = cyc("PAIR", "real")
check(c and c.pos == 1, "long 1 of 2")
local sells, buys = 0, 0
for _, o in ipairs(real_orders(true)) do
  if o.side == "S" then sells = sells + o.bal else buys = buys + o.bal end
end
check(buys == 0, "rest of the bid leg cancelled")
check(sells == 1, "exit sized to position (1), got " .. sells)
SIM.trade("BMX6", 1, 7002, 1)
SIM.run(0.5)
check(SC.C.position(SC.by_sec.BMX6, "real") == 0, "flat")
check(math.abs((agg("PAIR", "real").ticks or 0) - 1) < 1e-9, "+1 tick")

------------------------------------------------------------------
print("TEST 12: gap study journal and stop")
fresh(base_cfg())
quiet_gap()
SIM.run(0.3)
SIM.set("BMX6", "S", 7001, 5)     -- дырка закрылась
SIM.run(31)
SC.shutdown()
local f12 = io.open(OUT .. "/scalp_gaps_20261007.csv", "r")
local txt = f12 and f12:read("*a") or ""
if f12 then f12:close() end
check(txt:find("cancel") ~= nil, "gap episode written with cause 'cancel'")

------------------------------------------------------------------
print("TEST 15: another robot quotes the contract -> no real orders, pair runs virtually")
fresh(base_cfg())
SIM.rows[#SIM.rows + 1] = { order_num = 9000000000000000777, trans_id = 123456, flags = 1, balance = 1, qty = 1,
                            price = "69.90", sec_code = "BMX6", class_code = "SPBFUT" }
SIM.run(6)
quiet_gap()
SIM.run(0.3)
check(#real_orders(false) == 0, "no real orders while foreign orders present")
check(cyc("PAIR", "virtual") ~= nil, "pair runs virtually")

------------------------------------------------------------------
-- TIGHT (пары у самого рынка)
------------------------------------------------------------------
local function tight_cfg(over)
  local c = base_cfg()
  c.INSTRUMENTS[1].SETUPS = { PAIR = "off", TIGHT = "live", FADE = "off", WALL = "off" }
  c.DEFAULTS = { MAX_POS = 2, QUOTE_SIZE = 1, EXIT_HOLD_EOD = true }
  for k, v in pairs(over or {}) do c.DEFAULTS[k] = v end
  return c
end
local function legs()
  local b, a
  for _, o in ipairs(real_orders(true)) do if o.side == "B" then b = o.px else a = o.px end end
  return b, a
end
-- стакан без условий для TIGHT (дырка 0, ровные объёмы) - фон для прогрева
local function flat_book()
  SIM.book("BMX6", { { 9999, 10 }, { 9998, 12 }, { 9997, 15 } }, { { 10000, 10 }, { 10001, 12 }, { 10002, 15 } })
end

print("TEST 16: TIGHT hole 1 tick, ask volume >= 1.4x bid -> sell into the hole, buy joins the bid")
fresh(tight_cfg()); flat_book(); SIM.run(1)
SIM.book("BMX6", { { 9999, 20 }, { 9998, 30 } }, { { 10001, 100 }, { 10002, 30 } })
SIM.run(0.3)
local b, a = legs()
check(b == 9999 and a == 10000, "buy 99.99 / sell 100.00, got " .. tostring(b) .. " / " .. tostring(a))

print("TEST 17: TIGHT hole 1 tick, bid volume bigger -> buy into the hole, sell joins the ask")
fresh(tight_cfg()); flat_book(); SIM.run(1)
SIM.book("BMX6", { { 9999, 100 }, { 9998, 30 } }, { { 10001, 20 }, { 10002, 30 } })
SIM.run(0.3)
b, a = legs()
check(b == 10000 and a == 10001, "buy 100.00 / sell 100.01, got " .. tostring(b) .. " / " .. tostring(a))

print("TEST 18: TIGHT hole 1 tick, volumes differ < 1.4x -> nothing")
fresh(tight_cfg()); flat_book(); SIM.run(1)
SIM.book("BMX6", { { 9999, 20 }, { 9998, 30 } }, { { 10001, 27 }, { 10002, 30 } })
SIM.run(0.5)
check(#real_orders(false) == 0, "no orders at ratio 1.35")

print("TEST 19: TIGHT hole 2 ticks -> buy 100.00 / sell 100.01 unconditionally")
fresh(tight_cfg()); flat_book(); SIM.run(1)
SIM.book("BMX6", { { 9999, 5 }, { 9998, 30 } }, { { 10002, 90 }, { 10003, 30 } })
SIM.run(0.3)
b, a = legs()
check(b == 10000 and a == 10001, "buy 100.00 / sell 100.01, got " .. tostring(b) .. " / " .. tostring(a))

print("TEST 20: TIGHT no hole, walls >= 3x behind both best levels -> join both queues")
fresh(tight_cfg()); flat_book(); SIM.run(1)
SIM.book("BMX6", { { 9999, 20 }, { 9998, 800 } }, { { 10000, 100 }, { 10001, 1000 } })
SIM.run(0.3)
b, a = legs()
check(b == 9999 and a == 10000, "buy 99.99 / sell 100.00, got " .. tostring(b) .. " / " .. tostring(a))
SIM.book("BMX6", { { 9999, 20 }, { 9998, 50 } }, { { 10000, 100 }, { 10001, 1000 } })   -- стена бидов пропала
SIM.run(0.8)
check(#real_orders(true) == 0, "pair cancelled when the bid wall is gone")

print("TEST 21: TIGHT one leg rejected (would be taker) -> the other is cancelled")
fresh(tight_cfg()); flat_book(); SIM.run(1)
SIM.book("BMX6", { { 9999, 20 }, { 9998, 30 } }, { { 10001, 100 }, { 10002, 30 } })
SIM.run(0.03)
SIM.mkt.BMX6.bids[10000] = 3          -- кто-то встал бидом 100.00 раньше нашей продажи 100.00
SIM.run(0.5)
check((SIM.boc_rejects or 0) == 1, "sell leg rejected as taker")
check(#real_orders(true) == 0, "buy leg cancelled too")
check(SC.C.position(SC.by_sec.BMX6, "real") == 0, "flat")

print("TEST 22: exit hangs to the end of the day through a trend; position capped by MAX_POS")
fresh(tight_cfg()); flat_book(); SIM.run(1)
SIM.book("BMX6", { { 9999, 5 }, { 9998, 30 } }, { { 10002, 90 }, { 10003, 30 } })
SIM.run(0.3)
SIM.trade("BMX6", -1, 10000, 1)       -- купили 100.00, тейк 100.01
SIM.run(0.3)
SIM.book("BMX6", { { 9980, 5 }, { 9979, 30 } }, { { 9983, 90 }, { 9984, 30 } })   -- рынок -20 тиков
SIM.run(6)                             -- пауза резкого движения прошла
SIM.run(120)
local hold_ok = false
for _, o in ipairs(real_orders(true)) do if o.side == "S" and o.px == 10001 then hold_ok = true end end
check(hold_ok, "take-profit 100.01 still resting after 2 minutes against the trend")
local maxp = 0
for _ = 1, 40 do
  SIM.trade("BMX6", -1, SIM.best("BMX6", "B") or 9980, 1)
  local bb = SIM.best("BMX6", "B")
  for _, o in ipairs(real_orders(true)) do if o.side == "B" and o.px > (bb or 0) then SIM.trade("BMX6", -1, o.px, 1) end end
  SIM.run(0.5)
  local p = SIM.pos.BMX6 or 0
  if p > maxp then maxp = p end
end
check(maxp <= 2, "position never above MAX_POS = 2, max " .. maxp)
SIM.book("BMX6", { { 9980, 5 }, { 9979, 30 } }, { { 9983, 90 }, { 9984, 30 } })
SIM.t = os.time({ year = 2026, month = 10, day = 7, hour = 23, min = 40, sec = 0 })   -- конец окна
SIM.run(1)
local stop = false
for _, c in ipairs(SC.C.active(SC.by_sec.BMX6, "real")) do if c.phase == "STOP" then stop = true end end
check(stop, "session tail -> STOP (passive close)")

print("TEST 23: sharp move -> entries paused and resting entry legs cancelled")
fresh(tight_cfg()); flat_book(); SIM.run(1)
SIM.book("BMX6", { { 9999, 5 }, { 9998, 30 } }, { { 10002, 90 }, { 10003, 30 } })
SIM.run(0.3)
check(#real_orders(true) == 2, "pair resting")
SIM.book("BMX6", { { 10005, 5 }, { 10004, 30 } }, { { 10008, 90 }, { 10009, 30 } })  -- +6 тиков
SIM.run(0.5)
check(#real_orders(true) == 0, "pair cancelled on sharp move")
SIM.run(3)
check(#real_orders(true) == 0, "no new pair during the pause")
SIM.run(3)
check(#real_orders(true) == 2, "pair again after ~5 s")

print("TEST 24: restart - live orders and position are adopted, not cancelled")
fresh(tight_cfg()); flat_book(); SIM.run(1)
SIM.book("BMX6", { { 9999, 5 }, { 9998, 30 } }, { { 10002, 90 }, { 10003, 30 } })
SIM.run(0.3)
SIM.trade("BMX6", -1, 10000, 1)       -- лонг 1, тейк 100.01 висит
SIM.run(1.5)                           -- состояние сохранено
local exit_num
for _, o in ipairs(real_orders(true)) do if o.side == "S" and not exit_num then exit_num = o.num end end
check(exit_num ~= nil, "exit resting before restart")
local kills_before = 0
for _, t in ipairs(SIM.sent) do if t.ACTION == "KILL_ORDER" then kills_before = kills_before + 1 end end
-- "падение" скрипта: новый экземпляр с тем же эмулятором
local keep = SIM
OnQuote, OnAllTrade, OnTransReply, OnOrder, OnTrade = nil, nil, nil, nil, nil
SC = { dir = DIR, out_dir = OUT, config_override = tight_cfg() }
SC.clock = function() return SIM.t end
dofile(DIR .. "/tools/sim_quik.lua")
SIM = keep
dofile(DIR .. "/scalp.lua")
SC.init()
SIM.run(0.5)
local c24
for _, c in ipairs(SC.C.active(SC.by_sec.BMX6, "real")) do if c.pos ~= 0 then c24 = c end end
check(c24 and c24.pos == 1 and c24.exit and c24.exit.key == tostring(exit_num), "cycle restored with its resting exit")
local kills_after = 0
for _, t in ipairs(SIM.sent) do if t.ACTION == "KILL_ORDER" then kills_after = kills_after + 1 end end
check(kills_after == kills_before, "adopted exit was not cancelled")
SIM.trade("BMX6", 1, 10001, 1)
SIM.run(0.5)
check(SC.C.position(SC.by_sec.BMX6, "real") == 0, "adopted exit filled -> flat")
check(math.abs((agg("TIGHT", "real").ticks or 0) - 1) < 1e-9, "+1 tick on the restored cycle")
check(#SC.C.active(SC.by_sec.BMX6, "real") <= 1, "second restored pair still managed")
local pnl_before = SC.R.pnl.real
SIM.run(1.5)
SC = { dir = DIR, out_dir = OUT, config_override = tight_cfg() }
SC.clock = function() return SIM.t end
keep = SIM
OnQuote, OnAllTrade, OnTransReply, OnOrder, OnTrade = nil, nil, nil, nil, nil
dofile(DIR .. "/tools/sim_quik.lua"); SIM = keep
dofile(DIR .. "/scalp.lua"); SC.init()
check(math.abs((SC.R.pnl.real or 0) - pnl_before) < 1e-9 and pnl_before > 0, "day P&L survives restart: " .. tostring(SC.R.pnl.real))
check(math.abs((agg("TIGHT", "real").ticks or 0) - 1) < 1e-9, "setup stats survive restart")

print("TEST 25: command file 'flatten' -> STOP phase, no new entries")
fresh(tight_cfg()); flat_book(); SIM.run(1)
SIM.book("BMX6", { { 9999, 5 }, { 9998, 30 } }, { { 10002, 90 }, { 10003, 30 } })
SIM.run(0.3)
SIM.trade("BMX6", -1, 10000, 1)
SIM.run(0.3)
local fc = io.open(OUT .. "/scalp_cmd.txt", "w"); fc:write("flatten\n"); fc:close()
SIM.run(1.5)
local c25
for _, c in ipairs(SC.C.active(SC.by_sec.BMX6, "real")) do if c.pos ~= 0 then c25 = c end end
check(c25 and c25.phase == "STOP", "flatten -> STOP")
os.remove(OUT .. "/scalp_cmd.txt")

print("TEST 26: hold mode never sells below entry before the session tail (10 min against the trend)")
fresh(tight_cfg()); flat_book(); SIM.run(1)
SIM.book("BMX6", { { 9999, 5 }, { 9998, 30 } }, { { 10002, 90 }, { 10003, 30 } })
SIM.run(0.3)
SIM.trade("BMX6", -1, 10000, 1)
SIM.run(0.3)
local c26
for _, c in ipairs(SC.C.active(SC.by_sec.BMX6, "real")) do if c.pos ~= 0 then c26 = c end end
if c26 then c26.tp_px = nil end            -- как после восстановления без второй ноги
SIM.book("BMX6", { { 9975, 5 }, { 9974, 30 } }, { { 9977, 90 }, { 9978, 30 } })   -- -0.24%: ещё не стоп
local bad = false
for _ = 1, 600 do
  SIM.run(1)
  for _, o in ipairs(SC.O.all_live(SC.by_sec.BMX6, "real")) do
    if o.cycle == c26 and o.side == "S" and o.px < 10000 then bad = true end
  end
  if c26 and c26.realized < 0 then bad = true end
end
check(not bad, "no sell order below the 100.00 entry during 10 minutes")

print("TEST 28: soft stop at -0.3% (passive), hard stop at -0.5% (market order)")
fresh(tight_cfg()); flat_book(); SIM.run(1)
SIM.book("BMX6", { { 9999, 5 }, { 9998, 30 } }, { { 10002, 90 }, { 10003, 30 } })
SIM.run(0.3)
SIM.trade("BMX6", -1, 10000, 1)          -- лонг 100.00
SIM.run(0.3)
SIM.book("BMX6", { { 9965, 5 }, { 9964, 30 } }, { { 9968, 90 }, { 9969, 30 } })   -- -0.335%
SIM.run(0.5)
local ex28
for _, o in ipairs(SC.O.all_live(SC.by_sec.BMX6, "real")) do if o.role == "exit" then ex28 = o end end
check(ex28 and ex28.side == "S" and ex28.px == 9966 and not ex28.taker, "soft stop: passive sell at bid + 1 (99.66), got " .. tostring(ex28 and ex28.px))
check((SIM.hard_fills or 0) == 0, "no market order yet")
SIM.book("BMX6", { { 9945, 5 }, { 9944, 30 } }, { { 9948, 90 }, { 9949, 30 } })   -- -0.535%
SIM.run(1)
check((SIM.taker_orders or 0) >= 1 and (SIM.hard_fills or 0) >= 1, "hard stop: market order sent and filled")
check(SC.C.position(SC.by_sec.BMX6, "real") == 0 and (SIM.pos.BMX6 or 0) == 0, "flat after hard stop")
local a28 = agg("TIGHT", "real")
check(math.abs((a28.ticks or 0) + 55) < 1e-9, "-55 ticks (sold at best bid 99.45), got " .. tostring(a28.ticks))
check((a28.rub or 0) < -55 * 0.8, "taker fee included in rubles: " .. tostring(a28.rub))
check((SIM.taker_fills or 0) == 0, "no taker fills from passive orders")

------------------------------------------------------------------
print("TEST 13: random market 20 min (LIVE + virtual setups) - invariants")
local function fuzz(mode, minutes, seed, hold)
  local cfg = base_cfg({ MODE = mode })
  cfg.INSTRUMENTS[1].SETUPS = { PAIR = "live", TIGHT = "live", FADE = "live", WALL = "paper" }
  cfg.DEFAULTS = { MAX_POS = 3, QUOTE_SIZE = 1, EXIT_HOLD_EOD = hold }
  fresh(cfg)
  math.randomseed(seed)
  local fair = 7000
  local inv = { taker = 0, maxpos = 0, cross = 0, mismatch = 0, maxlive = 0 }
  local function refill()
    -- новый уровень рынка, пересекающий заявку робота, - это сделка с роботом, а не заявка в стакане
    local rb, ra
    for _, o in ipairs(SIM.robot_orders("BMX6", true)) do
      if o.side == "B" and (not rb or o.px > rb) then rb = o.px end
      if o.side == "S" and (not ra or o.px < ra) then ra = o.px end
    end
    for k = 0, 6 do
      local bp, ap = fair - 1 - k, fair + k
      if not SIM.mkt.BMX6.bids[bp] and math.random() < 0.15 then
        if ra and bp >= ra then SIM.trade("BMX6", 1, bp, math.random(1, 20))
        else SIM.mkt.BMX6.bids[bp] = math.random(1, 20) end
      end
      if not SIM.mkt.BMX6.asks[ap] and math.random() < 0.15 then
        if rb and ap <= rb then SIM.trade("BMX6", -1, ap, math.random(1, 20))
        else SIM.mkt.BMX6.asks[ap] = math.random(1, 20) end
      end
    end
    -- уровни, оказавшиеся по ту сторону справедливой цены, снимаются
    for p in pairs(SIM.mkt.BMX6.bids) do if p >= fair or p < fair - 30 then SIM.mkt.BMX6.bids[p] = nil end end
    for p in pairs(SIM.mkt.BMX6.asks) do if p < fair or p > fair + 30 then SIM.mkt.BMX6.asks[p] = nil end end
    if OnQuote then OnQuote("SPBFUT", "BMX6") end
  end
  local steps = minutes * 60 * 20
  for _ = 1, steps do
    local r = math.random()
    if r < 0.02 then
      local d = (math.random() < 0.5) and -1 or 1
      fair = fair + d
      if d > 0 then local a = SIM.best("BMX6", "S"); if a and a < fair then SIM.trade("BMX6", 1, fair - 1, 40) end
      else local b = SIM.best("BMX6", "B"); if b and b >= fair then SIM.trade("BMX6", -1, fair, 40) end end
    elseif r < 0.12 then
      local side = (math.random() < 0.5) and -1 or 1
      local b = SIM.best("BMX6", side < 0 and "B" or "S")
      if b then SIM.trade("BMX6", side, b, math.random(1, 5)) end
    elseif r < 0.135 then
      -- снятие лучших уровней (дырка)
      local side = (math.random() < 0.5) and "bids" or "asks"
      for _ = 1, math.random(1, 3) do
        local b = SIM.best("BMX6", side == "bids" and "B" or "S")
        if b then SIM.mkt.BMX6[side][b] = nil end
      end
      if OnQuote then OnQuote("SPBFUT", "BMX6") end
    elseif r < 0.137 then
      -- вынос на 3-6 уровней
      local side = (math.random() < 0.5) and -1 or 1
      local b = SIM.best("BMX6", side < 0 and "B" or "S")
      if b then
        local to = b + side * math.random(2, 5)
        SIM.trade("BMX6", side, to, 200)
        fair = (side < 0) and to or to + 1
      end
    end
    refill()
    SIM.run(0.05)
    inv.taker = SIM.taker_fills or 0
    local p = SIM.pos.BMX6 or 0
    if math.abs(p) > inv.maxpos then inv.maxpos = math.abs(p) end
    if mode == "LIVE" and SC.C.position(SC.by_sec.BMX6, "real") ~= p then inv.mismatch = inv.mismatch + 1 end
    local live = 0
    local bb, ba = SIM.best("BMX6", "B"), SIM.best("BMX6", "S")
    for _, o in ipairs(SIM.robot_orders("BMX6", true)) do
      live = live + 1
      if (o.side == "B" and ba and o.px >= ba) or (o.side == "S" and bb and o.px <= bb) then inv.cross = inv.cross + 1 end
    end
    if live > inv.maxlive then inv.maxlive = live end
  end
  return inv
end
local inv = fuzz("LIVE", 20, 42, false)
check(inv.taker == 0, "no taker fills")
check(inv.maxpos <= 3, "position within MAX_POS, max " .. inv.maxpos)
check((SIM.self_cross or 0) == 0, "no self-cross attempts: " .. tostring(SIM.self_cross))
check(inv.cross == 0, "robot orders never crossing the market: " .. inv.cross)
check(inv.mismatch <= 3, "robot position == account position (transient mismatches " .. inv.mismatch .. ")")
check(inv.maxlive <= 5, "live robot orders <= MAX_POS + 2, max " .. inv.maxlive)
local st = SC.O.stats
print(string.format("  LIVE fuzz: tx %d, new %d, kill %d, boc-rej %d, kill errors %d", st.tx, st.new, st.kill, st.rej_boc, SIM.kill_errors or 0))
for _, l in ipairs(SC.ST.summary()) do print("  " .. l) end
check((SIM.kill_errors or 0) <= st.kill * 0.2, "kill errors are rare (fill/cancel races only)")

print("TEST 14: random market 20 min in PAPER")
inv = fuzz("PAPER", 20, 7, true)
check(#SIM.sent == 0, "PAPER sends nothing")
for _, l in ipairs(SC.ST.summary()) do print("  " .. l) end

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
