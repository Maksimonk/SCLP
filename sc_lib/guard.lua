-- guard.lua : ФИЛЬТР НЕБЛАГОПРИЯТНОГО ОТБОРА (adverse selection).
--
-- 1. Ожидаемый перевес заявки (тики, на одно исполнение):
--      edge = pred + AS - cost,    pred = fair - px (покупка) | px - fair (продажа)
--    AS   - выученная поправка на отбор: E[маркаут через AS_H_SEC - pred | исполнение] по сетапу. Отрицательна, когда
--           исполняет нас тот, кто знает больше (цену "протаскивают" сквозь нас). Пока исполнений мало - априорная
--           -AS_PRIOR_TICKS с весом AS_PRIOR_N исполнений.
--    cost - издержки на сторону: (BROKER_FEE_RUB + EXCH_MAKER_FEE_RUB) / стоимость тика.
--    Вход ставится, только если edge >= EDGE_MIN_TICKS по каждой ноге (у пары - по обеим).
-- 2. Cancel-on-Mismatch: стоящая входная заявка снимается, если edge < -EDGE_CANCEL_TICKS, или если она подошла к
--    голове очереди (впереди <= QUEUE_FRONT_LOTS) и edge стал < 0 - исполнение вот-вот случится и будет в минус.
-- 3. Режим рынка (alpha.lua): TOXIC (VPIN / всплеск волатильности) - новых входов нет; тренд (|z| >= REGIME_Z) -
--    симметричные пары не ставятся (MM котирует одну сторону).
-- 4. Автоотключение: реальные циклы сетапа за день (последние GUARD_N) в минусе со статистикой
--    t = mean / (sd / sqrt n) <= -GUARD_T -> сетап до конца дня торгует ВИРТУАЛЬНО (статистика копится дальше).
return function(SC)
  local G = {}
  SC.G = G
  local U = SC.U
  local abs, sqrt, min, max = math.abs, math.sqrt, math.min, math.max

  G.as = {}          -- [lkey|setup] = { n, m } (обучаемое, переживает перезапуск)
  G.pend = {}        -- исполнения входа, ждут маркаута
  G.ring = {}        -- [sec|setup] = рубли последних реальных циклов (за день)
  G.demoted = {}     -- [sec|setup] = причина (за день)

  local function akey(inst, setup) return (inst.lkey or inst.sec) .. "|" .. setup end

  -- поправка на отбор, тиков (обычно < 0)
  function G.bias(inst, setup)
    local P = inst.P
    local prior, n0 = -P.AS_PRIOR_TICKS, P.AS_PRIOR_N
    local e = G.as[akey(inst, setup)]
    if not e or e.n == 0 then return prior end
    local w = min(e.n, P.AS_TAU_N)
    return (prior * n0 + e.m * w) / (n0 + w)
  end

  -- перевес заявки: edge, pred (без поправки и издержек)
  function G.edge(inst, setup, side, px, t)
    local fair = (inst.A and inst.A.fair_t == t and inst.A.fair) or SC.A.fair(inst, t)
    if not fair then return -math.huge, 0 end
    local pred = (side == "B") and (fair - px) or (px - fair)
    return pred + G.bias(inst, setup) - SC.R.cost_ticks(inst), pred
  end

  ------------------------------------------------------------------
  -- ФИЛЬТР НОВОГО ВХОДА (PAIR, TIGHT, WALL...; MM считает сам; тейкерские сетапы - мимо)
  ------------------------------------------------------------------
  function G.filter(inst, spec, t)
    local P = inst.P
    if spec.guarded or spec.taker then return true end
    if P.REGIME_GATE then
      local reg = SC.A.regime(inst)
      if reg == "TOXIC" then return false, "toxic" end
      if spec.pair and (reg == "UP" or reg == "DN") then return false, "trend" end
      if not spec.pair and spec.legs[1] then
        local side = spec.legs[1].side
        if (reg == "UP" and side == "S") or (reg == "DN" and side == "B") then return false, "trend" end
      end
    end
    if not P.GUARD_EDGE then return true end
    for _, l in ipairs(spec.legs) do
      local e = G.edge(inst, spec.setup, l.side, l.px, t)
      if e < P.EDGE_MIN_TICKS then return false, "edge" end
    end
    return true
  end

  -- при открытии цикла запомнить прогноз по каждой ноге
  function G.on_open(c, t)
    for _, o in ipairs(c.legs) do
      local _, pred = G.edge(c.inst, c.setup, o.side, o.px, t)
      o.pred = pred
    end
  end

  ------------------------------------------------------------------
  -- CANCEL-ON-MISMATCH (стоящие входные заявки)
  ------------------------------------------------------------------
  function G.entry_check(c, t)
    local inst, P = c.inst, c.inst.P
    if not P.GUARD_EDGE or c.no_guard then return nil end
    for _, o in ipairs(SC.C.live_orders(c)) do
      if o.role == "entry" and not o.taker and not o.want_kill then
        local e, pred = G.edge(inst, c.setup, o.side, o.px, t)
        o.pred = pred
        if e < -P.EDGE_CANCEL_TICKS then return "edge" end
        local ahead = o.q_ahead
        if P.QUEUE_CANCEL and o.state == "active" and ahead and ahead <= P.QUEUE_FRONT_LOTS and e < 0 then
          return "mismatch"
        end
      end
    end
    return nil
  end

  ------------------------------------------------------------------
  -- ОБУЧЕНИЕ ПОПРАВКИ НА ОТБОР (маркаут исполнений входа)
  ------------------------------------------------------------------
  function G.on_fill(c, o, q, px, t)
    if o.role ~= "entry" or o.taker then return end
    local pred = o.pred
    if pred == nil then local _; _, pred = G.edge(c.inst, c.setup, o.side, px, t) end
    G.pend[#G.pend + 1] = { t = t, inst = c.inst, setup = c.setup, sgn = (o.side == "B") and 1 or -1, px = px,
                            pred = pred, q = q }
  end

  local function mid_at(inst, t)
    local m = inst.mids
    for i = #m, 1, -1 do if m[i].t <= t then return m[i].mid end end
    return m[1] and m[1].mid
  end

  function G.tick(t)
    if #G.pend == 0 then return end
    local keep = {}
    for _, f in ipairs(G.pend) do
      local H = f.inst.P.AS_H_SEC
      if t >= f.t + H then
        local m = mid_at(f.inst, f.t + H)
        if m then
          local mk = f.sgn * (m - f.px)
          local res = U.clamp(mk - f.pred, -f.inst.P.VOL_CLIP_TICKS, f.inst.P.VOL_CLIP_TICKS)
          local k = akey(f.inst, f.setup)
          local e = G.as[k] or { n = 0, m = 0 }
          G.as[k] = e
          e.n = e.n + 1
          e.m = e.m + (res - e.m) / min(e.n, f.inst.P.AS_TAU_N)
        end
      else
        keep[#keep + 1] = f
      end
    end
    G.pend = keep
  end

  ------------------------------------------------------------------
  -- АВТООТКЛЮЧЕНИЕ СЕТАПА (реальные циклы в минусе статистически значимо)
  ------------------------------------------------------------------
  function G.on_cycle_done(c, rub)
    if c.backend ~= "real" or c.traded == 0 then return end
    local P = c.inst.P
    local k = c.inst.sec .. "|" .. c.setup
    local r = G.ring[k] or {}
    G.ring[k] = r
    r[#r + 1] = rub
    while #r > P.GUARD_N do table.remove(r, 1) end
    if not P.GUARD_DEMOTE or G.demoted[k] or #r < P.GUARD_MIN then return end
    local n, s = #r, 0
    for i = 1, n do s = s + r[i] end
    local mean = s / n
    local v = 0
    for i = 1, n do v = v + (r[i] - mean) ^ 2 end
    local sd = sqrt(v / max(1, n - 1))
    local tstat = (sd > 1e-9) and mean / (sd / sqrt(n)) or (mean < 0 and -math.huge or 0)
    if mean < 0 and tstat <= -P.GUARD_T then
      G.demoted[k] = string.format("%d cycles, mean %.2f RUB, t %.1f", n, mean, tstat)
      U.alert(string.format("[%s] %s LOSES (%s) - switched to VIRTUAL until the end of the day",
        c.inst.sec, c.setup, G.demoted[k]))
    end
  end

  function G.is_demoted(inst, setup) return G.demoted[inst.sec .. "|" .. setup] ~= nil end

  function G.reset_day()
    G.ring, G.demoted = {}, {}
  end

  -- строки для сводки: поправка на отбор по сетапам
  function G.summary()
    local r = {}
    for k, e in pairs(G.as) do r[#r + 1] = string.format("%s AS %+.2f (n %d)", k, e.m, e.n) end
    table.sort(r)
    return r
  end

  function G.dump() return G.as end
  function G.load(t) for k, v in pairs(t or {}) do G.as[k] = v end end

  return G
end
