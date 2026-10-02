-- stats.lua : статистика сетапов, журналы scalp_cycles (циклы) и scalp_fills (маркауты входов).
-- Маркаут входа = насколько середина через 1/5/30 с ушла в нашу сторону от цены исполнения (тики, + хорошо).
return function(SC)
  local ST = {}
  SC.ST = ST
  local U = SC.U
  local abs = math.abs

  ST.agg = {}          -- [sec|setup|backend] = счётчики
  local pend = {}      -- маркауты в ожидании

  local function A(c)
    local k = c.inst.sec .. "|" .. c.setup .. "|" .. c.backend
    local a = ST.agg[k]
    if not a then
      a = { sec = c.inst.sec, setup = c.setup, backend = c.backend, open = 0, rej_boc = 0, rej_other = 0,
            nofill = 0, filled = 0, both = 0, wins = 0, losses = 0, flat = 0, ticks = 0, rub = 0,
            cancel = {}, phase = {}, mk = { 0, 0, 0 }, mk_n = 0 }
      ST.agg[k] = a
    end
    return a
  end

  function ST.on_open(c) A(c).open = A(c).open + 1 end

  function ST.on_fill(c, o, q, px, t)
    if o.role ~= "entry" then return end
    local s = c.inst.sig
    pend[#pend + 1] = { t = t, c = c, sgn = (o.side == "B") and 1 or -1, px = px, q = q,
                        mid0 = s.valid and s.mid or px, spread = s.spread, imb = s.imb1 }
  end

  local function mid_at(inst, t)
    local m = inst.mids
    for i = #m, 1, -1 do if m[i].t <= t then return m[i].mid end end
    return m[1] and m[1].mid
  end

  local function flush_marks(t, force)
    local keep = {}
    for _, f in ipairs(pend) do
      if force or t >= f.t + 30 then
        local inst = f.c.inst
        local mk = {}
        for i, h in ipairs({ 1, 5, 30 }) do
          local m = (t >= f.t + h) and mid_at(inst, f.t + h) or nil
          mk[i] = m and f.sgn * (m - f.px) or nil
        end
        local a = A(f.c)
        if mk[3] then
          a.mk_n = a.mk_n + 1
          for i = 1, 3 do a.mk[i] = a.mk[i] + (mk[i] or 0) end
        end
        U.csv("scalp_fills", "date,time,sec,setup,backend,side,px,qty,mid0,spread,imb,mk1,mk5,mk30",
          table.concat({ U.date("%Y-%m-%d", f.t), U.date("%H:%M:%S", f.t) .. string.format(".%03d", math.floor((f.t % 1) * 1000)),
            inst.sec, f.c.setup, f.c.backend, f.sgn > 0 and "B" or "S", inst:price_str(f.px), f.q,
            U.fmt(f.mid0, 1), f.spread or "", U.fmt(f.imb, 2),
            U.fmt(mk[1], 1), U.fmt(mk[2], 1), U.fmt(mk[3], 1) }, ","))
      else
        keep[#keep + 1] = f
      end
    end
    pend = keep
  end

  function ST.on_done(c)
    local a = A(c)
    local inst = c.inst
    if c.traded == 0 then
      if c.reject_kind == "boc" then a.rej_boc = a.rej_boc + 1
      elseif c.reject_kind then a.rej_other = a.rej_other + 1
      else a.nofill = a.nofill + 1 end
      local why = c.cancel_why or (c.reject_kind and ("reject_" .. c.reject_kind)) or "?"
      a.cancel[why] = (a.cancel[why] or 0) + 1
      return
    end
    a.filled = a.filled + 1
    if c.pair and c.n_filled_legs >= 1 then
      -- обе ноги пары исполнились как задумано (вторая - тейком)
      local legs_filled = 0
      for _, o in ipairs(c.legs) do if o.filled > 0 then legs_filled = legs_filled + 1 end end
      if legs_filled >= 2 then a.both = a.both + 1 end
    end
    local per_lot = c.realized / math.max(1, c.traded / 2)
    if c.realized > 0 then a.wins = a.wins + 1 elseif c.realized < 0 then a.losses = a.losses + 1 else a.flat = a.flat + 1 end
    a.ticks = a.ticks + c.realized
    local rub = SC.R.cycle_rub(c)
    a.rub = a.rub + rub
    local ph = c.phase or "TP"
    a.phase[ph] = (a.phase[ph] or 0) + 1
    local entry = c.fills[1]
    local last = c.fills[#c.fills]
    local info = {}
    for k, v in pairs(c.info or {}) do info[#info + 1] = k .. "=" .. (type(v) == "number" and U.fmt(v, 2) or tostring(v)) end
    table.sort(info)
    U.csv("scalp_cycles",
      "date,time,sec,setup,backend,side,qty,entry,exit,pnl_ticks,pnl_ticks_per_lot,pnl_rub,hold_sec,exit_phase,legs_filled,info",
      table.concat({ U.date("%Y-%m-%d", c.t0), U.date("%H:%M:%S", c.t0), inst.sec, c.setup, c.backend,
        entry and entry.side or "", c.traded / 2,
        entry and inst:price_str(entry.px) or "", last and inst:price_str(last.px) or "",
        U.fmt(c.realized, 1), U.fmt(per_lot, 2), U.fmt(rub, 2),
        U.fmt((c.t_done or c.t0) - (c.t_pos or c.t0), 1), ph, c.n_filled_legs, table.concat(info, " ") }, ","))
    U.log(string.format("[%s] %s/%s cycle %d done: %s%d @ %s -> %s, %+.1f ticks, %+.2f RUB, phase %s",
      inst.sec, c.setup, c.backend, c.id, entry and entry.side or "?", c.traded / 2,
      entry and inst:price_str(entry.px) or "?", last and inst:price_str(last.px) or "?", c.realized, rub, ph))
  end

  local last_hb
  function ST.summary()
    local lines = {}
    local keys = {}
    for k in pairs(ST.agg) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
      local a = ST.agg[k]
      local n = a.wins + a.losses + a.flat
      local reasons = {}
      for w, cnt in pairs(a.cancel) do reasons[#reasons + 1] = { w, cnt } end
      table.sort(reasons, function(x, y) return x[2] > y[2] end)
      local rs = {}
      for i = 1, math.min(4, #reasons) do rs[#rs + 1] = reasons[i][1] .. ":" .. reasons[i][2] end
      local mk = a.mk_n > 0 and string.format(" mk1/5/30 %+.2f/%+.2f/%+.2f", a.mk[1] / a.mk_n, a.mk[2] / a.mk_n, a.mk[3] / a.mk_n) or ""
      lines[#lines + 1] = string.format("%s %s/%s: open %d, boc-rej %d, nofill %d [%s], filled %d (pair both %d), win %d/%d, %+.1f ticks, %+.0f RUB%s",
        a.sec, a.setup, a.backend, a.open, a.rej_boc, a.nofill, table.concat(rs, " "), a.filled, a.both,
        a.wins, n, a.ticks, a.rub, mk)
    end
    return lines
  end

  function ST.tick(t)
    flush_marks(t)
    for _, inst in ipairs(SC.insts) do SC.K.flush_episodes(inst, t) end
    local hb = SC.cfg.HEARTBEAT_SEC or 60
    if not last_hb then last_hb = t end
    if t - last_hb >= hb then
      last_hb = t
      local O = SC.O.stats
      U.log(string.format("HEARTBEAT pnl real %+.0f / virtual %+.0f RUB | tx %d new %d kill %d boc-rej %d other-rej %d err %d%s",
        SC.R.pnl.real or 0, SC.R.pnl.virtual or 0, O.tx, O.new, O.kill, O.rej_boc, O.rej_other, O.err_tx,
        SC.O.halt and (" | HALT: " .. SC.O.halt) or ""))
      for _, l in ipairs(ST.summary()) do U.log("  " .. l) end
      for sec, setups in pairs(SC.S.why_not) do
        for name, reasons in pairs(setups) do
          local r = {}
          for w, cnt in pairs(reasons) do r[#r + 1] = { w, cnt } end
          table.sort(r, function(x, y) return x[2] > y[2] end)
          local s = {}
          for i = 1, math.min(5, #r) do s[#s + 1] = r[i][1] .. ":" .. r[i][2] end
          U.log(string.format("  %s %s skipped (checks): %s", sec, name, table.concat(s, " ")))
        end
      end
      SC.S.why_not = {}
    end
  end

  function ST.final(t)
    flush_marks(t, true)
    for _, inst in ipairs(SC.insts) do SC.K.flush_episodes(inst, t, true) end
    for _, l in ipairs(ST.summary()) do U.log("FINAL " .. l) end
  end

  return ST
end
