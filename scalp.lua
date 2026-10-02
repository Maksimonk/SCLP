-- scalp.lua : скальпер "только пассивными" заявками для QUIK (FORTS). Запуск: QUIK -> Сервисы -> Lua скрипты.
-- Ловит дырки у рынка (широкий спред) парой bid+ask, выносы (FADE) и стены за пустотами (WALL).
-- Все заявки отправляются с условием исполнения "Только пассивная": биржа отклоняет заявку, которая стала
-- бы тейкерской. Отказ одной ноги пары -> вторую сразу снимаем. Выход из позиции - тоже только пассивно.
-- Настройки: scalp_config.lua (пояснения - sc_lib/defaults.lua). Описание - README.md.

SC = SC or {}
SC.dir = SC.dir or (getScriptPath and getScriptPath()) or "."
SC.running = true
SC.insts = {}

local function load_mod(name) return dofile(SC.dir .. "/sc_lib/" .. name .. ".lua")(SC) end

local U = load_mod("util")
SC.cfg = {}   -- до загрузки настроек
load_mod("book"); load_mod("oms"); load_mod("paper"); load_mod("cycle")
load_mod("setups"); load_mod("risk"); load_mod("stats"); load_mod("ui")
local O, V, C, S, R, K, ST, W = SC.O, SC.V, SC.C, SC.S, SC.R, SC.K, SC.ST, SC.W

------------------------------------------------------------------
-- НАСТРОЙКИ
------------------------------------------------------------------
local DEF = dofile(SC.dir .. "/sc_lib/defaults.lua")
local FIXED = { MODE = true, ACCOUNT = true, TX = true, TX_ENCODING = true, TRANS_ID_BASE = true, SHARED_ACCOUNT = true }

local function read_user_config()
  if SC.config_override then return SC.config_override end
  local ok, cfg = pcall(dofile, SC.dir .. "/scalp_config.lua")
  if not ok or type(cfg) ~= "table" then return nil, tostring(cfg) end
  return cfg
end

local function build_global(user, old)
  local g = U.merge(DEF.GLOBAL, {})
  for k, v in pairs(user) do
    if k ~= "INSTRUMENTS" and k ~= "DEFAULTS" then
      if k == "TX" then g.TX = U.merge(DEF.GLOBAL.TX, v) else g[k] = v end
    end
  end
  if old then for k in pairs(FIXED) do g[k] = old[k] end end
  return g
end

local function build_P(user, entry)
  local P = U.merge(DEF.INSTRUMENT, user.DEFAULTS or {})
  P = U.merge(P, entry)
  P.SETUPS = U.merge(DEF.INSTRUMENT.SETUPS, U.merge((user.DEFAULTS or {}).SETUPS or {}, entry.SETUPS or {}))
  return P
end

------------------------------------------------------------------
-- ИНСТРУМЕНТЫ
------------------------------------------------------------------
local function param(class, sec, name)
  if not getParamEx then return nil end
  local ok, p = pcall(getParamEx, class, sec, name)
  if ok and p and tonumber(p.param_type) ~= 0 then return U.num(p.param_value) end
  return nil
end

local function days_to(mat)
  mat = tonumber(mat)
  if not mat or mat <= 0 then return nil end
  local y, m, d = math.floor(mat / 10000), math.floor(mat / 100) % 100, mat % 100
  local exp = os.time({ year = y, month = m, day = d, hour = 18 })
  return (exp - U.now()) / 86400
end

local function resolve(class, base, close_days)
  local list = getClassSecurities and getClassSecurities(class) or ""
  local best, best_mat
  for code in tostring(list):gmatch("[^,]+") do
    if code:sub(1, #base) == base and #code == #base + 2 then
      local info = getSecurityInfo(class, code)
      local mat = info and tonumber(info.mat_date)
      local dl = days_to(mat)
      if mat and dl and dl > close_days and (not best_mat or mat < best_mat) then best, best_mat = code, mat end
    end
  end
  return best
end

local function make_inst(class, sec, P)
  local info = getSecurityInfo and getSecurityInfo(class, sec)
  if not info then return nil, "no security " .. class .. ":" .. sec end
  local tick = param(class, sec, "SEC_PRICE_STEP") or U.num(info.min_price_step)
  if not tick or tick <= 0 then return nil, "no price step for " .. sec end
  local inst = { class = class, sec = sec, P = P, tick = tick, scale = tonumber(info.scale) or 2,
                 step_price = param(class, sec, "STEPPRICE") or P.STEPPRICE_RUB }
  function inst:price_str(idx) return string.format("%." .. self.scale .. "f", idx * self.tick) end
  local dl = days_to(info.mat_date)
  if dl and dl <= P.EXPIRY_CLOSE_DAYS then
    inst.disabled = true
    U.alert(sec .. ": expiry in " .. U.fmt(dl, 1) .. " days - no new entries")
  end
  return inst
end

local function setup_instruments(user)
  for i, entry in ipairs(user.INSTRUMENTS or {}) do
    local P = build_P(user, entry)
    if P.ENABLED ~= false then
      local class = P.CLASS
      local sec = entry.SEC or (entry.BASE and resolve(class, entry.BASE, P.EXPIRY_CLOSE_DAYS))
      if not sec then
        U.alert("instrument #" .. i .. ": no contract for BASE " .. tostring(entry.BASE))
      else
        local inst, err = make_inst(class, sec, P)
        if not inst then U.alert(err) else
          inst.cfg_index = i
          K.new_market(inst)
          if entry.REF then
            local rsec = entry.REF.SEC or (entry.REF.BASE and resolve(entry.REF.CLASS or class, entry.REF.BASE, 0))
            local rinfo = rsec and getSecurityInfo(entry.REF.CLASS or class, rsec)
            if rinfo then
              local rc = entry.REF.CLASS or class
              inst.ref = { class = rc, sec = rsec, tick = param(rc, rsec, "SEC_PRICE_STEP") or U.num(rinfo.min_price_step),
                           mult = entry.REF.mult or 1, mids = {} }
              if Subscribe_Level_II_Quotes then pcall(Subscribe_Level_II_Quotes, rc, rsec) end
            else
              U.alert(sec .. ": reference instrument not found")
            end
          end
          if Subscribe_Level_II_Quotes then pcall(Subscribe_Level_II_Quotes, class, sec) end
          SC.insts[#SC.insts + 1] = inst
          U.log(string.format("INSTRUMENT %s (%s): tick %s, step %s RUB, ref %s, setups %s", sec, entry.BASE or "SEC",
            tostring(inst.tick), tostring(inst.step_price), inst.ref and inst.ref.sec or "-",
            (function() local r = {} for k, v in pairs(P.SETUPS) do r[#r + 1] = k .. "=" .. v end table.sort(r) return table.concat(r, " ") end)()))
        end
      end
    end
  end
  SC.by_sec = {}
  SC.ref_of = {}
  for _, inst in ipairs(SC.insts) do
    SC.by_sec[inst.sec] = inst
    if inst.ref then
      SC.ref_of[inst.ref.sec] = SC.ref_of[inst.ref.sec] or {}
      table.insert(SC.ref_of[inst.ref.sec], inst)
    end
  end
end

------------------------------------------------------------------
-- СОСТОЯНИЕ (позиция и заявки - на случай перезапуска)
------------------------------------------------------------------
local state_dirty, state_t = false, 0
local function state_path() return U.path("scalp_state.txt") end

local function save_state(t, force)
  if not force and (not state_dirty or t - state_t < 1) then return end
  state_dirty, state_t = false, t
  local parts = { "return { day = '" .. U.date("%Y%m%d", t) .. "', pos = {" }
  for _, inst in ipairs(SC.insts) do
    local q = C.position(inst, "real")
    if q ~= 0 then
      local cost, n = 0, 0
      for _, c in ipairs(C.active(inst, "real")) do
        if c.pos ~= 0 then cost = cost + c.avg * math.abs(c.pos); n = n + math.abs(c.pos) end
      end
      parts[#parts + 1] = string.format("['%s'] = { q = %d, avg = %.4f },", inst.sec, q, cost / math.max(1, n))
    end
  end
  parts[#parts + 1] = "}, orders = {"
  for _, o in ipairs(O.all_live(nil, "real")) do
    if o.key then parts[#parts + 1] = string.format("{ sec = '%s', key = '%s' },", o.inst.sec, o.key) end
  end
  parts[#parts + 1] = "} }"
  U.write_file_atomic(state_path(), table.concat(parts, "\n"))
end
function SC.mark_state() state_dirty = true end

local function restore_state(t)
  local ok, st = pcall(dofile, state_path())
  if not ok or type(st) ~= "table" or st.day ~= U.date("%Y%m%d", t) then return end
  if SC.cfg.SHARED_ACCOUNT then
    for sec, p in pairs(st.pos or {}) do
      local inst = SC.by_sec[sec]
      if inst and p.q ~= 0 then C.adopt(inst, p.q, p.avg / inst.tick, t, "restart (scalp_state.txt)") end
    end
  end
  if SC.cfg.CANCEL_ON_START and SC.cfg.MODE == "LIVE" then
    -- снимаем только те, что таблица заявок показывает активными (снятие несуществующей - ошибочная транзакция)
    local active = {}
    local n = getNumberOf and getNumberOf("orders") or 0
    for i = 0, n - 1 do
      local row = getItem("orders", i)
      if row and U.bit(row.flags, 0) then
        local k = U.key_from_num(row.order_num)
        if k then active[k] = true end
      end
    end
    for _, r in ipairs(st.orders or {}) do
      local inst = SC.by_sec[r.sec]
      if inst and active[r.key] then
        U.log("cancel order left from previous run: " .. r.key)
        pcall(sendTransaction, O.build_kill(inst, r.key, O.next_tid()))
      end
    end
  end
end

------------------------------------------------------------------
-- ЧУЖИЕ ЗАЯВКИ И ПОЗИЦИЯ БРОКЕРА
------------------------------------------------------------------
local function scan_foreign(t)
  if SC.cfg.MODE ~= "LIVE" or not getNumberOf then return end
  local seen = {}
  local n = getNumberOf("orders") or 0
  for i = 0, n - 1 do
    local row = getItem("orders", i)
    if row and SC.by_sec[row.sec_code] and U.bit(row.flags, 0) then
      local k = U.key_from_num(row.order_num)
      if not (k and O.by_num[k]) and not (O.by_tid[tonumber(row.trans_id) or -1]) then
        seen[row.sec_code] = (seen[row.sec_code] or 0) + 1
      end
    end
  end
  for _, inst in ipairs(SC.insts) do
    local was = inst.foreign_block
    inst.foreign_block = SC.cfg.FOREIGN_ORDERS_BLOCK and (seen[inst.sec] or 0) > 0 or false
    if inst.foreign_block ~= was then
      U.log(string.format("[%s] foreign active orders: %d -> real entries %s", inst.sec, seen[inst.sec] or 0,
        inst.foreign_block and "BLOCKED (another robot quotes this contract: self-cross risk)" or "allowed"))
    end
  end
end

local function broker_pos(inst)
  if not getNumberOf then return nil end
  local n = getNumberOf("futures_client_holding") or 0
  for i = 0, n - 1 do
    local r = getItem("futures_client_holding", i)
    if r and r.sec_code == inst.sec and (r.trdaccid == SC.cfg.ACCOUNT or SC.cfg.ACCOUNT == "") then
      return U.num(r.totalnet) or 0
    end
  end
  return 0
end

local function sync_broker(t)
  if SC.cfg.SHARED_ACCOUNT or SC.cfg.MODE ~= "LIVE" then return end
  for _, inst in ipairs(SC.insts) do
    local b = broker_pos(inst)
    local mine = C.position(inst, "real")
    local pend = 0
    for _, o in ipairs(O.all_live(inst, "real")) do pend = pend + O.unsettled(o) end
    if b and b ~= mine and pend == 0 then
      inst.pos_diff_t = inst.pos_diff_t or t
      if t - inst.pos_diff_t >= SC.cfg.POS_SYNC_SEC and inst.sig.valid then
        inst.pos_diff_t = nil
        C.adopt(inst, b - mine, inst.sig.mid, t, "broker position differs")
      end
    else
      inst.pos_diff_t = nil
    end
  end
end

------------------------------------------------------------------
-- СОБЫТИЯ (колбэки складывают, основной цикл разбирает)
------------------------------------------------------------------
local Q, qh, qt = {}, 1, 0
local function push(e) qt = qt + 1; Q[qt] = e end
local dirty = {}

function OnQuote(class, sec)
  if SC.by_sec and SC.by_sec[sec] then dirty[sec] = true end
  if SC.ref_of and SC.ref_of[sec] then dirty["ref:" .. sec] = true end
end
function OnAllTrade(tr)
  if SC.by_sec and SC.by_sec[tr.sec_code] then
    push({ k = "tape", sec = tr.sec_code, price = tr.price, qty = tr.qty, flags = tr.flags })
  end
end
function OnTransReply(r)
  push({ k = "reply", trans_id = r.trans_id, status = r.status, order_num = r.order_num,
         result_msg = r.result_msg, sec = r.sec_code })
end
function OnOrder(o)
  if SC.by_sec and SC.by_sec[o.sec_code] then
    push({ k = "order", trans_id = o.trans_id, order_num = o.order_num, flags = o.flags, qty = o.qty,
           balance = o.balance, price = o.price, sec_code = o.sec_code, passive_only_order = o.passive_only_order })
  end
end
function OnTrade(tr)
  if SC.by_sec and SC.by_sec[tr.sec_code] then
    push({ k = "trade", trade_num = tr.trade_num, order_num = tr.order_num, trans_id = tr.trans_id,
           qty = tr.qty, price = tr.price, flags = tr.flags, sec_code = tr.sec_code })
  end
end
function OnStop()
  SC.running = false
  return 10000
end

local function process_events(t)
  while qh <= qt do
    local e = Q[qh]; Q[qh] = nil; qh = qh + 1
    if e.k == "tape" then
      local inst = SC.by_sec[e.sec]
      if inst then
        local tr = K.on_tape(inst, e, t)
        if tr then V.on_tape(inst, tr, t) end
      end
    elseif e.k == "reply" then O.on_reply(e, t); SC.mark_state()
    elseif e.k == "order" then O.on_order(e, t); SC.mark_state()
    elseif e.k == "trade" then O.on_trade(e, t); SC.mark_state()
    end
  end
end

------------------------------------------------------------------
-- ИНИЦИАЛИЗАЦИЯ И ТАКТ
------------------------------------------------------------------
function SC.init()
  local user, err = read_user_config()
  if not user then error("scalp_config.lua: " .. tostring(err)) end
  SC.user = user
  SC.cfg = build_global(user)
  local t = U.now()
  SC.t_start = t
  R.check_day(t)
  U.log(string.format("=== SCALP start: MODE %s, account %s, passive-only via universal format (%s = %s) ===",
    SC.cfg.MODE, SC.cfg.ACCOUNT, SC.cfg.TX.COND, SC.cfg.TX.COND_PASSIVE))
  setup_instruments(user)
  if #SC.insts == 0 then U.alert("no instruments") end
  restore_state(t)
  scan_foreign(t)
  W.open()
end

local t_cfg, t_foreign, t_sync = 0, 0, 0
local function reload_config(t)
  local user = read_user_config()
  if not user then U.log_every("cfgerr", 60, "scalp_config.lua: read error, keeping old settings"); return end
  SC.cfg = build_global(user, SC.cfg)
  for _, inst in ipairs(SC.insts) do
    local entry = (user.INSTRUMENTS or {})[inst.cfg_index]
    if entry then inst.P = build_P(user, entry) end
  end
end

function SC.step(t)
  R.check_day(t)
  process_events(t)
  for _, inst in ipairs(SC.insts) do
    if dirty[inst.sec] or not inst.t_book_read or t - inst.t_book_read >= 0.5 then
      dirty[inst.sec] = nil
      K.read_book(inst, t)
      V.on_book(inst, t)
    end
    if inst.ref and (dirty["ref:" .. inst.ref.sec] or not inst.ref.t_read or t - inst.ref.t_read >= 0.25) then
      K.read_ref(inst, t)
    end
  end
  for _, inst in ipairs(SC.insts) do
    if inst.ref then dirty["ref:" .. inst.ref.sec] = nil end
  end
  V.tick(t)
  C.tick_all(t)
  if O.halt and not SC.halt_done then
    SC.halt_done = true
    U.alert("HALT: " .. O.halt)
    for _, c in ipairs(C.active(nil, "real")) do
      if c.state == "ENTRY" then C.cancel_all(c, t, "halt") end
    end
  end
  for _, inst in ipairs(SC.insts) do S.scan(inst, t) end
  O.tick(t)
  ST.tick(t)
  W.tick(t)
  if t - t_foreign >= 5 then t_foreign = t; scan_foreign(t) end
  if t - t_sync >= 1 then t_sync = t; sync_broker(t) end
  if t - t_cfg >= 5 then t_cfg = t; reload_config(t) end
  save_state(t)
end

function SC.shutdown()
  local t = U.now()
  if SC.cfg.CANCEL_ON_STOP then
    O.cancel_all("stop")
    -- подождать подтверждений до 3 с
    local t_end = t + 3
    while U.now() < t_end and next(O.live) do
      process_events(U.now())
      O.tick(U.now())
      V.tick(U.now())
      if sleep and not SC.clock then sleep(50) else break end
    end
  end
  for _, inst in ipairs(SC.insts) do
    local q = C.position(inst, "real")
    if q ~= 0 then U.alert(inst.sec .. ": stopped WITH POSITION " .. q .. " (saved to scalp_state.txt, next start closes it)") end
  end
  save_state(U.now(), true)
  ST.final(U.now())
  W.close()
  U.log("=== SCALP stop ===")
  U.close_all()
end

function main()
  local ok, err = pcall(SC.init)
  if not ok then
    U.alert("init error: " .. tostring(err))
    U.close_all()
    return
  end
  while SC.running do
    local t = U.now()
    local ok2, err2 = pcall(SC.step, t)
    if ok2 then SC.errors = 0 else
      U.log_every("steperr", 10, "STEP ERROR: " .. tostring(err2))
      SC.errors = (SC.errors or 0) + 1
      if SC.errors > 50 then
        U.alert("too many errors - cancelling orders and stopping")
        SC.running = false
      end
    end
    U.flush()
    sleep(SC.cfg.LOOP_MS or 10)
  end
  pcall(SC.shutdown)
end
