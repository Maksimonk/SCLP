-- risk.lua : окна торговли, лимиты, паузы, достоверность данных, КРИТИЧЕСКИЕ ПОРОГИ.
--
-- Формулы порогов (подробно - docs/model.md):
--   издержки на сторону, тиков     c = (BROKER_FEE_RUB + EXCH_MAKER_FEE_RUB) / стоимость_тика
--   минимальный захват круга       C_min = max(1, ceil(2c + CAPTURE_SAFETY_TICKS))
--   лимит позиции по VaR           q_VaR = floor( VAR_BUDGET_FRAC * B / (VAR_Z * sigma * sqrt(VAR_H_SEC) * стоимость_тика) ),
--                                  B = DAILY_LOSS_LIMIT_RUB + итог_дня + открытые (остаток дневного бюджета)
--   стоп по волатильности          S = max(STOP_MIN_TICKS, ceil(VOL_STOP_K * sigma * sqrt(VOL_STOP_H_SEC)))
--   просадка дня от пика           peak - (итог + открытые) >= DAY_DD_LIMIT_RUB -> только закрытие
--   безубыточная доля прибыльных   p* = L / (W + L)  (W, L - средние выигрыш и проигрыш, в сводке)
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
      R.peak = 0
      if SC.O then SC.O.stats.err_tx = 0 end
      if SC.G then SC.G.reset_day() end
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
      if SC.paused then return false, "cmd_pause" end
      for _, c in ipairs(SC.C.active(inst, "real")) do
        if c.hard then return false, "hard_stop" end           -- идёт жёсткий стоп - новые пары не ставим
      end
      local act = SC.C.active(inst, "real")
      for _, c in ipairs(act) do
        -- в стакане одна пара за раз; пара, которая уже снимается целиком, следующей не мешает
        if c.state == "ENTRY" and R.entry_live(c) then return false, "busy" end
      end
      if #act >= R.max_cycles(inst) then return false, "max_cycles" end
    else
      for _, c in ipairs(SC.C.active(inst, "virtual", setup)) do
        if c.state == "ENTRY" and R.entry_live(c) then return false, "busy" end
      end
      if #SC.C.active(inst, "virtual", setup) >= R.max_cycles(inst) then return false, "max_cycles" end
    end
    if t < (R.pause_until[key] or 0) then return false, "streak_pause" end
    if t - (R.last_loss[key] or -1e9) < inst.P.LOSS_COOLDOWN_SEC then return false, "loss_cooldown" end
    return true
  end

  -- входная пара ещё "живая": хотя бы одна её заявка не снимается
  function R.entry_live(c)
    for _, o in ipairs(SC.C.live_orders(c)) do
      if not o.want_kill then return true end
    end
    return false
  end

  -- порог в тиках инструмента: NAME_TICKS, если задан, иначе NAME_PCT % от текущей цены (не меньше 1 тика)
  function R.thr(inst, name)
    local P = inst.P
    local tk = P[name .. "_TICKS"]
    if tk then return tk end
    local pct = P[name .. "_PCT"] or 0
    local s = inst.sig
    if not s.valid then return math.huge end
    return math.max(1, s.mid * pct / 100)
  end

  ------------------------------------------------------------------
  -- ИЗДЕРЖКИ И КРИТИЧЕСКИЕ ПОРОГИ
  ------------------------------------------------------------------
  -- издержки на одно исполнение (сторону), тиков
  function R.cost_ticks(inst)
    local P = inst.P
    local fee = (P.BROKER_FEE_RUB or 0) + (P.EXCH_MAKER_FEE_RUB or 0)
    local st = inst.step_price
    if fee <= 0 or not st or st <= 0 then return 0 end
    return fee / st
  end

  -- минимальный захват круга (покупка + продажа), тиков: покрыть две комиссии и запас
  function R.min_capture(inst)
    local P = inst.P
    return math.max(1, math.ceil(2 * R.cost_ticks(inst) + (P.CAPTURE_SAFETY_TICKS or 0) - 1e-9))
  end

  -- лимит позиции: MAX_POS, HARD_MAX_POS и VaR открытой позиции против остатка дневного бюджета
  function R.pos_cap(inst, backend)
    local P = inst.P
    local cap = math.min(P.MAX_POS, SC.cfg.HARD_MAX_POS)
    if not P.VAR_CAP then return cap end
    local sg = SC.A and SC.A.sigma(inst)
    local st = inst.step_price
    if not sg or not st or st <= 0 then return cap end
    local budget = SC.cfg.DAILY_LOSS_LIMIT_RUB + (R.pnl[backend or "real"] or 0)
    if (backend or "real") == "real" then budget = budget + math.min(0, R.unrealized or 0) end
    local per_lot = P.VAR_Z * sg * math.sqrt(P.VAR_H_SEC) * st
    if per_lot <= 0 then return cap end
    local q = math.floor(P.VAR_BUDGET_FRAC * math.max(0, budget) / per_lot)
    return math.min(cap, q)
  end

  -- порог стопа по цене, тиков: по волатильности (если включено и sigma известна), иначе STOP_TICKS
  function R.stop_ticks(inst)
    local P = inst.P
    local sg = SC.A and SC.A.sigma(inst)
    if (P.VOL_STOP_K or 0) > 0 and sg then
      return math.max(P.STOP_MIN_TICKS, math.ceil(P.VOL_STOP_K * sg * math.sqrt(P.VOL_STOP_H_SEC) - 1e-9))
    end
    return P.STOP_TICKS
  end

  function R.max_cycles(inst)
    local P = inst.P
    local n = P.MAX_REAL_CYCLES or 0
    if n <= 0 then n = math.max(1, math.floor(math.min(P.MAX_POS, SC.cfg.HARD_MAX_POS) / math.max(1, P.QUOTE_SIZE))) end
    return n
  end

  ------------------------------------------------------------------
  -- РЕЗКОЕ ДВИЖЕНИЕ: пауза входов на MOVE_PAUSE_SEC
  ------------------------------------------------------------------
  function R.watch_moves(inst, t)
    local P, s = inst.P, inst.sig
    if not s.valid then return end
    local why
    local w = P.MOVE_PAUSE_WINDOW_SEC
    local lo, hi = s.mid, s.mid
    local from = math.max(t - w, inst.move_reset_t or 0)   -- после срабатывания старый ход не считается заново
    for i = #inst.mids, 1, -1 do
      local m = inst.mids[i]
      if m.t < from then break end
      if m.mid < lo then lo = m.mid end
      if m.mid > hi then hi = m.mid end
    end
    if hi - lo >= R.thr(inst, "MOVE_PAUSE") then why = string.format("mid moved %.1f ticks in %g s", hi - lo, w) end
    local sw = inst.last_sweep
    if not why and sw and t - sw.t < 0.5 and sw.levels >= P.MOVE_PAUSE_SWEEP_LEVELS then
      why = string.format("sweep %d levels", sw.levels)
    end
    if not why and inst.ref then
      local rm = SC.K.ref_move(inst, t, w)
      if rm and abs(rm) >= R.thr(inst, "MOVE_PAUSE_REF") then why = string.format("ref moved %.1f ticks", rm) end
    end
    if why then
      if not inst.move_pause_until or t >= inst.move_pause_until then
        U.log(string.format("[%s] SHARP MOVE (%s): entries paused %d s", inst.sec, why, P.MOVE_PAUSE_SEC))
      end
      inst.move_pause_until = t + P.MOVE_PAUSE_SEC
      inst.move_reset_t = t
    end
  end
  function R.move_paused(inst, t) return inst.move_pause_until ~= nil and t < inst.move_pause_until end

  -- дневной лимит с учётом открытых позиций (выходы могут висеть до конца дня)
  function R.check_open_loss(t)
    if R.day_stop then return end
    local un = 0
    for _, c in ipairs(SC.C.active(nil, "real")) do
      local s = c.inst.sig
      if c.pos ~= 0 and c.avg and s.valid then un = un + (s.mid - c.avg) * c.pos * (c.inst.step_price or 0) end
    end
    R.unrealized = un
    local eq = (R.pnl.real or 0) + un
    R.peak = math.max(R.peak or 0, eq)
    local dd = SC.cfg.DAY_DD_LIMIT_RUB or 0
    if dd > 0 and R.peak - eq >= dd then
      R.day_stop = true
      U.alert(string.format("DRAWDOWN FROM DAY PEAK %.0f RUB (peak %.0f, now %.0f) - closing passively, no new entries",
        R.peak - eq, R.peak, eq))
      return
    end
    if eq <= -SC.cfg.DAILY_LOSS_LIMIT_RUB then
      R.day_stop = true
      U.alert(string.format("DAILY LOSS LIMIT incl. open positions: %.0f RUB - closing passively, no new entries",
        (R.pnl.real or 0) + un))
    end
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
    local maxpos = R.pos_cap(inst, backend)
    if maxpos < math.min(P.MAX_POS, SC.cfg.HARD_MAX_POS) and (pos + b + nb > maxpos or -(pos - s - ns) > maxpos) then
      return false, "var_cap"
    end
    if pos + b + nb > maxpos or -(pos - s - ns) > maxpos then return false, "max_pos" end
    if backend == "real" and not SC.O.can_send(t, #spec.legs) then return false, "tx_limit" end
    -- не встать против своей же заявки (кросс-сделка: биржа отклоняет и берёт сбор за ошибку)
    local min_sell, max_buy
    for _, o in ipairs(SC.O.all_live(inst, backend)) do
      if o.side == "S" and (not min_sell or o.px < min_sell) then min_sell = o.px end
      if o.side == "B" and (not max_buy or o.px > max_buy) then max_buy = o.px end
    end
    for _, l in ipairs(spec.legs) do
      if l.side == "B" and min_sell and l.px >= min_sell then return false, "self_cross" end
      if l.side == "S" and max_buy and l.px <= max_buy then return false, "self_cross" end
    end
    return true
  end

  -- закрывать ли позицию принудительно (фаза STOP)
  function R.force_exit(inst, c, t)
    local ss, flatten = R.session(t)
    if ss == "tail" and flatten then return true end
    if ss == "closed" then return true end
    if c.backend == "real" and SC.flatten then return true end
    if c.backend == "real" and (R.day_stop or SC.O.halt) then return true end
    if inst.disabled then return true end
    return false
  end

  ------------------------------------------------------------------
  -- ИТОГ ЦИКЛА
  ------------------------------------------------------------------
  function R.cycle_rub(c)
    local inst = c.inst
    return c.realized * (inst.step_price or 0) - (inst.P.BROKER_FEE_RUB or 0) * c.traded - (c.taker_fee or 0)
  end

  function R.on_cycle_done(c, t)
    SC.S.note_done(c)
    if c.traded == 0 then return end
    local rub = R.cycle_rub(c)
    local key = c.inst.sec .. c.backend
    if SC.G then SC.G.on_cycle_done(c, rub) end
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
