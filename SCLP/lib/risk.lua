-- risk.lua : pre-trade checks, trading pauses, daily loss auto-stop, order-rate and OTR warnings.
-- Position-increasing orders (arrow keys, requotes) pass every check. Position-reducing orders (take-profit,
-- passive flatten) skip the position, spread, pause-window and rate checks. PANIC skips all of them.
return function(X)
  local R = {}
  X.R = R
  local U = X.U
  local abs, max = math.abs, math.max

  R.day_stop = false

  function R.connected()
    if not isConnected or X.clock then return true end
    local ok, v = pcall(isConnected)
    return not ok or v == 1
  end

  -- current pause window for the instrument class: label or nil
  function R.pause_window(inst, t)
    local list = (X.cfg.PAUSE_WINDOWS or {})[inst.class] or (X.cfg.PAUSE_WINDOWS or {}).default or {}
    local now = U.msk_sec(t)
    for _, w in ipairs(list) do
      local a, b = U.hms(w[1]), U.hms(w[2])
      if a and b and now >= a and now < b then return w[3] or "пауза" end
    end
    return nil
  end

  function R.broker_pos(inst)
    if not (inst.forts and getNumberOf) then return nil end
    local acc = X.O.account(inst.class)
    local n = getNumberOf("futures_client_holding") or 0
    for i = 0, n - 1 do
      local r = getItem("futures_client_holding", i)
      if r and r.sec_code == inst.sec and (acc == "" or r.trdaccid == acc) then return U.num(r.totalnet) or 0, r end
    end
    return 0
  end

  -- market state blocking NEW position-increasing orders: reason or nil
  function R.market_block(inst, t)
    local bk = inst.bk
    if not R.connected() then return "нет связи с сервером" end
    if not bk or not bk.valid then return "нет стакана / стакан пересечён" end
    if inst.trading == false then return "торги: " .. tostring(inst.status_text) end
    local pw = R.pause_window(inst, t)
    if pw then return "пауза: " .. pw end
    local maxs = X.cfg.MAX_SPREAD_TICKS or 0
    if maxs > 0 and bk.spread > maxs then return "спред " .. bk.spread .. " > " .. maxs .. " тиков" end
    local k = X.cfg.SPREAD_WIDE_K or 0
    if k > 0 and bk.spread_avg and bk.spread >= 3 and bk.spread > k * bk.spread_avg
       and t - (X.t_inst or t) > 30 then
      return string.format("аномальный спред %d (обычно %.1f)", bk.spread, bk.spread_avg)
    end
    return nil
  end

  -- can we send a position-increasing order? ok, reason
  local function blocked()
    if X.recovering then return "идёт восстановление после запуска" end
    if X.block then
      return string.format("РАСХОЖДЕНИЕ ПОЗИЦИИ (SCLP %+d, QUIK %+d): A,A - принять, P,P - PANIC", X.block.computed, X.block.real)
    end
  end
  R.blocked = blocked

  function R.can_open(inst, side, qty, t)
    local b = blocked()
    if b then return false, b end
    if X.O.halt then return false, "ОСТАНОВ: " .. X.O.halt end
    if X.panic and X.panic.stage ~= "done" then return false, "идёт PANIC" end
    if R.day_stop then return false, "дневной лимит убытка" end
    if X.paused then return false, "пауза (H - продолжить)" end
    if qty < 1 or qty > (X.cfg.MAX_ORDER_QTY or 100) then return false, "объём вне 1.." .. (X.cfg.MAX_ORDER_QTY or 100) end
    local mb = R.market_block(inst, t)
    if mb then return false, mb end
    local per_min = X.O.orders_last_min(t)
    if per_min >= (X.cfg.MAX_ORDERS_PER_MIN or 60) then return false, "лимит заявок в минуту (" .. per_min .. ")" end
    -- worst case: every working order fills
    local pos = X.M.get(inst).pos
    local wb, ws = X.O.working_qty(inst, "B"), X.O.working_qty(inst, "S")
    local long = pos + wb + (side == "B" and qty or 0)
    local short = pos - ws - (side == "S" and qty or 0)
    local lim = math.min(X.st.max_pos, X.cfg.HARD_MAX_POS or 1000)
    -- an order that only reduces the current position is fine even at the limit
    local reduces = (side == "S" and pos - ws >= qty) or (side == "B" and -(pos + wb) >= qty)
    if not reduces and (long > lim or -short > lim) then
      return false, string.format("лимит позиции %d (позиция %+d, в заявках +%d/-%d)", lim, pos, wb, ws)
    end
    return true
  end

  -- can we send a position-reducing passive order (take-profit, passive flatten)?
  function R.can_reduce(inst, t)
    local b = blocked()
    if b then return false, b end
    if X.O.halt then return false, "ОСТАНОВ: " .. X.O.halt end
    if X.panic and X.panic.stage ~= "done" then return false, "идёт PANIC" end
    if not R.connected() then return false, "нет связи с сервером" end
    if not inst.bk or not inst.bk.valid then return false, "нет стакана" end
    return true
  end

  ------------------------------------------------------------------
  -- TICK: daily loss, pause windows, warnings
  ------------------------------------------------------------------
  local was_pause, t_warn_otr, t_warn_rate, day = nil, -1e9, -1e9, nil
  function R.tick(t)
    local d = U.date("%Y%m%d", t)
    if day and d ~= day then
      -- new trading day: intraday statistics restart, open lots carry over, the journal keeps the history
      U.log("=== new day: intraday metrics and daily loss stop reset, open positions carried over ===")
      R.day_stop = false
      X.M.new_day(t)
      X.O.new_day()
      if X.inst then X.S.mark(X.inst) end
      X.S.mark_settings()
    end
    day = d
    local inst = X.inst
    if not inst then return end
    -- daily loss on session equity (all instruments, realized + open, net of fees)
    local eq = X.M.total_equity()
    if not R.day_stop and eq <= -(X.st.max_loss or 1e18) then
      R.day_stop = true
      U.alert(string.format("DAILY LOSS LIMIT: equity %.2f RUB <= -%s - trading stopped", eq, tostring(X.st.max_loss)), 3)
      if X.cfg.AUTO_PANIC_ON_LOSS ~= false then X.T.panic("дневной лимит убытка", t) end
    end
    -- entering a pause window (clearing, auction): resting quotes would face a re-priced market
    local pw = R.pause_window(inst, t)
    if pw and pw ~= was_pause and X.cfg.CANCEL_ON_PAUSE ~= false then
      local n = X.T.cancel_where(function(o) return o.mode ~= "taker" end, "pause", t)
      U.log(string.format("[%s] pause window '%s': %d order(s) cancelled", inst.sec, pw, n))
      X.say("Пауза: " .. pw .. (n > 0 and (", снято заявок " .. n) or ""))
    end
    was_pause = pw
    -- MOEX order-to-trade: warn (fees for erroneous transactions; check your broker's rules for inefficient ones)
    local st = X.O.st
    local otr = X.M.otr()
    if st.sent >= 50 and otr > (X.cfg.OTR_WARN or 20) and t - t_warn_otr > 300 then
      t_warn_otr = t
      U.alert(string.format("order-to-trade ratio %.1f (transactions per fill) is high - fewer requotes/cancels", otr), 2)
    end
    local pm = X.O.orders_last_min(t)
    if pm >= 0.8 * (X.cfg.MAX_ORDERS_PER_MIN or 60) and t - t_warn_rate > 60 then
      t_warn_rate = t
      U.alert(string.format("%d orders in the last minute (limit %d)", pm, X.cfg.MAX_ORDERS_PER_MIN or 60), 2)
    end
  end

  -- loss limit raised above the current loss in the settings window -> trading allowed again
  function R.on_limit_changed()
    if R.day_stop and X.M.total_equity() > -(X.st.max_loss or 0) then
      R.day_stop = false
      U.log("daily loss stop cleared: limit raised to " .. tostring(X.st.max_loss))
    end
  end

  return R
end
