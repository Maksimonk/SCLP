-- probe_passive.lua : check the "Только пассивная" (Book-or-Cancel) universal-format order with YOUR broker.
-- Run in QUIK (Services -> Lua scripts) during trading hours, BEFORE the first live use of sclp.lua.
--  1. Places a passive BUY of 1 lot PROBE_OFFSET ticks below the best bid with the same TX fields as sclp.lua
--     (sclp_config.lua / lib/defaults.lua), instrument = DEFAULT_INSTRUMENT.
--  2. Writes the QUIK reply and all fields of the orders-table row (look for passive_only_order), then cancels it.
--  3. Optional (PROBE_CROSS = true): a passive buy AT the best ask - the exchange must reject it.
--     CAUTION: if the flag does not work it fills and you hold 1 lot - close it manually.
-- Result: probe_passive_YYYYMMDD_HHMMSS.txt in the SCLP folder. If QUIK answers "Неправильно указан параметр":
-- Transaction pocket (F7) -> create the order by hand with "Только пассивная" -> save as .tri -> copy field names to TX.
local PROBE_OFFSET = 20
local PROBE_CROSS = false

SCLP = { dir = getScriptPath():gsub("[\\/]tools$", "") }
local X = SCLP
local U = dofile(X.dir .. "/lib/util.lua")(X)
local ok, user = pcall(dofile, X.dir .. "/sclp_config.lua")
X.cfg = U.merge(dofile(X.dir .. "/lib/defaults.lua"), ok and user or {})
local O = dofile(X.dir .. "/lib/oms.lua")(X)
local I = dofile(X.dir .. "/lib/inst.lua")(X)

local out = {}
local function say(s) out[#out + 1] = s; U.log("[probe] " .. s) end

local running = true
local replies, orders = {}, {}
function OnTransReply(r) replies[#replies + 1] = r end
function OnOrder(o) orders[#orders + 1] = o end
function OnStop() running = false; return 1000 end

local function wait(cond, sec)
  local t_end = os.time() + sec
  while running and os.time() <= t_end do
    local v = cond()
    if v then return v end
    sleep(100)
  end
end

local function final_reply(tid)
  return wait(function()
    for _, r in ipairs(replies) do
      local st = tonumber(r.status)
      if tonumber(r.trans_id) == tid and st ~= 0 and st ~= 1 then return r end
    end
  end, 15)
end

local function dump(row)
  local keys = {}
  for k in pairs(row) do keys[#keys + 1] = tostring(k) end
  table.sort(keys)
  local r = {}
  for _, k in ipairs(keys) do
    if type(row[k]) ~= "table" then r[#r + 1] = k .. "=" .. U.from_cp1251(tostring(row[k])) end
  end
  return table.concat(r, "; ")
end

local function send_and_wait(inst, side, px)
  local tid = O.next_tid()
  local t = O.build_boc(inst, side, px, 1, tid)
  local f = {}
  for k, v in pairs(t) do f[#f + 1] = U.from_cp1251(k) .. "=" .. U.from_cp1251(v) end
  table.sort(f)
  say("SEND: " .. table.concat(f, "; "))
  local res = sendTransaction(t)
  if res ~= "" then
    say("QUIK REJECTED THE TRANSACTION LOCALLY: " .. U.from_cp1251(res))
    say("=> field names in TX do not fit: F7 -> order with 'Только пассивная' -> save .tri")
    return nil
  end
  local rep = final_reply(tid)
  if not rep then say("no OnTransReply in 15 s"); return nil end
  say(string.format("REPLY: status=%s order_num=%s msg=%s", tostring(rep.status), tostring(rep.order_num),
    U.from_cp1251(rep.result_msg or "")))
  return rep, tid
end

function main()
  local inst, err = I.resolve(X.cfg.DEFAULT_INSTRUMENT)
  if not inst then say("instrument: " .. tostring(err)); return end
  Subscribe_Level_II_Quotes(inst.class, inst.sec)
  sleep(1500)
  local q = getQuoteLevel2(inst.class, inst.sec)
  local nb, na = tonumber(q and q.bid_count) or 0, tonumber(q and q.offer_count) or 0
  if nb == 0 or na == 0 then say("empty order book - run during trading hours"); return end
  local bb, ba = inst:idx(U.num(q.bid[nb].price)), inst:idx(U.num(q.offer[1].price))
  local px = bb - PROBE_OFFSET
  if inst.pmin and px < inst.pmin then px = inst.pmin end
  say(string.format("instrument %s, tick %s, best %s / %s, account %s", inst.sec, tostring(inst.tick),
    inst:px_str(bb), inst:px_str(ba), O.account(inst.class)))

  local rep, tid = send_and_wait(inst, "B", px)
  if rep and tonumber(rep.status) == 3 then
    local row = wait(function()
      for _, o in ipairs(orders) do if tonumber(o.trans_id) == tid then return o end end
    end, 10)
    if row then
      say("ORDER ROW: " .. dump(row))
      say(row.passive_only_order == nil and "=> QUIK does not give passive_only_order: check the orders table column by hand"
        or ("=> passive_only_order = " .. tostring(row.passive_only_order) .. " (0/false - flag NOT set)"))
      local key = U.key_from_num(row.order_num) or U.key_from_num(rep.order_num)
      if key then
        local kt = O.next_tid()
        sendTransaction(O.build_kill(inst.class, inst.sec, key, kt))
        local kr = final_reply(kt)
        say("KILL: " .. (kr and (tostring(kr.status) .. " " .. U.from_cp1251(kr.result_msg or "")) or "no reply - CANCEL BY HAND"))
      end
    else
      say("no OnOrder row in 10 s - cancel the order by hand if it is resting")
    end
  end

  if PROBE_CROSS then
    q = getQuoteLevel2(inst.class, inst.sec)
    ba = inst:idx(U.num(q.offer[1].price))
    local rep2 = send_and_wait(inst, "B", ba)
    if rep2 then
      if tonumber(rep2.status) == 3 then
        say("!!! ORDER AT THE ASK WAS ACCEPTED - the passive flag does NOT work. Check the position and close it by hand!")
      else
        say("=> rejected as expected, class: " .. O.classify(U.from_cp1251(rep2.result_msg or "")))
      end
    end
  end

  local f = io.open(X.dir .. "/probe_passive_" .. os.date("%Y%m%d_%H%M%S") .. ".txt", "w")
  if f then f:write(table.concat(out, "\n"), "\n"); f:close() end
  message("probe_passive: done, see probe_passive_*.txt", 1)
  U.close_all()
end
