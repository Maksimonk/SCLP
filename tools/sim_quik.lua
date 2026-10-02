-- sim_quik.lua : эмулятор QUIK + биржи для тестов (обычный Lua 5.3/5.4, без QUIK).
-- Биржа: "только пассивная" заявка, пересекающая стакан в момент прихода, отклоняется; иначе встаёт
-- в очередь за уже стоящим объёмом. Рыночные сделки задаются тестом (SIM.trade), заявки робота
-- исполняются по цене-времени. Задержка транзакций - SIM.latency.
SIM = {
  t = os.time({ year = 2026, month = 10, day = 7, hour = 12, min = 0, sec = 0 }),
  latency = 0.1,
  mkt = {},            -- [sec] = { bids = {[idx] = qty}, asks = {...} } - объём рынка (без робота)
  info = {},           -- [sec] = { tick, scale, step, mat }
  resting = {},        -- заявки робота на бирже
  rows = {},           -- таблица заявок QUIK
  sched = {},
  sent = {},           -- все транзакции робота
  next_num = 9100000000000000001,
  next_trade = 5000000001,
  passive_flag = 1,    -- значение passive_only_order в таблице заявок
  pos = {},            -- позиция счёта
  log = {},
}

local function cp(s) return SC.U.to_cp1251(s) end

function SIM.add_sec(sec, tick, scale, step, mat)
  SIM.info[sec] = { tick = tick, scale = scale, step = step, mat = mat }
  SIM.mkt[sec] = { bids = {}, asks = {} }
end

function SIM.at(dt, fn) SIM.sched[#SIM.sched + 1] = { at = SIM.t + dt, fn = fn } end

local function quote(sec)
  if OnQuote then OnQuote("SPBFUT", sec) end
end

-- уровень рынка: side "B"/"S", px - индекс тика
function SIM.set(sec, side, px, qty)
  local m = SIM.mkt[sec][side == "B" and "bids" or "asks"]
  m[px] = (qty and qty > 0) and qty or nil
  quote(sec)
end
function SIM.book(sec, bids, asks)    -- bids/asks = { {px, qty}, ... }
  SIM.mkt[sec] = { bids = {}, asks = {} }
  for _, l in ipairs(bids) do SIM.mkt[sec].bids[l[1]] = l[2] end
  for _, l in ipairs(asks) do SIM.mkt[sec].asks[l[1]] = l[2] end
  quote(sec)
end

local function best(sec, side)       -- лучший уровень РЫНКА (без робота)
  local m = SIM.mkt[sec][side == "B" and "bids" or "asks"]
  local b
  for p in pairs(m) do
    if not b or (side == "B" and p > b) or (side == "S" and p < b) then b = p end
  end
  return b
end
SIM.best = best

------------------------------------------------------------------
-- API QUIK
------------------------------------------------------------------
function getScriptPath() return SC.dir end
function isConnected() return 1 end
function message(s) SIM.log[#SIM.log + 1] = s end
function sleep() end
function Subscribe_Level_II_Quotes() return true end
function getClassSecurities(class)
  local r = {}
  for sec in pairs(SIM.info) do r[#r + 1] = sec end
  table.sort(r)
  return table.concat(r, ",")
end
function getSecurityInfo(class, sec)
  local i = SIM.info[sec]
  if not i then return nil end
  return { scale = i.scale, min_price_step = i.tick, mat_date = i.mat, code = sec, class_code = class }
end
function getParamEx(class, sec, name)
  local i = SIM.info[sec]
  if not i then return { param_type = "0", param_value = "0" } end
  if name == "SEC_PRICE_STEP" then return { param_type = "1", param_value = tostring(i.tick) } end
  if name == "STEPPRICE" then return { param_type = "1", param_value = tostring(i.step) } end
  return { param_type = "0", param_value = "0" }
end

function getQuoteLevel2(class, sec)
  local i = SIM.info[sec]
  local agg = { B = {}, S = {} }
  for side, key in pairs({ B = "bids", S = "asks" }) do
    for p, q in pairs(SIM.mkt[sec][key]) do agg[side][p] = (agg[side][p] or 0) + q end
  end
  for _, o in ipairs(SIM.resting) do
    if o.sec == sec and o.active and o.bal > 0 then agg[o.side][o.px] = (agg[o.side][o.px] or 0) + o.bal end
  end
  local function arr(side)
    local ps = {}
    for p in pairs(agg[side]) do ps[#ps + 1] = p end
    table.sort(ps)          -- по возрастанию: у бидов лучший последний, у асков - первый
    local r = {}
    for _, p in ipairs(ps) do
      r[#r + 1] = { price = string.format("%." .. i.scale .. "f", p * i.tick), quantity = tostring(agg[side][p]) }
    end
    return r
  end
  local b, a = arr("B"), arr("S")
  return { bid_count = tostring(#b), offer_count = tostring(#a), bid = b, offer = a }
end

function getNumberOf(name)
  if name == "orders" then return #SIM.rows end
  if name == "futures_client_holding" then return 1 end
  return 0
end
function getItem(name, i)
  if name == "orders" then return SIM.rows[i + 1] end
  if name == "futures_client_holding" then
    local sec = next(SIM.pos)
    return sec and { sec_code = sec, trdaccid = SC.cfg.ACCOUNT, totalnet = SIM.pos[sec] } or nil
  end
end

------------------------------------------------------------------
-- ТРАНЗАКЦИИ
------------------------------------------------------------------
local function row_of(o)
  local flags = (o.active and 1 or 0) + (o.cancelled and 2 or 0) + (o.side == "S" and 4 or 0)
  return { order_num = o.num, trans_id = o.tid, flags = flags, balance = o.bal, qty = o.qty,
           price = string.format("%.2f", o.px * SIM.info[o.sec].tick), sec_code = o.sec, class_code = "SPBFUT",
           passive_only_order = o.passive and SIM.passive_flag or 0 }
end
local function emit_order(o)
  local r = row_of(o)
  SIM.rows[o.row] = r
  if OnOrder then OnOrder(r) end
end

local function fill_robot(o, q, px)
  o.bal = o.bal - q
  if o.bal <= 0 then o.active = false end
  SIM.pos[o.sec] = (SIM.pos[o.sec] or 0) + (o.side == "B" and q or -q)
  SIM.next_trade = SIM.next_trade + 1
  local tr = { trade_num = SIM.next_trade, order_num = o.num, trans_id = o.tid, qty = q,
               price = string.format("%.2f", px * SIM.info[o.sec].tick), flags = (o.side == "S") and 4 or 0, sec_code = o.sec }
  SIM.fills = SIM.fills or {}
  SIM.fills[#SIM.fills + 1] = { sec = o.sec, side = o.side, q = q, px = px, t = SIM.t, tid = o.tid }
  emit_order(o)
  if OnTrade then OnTrade(tr) end
end

local function all_trade(sec, px, q, aggr)
  if OnAllTrade then
    OnAllTrade({ sec_code = sec, class_code = "SPBFUT", price = string.format("%.2f", px * SIM.info[sec].tick),
                 qty = q, flags = (aggr < 0) and 1 or 2 })
  end
end

function sendTransaction(t)
  SIM.sent[#SIM.sent + 1] = t
  if t.ACTION == "KILL_ORDER" then
    local tid = tonumber(t.TRANS_ID)
    SIM.at(SIM.latency, function()
      local o
      for _, x in ipairs(SIM.resting) do if tostring(x.num) == t.ORDER_KEY then o = x end end
      if o and o.active then
        o.active = false; o.cancelled = true
        if OnTransReply then OnTransReply({ trans_id = tid, status = 3, order_num = o.num, result_msg = cp("Заявка снята") }) end
        emit_order(o)
        quote(o.sec)
      else
        SIM.kill_errors = (SIM.kill_errors or 0) + 1
        if OnTransReply then OnTransReply({ trans_id = tid, status = 4, order_num = 0, result_msg = cp("Заявка не найдена") }) end
      end
    end)
    return ""
  end
  if t.ACTION ~= cp("Ввод заявки") then return cp("Неизвестное действие") end
  local need = { "Торговый счет", "К/П", "Тип", "Инструмент", "Цена", "Количество" }
  for _, k in ipairs(need) do
    if t[cp(k)] == nil then return cp("Не указан параметр " .. k) end
  end
  for k, v in pairs(t) do
    local known = { TRANS_ID = 1, CLASSCODE = 1, ACTION = 1 }
    for _, n in ipairs(need) do known[cp(n)] = 1 end
    known[cp("Условие исполнения")] = 1
    known[cp("Код клиента")] = 1
    if not known[k] then return cp("Неправильно указан параметр: ") .. k end
  end
  local passive = t[cp("Условие исполнения")] == cp("Только пассивная")
  local tid = tonumber(t.TRANS_ID)
  local sec = t[cp("Инструмент")]
  local side = (t[cp("К/П")] == cp("Покупка")) and "B" or "S"
  local px = math.floor(tonumber(t[cp("Цена")]) / SIM.info[sec].tick + 0.5)
  local qty = tonumber(t[cp("Количество")])
  SIM.at(SIM.latency, function()
    local opp = best(sec, side == "B" and "S" or "B")
    local cross = opp and ((side == "B" and px >= opp) or (side == "S" and px <= opp))
    if cross and passive then
      SIM.boc_rejects = (SIM.boc_rejects or 0) + 1
      if OnTransReply then OnTransReply({ trans_id = tid, status = 4, order_num = 0,
        result_msg = cp("(11) Заявка с признаком «Только пассивная» отклонена: есть встречная заявка") }) end
      return
    end
    SIM.next_num = SIM.next_num + 1
    local o = { num = SIM.next_num, tid = tid, sec = sec, side = side, px = px, qty = qty, bal = qty,
                active = true, passive = passive,
                queue = SIM.mkt[sec][side == "B" and "bids" or "asks"][px] or 0 }
    SIM.resting[#SIM.resting + 1] = o
    o.row = #SIM.rows + 1
    if OnTransReply then OnTransReply({ trans_id = tid, status = 3, order_num = o.num, result_msg = cp("Заявка зарегистрирована") }) end
    emit_order(o)
    if cross then      -- без признака пассивности - тейкерская сделка
      SIM.taker_fills = (SIM.taker_fills or 0) + 1
      fill_robot(o, qty, opp)
    end
    quote(sec)
  end)
  return ""
end

------------------------------------------------------------------
-- РЫНОК: агрессивная сделка. aggr = -1 продавец бьёт в биды до цены px, +1 покупатель
------------------------------------------------------------------
function SIM.trade(sec, aggr, px, qty)
  local side = (aggr < 0) and "B" or "S"
  local key = (aggr < 0) and "bids" or "asks"
  local left = qty
  -- цены от лучшей к px
  local prices = {}
  for p in pairs(SIM.mkt[sec][key]) do prices[p] = true end
  for _, o in ipairs(SIM.resting) do if o.sec == sec and o.side == side and o.active then prices[o.px] = true end end
  local list = {}
  for p in pairs(prices) do
    if (aggr < 0 and p >= px) or (aggr > 0 and p <= px) then list[#list + 1] = p end
  end
  table.sort(list, function(a, b) if aggr < 0 then return a > b else return a < b end end)
  for _, p in ipairs(list) do
    if left <= 0 then break end
    local mq = SIM.mkt[sec][key][p] or 0
    -- очередь: сначала рынок, стоявший раньше робота
    local ours = {}
    for _, o in ipairs(SIM.resting) do if o.sec == sec and o.side == side and o.active and o.px == p then ours[#ours + 1] = o end end
    local ahead = 0
    for _, o in ipairs(ours) do ahead = math.max(ahead, math.min(o.queue, mq)) end
    local d = math.min(ahead, left)
    if d > 0 then
      mq = mq - d; left = left - d
      for _, o in ipairs(ours) do o.queue = math.max(0, o.queue - d) end
      all_trade(sec, p, d, aggr)
    end
    for _, o in ipairs(ours) do
      if left <= 0 then break end
      local f = math.min(o.bal, left)
      left = left - f
      all_trade(sec, p, f, aggr)
      fill_robot(o, f, p)
    end
    local d2 = math.min(mq, left)
    if d2 > 0 then mq = mq - d2; left = left - d2; all_trade(sec, p, d2, aggr) end
    SIM.mkt[sec][key][p] = (mq > 0) and mq or nil
  end
  quote(sec)
end

------------------------------------------------------------------
-- ВРЕМЯ: шаг 10 мс, события эмулятора, такт робота
------------------------------------------------------------------
function SIM.run(sec_total)
  local steps = math.floor(sec_total / 0.01 + 0.5)
  for _ = 1, steps do
    SIM.t = SIM.t + 0.01
    local due, keep = {}, {}
    for _, e in ipairs(SIM.sched) do if e.at <= SIM.t + 1e-9 then due[#due + 1] = e else keep[#keep + 1] = e end end
    SIM.sched = keep
    table.sort(due, function(a, b) return a.at < b.at end)
    for _, e in ipairs(due) do e.fn() end
    SC.step(SIM.t)
  end
end

function SIM.robot_orders(sec, active_only)
  local r = {}
  for _, o in ipairs(SIM.resting) do
    if (not sec or o.sec == sec) and (not active_only or o.active) then r[#r + 1] = o end
  end
  return r
end
