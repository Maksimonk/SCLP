-- alpha.lua : СПРАВЕДЛИВАЯ ЦЕНА И МИКРОСТРУКТУРНЫЕ СИГНАЛЫ (всё в тиках инструмента).
--
--   fair = mid + G(I1, S, OBI_k) + kf * flow + kl * lead
--     G      - таблица микроцены Стойкова: средний сдвиг середины через MICRO_H_SEC при данном дисбалансе L1,
--              спреде и знаке OBI_k. Учится на своих данных; пока ячейка не набрала MICRO_MIN_N наблюдений -
--              формула P_micro = (Vb*Pa + Va*Pb) / (Vb + Va) с весом MICRO_W.
--     flow   - дрейф от потока рыночных заявок (Cartea-Jaimungal): EWMA (покупки - продажи) / глубину L1.
--     lead   - lead-lag: движение опорного (BR для BM) за LEAD_WIN_SEC, ещё не отыгранное инструментом.
--     kf, kl - регрессия остатка (dmid_H - G) на flow и lead (EWMA-моменты, МНК 2x2); до обучения - FLOW_KAPPA / LEAD_BETA.
--
--   sigma    - волатильность середины, тиков/sqrt(с): длинная (VOL_TAU_SEC) и быстрая (VOL_FAST_TAU_SEC).
--   regime   - "MR" (возврат к среднему) | "UP"/"DN" (тренд: |z| = |dmid_W| / (sigma*sqrt W) >= REGIME_Z) |
--              "TOXIC" (VPIN выше критического или быстрая sigma > REGIME_VOL_RATIO x длинной).
--   CVD      - дельта рыночных объёмов (покупки - продажи) по квантам CVD_QUANTUM_SEC, z-оценка скорости.
--   VPIN     - Easley-Lopez de Prado-O'Hara: среднее |Vbuy - Vsell| / V по VPIN_N объёмным корзинам.
--              Сторона агрессора берётся из флагов ленты QUIK (точная, без BVC).
--   A, k     - интенсивность исполнения лимитки на расстоянии d от середины: lambda(d) = A * exp(-k d)
--              (для формул Гэана-Леалля-Тапии), оценка по ленте.
--   айсберги - на уровне исполнилось больше ICE_K x видимого объёма, а уровень стоит.
--   очередь  - оценка объёма впереди наших заявок (сделки по нашей цене + доля снятий).
return function(SC)
  local A = {}
  SC.A = A
  local U = SC.U
  local exp, abs, floor, max, min, sqrt, log = math.exp, math.abs, math.floor, math.max, math.min, math.sqrt, math.log

  local function ewa(dt, tau) return 1 - exp(-max(0, dt) / max(1e-6, tau)) end

  ------------------------------------------------------------------
  -- ОБУЧАЕМОЕ (переживает перезапуск и смену контракта: ключ - BASE, файл scalp_alpha.txt)
  ------------------------------------------------------------------
  A.learn = {}                 -- [lkey] = { micro = {[cell] = {n, m}}, reg = {...}, sig2, vrate, ak = {...} }
  local function L(inst)
    local k = inst.lkey or inst.sec
    local l = A.learn[k]
    if not l then
      l = { micro = {}, reg = { n = 0, xx = 0, xz = 0, zz = 0, xy = 0, zy = 0 }, ak = { cnt = {}, T = 0 } }
      A.learn[k] = l
    end
    return l
  end
  A.L = L

  function A.new(inst)
    inst.A = {
      t_vs = nil, mid_vs = nil, sig2 = nil, sig2f = nil, n_vs = 0,
      pend = {}, t_sample = 0,
      fb = 0, fs = 0, t_flow = nil,
      q_t0 = nil, q_dv = 0, quanta = {}, cv_m = 0, cv_v = 0, cv_n = 0,
      vb = 0, vbuy = 0, vsell = 0, vsize = nil, buckets = {}, vpin = nil, vhist = {}, vrate = nil, t_vr = nil,
      t_ak = nil,
      ice = { B = {}, S = {} }, iceberg = nil,
      regime = "MR", z = 0, t_regime = 0,
      obik = 0,
    }
    local l = L(inst)
    if l.sig2 then inst.A.sig2 = l.sig2; inst.A.sig2f = l.sig2; inst.A.n_vs = 30 end
    if l.vrate then inst.A.vrate = l.vrate end
  end

  ------------------------------------------------------------------
  -- OBI по k уровням (как в формуле: простая сумма объёмов, без весов) и микроцена
  ------------------------------------------------------------------
  function A.obi(inst, k)
    local nb = inst.net
    if not nb then return 0 end
    k = k or inst.P.OBI_LEVELS
    local vb, va = 0, 0
    for i = 1, k do
      local b, a = nb.bids[i], nb.asks[i]
      if b then vb = vb + b.q end
      if a then va = va + a.q end
    end
    if vb + va <= 0 then return 0 end
    return (vb - va) / (vb + va)
  end

  -- P_micro = (Vb * Pa + Va * Pb) / (Vb + Va) - в тиках
  function A.micro(inst)
    local s = inst.sig
    return (s.bq * s.ba + s.aq * s.bb) / (s.bq + s.aq)
  end

  local function cell(inst)
    local s, P = inst.sig, inst.P
    local i = s.imb1
    local ib = (i < -0.6) and 1 or (i < -0.2) and 2 or (i <= 0.2) and 3 or (i <= 0.6) and 4 or 5
    local sb = min(s.spread, 3)
    local o = inst.A.obik
    local ob = (o < -P.OBI_NEUTRAL) and 1 or (o > P.OBI_NEUTRAL) and 3 or 2
    return ib * 100 + sb * 10 + ob
  end
  A.cell = cell

  -- поправка микроцены к середине, тиков
  function A.G(inst)
    local s, P = inst.sig, inst.P
    if P.MICRO_LEARN then
      local c = L(inst).micro[cell(inst)]
      if c and c.n >= P.MICRO_MIN_N then return c.m, true end
    end
    return P.MICRO_W * (A.micro(inst) - s.mid), false
  end

  ------------------------------------------------------------------
  -- ПОТОК СДЕЛОК (Cartea-Jaimungal): EWMA покупок/продаж рынком
  ------------------------------------------------------------------
  local function flow_decay(a, P, t)
    if a.t_flow then
      local k = exp(-max(0, t - a.t_flow) / P.FLOW_TAU_SEC)
      a.fb, a.fs = a.fb * k, a.fs * k
    end
    a.t_flow = t
  end
  -- нормированный дисбаланс потока: (buy - sell) / средняя глубина L1
  function A.flow(inst, t)
    local a, s = inst.A, inst.sig
    flow_decay(a, inst.P, t)
    local d = (s.depth and s.depth > 0) and s.depth or 1
    return (a.fb - a.fs) / d
  end

  ------------------------------------------------------------------
  -- LEAD-LAG: опорный ушёл (в %), а инструмент ещё нет -> тиков, на которые инструмент "должен" сдвинуться
  ------------------------------------------------------------------
  local function at(list, t, field)
    for i = #list, 1, -1 do
      if list[i].t <= t then return list[i][field] end
    end
    return list[1] and list[1][field]
  end
  function A.lead(inst, t)
    local R, s = inst.ref, inst.sig
    if not R or not R.valid or not R.micros or #R.micros == 0 or not s.valid then return 0 end
    if t - (R.t_read or 0) > inst.P.REF_STALE_SEC then return 0 end
    local w = inst.P.LEAD_WIN_SEC
    local r1, r0 = R.micros[#R.micros].v, at(R.micros, t - w, "v")
    local m0 = at(inst.mids, t - w, "mid")
    if not r0 or r0 <= 0 or not m0 or m0 <= 0 then return 0 end
    local r = (r1 / r0 - 1) * s.mid                 -- движение опорного в тиках инструмента
    local o = (s.mid / m0 - 1) * s.mid               -- своё движение
    -- сигнал даёт только опорный: неотыгранная часть его хода (своё движение без опорного - не сигнал)
    local lead = 0
    if r > 0 then lead = max(0, r - max(0, o)) elseif r < 0 then lead = min(0, r - min(0, o)) end
    return U.clamp(lead, -inst.P.LEAD_CLIP_TICKS, inst.P.LEAD_CLIP_TICKS)
  end

  ------------------------------------------------------------------
  -- СПРАВЕДЛИВАЯ ЦЕНА
  ------------------------------------------------------------------
  local function coefs(inst)
    local P, r = inst.P, L(inst).reg
    local kf, kl = P.FLOW_KAPPA, P.LEAD_BETA
    if P.FAIR_LEARN and r.n >= P.FAIR_MIN_N then
      local det = r.xx * r.zz - r.xz * r.xz
      if det > 1e-9 then
        local bf = (r.xy * r.zz - r.zy * r.xz) / det
        local bl = (r.zy * r.xx - r.xy * r.xz) / det
        -- усадка к априорным значениям, пока данных немного; разумные границы
        local w = r.n / (r.n + P.FAIR_MIN_N)
        kf = U.clamp(w * bf + (1 - w) * kf, -P.FAIR_COEF_MAX, P.FAIR_COEF_MAX)
        kl = U.clamp(w * bl + (1 - w) * kl, 0, 1.5)
      end
    end
    return kf, kl
  end
  A.coefs = coefs

  local function P_CLIP(inst) return inst.P.FLOW_CLIP_TICKS end

  -- fair (тики) и разложение для журнала
  function A.fair(inst, t)
    local s = inst.sig
    if not s.valid then return nil end
    local g = A.G(inst)
    local fl, ld = A.flow(inst, t), A.lead(inst, t)
    local kf, kl = coefs(inst)
    local f = s.mid + g + U.clamp(kf * fl, -P_CLIP(inst), P_CLIP(inst)) + kl * ld
    -- справедливая цена не выходит за лучшие цены дальше чем на спред (защита от выбросов обучения)
    f = U.clamp(f, s.bb - s.spread, s.ba + s.spread)
    inst.A.fair, inst.A.fair_t = f, t
    inst.A.parts = { g = g, flow = kf * fl, lead = kl * ld }
    return f
  end

  ------------------------------------------------------------------
  -- ВОЛАТИЛЬНОСТЬ И РЕЖИМ
  ------------------------------------------------------------------
  function A.sigma(inst)
    local a = inst.A
    if not a.sig2 or a.n_vs < 20 then return nil end
    return sqrt(max(a.sig2, inst.P.SIGMA_FLOOR ^ 2))
  end
  function A.sigma_or(inst, dflt) return A.sigma(inst) or dflt or inst.P.SIGMA_DEFAULT end

  local function vol_sample(inst, t)
    local a, s, P = inst.A, inst.sig, inst.P
    if not a.t_vs then a.t_vs, a.mid_vs = t, s.mid; return end
    local dt = t - a.t_vs
    if dt < P.VOL_SAMPLE_SEC then return end
    local d = s.mid - a.mid_vs
    local v = d * d / dt                                   -- тиков^2 в секунду
    v = min(v, (P.VOL_CLIP_TICKS ^ 2) / dt)                -- выбросы (переход контракта, клиринг)
    a.n_vs = a.n_vs + 1
    -- первые наблюдения - простое среднее (иначе старт с нуля после тихого прогрева = ложный всплеск)
    local first = 1 / a.n_vs
    if not a.sig2 then a.sig2, a.sig2f = v, v
    else
      a.sig2 = a.sig2 + max(ewa(dt, P.VOL_TAU_SEC), first) * (v - a.sig2)
      a.sig2f = a.sig2f + max(ewa(dt, P.VOL_FAST_TAU_SEC), first) * (v - a.sig2f)
    end
    a.t_vs, a.mid_vs = t, s.mid
    L(inst).sig2 = a.sig2
  end

  local function update_regime(inst, t)
    local a, s, P = inst.A, inst.sig, inst.P
    local sg = A.sigma(inst)
    if not sg then a.regime, a.z = "MR", 0; return end
    local w = P.REGIME_WIN_SEC
    local m0 = at(inst.mids, t - w, "mid") or s.mid
    a.z = (s.mid - m0) / (sg * sqrt(w))
    local toxic = false
    if a.vpin and A.vpin_crit(inst) and a.vpin >= A.vpin_crit(inst) then toxic = true; a.toxic_why = "vpin" end
    if a.sig2f and a.sig2 and a.sig2f > (P.REGIME_VOL_RATIO ^ 2) * max(a.sig2, P.SIGMA_FLOOR ^ 2) then toxic = true; a.toxic_why = "vol" end
    local new
    if toxic then new = "TOXIC"
    elseif abs(a.z) >= P.REGIME_Z then new = (a.z > 0) and "UP" or "DN"
    elseif a.regime == "UP" or a.regime == "DN" then
      -- гистерезис: тренд держится, пока |z| не упадёт ниже REGIME_Z_OFF
      if abs(a.z) >= P.REGIME_Z_OFF and U.sign(a.z) == ((a.regime == "UP") and 1 or -1) then new = a.regime else new = "MR" end
    else new = "MR" end
    if new ~= a.regime then
      if new ~= "MR" or t - a.t_regime > 1 then
        U.dbg(string.format("[%s] regime %s -> %s (z %.1f, vpin %s)", inst.sec, a.regime, new, a.z, U.fmt(a.vpin, 2)))
      end
      a.regime, a.t_regime = new, t
    end
  end
  function A.regime(inst) return inst.A and inst.A.regime or "MR" end

  ------------------------------------------------------------------
  -- ОБУЧЕНИЕ ТАБЛИЦЫ МИКРОЦЕНЫ И КОЭФФИЦИЕНТОВ (на своих данных, горизонт MICRO_H_SEC)
  ------------------------------------------------------------------
  local function learn_sample(inst, t)
    local a, s, P = inst.A, inst.sig, inst.P
    if t - a.t_sample >= P.MICRO_SAMPLE_SEC then
      a.t_sample = t
      a.pend[#a.pend + 1] = { t = t, mid = s.mid, cell = cell(inst), x = A.flow(inst, t), z = A.lead(inst, t) }
    end
    local H = P.MICRO_H_SEC
    local l = L(inst)
    local clip = P.VOL_CLIP_TICKS
    while a.pend[1] and t >= a.pend[1].t + H do
      local e = table.remove(a.pend, 1)
      local y = U.clamp(s.mid - e.mid, -clip, clip)
      local c = l.micro[e.cell]
      if not c then c = { n = 0, m = 0 }; l.micro[e.cell] = c end
      c.n = c.n + 1
      c.m = c.m + (y - c.m) / min(c.n, P.MICRO_TAU_N)
      -- остаток после таблицы - регрессия на поток и lead (EWMA-моменты)
      local res = y - c.m
      local r = l.reg
      r.n = r.n + 1
      local al = 1 / min(r.n, P.FAIR_TAU_N)
      r.xx = r.xx + al * (e.x * e.x - r.xx)
      r.xz = r.xz + al * (e.x * e.z - r.xz)
      r.zz = r.zz + al * (e.z * e.z - r.zz)
      r.xy = r.xy + al * (e.x * res - r.xy)
      r.zy = r.zy + al * (e.z * res - r.zy)
    end
  end

  ------------------------------------------------------------------
  -- КАЛИБРОВКА A, k: lambda(d) = A exp(-k d), d - насколько глубоко от середины дошла рыночная заявка
  ------------------------------------------------------------------
  local AK_BINS = 20                        -- d = 0.5, 1.0, ... 10 тиков
  local function ak_decay(inst, t)
    local a, ak = inst.A, L(inst).ak
    if a.t_ak then
      local dt = max(0, t - a.t_ak)
      local k = exp(-dt / inst.P.AK_TAU_SEC)
      for i = 1, AK_BINS do ak.cnt[i] = (ak.cnt[i] or 0) * k end
      ak.T = ak.T * k + dt
    end
    a.t_ak = t
  end
  local function ak_trade(inst, d, t)
    ak_decay(inst, t)
    local ak = L(inst).ak
    local j = min(AK_BINS, floor(d / 0.5 + 1e-9))
    for i = 1, j do ak.cnt[i] = (ak.cnt[i] or 0) + 1 end
  end
  -- A (1/с), k (1/тик); nil, если данных мало
  function A.ak(inst, t)
    if t then ak_decay(inst, t) end
    local ak = L(inst).ak
    if ak.T < 60 then return nil end
    local sw, sx, sy, sxx, sxy, npt = 0, 0, 0, 0, 0, 0
    for i = 1, AK_BINS do
      local c = ak.cnt[i] or 0
      if c >= 3 then
        local x, y = i * 0.5, log(c / ak.T)
        sw, sx, sy, sxx, sxy = sw + c, sx + c * x, sy + c * y, sxx + c * x * x, sxy + c * x * y
        npt = npt + 1
      end
    end
    if npt < 2 then return nil end
    local den = sw * sxx - sx * sx
    if den <= 1e-9 then return nil end
    local slope = (sw * sxy - sx * sy) / den
    local icpt = (sy - slope * sx) / sw
    local k = -slope
    if k <= 0.05 then return nil end
    return exp(icpt), k
  end

  ------------------------------------------------------------------
  -- CVD ПО КВАНТАМ И VPIN
  ------------------------------------------------------------------
  local function close_quanta(inst, t)
    local a, P = inst.A, inst.P
    local qs = P.CVD_QUANTUM_SEC
    if not a.q_t0 then a.q_t0 = t; return end
    local n = 0
    while t >= a.q_t0 + qs and n < 400 do
      local v = a.q_dv / qs                       -- скорость дельты, лотов/с
      local qq = a.quanta
      qq[#qq + 1] = v
      if #qq > 40 then table.remove(qq, 1) end
      -- статистика скорости (EWMA среднего и дисперсии) по окнам MOMO_QUANTA квантов
      local w = A.cvd_window(inst)
      a.cv_n = a.cv_n + 1
      local al = 1 / min(a.cv_n, P.CVD_STAT_N)
      local d = w - a.cv_m
      a.cv_m = a.cv_m + al * d
      a.cv_v = (1 - al) * (a.cv_v + al * d * d)
      a.q_dv = 0
      a.q_t0 = a.q_t0 + qs
      n = n + 1
    end
    if n >= 400 then a.q_t0 = t end
  end
  -- сумма скорости дельты за последние MOMO_QUANTA квантов (лотов/с в среднем)
  function A.cvd_window(inst)
    local qq, n = inst.A.quanta, inst.P.MOMO_QUANTA
    local s, k = 0, 0
    for i = #qq, max(1, #qq - n + 1), -1 do s = s + qq[i]; k = k + 1 end
    return k > 0 and s / k or 0
  end
  -- z-оценка скорости дельты d(dV)/dt
  function A.cvd_z(inst)
    local a = inst.A
    if a.cv_n < inst.P.CVD_MIN_N or a.cv_v <= 1e-9 then return 0 end
    return (A.cvd_window(inst) - a.cv_m) / sqrt(a.cv_v)
  end

  -- объём корзины: VPIN_BUCKET_LOTS, иначе средний объём за VPIN_BUCKET_SEC (пока он неизвестен - VPIN_BUCKET_DEFAULT)
  local function bucket_size(a, P)
    if (P.VPIN_BUCKET_LOTS or 0) > 0 then return P.VPIN_BUCKET_LOTS end
    if not a.vrate then return P.VPIN_BUCKET_DEFAULT end
    return max(1, floor(a.vrate * P.VPIN_BUCKET_SEC + 0.5))
  end

  local function vpin_add(inst, side, q, t)
    local a, P = inst.A, inst.P
    if not a.vsize then a.vsize = bucket_size(a, P) end
    while q > 1e-9 do
      local take = min(q, a.vsize - a.vb)
      a.vb = a.vb + take
      if side > 0 then a.vbuy = a.vbuy + take else a.vsell = a.vsell + take end
      q = q - take
      if a.vb >= a.vsize - 1e-9 then
        local b = a.buckets
        b[#b + 1] = abs(a.vbuy - a.vsell) / a.vb
        if #b > P.VPIN_N then table.remove(b, 1) end
        if #b >= min(P.VPIN_N, 10) then
          local s = 0
          for i = 1, #b do s = s + b[i] end
          a.vpin = s / #b
          local h = a.vhist
          h[#h + 1] = a.vpin
          if #h > 2000 then table.remove(h, 1) end
          a.vcrit = nil
        end
        a.vb, a.vbuy, a.vsell = 0, 0, 0
        a.vsize = bucket_size(a, P)
      end
    end
  end
  -- критический VPIN: VPIN_CRIT, если задан, иначе квантиль VPIN_Q своей истории (Easley et al.: CDF(VPIN) > 0.9)
  function A.vpin_crit(inst)
    local a, P = inst.A, inst.P
    if (P.VPIN_CRIT or 0) > 0 then return P.VPIN_CRIT end
    if #a.vhist < P.VPIN_HIST_MIN then return nil end
    if not a.vcrit then
      local c = {}
      for i = 1, #a.vhist do c[i] = a.vhist[i] end
      table.sort(c)
      a.vcrit = c[max(1, floor(P.VPIN_Q * #c + 0.5))]
    end
    return a.vcrit
  end

  ------------------------------------------------------------------
  -- АЙСБЕРГИ: на уровне исполнилось >= ICE_K x видимого объёма (на момент первой сделки), а уровень не исчез
  ------------------------------------------------------------------
  local function level_q(levels, px)
    for _, l in ipairs(levels or {}) do if l.p == px then return l.q end end
    return 0
  end
  A.level_q = level_q
  local function ice_trade(inst, side, p, q, t)
    local a, P, raw = inst.A, inst.P, inst.raw
    if not raw then return end
    local bookside = (side < 0) and "B" or "S"      -- продавец бьёт в биды, покупатель - в аски
    local tab = a.ice[bookside]
    local e = tab[p]
    if not e or t - e.t0 > P.ICE_WIN_SEC then
      e = { t0 = t, v0 = level_q(bookside == "B" and raw.bids or raw.asks, p), traded = 0 }
      tab[p] = e
    end
    e.traded = e.traded + q
    e.t = t
  end
  local function ice_check(inst, t)
    local a, P, raw = inst.A, inst.P, inst.raw
    if not raw then return end
    for side, tab in pairs(a.ice) do
      for p, e in pairs(tab) do
        if t - e.t0 > P.ICE_WIN_SEC then tab[p] = nil
        else
          local vis = level_q(side == "B" and raw.bids or raw.asks, p)
          if vis > 0 and e.traded >= P.ICE_MIN_LOTS and e.traded >= P.ICE_K * max(1, e.v0) then
            if not (a.iceberg and a.iceberg.p == p and a.iceberg.side == side) then
              U.log(string.format("[%s] ICEBERG %s %s: traded %d vs visible %d, still %d", inst.sec,
                side == "B" and "bid" or "ask", inst:price_str(p), e.traded, e.v0, vis))
            end
            a.iceberg = { side = side, p = p, t = t, traded = e.traded, visible = vis }
          end
        end
      end
    end
    if a.iceberg and (t - a.iceberg.t > P.ICE_WIN_SEC or
        level_q(a.iceberg.side == "B" and raw.bids or raw.asks, a.iceberg.p) == 0) then
      a.iceberg = nil
    end
  end

  ------------------------------------------------------------------
  -- ОЧЕРЕДЬ ВПЕРЕДИ НАШИХ ЗАЯВОК (FIFO на уровне цены)
  --   при постановке: впереди весь чужой объём уровня;
  --   сделка по нашей цене со стороны, бьющей в нас: впереди -= объём;
  --   уровень похудел больше, чем прошло сделками: снятия - впереди уменьшается пропорционально своей доле.
  ------------------------------------------------------------------
  local function track_queues(inst)
    local net = inst.net
    if not net then return end
    for _, o in pairs(SC.O.live) do
      if o.inst == inst and o.state == "active" and not o.taker then
        if o.backend == "virtual" then
          o.q_ahead = o.queue or 0
        else
          local lvl = level_q(o.side == "B" and net.bids or net.asks, o.px)
          if o.q_ahead == nil then
            o.q_ahead, o.q_lvl, o.q_tr = lvl, lvl, 0
          else
            local drop = (o.q_lvl or lvl) - lvl
            local tr = o.q_tr or 0
            local cancels = max(0, drop - tr)
            local ahead = o.q_ahead - tr
            if (o.q_lvl or 0) > 0 then ahead = ahead - cancels * max(0, ahead) / o.q_lvl end
            o.q_ahead = U.clamp(ahead, 0, lvl)
            o.q_lvl, o.q_tr = lvl, 0
          end
        end
      end
    end
  end
  A.track_queues = track_queues

  local function queue_trade(inst, side, p, q)
    for _, o in pairs(SC.O.live) do
      if o.inst == inst and o.backend == "real" and o.state == "active" and o.px == p and o.q_ahead then
        if (o.side == "B" and side < 0) or (o.side == "S" and side > 0) then o.q_tr = (o.q_tr or 0) + q end
      end
    end
  end

  ------------------------------------------------------------------
  -- СОБЫТИЯ
  ------------------------------------------------------------------
  function A.on_book(inst, t)
    local s = inst.sig
    if not inst.A or not s.valid then return end
    inst.A.obik = A.obi(inst)
    vol_sample(inst, t)
    learn_sample(inst, t)
    track_queues(inst)
    ice_check(inst, t)
  end

  function A.on_trade(inst, tr, t)
    local a, s, P = inst.A, inst.sig, inst.P
    if not a then return end
    close_quanta(inst, t)
    if tr.side ~= 0 then
      flow_decay(a, P, t)
      if tr.side > 0 then a.fb = a.fb + tr.q else a.fs = a.fs + tr.q end
      a.q_dv = a.q_dv + tr.side * tr.q
      vpin_add(inst, tr.side, tr.q, t)
      if s.valid then
        local d = (tr.side > 0) and (tr.p - s.mid) or (s.mid - tr.p)
        if d > 0 then ak_trade(inst, d, t) end
      end
      ice_trade(inst, tr.side, tr.p, tr.q, t)
      queue_trade(inst, tr.side, tr.p, tr.q)
    end
    -- интенсивность объёма (лотов/с) - размер корзины VPIN
    if a.t_vr then
      local dt = t - a.t_vr
      a.vacc = (a.vacc or 0) + tr.q
      if dt >= 10 then
        local r = a.vacc / dt
        a.vrate = a.vrate and (a.vrate + ewa(dt, P.VOL_TAU_SEC) * (r - a.vrate)) or r
        L(inst).vrate = a.vrate
        a.t_vr, a.vacc = t, 0
      end
    else a.t_vr, a.vacc = t, 0 end
  end

  -- каждый такт: кванты CVD закрываются и без сделок, режим пересчитывается
  function A.tick(inst, t)
    if not inst.A or not inst.sig.valid then return end
    close_quanta(inst, t)
    if t - (inst.A.t_reg_upd or 0) >= 0.1 then
      inst.A.t_reg_upd = t
      update_regime(inst, t)
    end
  end

  -- готов ли модуль (есть волатильность)
  function A.ready(inst) return inst.A ~= nil and A.sigma(inst) ~= nil end

  ------------------------------------------------------------------
  -- СОХРАНЕНИЕ ОБУЧЕННОГО
  ------------------------------------------------------------------
  local function path() return U.path(U.fname("scalp_alpha.txt")) end
  function A.load()
    local ok, t = pcall(dofile, path())
    if ok and type(t) == "table" then
      for k, v in pairs(t.learn or {}) do A.learn[k] = v end
      if SC.G and t.guard then SC.G.load(t.guard) end
      U.log("alpha: learned tables loaded (" .. path() .. ")")
    end
  end
  function A.save()
    local data = { learn = A.learn, guard = SC.G and SC.G.dump() or nil }
    U.write_file_atomic(path(), "return " .. U.serialize(data))
  end

  return A
end
