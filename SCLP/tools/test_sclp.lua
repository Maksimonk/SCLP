-- test_sclp.lua : SCLP scenario tests on the QUIK/exchange emulator (tools/sim_quik.lua), no QUIK needed.
-- Run from the repository root:  lua SCLP/tools/test_sclp.lua      (Lua 5.3+)
local ROOT = arg and arg[0] and arg[0]:match("^(.*)/SCLP/tools/") or "."
local OUT = os.getenv("SCLP_TEST_OUT") or (ROOT .. "/SCLP/tools/test_out")
os.execute('mkdir -p "' .. OUT .. '" 2>/dev/null || mkdir "' .. OUT .. '"')

local passed, failed = 0, 0
local function T_(name) print(name); if SCLP and SCLP.U then SCLP.U.log("##### " .. name) end end
local function check(cond, msg)
  if cond then passed = passed + 1 else failed = failed + 1; print("  FAIL: " .. msg) end
end

------------------------------------------------------------------
-- QUIK table API stubs (window, keys)
------------------------------------------------------------------
QTABLE_STRING_TYPE, QTABLE_LBUTTONDBLCLK, QTABLE_SELCHANGED, QTABLE_VKEY, QTABLE_CHAR, QTABLE_CLOSE = 1, 3, 5, 6, 7, 12
QTABLE_NO_INDEX, QTABLE_DEFAULT_COLOR = -1, -1
UI = {}
local function ui_reset() UI = { tables = {}, next = 0 } end
function AllocTable() UI.next = UI.next + 1; UI.tables[UI.next] = { cells = {}, rows = 0 }; return UI.next end
function AddColumn() end
function CreateWindow() end
function SetWindowCaption(id, s) UI.tables[id].caption = s end
function SetWindowPos(id, x, y, w, h) UI.tables[id].pos = { x, y, w, h } end
function GetWindowRect(id)                        -- top, left, bottom, right
  local p = UI.tables[id] and (UI.tables[id].moved or UI.tables[id].pos)
  if not p then return nil end
  return p[2], p[1], p[2] + p[4], p[1] + p[3]
end
function InsertRow(id) local tb = UI.tables[id]; tb.rows = tb.rows + 1; return tb.rows end
function SetCell(id, r, c, s) UI.tables[id].cells[r .. ":" .. c] = s end
function SetColor() end
function Highlight() end
function IsWindowClosed(id) return UI.tables[id] == nil or UI.tables[id].closed == true end
function DestroyTable(id) UI.tables[id] = nil end
function SetTableNotificationCallback(id, cb) UI.tables[id].cb = cb end

------------------------------------------------------------------
-- HARNESS
------------------------------------------------------------------
local function from(s) return SCLP.U.from_cp1251(s) end
local function cp(s) return SCLP.U.to_cp1251(s) end

local function fresh_exchange()
  SC = { U = nil, cfg = { ACCOUNT = "TEST01" }, step = function(t) if SCLP and SCLP.step then SCLP.step(t) end end }
  dofile(ROOT .. "/SCLP/tools/sim_quik.lua")
  SIM.add_sec("BMX6", 0.01, 2, 0.8, 20261102)
  SIM.add_sec("BMV6", 0.01, 2, 0.8, 20261001)       -- expired: must not be chosen
  -- spread 3 ticks: 70.00 / 70.03
  SIM.book("BMX6", { { 7000, 10 }, { 6999, 12 }, { 6998, 15 } }, { { 7003, 10 }, { 7004, 12 }, { 7005, 15 } })
end

local function base_cfg(over)
  local c = { ACCOUNT = "TEST01", DEFAULT_INSTRUMENT = "SPBFUT BM", OFFSET_TICKS = 0, QTY = 1, MAX_POS = 3,
              MAX_DAY_LOSS_RUB = 1000, TP_TICKS = 0, REQUOTE = false, PAUSE_WINDOWS = {},
              FEES = { SPBFUT = { BROKER_RUB = 0.5, EXCH_MAKER_PCT = 0, EXCH_TAKER_PCT = 0.0132 } } }
  for k, v in pairs(over or {}) do c[k] = v end
  return c
end

local function wipe_state()
  for _, f in ipairs({ "sclp_settings_TEST01.lua", "sclp_state_TEST01_SPBFUT_BMX6.lua", "sclp_ui.lua" }) do
    for _, sfx in ipairs({ "", ".tmp", ".bak" }) do os.remove(OUT .. "/" .. f .. sfx) end
  end
end

-- start (or restart) the script against the current exchange
local function start(cfg)
  if SCLP and SCLP.U then SCLP.U.close_all() end
  ui_reset()
  SCLP = { dir = ROOT .. "/SCLP", out_dir = OUT, config_override = cfg or base_cfg() }
  SCLP.clock = function() return SIM.t end
  dofile(ROOT .. "/SCLP/sclp.lua")
  SC.U = SCLP.U
  SCLP.init()
  SIM.run(5)          -- tables settle (3 s + 1 s stable), recovery runs
end
local X = function() return SCLP end

local function main_tbl() return UI.tables[1] end
local function key(vk, row) main_tbl().cb(1, QTABLE_VKEY, row or 1, vk); SIM.run(0.02) end
local function char(c) main_tbl().cb(1, QTABLE_CHAR, 1, c); SIM.run(0.02) end
local function dbl(row, col) main_tbl().cb(1, QTABLE_LBUTTONDBLCLK, row, col or 2); SIM.run(0.02) end
local UP, DOWN, LEFT, RIGHT, ENTER = 38, 40, 37, 39, 13
local function cell(r, c) return from(main_tbl().cells[r .. ":" .. c] or "") end

local function live(side)
  local r = {}
  for _, o in ipairs(SIM.robot_orders("BMX6", true)) do if not side or o.side == side then r[#r + 1] = o end end
  table.sort(r, function(a, b) return a.px < b.px end)
  return r
end
local function reset_book()
  SIM.book("BMX6", { { 7000, 10 }, { 6999, 12 }, { 6998, 15 } }, { { 7003, 10 }, { 7004, 12 }, { 7005, 15 } })
  SIM.run(0.3)
end
local function last_sent() return SIM.sent[#SIM.sent] end
local function inst() return SCLP.inst end
local function mx() return SCLP.M.get(SCLP.inst) end

------------------------------------------------------------------
T_("TEST 1: start, contract choice, settings window, recovery report")
wipe_state()
fresh_exchange()
start()
check(inst() and inst().sec == "BMX6", "nearest live contract BMX6 chosen")
check(SCLP.recovering == nil, "recovery finished")
check(SCLP.block == nil, "no mismatch on a clean start")
check(UI.tables[2] ~= nil, "recovery report window opened")
check(cell(1, 2):find("BMX6", 1, true) ~= nil, "window shows the instrument")
check(cell(10, 2):find("ТОРГОВЛЯ", 1, true) ~= nil, "state row says trading: " .. cell(10, 2))

------------------------------------------------------------------
T_("TEST 2: UP = passive BUY at bid + offset, universal format with 'Только пассивная'")
key(UP)
local t1 = last_sent()
check(t1 and t1.ACTION == cp("Ввод заявки"), "universal format")
check(t1 and t1[cp("Условие исполнения")] == cp("Только пассивная"), "BoC condition set")
check(t1 and t1[cp("К/П")] == cp("Покупка") and t1[cp("Цена")] == "70.00", "buy at best bid 70.00 (offset 0)")
SIM.run(0.2)
check(#live("B") == 1, "buy is resting")
key(UP)
check(#live("B") == 1, "key auto-repeat within 250 ms ignored")
SIM.run(0.3)
key(LEFT)
check(SCLP.st.offset == 0, "offset cannot go below 0")
key(RIGHT)
check(SCLP.st.offset == 1, "offset +1 via arrows")
key(187); key(187); key(189)                      -- "=/+" twice, "-" once
check(SCLP.st.qty == 2, "volume via +/- keys (no PgUp/PgDn needed)")
key(109)                                          -- numpad minus
check(SCLP.st.qty == 1, "numpad minus")
key(UP); SIM.run(0.2)
local b = live("B")
check(#b == 2 and b[1].px == 6999, "offset 1: buy = bid 70.00 - 1 = 69.99 (cheaper)")
SIM.run(0.3)
key(UP); SIM.run(0.2)
b = live("B")
check(#b == 3 and b[2].px == 6999, "again 69.99: measured from the bid as QUIK shows it")
local lat = SCLP.M.lat.key_send
check(#lat >= 3, "key -> send latency recorded")
check(#SCLP.M.lat.send_reply >= 3, "send -> reply latency recorded")

------------------------------------------------------------------
T_("TEST 3: no position limit; offset goes deeper: buy = bid - N, sell = ask + N")
SIM.run(0.3)
key(UP); SIM.run(0.2)
check(#live("B") == 4, "4th buy accepted: no position limit")
key(67)                                           -- C: cancel all
SIM.run(0.3)
check(#live() == 0, "C cancels everything")
for _ = 1, 6 do key(RIGHT) end                     -- offset 7
SIM.run(0.3)
key(UP); SIM.run(0.2)
check(live("B")[1] and live("B")[1].px == 6993, "buy = 70.00 - 7 = 69.93")
key(DOWN); SIM.run(0.2)
check(live("S")[1] and live("S")[1].px == 7010, "sell = 70.03 + 7 = 70.10")
key(LEFT); key(LEFT); SIM.run(0.3)
key(DOWN); SIM.run(0.2)
check(live("S")[1] and live("S")[1].px == 7008, "after two LEFT presses offset 5: sell = 70.03 + 5 = 70.08")
key(66); SIM.run(0.3)                              -- B: cancel buys
check(#live("B") == 0, "B cancels buys")
key(83); SIM.run(0.3)                              -- S
check(#live("S") == 0, "S cancels sells")
for _ = 1, 7 do key(LEFT) end
check(SCLP.st.offset == 0, "offset back to 0")

------------------------------------------------------------------
T_("TEST 4: fill -> take-profit -> closed trade, net P&L with broker fee, markouts")
SCLP.st.tp = 1
SIM.run(0.3)
key(UP); SIM.run(0.2)                             -- buy 70.00 (offset 0)
SCLP.st.offset = 2                                -- the counter order uses the global offset at fill time
SIM.trade("BMX6", -1, 7000, 20)                   -- seller hits the bid (queue 10 first, then us)
SIM.run(0.2)
check(mx().pos == 1, "position +1")
local tp = live("S")[1]
check(tp and tp.px == 7005, "counter sell from the market: ask 70.03 + 2 = 70.05 (not from the fill price)")
key(67); SIM.run(0.3)
SIM.book("BMX6", { { 6990, 10 } }, { { 6993, 10 } }); SIM.run(0.3)   -- market falls under the entry
SCLP.T.restore_tps(SIM.t); SIM.run(0.3)
tp = live("S")[1]
-- break-even 70.00 + (0.50 + 0.50) / 0.80 = 70.0125 -> + 2 = 70.0325 -> 70.04 (market would give 69.95)
check(tp and tp.px == 7004, "counter not worse than break-even + 2 = 70.04, got " .. tostring(tp and tp.px))
key(71)                                                              -- G off
key(67); SIM.run(0.3)
SCLP.T.restore_tps(SIM.t); SIM.run(0.3)
tp = live("S")[1]
check(tp and tp.px == 6995, "G off: purely from the market 69.93 + 2 = 69.95")
key(71)
key(67); SIM.run(0.3)
SCLP.st.offset = 0                                                   -- offset 0: still >= 1 tick of profit
SCLP.T.restore_tps(SIM.t); SIM.run(0.3)
tp = live("S")[1]
check(tp and tp.px == 7003, "offset 0: break-even 70.0125 + 1 tick = 70.0225 -> 70.03, got " .. tostring(tp and tp.px))
key(67); SIM.run(0.3)
SCLP.st.offset = 2
reset_book()
SCLP.T.restore_tps(SIM.t); SIM.run(0.3)
SIM.trade("BMX6", 1, 7005, 60)
SIM.run(0.2)
check(mx().pos == 0, "flat after TP")
check(mx().n == 1 and mx().wins == 1, "one winning trade")
local v = SCLP.M.values(inst())
check(math.abs(v.real_gross - 4.0) < 1e-9, "gross +5 ticks x 0.8 = 4.00, got " .. v.real_gross)
check(math.abs(v.real_net - 3.0) < 1e-9, "net = 4.00 - 2 x 0.50 fee = 3.00, got " .. v.real_net)
SIM.run(31)
check(mx().mk_n == 2, "markouts of both fills computed")
check(SCLP.O.st.taker_suspect == 0, "no taker fills")
SCLP.st.tp, SCLP.st.offset = 0, 0

------------------------------------------------------------------
T_("TEST 5: orders are never moved by the script")
reset_book()
key(UP); SIM.run(0.5)                             -- buy 70.00
SIM.set("BMX6", "B", 7001, 5)                     -- market bid moves up: we are behind
SIM.run(1)
b = live("B")
check(#b == 1 and b[1].px == 7000, "not chased: still 70.00")
SIM.set("BMX6", "B", 7001, 0); SIM.set("BMX6", "B", 7000, 0)   -- support under us leaves
SIM.run(1)
b = live("B")
check(#b == 1 and b[1].px == 7000, "not pulled back: still 70.00")
local kills = 0
for _, tx in ipairs(SIM.sent) do if tx.ACTION == "KILL_ORDER" then kills = kills + 1 end end
key(67); SIM.run(0.3)
local kills2 = 0
for _, tx in ipairs(SIM.sent) do if tx.ACTION == "KILL_ORDER" then kills2 = kills2 + 1 end end
check(kills2 == kills + 1, "the only cancel is the user's C")

T_("TEST 5b: arrow-key orders never move; the F close follows the market only at break-even or better")
reset_book()
SCLP.st.tp, SCLP.st.requote = 0, true
key(UP); SIM.run(0.2)
SIM.trade("BMX6", -1, 7000, 30); SIM.run(0.3)       -- long 1 @ 70.00
check(mx().pos == 1, "long 1")
SIM.book("BMX6", { { 7000, 10 } }, { { 7003, 10 } }); SIM.run(0.3)
key(DOWN); SIM.run(0.3)                              -- an extra quote with the arrow key: sell 70.03
SIM.book("BMX6", { { 7004, 10 } }, { { 7007, 10 } }); SIM.run(1.5)
check(live("S")[1] and live("S")[1].px == 7003, "arrow-key sell is never moved (even with R on and a position open)")
key(67); SIM.run(0.3)
SIM.book("BMX6", { { 7000, 10 } }, { { 7003, 10 } }); SIM.run(0.3)
char(string.byte("f")); SIM.run(0.3)                 -- F: passive close at bid + 1 = 70.01
check(live("S")[1] and live("S")[1].px == 7001, "F close at 70.01")
SIM.book("BMX6", { { 6997, 10 } }, { { 6999, 10 } })  -- market falls through our entry
SIM.run(1.5)
local cs = live("S")[1]
-- break-even: 70.00 + (0.50 entry + 0.50 exit fee) / 0.80 RUB per tick = 70.0125: the market (69.98) is worse
check(cs and cs.px == 7001, "market below break-even: the F close is NOT moved (stays 70.01), got " .. tostring(cs and cs.px))
SIM.book("BMX6", { { 7004, 10 } }, { { 7006, 10 } })  -- market rises
SIM.run(1.5)
cs = live("S")[1]
check(cs and cs.px == 7005, "F close follows the market up to bid + 1 = 70.05, got " .. tostring(cs and cs.px))
key(82)                                              -- R off
SIM.book("BMX6", { { 7006, 10 } }, { { 7008, 10 } })
SIM.run(1.5)
check(live("S")[1] and live("S")[1].px == 7005, "R off: closing order stays")
key(67); SIM.run(0.3)
reset_book()
key(DOWN); SIM.run(0.3)
SIM.trade("BMX6", 1, 7003, 20); SIM.run(0.3)
check(mx().pos == 0, "flat again")
-- several entries: break-even is the position AVERAGE, a closing order is never pushed away from the market
SIM.book("BMX6", { { 7000, 10 } }, { { 7003, 10 } }); SIM.run(0.3)
key(DOWN); SIM.run(0.3); SIM.trade("BMX6", 1, 7003, 20); SIM.run(0.3)    -- short 1 @ 70.03
SIM.book("BMX6", { { 7010, 10 } }, { { 7013, 10 } }); SIM.run(0.3)
key(DOWN); SIM.run(0.3); SIM.trade("BMX6", 1, 7013, 20); SIM.run(0.3)    -- short 1 @ 70.13, avg 70.08
check(mx().pos == -2, "short 2, avg 70.08")
SIM.book("BMX6", { { 7006, 10 } }, { { 7009, 10 } }); SIM.run(0.3)
key(UP); SIM.run(1.5)                                                      -- closing buy at bid 70.06
local cb = live("B")[1]
check(cb and cb.px == 7006, "closing buy stays at 70.06 (old code dragged it to the oldest lot 70.03), got " .. tostring(cb and cb.px))
key(67); SIM.run(0.3)
SIM.book("BMX6", { { 7000, 10 } }, { { 7003, 10 } }); SIM.run(0.3)
for _ = 1, 2 do
  SIM.book("BMX6", { { 7000, 10 } }, { { 7003, 10 } }); SIM.run(0.3)
  key(UP); SIM.run(0.3); SIM.trade("BMX6", -1, 7000, 20); SIM.run(0.3)
end
check(mx().pos == 0, "flat again (2)")

------------------------------------------------------------------
T_("TEST 6: BoC reject when the book moves before the order arrives - no automatic re-price")
reset_book()
key(UP)                                           -- offset 0 -> buy 70.00
SIM.set("BMX6", "S", 7000, 3)                     -- ask drops to 70.00 within the 100 ms latency
SIM.run(0.3)
check(SCLP.O.st.rej_boc == 1, "exchange rejected the would-be taker (BoC)")
check(mx().pos == 0, "no fill")
check(#live("B") == 0, "nothing re-sent automatically")
check((SCLP.last_msg or ""):find("тейкер", 1, true) ~= nil, "user notified")
SIM.set("BMX6", "S", 7000, 0)
SIM.run(0.3)

------------------------------------------------------------------
T_("TEST 7: PANIC (P,P): cancel + IOC flatten, the only taker order")
reset_book()
key(UP); SIM.run(0.3); key(UP); SIM.run(0.3)
SIM.trade("BMX6", -1, 7000, 30)
SIM.run(0.3)
check(mx().pos == 2, "long 2")
key(DOWN); SIM.run(0.3)
check(#live("S") == 1, "a sell is resting")
SIM.limits = { BMX6 = { 6500, 7500 } }             -- exchange price band 65.00 .. 75.00
SIM.book("BMX6", { { 6999, 1 }, { 6998, 5 } }, { { 7003, 10 } })   -- thin bid: the sweep goes 2 levels
SIM.run(0.2)
local real0 = mx().realized
local taker_before = SIM.taker_orders or 0
key(80)
check(SCLP.panic == nil, "first P only arms")
key(80)
SIM.run(3)
check(SCLP.panic and SCLP.panic.stage == "done", "PANIC done")
check(mx().pos == 0, "flat after PANIC")
local ioc0
for i = #SIM.sent, 1, -1 do if SIM.sent[i].EXECUTION_CONDITION == "KILL_BALANCE" then ioc0 = SIM.sent[i]; break end end
check(ioc0 and ioc0.PRICE == "65.00", "market sell limit = lower band edge 65.00, got " .. tostring(ioc0 and ioc0.PRICE))
-- real fills: 1 @ 69.99 + 1 @ 69.98 against entry 2 @ 70.00 -> (-1 -2) ticks x 0.80 = -2.40, not the 65.00 limit
check(math.abs((mx().realized - real0) - (-2.4)) < 1e-9, "P&L from real trade prices: -2.40, got " .. (mx().realized - real0))
local po = SCLP.O.by_tid[tonumber(ioc0.TRANS_ID)]
check(po and math.abs(po.cost / po.filled - 6998.5) < 1e-9, "order VWAP 69.985 from trades")
SIM.limits = nil
check(#live() == 0, "no resting orders")
check((SIM.taker_orders or 0) - taker_before >= 1, "IOC (KILL_BALANCE) taker order used")
local ioc = SIM.sent[#SIM.sent]
for i = #SIM.sent, 1, -1 do if SIM.sent[i].EXECUTION_CONDITION then ioc = SIM.sent[i]; break end end
check(ioc.EXECUTION_CONDITION == "KILL_BALANCE" and ioc.OPERATION == "S", "IOC sell")
key(UP)
check(#live("B") == 0, "after PANIC trading is paused")
key(72)                                           -- H resume
SIM.book("BMX6", { { 7000, 10 }, { 6999, 12 }, { 6998, 15 } }, { { 7003, 10 }, { 7004, 12 }, { 7005, 15 } })
SIM.run(0.5)
key(UP); SIM.run(0.2)
check(#live("B") == 1, "H resumes trading")
key(67); SIM.run(0.3)

------------------------------------------------------------------
T_("TEST 8: hotkeys: CHAR after VKEY is de-duplicated, Cyrillic layout works, F flattens passively")
reset_book()
main_tbl().cb(1, QTABLE_VKEY, 1, 75)              -- K (skew on)
main_tbl().cb(1, QTABLE_CHAR, 1, string.byte("k"))
SIM.run(0.02)
check(SCLP.st.skew == true, "K toggled once (VKEY + CHAR de-duplicated)")
SIM.run(0.3)
char(0xEB)                                        -- 'л' (K key in the Russian layout, CP1251)
check(SCLP.st.skew == false, "Cyrillic 'л' = K")
SIM.run(0.3)
key(UP); SIM.run(0.2)
SIM.trade("BMX6", -1, 7000, 30); SIM.run(0.2)
check(mx().pos == 1, "long 1")
char(0xE0)                                        -- 'а' = F
SIM.run(0.2)
local fl = live("S")[1]
check(fl and fl.px == 7000, "F: passive flatten at the most aggressive passive price (bid 69.99 + 1)")
SIM.trade("BMX6", 1, 7000, 1); SIM.run(0.2)
check(mx().pos == 0, "flattened passively")

------------------------------------------------------------------
T_("TEST 9: settings editor: double click, typed value, validation, Enter / Esc")
dbl(3)                                            -- qty row
check(SCLP.edit and SCLP.edit.id == "qty", "edit mode on the volume row")
key(UP)
check(#live("B") == 0, "trading keys disabled while editing")
key(50 + 48 - 48); key(ENTER)                     -- '2'? (VK 50 = '2')
check(SCLP.st.qty == 2, "volume set to 2")
dbl(3); key(48); key(ENTER)                       -- 0 -> invalid
check(SCLP.st.qty == 2, "volume 0 rejected")
dbl(2); key(189); key(51); key(27)                -- "-3" then Esc
check(SCLP.st.offset == 0 and SCLP.edit == nil, "Esc cancels the edit")
dbl(2); key(189); key(51); key(ENTER)
check(SCLP.st.offset == 0, "typed offset -3 rejected")
dbl(8); for _, d in ipairs({ 53, 48, 48 }) do key(d) end; key(ENTER)
check(SCLP.st.max_loss == 500, "loss limit 500")
SCLP.st.qty = 1
dbl(1); for _, c in ipairs({ 90, 90, 90 }) do key(c) end; key(ENTER)
check(inst().sec == "BMX6" and (SCLP.last_msg or ""):find("не найден", 1, true) ~= nil, "unknown ticker rejected")

------------------------------------------------------------------
T_("TEST 10: daily loss limit -> stop + automatic PANIC")
reset_book()
SCLP.st.max_loss = -SCLP.M.total_equity() + 5     -- 5 RUB of room left
key(UP); SIM.run(0.2)
SIM.trade("BMX6", -1, 7000, 30); SIM.run(0.2)
check(mx().pos == 1, "long 1")
SIM.book("BMX6", { { 6990, 10 }, { 6989, 12 } }, { { 6993, 10 }, { 6994, 12 } })
SIM.run(3)
check(SCLP.R.day_stop == true, "daily loss stop")
check(mx().pos == 0, "auto-PANIC flattened")
key(UP)
check(#live("B") == 0, "no new orders after the loss stop")
dbl(8); for _, d in ipairs({ 53, 48, 48 }) do key(d) end; key(ENTER)
check(SCLP.R.day_stop == false, "raising the limit clears the stop")
key(72)
SIM.book("BMX6", { { 7000, 10 }, { 6999, 12 }, { 6998, 15 } }, { { 7003, 10 }, { 7004, 12 }, { 7005, 15 } })
SIM.run(0.5)

------------------------------------------------------------------
T_("TEST 11: restart with an active order, a partial fill while the script is off")
reset_book()
SCLP.st.tp = 1
key(UP); SIM.run(0.2)                             -- buy 1 @ 70.00 -> fill -> TP @ 70.03
SIM.trade("BMX6", -1, 7000, 30); SIM.run(0.2)
reset_book()
SCLP.st.qty = 2
key(UP); SIM.run(0.3)                             -- buy 2 @ 70.00 resting behind 10 lots
local real_before = mx().realized
check(#live("B") == 1 and #live("S") == 1, "a resting buy and a TP")
local stats_sent = SCLP.O.st.sent
-- CRASH: no shutdown, no final flush (state was written on every event)
SCLP.running = false
OnTrade, OnOrder, OnTransReply, OnQuote = nil, nil, nil, nil
SIM.trade("BMX6", -1, 7000, 11)                   -- while off: 10 market ahead, 1 of our 2 filled
SIM.run(0.1)
start()
check(SCLP.block == nil, "position matches the exchange after recovery")
check(mx().pos == 2, "position 1 (before) + 1 (filled while off) = 2, got " .. mx().pos)
local rep = {}
local rid = 0
for id in pairs(UI.tables) do if id > rid then rid = id end end
for k, v in pairs(UI.tables[rid].cells) do rep[#rep + 1] = from(v) end
local rtxt = table.concat(rep, "\n")
check(rtxt:find("исполнение без скрипта", 1, true) ~= nil, "report shows the downtime fill")
check(rtxt:find("заявка снова под управлением", 1, true) ~= nil, "report shows re-attached orders")
local ob = SCLP.O.working(inst(), "B")[1]
check(ob and ob.filled == 1 and ob.qty == 2, "re-attached buy knows its partial fill")
check(SCLP.O.st.sent >= stats_sent, "session counters continue (not reset to 0)")
check(#SCLP.M.get(inst()).lots == 2, "two open lots (FIFO)")
SIM.run(0.5)
check(#live("S") == 2, "missing TP of the downtime lot restored (passive)")
-- a duplicate OnTrade after reconnect is ignored
local tr = SIM.trade_rows[#SIM.trade_rows]
OnTrade(tr); SIM.run(0.1)
check(mx().pos == 2, "duplicate trade ignored")
key(67); SIM.run(0.3)

------------------------------------------------------------------
T_("TEST 12: restart with a position mismatch -> blocked, A,A adopts the exchange position")
SCLP.running = false
SIM.pos.BMX6 = SIM.pos.BMX6 + 3                   -- manual trade outside SCLP
start()
check(SCLP.block and SCLP.block.real == 5 and SCLP.block.computed == 2, "mismatch detected 2 vs 5")
key(UP)
check(#live("B") == 0, "trading blocked")
key(65); key(65)
check(SCLP.block == nil and mx().pos == 5, "A,A adopted the exchange position")
SIM.run(0.5)

------------------------------------------------------------------
T_("TEST 13: corrupt state file -> backup; both corrupt -> exchange data only")
SCLP.running = false
local p = OUT .. "/sclp_state_TEST01_SPBFUT_BMX6.lua"
local f = io.open(p, "w"); f:write("return { broken"); f:close()
start()
check(mx().pos == 5, "backup (.bak) used, position 5")
SCLP.running = false
for _, sfx in ipairs({ "", ".bak", ".tmp" }) do local g = io.open(p .. sfx, "w"); g:write("garbage"); g:close() end
start()
check(SCLP.block ~= nil, "no usable state: exchange position differs from 0 -> blocked")
key(80); key(80)
SIM.run(3)
check(SCLP.block == nil and SIM.pos.BMX6 == 0, "P,P during mismatch flattens the exchange position")

------------------------------------------------------------------
T_("TEST 14: restart finds an SCLP order missing from the file (TRANS_ID range) and adopts it")
reset_book()
key(72)
SIM.book("BMX6", { { 7000, 10 }, { 6999, 12 }, { 6998, 15 } }, { { 7003, 10 }, { 7004, 12 }, { 7005, 15 } })
SIM.run(0.5)
SCLP.st.tp = 0
key(UP); SIM.run(0.3)
SCLP.running = false
for _, sfx in ipairs({ "", ".bak", ".tmp" }) do os.remove(p .. sfx) end
start()
local ad = SCLP.O.working(inst(), "B")[1]
check(ad and ad.src == "adopted", "order adopted by TRANS_ID range")
-- no file: today's SCLP trades are replayed; the earlier manual +3 shows up as a mismatch again
check(SCLP.block ~= nil, "replayed trades differ from the exchange (manual trade) -> blocked")
key(65); key(65)
check(SCLP.block == nil and mx().pos == SIM.pos.BMX6, "adopted")
key(67); SIM.run(0.3)
check(#live() == 0, "adopted order can be cancelled")

------------------------------------------------------------------
T_("TEST 15: new day: intraday metrics reset, open lots carried over")
reset_book()
SCLP.st.tp, SCLP.st.qty = 0, 1
local pos0 = mx().pos
key(UP); SIM.run(0.2)
SIM.trade("BMX6", -1, 7000, 30); SIM.run(0.5)
check(mx().pos == pos0 + 1, "bought 1 before the day change")
local lots0 = #mx().lots
SCLP.running = false
local txt = io.open(p):read("*a")
txt = txt:gsub('day = "%d+"', 'day = "20261006"')
local h = io.open(p, "w"); h:write(txt); h:close()
start()
check(SCLP.block == nil, "yesterday-evening trades are not counted twice (trade numbers kept across days)")
check(mx().pos == pos0 + 1 and #mx().lots == lots0, "open lots carried over")
check(mx().n == 0 and mx().realized == 0, "intraday statistics reset")

------------------------------------------------------------------
T_("TEST 16: every regular order is Book-or-Cancel; only PANIC uses IOC; per-class field overrides")
SCLP.running = false
start(base_cfg({ TX_BY_CLASS = { SPBFUT = { COND = "Условие исполнения" } } }))
reset_book()
local fixed = 0
for _, tx in ipairs(SIM.sent) do
  if tx.ACTION == "NEW_ORDER" and tx.EXECUTION_CONDITION ~= "KILL_BALANCE" then fixed = fixed + 1 end
end
check(fixed == 0, "no plain limit order was ever sent in the whole run")
key(UP); SIM.run(0.2)
check(last_sent()[cp("Условие исполнения")] == cp("Только пассивная"), "BoC with per-class TX override")
key(67); SIM.run(0.3)

------------------------------------------------------------------
T_("TEST 17: switching instrument with an open position needs confirmation")
SIM.add_sec("BRX6", 0.01, 2, 7.6, 20261030)
SIM.book("BRX6", { { 6500, 10 } }, { { 6502, 10 } })
local held = mx().pos
check(held ~= 0, "position open on BMX6")
SCLP.switch_instrument("SPBFUT BRX6", SIM.t)
check(inst().sec == "BMX6", "first attempt only warns")
SCLP.switch_instrument("SPBFUT BRX6", SIM.t)
SIM.run(0.2)
check(inst().sec == "BRX6", "second attempt switches")
check(SCLP.st.open_insts["SPBFUT:BMX6"] ~= nil, "old instrument remembered as having open legs")

------------------------------------------------------------------
T_("TEST 18: reply status 12 (timeout) is not a reject: the order is found in the orders table")
SCLP.switch_instrument("SPBFUT BRX6", SIM.t)
SCLP.st.offset = 0
SIM.run(0.3)
key(UP)
local o12 = SCLP.O.working(inst(), "B")[1]
OnTransReply({ trans_id = o12.tid, status = 12, result_msg = "timeout" })
SIM.run(0.02)
check(o12.uncertain and not o12.done, "status 12: state unknown, not rejected")
SIM.run(0.3)
check(o12.state == "ACTIVE" and not o12.uncertain, "the order became ACTIVE from the real reply / orders table")
key(67); SIM.run(0.3)

------------------------------------------------------------------
T_("TEST 19: a lost OnTrade is recovered from the trades table with the real price")
SIM.book("BRX6", { { 6500, 10 } }, { { 6502, 10 } })
SIM.run(0.2)
local p0 = mx().pos
key(UP); SIM.run(0.3)                              -- buy at 65.00 behind 10 lots
local saved_ot = OnTrade
OnTrade = nil                                      -- QUIK "loses" the trade callback
SIM.trade("BRX6", -1, 6500, 11); SIM.run(0.2)
OnTrade = saved_ot
check(mx().pos == p0 + 1, "trade taken from the trades table as soon as the order row shows the execution")
local lot = mx().lots[#mx().lots]
check(lot and lot.px == 6500, "booked at the real trade price 65.00")

------------------------------------------------------------------
T_("TEST 20: average-price window, no order-size / per-minute limits")
local m20 = mx()
local b0, c0 = m20.bought, m20.buy_cost or 0
SCLP.st.qty = 50                                  -- bigger than the old 20-lot cap
SIM.book("BRX6", { { 6500, 1 } }, { { 6503, 100 } })
SIM.run(0.3)
key(UP); SIM.run(0.3)                             -- 50 @ 65.00
check(live("B")[1] == nil and #SCLP.O.working(inst(), "B") == 1 and SCLP.O.working(inst(), "B")[1].qty == 50, "50-lot order accepted")
SIM.trade("BRX6", -1, 6500, 3); SIM.run(0.3)       -- 1 market ahead, 2 of ours filled
SCLP.st.qty = 1
SIM.book("BRX6", { { 6501, 1 } }, { { 6503, 100 } })
SIM.run(0.3)
key(UP); SIM.run(0.3)                             -- 1 @ 65.01
SIM.trade("BRX6", -1, 6501, 2); SIM.run(0.5)
local avgw = UI.tables[2]
local want = string.format("%.4f", ((c0 + 6500 * 2 + 6501) / (b0 + 3)) * 0.01)
check(avgw and from(avgw.cells["1:2"] or "") == tostring(b0 + 3), "window: bought lots " .. tostring(avgw and from(avgw.cells["1:2"] or "")))
check(avgw and from(avgw.cells["2:2"] or "") == want, "window: average buy price " .. want .. ", got " .. tostring(avgw and from(avgw.cells["2:2"] or "")))
key(67); SIM.run(0.3)

------------------------------------------------------------------
T_("TEST 21: the average-price window comes back after closing; windows remember their position")
local avg_id = 2
UI.tables[avg_id].closed = true
SIM.run(1.5)
local reopened
for id, tb in pairs(UI.tables) do
  if id ~= avg_id and not tb.closed and from(tb.caption or ""):find("средние цены", 1, true) then reopened = tb end
end
check(reopened ~= nil, "average-price window reopened")
UI.tables[1].moved = { 300, 200, 900, 400 }      -- the user moves the main window
SIM.run(6)                                        -- saved within 5 s
SCLP.running = false
start()
local mp = UI.tables[1].pos
check(mp and mp[1] == 300 and mp[2] == 200 and mp[3] == 900 and mp[4] == 400, "main window restored at the saved place")

SCLP.U.close_all()
print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
