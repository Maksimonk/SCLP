-- mm.lua : ДИНАМИЧЕСКИЙ МАРКЕТ-МЕЙКИНГ С УПРАВЛЕНИЕМ ПОЗИЦИЕЙ (всё в тиках и лотах).
--
-- Авелланеда-Стойков (2008):
--   резервная цена   r = s - q * gamma * sigma^2 * tau          (s - справедливая цена из alpha.lua)
--   полный спред     2*delta = gamma * sigma^2 * tau + (2/gamma) * ln(1 + gamma/k)
-- Гэан-Леалль-Тапия (2013), асимптотическое решение в замкнутой форме (не зависит от T - t):
--   C       = sqrt( sigma^2 * gamma / (2 k A) * (1 + gamma/k)^(1 + k/gamma) )
--   delta_b = (1/gamma) ln(1 + gamma/k) + (2q + 1)/2 * C          (бид = s - delta_b)
--   delta_a = (1/gamma) ln(1 + gamma/k) - (2q - 1)/2 * C          (аск = s + delta_a)
-- Хо-Столл (1981): та же идея - спред и центр котировок сдвигаются против позиции; у GLT это член (2q +- 1)/2 * C.
-- A, k - интенсивность исполнения lambda(d) = A exp(-k d), калибруется по ленте (alpha.lua), до этого MM_A / MM_K.
--
-- Где применяется:
--   1) сетап MM - котировки ставятся прямо по формулам (по умолчанию "paper");
--   2) EXIT_MODE = "AS" - выход любого цикла (PAIR, TIGHT, MM): цена закрывающей стороны по формуле от СУММАРНОЙ
--      позиции инструмента. Чем больше позиция, тем ближе к рынку выход и дальше вход в ту же сторону.
return function(SC)
  local M = {}
  SC.M = M
  local U = SC.U
  local abs, floor, ceil, max, min, sqrt, log = math.abs, math.floor, math.ceil, math.max, math.min, math.sqrt, math.log

  -- параметры модели для инструмента: gamma, sigma (тик/sqrt с), A (1/с), k (1/тик)
  function M.params(inst, t)
    local P = inst.P
    local sg = SC.A.sigma_or(inst)
    local a, k = SC.A.ak(inst, t)
    if not a or P.MM_AK_FIXED then a, k = P.MM_A, P.MM_K end
    return P.MM_GAMMA, sg, a, k
  end

  -- отступы бида и аска от справедливой цены при позиции q (лоты)
  function M.deltas(inst, q, t)
    local P = inst.P
    local g, sg, a, k = M.params(inst, t)
    local base = (1 / g) * log(1 + g / k)
    if P.MM_MODEL == "AS" then
      local tau = P.MM_HORIZON_SEC
      local skew = q * g * sg * sg * tau                      -- r = s - skew
      local half = 0.5 * g * sg * sg * tau + base
      return half + skew, half - skew, base
    end
    local C = sqrt(sg * sg * g / (2 * k * a) * (1 + g / k) ^ (1 + k / g))
    local db = base + (2 * q + 1) / 2 * C
    local da = base - (2 * q - 1) / 2 * C
    return db, da, base, C
  end

  -- резервная цена (центр котировок с учётом позиции)
  function M.reservation(inst, q, fair, t)
    local db, da = M.deltas(inst, q, t)
    return fair + (da - db) / 2
  end

  -- предельная позиция по модели: перекос центра = базовому полуспреду (дальше вход в ту же сторону бессмыслен)
  --   GLT: q_max = base / C;   A-S: q_max = base / (gamma sigma^2 tau)
  function M.qmax(inst, t)
    local P = inst.P
    local g, sg = M.params(inst, t)
    local _, _, base, C = M.deltas(inst, 0, t)
    local per = (P.MM_MODEL == "AS") and (g * sg * sg * P.MM_HORIZON_SEC) or C
    if not per or per <= 1e-9 then return math.huge end
    return max(1, floor(base / per + 1e-9))
  end

  -- котировки (целые тики, пассивные): bid, ask; nil - сторону не котируем
  function M.quotes(inst, q, t)
    local P, s = inst.P, inst.sig
    local fair = SC.A.fair(inst, t)
    if not fair then return nil end
    local db, da = M.deltas(inst, q, t)
    local bid = floor(fair - db + 1e-9)
    local ask = ceil(fair + da - 1e-9)
    -- пассивность: не пересекать встречную лучшую цену
    bid = min(bid, s.ba - 1)
    ask = max(ask, s.bb + 1)
    -- минимальный захват с учётом издержек (брокер, биржа): иначе раздвигаем от справедливой цены
    local cmin = SC.R.min_capture(inst)
    if ask - bid < cmin then
      local need = cmin - (ask - bid)
      local down = ceil(need / 2)
      bid, ask = bid - down, ask + (need - down)
    end
    return bid, ask, fair
  end

  -- цена выхода для цикла при EXIT_MODE = "AS": закрывающая сторона котировки по суммарной позиции
  function M.exit_quote(inst, c, t)
    local q = SC.C.position(inst, c.backend)
    local bid, ask = M.quotes(inst, q, t)
    if not bid then return nil end
    return (c.pos > 0) and ask or bid
  end

  ------------------------------------------------------------------
  -- СЕТАП MM: котировки по GLT/A-S вокруг справедливой цены
  ------------------------------------------------------------------
  function M.propose(inst, backend, t)
    local P, s = inst.P, inst.sig
    local name = "MM"
    local nope = SC.S.nope
    if not SC.A.ready(inst) then return nope(inst, name, "warmup") end
    if SC.R.move_paused(inst, t) then return nope(inst, name, "sharp_move") end
    if SC.S.since_end(inst, name, backend, t) < P.MM_COOLDOWN_SEC then return nope(inst, name, "cooldown") end
    local reg = SC.A.regime(inst)
    if reg == "TOXIC" then return nope(inst, name, "toxic") end
    local q = SC.C.position(inst, backend)
    local bid, ask, fair = M.quotes(inst, q, t)
    if not bid then return nope(inst, name, "no_fair") end
    local qs = P.QUOTE_SIZE
    local qmax = min(M.qmax(inst, t), SC.R.pos_cap(inst, backend))
    local legs = {}
    local want_b = q + qs <= qmax
    local want_a = -(q - qs) <= qmax
    -- режим тренда: котировки против движения не ставим (одностороннее котирование)
    if reg == "UP" then want_a = want_a and q > 0 end      -- в росте не продаём, кроме разгрузки лонга
    if reg == "DN" then want_b = want_b and q < 0 end
    local G = SC.G
    if want_b and G.edge(inst, name, "B", bid, t) < P.EDGE_MIN_TICKS then want_b = false end
    if want_a and G.edge(inst, name, "S", ask, t) < P.EDGE_MIN_TICKS then want_a = false end
    if want_b then legs[#legs + 1] = { side = "B", px = bid, qty = qs } end
    if want_a then legs[#legs + 1] = { side = "S", px = ask, qty = qs } end
    if #legs == 0 then return nope(inst, name, (reg == "UP" or reg == "DN") and "trend" or "edge") end
    return {
      setup = name, pair = (#legs == 2), guarded = true,
      legs = legs,
      tp = function(c)
        for _, o in ipairs(c.legs) do if o.side ~= c.entry_side then return o.px end end
        local bq, aq = M.quotes(inst, SC.C.position(inst, c.backend), U.now())
        if c.pos > 0 then return max(aq or ceil(c.avg + 1), ceil(c.avg + SC.R.min_capture(inst) - 1e-9)) end
        return min(bq or floor(c.avg - 1), floor(c.avg - SC.R.min_capture(inst) + 1e-9))
      end,
      info = { fair = fair - s.mid, q = q, regime = reg, spread = s.spread },
    }
  end

  -- стоящие входные котировки: переставить, если модель хочет другую цену
  function M.check(c, t)
    local inst, P, s = c.inst, c.inst.P, c.inst.sig
    if not s.valid then return "nobook" end
    if t - c.t0 > P.MM_TTL_SEC then return "ttl" end
    if SC.R.move_paused(inst, t) then return "sharp_move" end
    local reg = SC.A.regime(inst)
    if reg == "TOXIC" then return "toxic" end
    if t - c.t0 < P.MM_MIN_LIFE_SEC then return nil end
    local q = SC.C.position(inst, c.backend)
    local bid, ask = M.quotes(inst, q, t)
    if not bid then return "nofair" end
    for _, o in ipairs(SC.C.live_orders(c)) do
      if o.side == "B" and reg == "DN" and q >= 0 then return "trend" end
      if o.side == "S" and reg == "UP" and q <= 0 then return "trend" end
      local want = (o.side == "B") and bid or ask
      -- стоим агрессивнее модели (риск) - переставить сразу; модель хочет ближе к рынку - только при заметной разнице
      -- (перестановка = конец очереди)
      local worse = (o.side == "B" and o.px > want) or (o.side == "S" and o.px < want)
      if abs(o.px - want) >= (worse and P.MM_REQUOTE_TICKS or P.MM_IMPROVE_TICKS) then return "requote" end
    end
    return nil
  end

  return M
end
