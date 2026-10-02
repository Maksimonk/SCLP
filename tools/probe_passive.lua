-- probe_passive.lua : ПРОВЕРКА "только пассивной" заявки у вашего брокера. Запускать в QUIK
-- (Сервисы -> Lua скрипты) в торговое время, ДО первого запуска scalp.lua в LIVE.
--
-- Что делает:
--  1. Ставит "только пассивную" ПОКУПКУ 1 контракта далеко от рынка (лучший бид - PROBE_OFFSET тиков) теми же
--     полями, что и робот (scalp_config.lua / sc_lib/defaults.lua, раздел TX).
--  2. Пишет ответ QUIK и ВСЕ поля строки таблицы заявок (ищем passive_only_order) и снимает заявку.
--  3. (по желанию, PROBE_CROSS = true) ставит "только пассивную" покупку ПО ЛУЧШЕМУ АСКУ - биржа должна её
--     отклонить. Текст отказа попадёт в отчёт. ОСТОРОЖНО: если признак не работает, заявка исполнится и
--     у вас будет 1 контракт - закройте его вручную.
-- Результат: probe_passive_ГГГГММДД_ЧЧММСС.txt рядом со скриптом scalp.lua.
-- Если QUIK отвечает "Неправильно указан параметр": откройте "Карман транзакций" (F7), создайте заявку
-- вручную с "Условие исполнения = Только пассивная", сохраните в .tri и перенесите названия полей в TX.

local PROBE_OFFSET = 20       -- тиков ниже лучшего бида
local PROBE_CROSS = false     -- true - проверить отказ пересекающей заявки (см. предупреждение выше)

SC = { dir = getScriptPath():gsub("[\\/]tools$", "") }
local U = dofile(SC.dir .. "/sc_lib/util.lua")(SC)
local DEF = dofile(SC.dir .. "/sc_lib/defaults.lua")
local user = dofile(SC.dir .. "/scalp_config.lua")
SC.cfg = U.merge(DEF.GLOBAL, {})
for k, v in pairs(user) do
  if k ~= "INSTRUMENTS" and k ~= "DEFAULTS" then
    if k == "TX" then SC.cfg.TX = U.merge(DEF.GLOBAL.TX, v) else SC.cfg[k] = v end
  end
end
local O = dofile(SC.dir .. "/sc_lib/oms.lua")(SC)

local out = {}
local function say(s)
  out[#out + 1] = s
  U.log("[probe] " .. s)
end

local running = true
local replies, orders = {}, {}
function OnTransReply(r) replies[#replies + 1] = r end
function OnOrder(o) orders[#orders + 1] = o end
function OnStop() running = false; return 1000 end

local function wait(cond, sec)
  local t0 = os.clock()
  local t_end = os.time() + sec
  while running and os.time() <= t_end do
    local v = cond()
    if v then return v end
    sleep(100)
  end
  return nil
end

local function resolve(class, base)
  local best, best_mat
  for code in tostring(getClassSecurities(class) or ""):gmatch("[^,]+") do
    if code:sub(1, #base) == base and #code == #base + 2 then
      local info = getSecurityInfo(class, code)
      local mat = info and tonumber(info.mat_date)
      if mat and mat >= tonumber(os.date("%Y%m%d")) + 2 and (not best_mat or mat < best_mat) then best, best_mat = code, mat end
    end
  end
  return best
end

local function dump(row)
  local keys = {}
  for k in pairs(row) do keys[#keys + 1] = tostring(k) end
  table.sort(keys)
  local r = {}
  for _, k in ipairs(keys) do
    local v = row[k]
    if type(v) ~= "table" then r[#r + 1] = k .. "=" .. U.from_cp1251(tostring(v)) end
  end
  return table.concat(r, "; ")
end

local function send_and_wait(inst, side, px)
  local tid = O.next_tid()
  local t = O.build_new(inst, side, px, 1, tid)
  local fields = {}
  for k, v in pairs(t) do fields[#fields + 1] = U.from_cp1251(k) .. "=" .. U.from_cp1251(v) end
  table.sort(fields)
  say("SEND: " .. table.concat(fields, "; "))
  local res = sendTransaction(t)
  if res ~= "" then
    say("QUIK REJECTED THE TRANSACTION LOCALLY: " .. U.from_cp1251(res))
    say("=> названия полей TX не подходят. F7 'Карман транзакций' -> заявка 'Только пассивная' -> сохранить .tri")
    return nil
  end
  local rep = wait(function()
    for _, r in ipairs(replies) do
      if tonumber(r.trans_id) == tid and tonumber(r.status) ~= 0 and tonumber(r.status) ~= 1 then return r end
    end
  end, 15)
  if not rep then say("no OnTransReply in 15 s"); return nil end
  say(string.format("REPLY: status=%s order_num=%s msg=%s", tostring(rep.status), tostring(rep.order_num),
    U.from_cp1251(rep.result_msg or "")))
  return rep, tid
end

function main()
  local entry = (user.INSTRUMENTS or {})[1]
  if not entry then say("no instruments in scalp_config.lua"); return end
  local class = entry.CLASS or "SPBFUT"
  local sec = entry.SEC or resolve(class, entry.BASE)
  local info = sec and getSecurityInfo(class, sec)
  if not info then say("instrument not found"); return end
  local tick = tonumber(getParamEx(class, sec, "SEC_PRICE_STEP").param_value) or tonumber(info.min_price_step)
  local inst = { class = class, sec = sec, tick = tick, scale = tonumber(info.scale) or 2 }
  function inst:price_str(idx) return string.format("%." .. self.scale .. "f", idx * self.tick) end
  Subscribe_Level_II_Quotes(class, sec)
  sleep(1500)
  local q = getQuoteLevel2(class, sec)
  local nb = tonumber(q and q.bid_count) or 0
  local na = tonumber(q and q.offer_count) or 0
  if nb == 0 or na == 0 then say("empty order book - run during trading hours"); return end
  local bb = math.floor(U.num(q.bid[nb].price) / tick + 0.5)
  local ba = math.floor(U.num(q.offer[1].price) / tick + 0.5)
  local pmin = U.num(getParamEx(class, sec, "PRICEMIN").param_value) or 0
  local px = bb - PROBE_OFFSET
  if pmin > 0 and px * tick < pmin then px = math.ceil(pmin / tick) end
  say(string.format("instrument %s, tick %s, best %s / %s, account %s", sec, tostring(tick),
    inst:price_str(bb), inst:price_str(ba), SC.cfg.ACCOUNT))

  -- 1. заявка далеко от рынка
  local rep, tid = send_and_wait(inst, "B", px)
  if rep and tonumber(rep.status) == 3 then
    local row = wait(function()
      for _, o in ipairs(orders) do if tonumber(o.trans_id) == tid then return o end end
    end, 10)
    if row then
      say("ORDER ROW: " .. dump(row))
      if row.passive_only_order == nil then
        say("=> поле passive_only_order QUIK не отдаёт: проверьте в таблице заявок колонку 'Только пассивная' вручную")
      else
        say("=> passive_only_order = " .. tostring(row.passive_only_order) .. " (0/false - признак НЕ установлен)")
      end
      local key = U.key_from_num(row.order_num) or U.key_from_num(rep.order_num)
      if key then
        local kt = O.next_tid()
        sendTransaction(O.build_kill(inst, key, kt))
        local kr = wait(function()
          for _, r in ipairs(replies) do if tonumber(r.trans_id) == kt and tonumber(r.status) ~= 0 and tonumber(r.status) ~= 1 then return r end end
        end, 10)
        say("KILL: " .. (kr and (tostring(kr.status) .. " " .. U.from_cp1251(kr.result_msg or "")) or "no reply - СНИМИТЕ ЗАЯВКУ ВРУЧНУЮ"))
      end
    else
      say("no OnOrder row in 10 s - снимите заявку вручную, если она стоит")
    end
  end

  -- 2. пересекающая заявка (по желанию)
  if PROBE_CROSS then
    q = getQuoteLevel2(class, sec)
    ba = math.floor(U.num(q.offer[1].price) / tick + 0.5)
    local rep2 = send_and_wait(inst, "B", ba)
    if rep2 then
      if tonumber(rep2.status) == 3 then
        say("!!! ЗАЯВКА ПО АСКУ ПРИНЯТА - признак пассивности НЕ работает. Проверьте позицию и закройте её вручную!")
      else
        say("=> отказ, как и должно быть. Класс текста для робота: " .. O.classify_reject(U.from_cp1251(rep2.result_msg or "")))
      end
    end
  end

  local f = io.open(SC.dir .. "/probe_passive_" .. os.date("%Y%m%d_%H%M%S") .. ".txt", "w")
  if f then f:write(table.concat(out, "\n"), "\n"); f:close() end
  message("probe_passive: done, see probe_passive_*.txt", 1)
  U.close_all()
end
