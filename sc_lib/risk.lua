-- risk.lua : окна торговли, лимиты, паузы, достоверность данных.
return function(SC)
  local R = {}
  SC.R = R
  local U = SC.U
  local abs = math.abs

  R.day = nil
  R.pnl = {}            -- [backend] = руб. за день
  R.inst_pnl = {}       -- [sec .. backend] = руб.
  R.streak = {}         -- [sec .. backend] = убыточных подряд
  R.pause_until = {}    -- [sec .. backend] = время
  R.last_loss = {}      -- [sec .. backend] = время
  R.day_stop = false

  function R.check_day(t)
    local d = U.date("%Y%m%d", t)
    if d ~= R.day then
      if R.day then U.log("=== new day: daily counters reset ===") end
      R.day = d
      R.pnl = { real = 0, virtual = 0 }
      R.inst_pnl, R.streak, R.pause_until, R.last_loss = {}, {}, {}, {}
      R.day_stop = false
      if SC.O then SC.O.stats.err_tx = 0 end
    end
  end

  ------------------------------------------------------------------
  -- ОКНА ТОРГОВЛИ: "closed" | "open" | "tail" (без новых входов, позицию закрываем)
  ------------------------------------------------------------------
  function R.session(t)
    local wd = U.weekday(t)
    local weekend = (wd == 1 or wd == 7)
    local list = weekend and SC.cfg.SESSIONS_WEEKEND or SC.cfg.SESSIONS
    if not list or #list == 0 then return "closed" end
    local now = U.msk_sec(t)
    for _, w in ipairs(list) do
      local a, b = U.hms(w[1]), U.hms(w[2])
      if a and b and now >= a and now < b then
        local tail = w[5] or 600
        if now >= b - tail then return "tail", w[3] ~= false end
        return "open"
      end
    end
    return "closed"
  end

  ------------------------------------------------------------------
  -- ДАННЫЕ
  ------------------------------------------------------------------
  function R.data_ok(inst, t)
    if not inst.sig.valid then return false, "no_book" end
    if isConnected and not SC.clock then
      local ok, v = pcall(isConnected)
      if ok and v ~= 1 then return false, "disconnected" end
    end
    local tc = inst.t_book_change or 0
    if inst.t_last_trade and t - tc > SC.cfg.STALE_BOOK_SEC and t - inst.t_last_trade < SC.cfg.STALE_BOOK_SEC then
      inst.t_data_bad = t
      return false, "book_frozen"
    end
    if t - tc > SC.cfg.STALE_MAX_SEC then inst.t_data_bad = t; return false, "book_stale" end
    if inst.t_data_bad and t - inst.t_data_bad < SC.cfg.DATA_RECOVER_SEC then return false, "data_recover" end
    return true
  end

  ------------------------------------------------------------------
  -- МОЖНО ЛИ ОТКРЫВАТЬ
  ------------------------------------------------------------------
  local function note(inst, setup, why)
    local a = SC.S.why_not[inst.sec] or {}
    SC.S.why_not[inst.sec] = a
    local b = a[setup] or {}
    a[setup] = b
    b[why] = (b[why] or 0) + 1
    return false, why
  end

  function R.can_open(inst, backend, setup, t)
    if t < (SC.t_start or 0) + SC.cfg.STARTUP_SETTLE_SEC then return false, "startup" end
    local ss = R.session(t)
    if ss ~= "open" then return false, "session_" .. ss end
    local ok, why = R.data_ok(inst, t)
    if not ok then return false, why end
    if inst.disabled then return false, "disabled" end
    local key = inst.sec .. backend
    if backend == "real" then
      if SC.O.halt then return false, "halt" end
      if t < SC.O.pause_until then return false, "reject_pause" end
      if R.day_stop then return false, "day_loss" end
      if SC.O.stats.err_tx >= SC.cfg.MAX_ERR_TX_PER_DAY then return false, "err_tx_limit" end
      if inst.foreign_block then return note(inst, setup, "foreign_orders") end
      local lim = inst.P.INST_LOSS_LIMIT_RUB or 0
      if lim > 0 and (R.inst_pnl[key] or 0) <= -lim then return false, "inst_loss" end
      local n = #SC.C.active(inst, "real")
      if n >= inst.P.MAX_REAL_CYCLES then return false, "busy" end
    else
      if #SC.C.active(inst, "virtual", setup) > 0 then return false, "busy" end
    end
    if t < (R.pause_until[key] or 0) then return false, "streak_pause" end
    if t - (R.last_loss[key] or -1e9) < inst.P.LOSS_COOLDOWN_SEC then return false, "loss_cooldown" end
    return true
  end

  -- вписывается ли новый вход в лимиты позиции (худший случай: исполнится всё стоящее)
  function R.fits(inst, backend, spec, t)
    local P = inst.P
    local pos = SC.C.position(inst, backend)
    local b, s = SC.O.open_qty(inst, backend)
    local nb, ns = 0, 0
    for _, l in ipairs(spec.legs) do
      if l.side == "B" then nb = nb + l.qty else ns = ns + l.qty end
    end
    local maxpos = math.min(P.MAX_POS, SC.cfg.HARD_MAX_POS)
    if pos + b + nb > maxpos or -(pos - s - ns) > maxpos then return false, "max_pos" end
    if backend == "real" and not SC.O.can_send(t, #spec.legs) then return false, "tx_limit" end
    return true
  end

  -- закрывать ли позицию принудительно (фаза STOP)
  function R.force_exit(inst, c, t)
    local ss, flatten = R.session(t)
    if ss == "tail" and flatten then return true end
    if ss == "closed" then return true end
    if c.backend == "real" and (R.day_stop or SC.O.halt) then return true end
    if inst.disabled then return true end
    return false
  end

  ------------------------------------------------------------------
  -- ИТОГ ЦИКЛА
  ------------------------------------------------------------------
  function R.cycle_rub(c)
    local inst = c.inst
    return c.realized * (inst.step_price or 0) - (inst.P.BROKER_FEE_RUB or 0) * c.traded
  end

  function R.on_cycle_done(c, t)
    SC.S.note_done(c)
    if c.traded == 0 then return end
    local rub = R.cycle_rub(c)
    local key = c.inst.sec .. c.backend
    R.pnl[c.backend] = (R.pnl[c.backend] or 0) + rub
    R.inst_pnl[key] = (R.inst_pnl[key] or 0) + rub
    if c.realized < 0 then
      R.last_loss[key] = t
      R.streak[key] = (R.streak[key] or 0) + 1
      if R.streak[key] >= c.inst.P.MAX_LOSS_STREAK then
        R.pause_until[key] = t + c.inst.P.STREAK_PAUSE_SEC
        U.log(string.format("[%s/%s] %d losing cycles in a row - pause %d s", c.inst.sec, c.backend,
          R.streak[key], c.inst.P.STREAK_PAUSE_SEC))
        R.streak[key] = 0
      end
    elseif c.realized > 0 then
      R.streak[key] = 0
    end
    if c.backend == "real" and not R.day_stop and R.pnl.real <= -SC.cfg.DAILY_LOSS_LIMIT_RUB then
      R.day_stop = true
      U.alert(string.format("DAILY LOSS LIMIT: %.0f RUB - no new entries today, positions close passively", R.pnl.real))
    end
  end

  return R
end
