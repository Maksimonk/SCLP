-- setups.lua : где и когда входить (PAIR, FADE, WALL) и когда снимать входные заявки.
-- Пороги - стартовые гипотезы из исследований (docs/research.md); проверяются журналами scalp_gaps / scalp_cycles.
return function(SC)
  local S = {}
  SC.S = S
  local U, K = SC.U, SC.K
  local abs, max, min, floor = math.abs, math.max, math.min, math.floor

  S.why_not = {}     -- [sec][setup][причина] = счётчик (почему не вошли) - в сводку
  local function nope(inst, setup, why)
    local a = S.why_not[inst.sec] or {}
    S.why_not[inst.sec] = a
    local b = a[setup] or {}
    a[setup] = b
    b[why] = (b[why] or 0) + 1
    inst.skip = inst.skip or {}
    inst.skip[setup] = why
    return nil
  end

  S.last_end = {}    -- [sec..setup..backend] = время конца последнего цикла
  function S.note_done(c)
    S.last_end[c.inst.sec .. c.setup .. c.backend] = c.t_done
  end
  local function since_end(inst, setup, backend, t)
    local e = S.last_end[inst.sec .. setup .. backend]
    return e and (t - e) or 1e9
  end

  ------------------------------------------------------------------
  -- PAIR: "тихая" дырка у рынка
  ------------------------------------------------------------------
  local function pair_prices(inst)
    local P, s = inst.P, inst.sig
    local lo, hi = s.bb + 1, s.ba - 1                 -- строго внутри спреда
    local function fit(shift)
      local bid = U.clamp(s.bb + P.PAIR_INSIDE + shift, lo, hi)
      local ask = U.clamp(s.ba - P.PAIR_INSIDE + shift, lo, hi)
      if ask - bid >= P.PAIR_MIN_CAPTURE then return bid, ask end
    end
    local shift = U.round(P.PAIR_MICRO_SKEW * (s.micro - s.mid))
    local bid, ask = fit(shift)
    if not bid and shift ~= 0 then bid, ask = fit(0) end
    return bid, ask
  end

  function S.pair_propose(inst, backend, t)
    local P, s = inst.P, inst.sig
    local name = "PAIR"
    if s.spread < P.PAIR_MIN_SPREAD then return nil end         -- обычный рынок - не считаем как отказ
    if since_end(inst, name, backend, t) < P.PAIR_COOLDOWN_SEC then return nope(inst, name, "cooldown") end
    local ep = inst.ep
    if ep and ep.cause == "sweep" then return nope(inst, name, "gap_by_sweep") end
    local sw = inst.last_sweep
    if sw and t - sw.t < P.PAIR_NO_SWEEP_SEC then return nope(inst, name, "recent_sweep") end
    if abs(s.imb1) > P.PAIR_IMB_MAX then return nope(inst, name, "imbalance") end
    if abs(K.ofi_norm(inst, t)) >= P.PAIR_OFI_CANCEL then return nope(inst, name, "ofi") end
    if K.burst_ratio(inst, t) > P.BURST_MAX then return nope(inst, name, "burst") end
    local rm = K.ref_move(inst, t)
    if rm == nil then
      if inst.ref and P.REF_REQUIRED then return nope(inst, name, "ref_unknown") end
    elseif abs(rm) >= P.REF_QUIET_TICKS then return nope(inst, name, "ref_moving") end
    local bid, ask = pair_prices(inst)
    if not bid then return nope(inst, name, "no_room") end
    local q = P.QUOTE_SIZE
    return {
      setup = name, pair = true,
      legs = { { side = "B", px = bid, qty = q }, { side = "S", px = ask, qty = q } },
      tp = function(c)
        -- тейк = цена второй ноги, но не ближе PAIR_TP_MIN_TICKS от входа
        local other
        for _, o in ipairs(c.legs) do if o.side ~= c.entry_side then other = o end end
        local px = other and other.px or nil
        if c.pos > 0 then
          local m = math.ceil(c.avg + P.PAIR_TP_MIN_TICKS - 1e-9)
          return (px and px >= m) and px or m
        else
          local m = math.floor(c.avg - P.PAIR_TP_MIN_TICKS + 1e-9)
          return (px and px <= m) and px or m
        end
      end,
      info = { spread = s.spread, imb = s.imb1, cause = ep and ep.cause or "", ref = rm },
    }
  end

  local function pair_check(c, t)
    local inst, P, s = c.inst, c.inst.P, c.inst.sig
    if t - c.t0 > P.PAIR_TTL_SEC then return "ttl" end
    if not s.valid then return "nobook" end
    for _, o in ipairs(SC.C.live_orders(c)) do
      if o.side == "B" and s.bb > o.px then return "outbid" end
      if o.side == "S" and s.ba < o.px then return "undercut" end
    end
    if abs(s.imb1) > P.PAIR_IMB_CANCEL then return "imb" end
    if abs(K.ofi_norm(inst, t)) >= P.PAIR_OFI_CANCEL then return "ofi" end
    local sw = inst.last_sweep
    if sw and sw.t > c.t0 then return "sweep" end
    local rm = K.ref_move(inst, t)
    if rm and abs(rm) >= P.REF_CANCEL_TICKS then return "ref" end
    if K.burst_ratio(inst, t) > P.BURST_MAX then return "burst" end
    return nil
  end

  ------------------------------------------------------------------
  -- FADE: после большого выноса - встать внутрь пустоты против движения
  ------------------------------------------------------------------
  S.fade_used = {}
  function S.fade_propose(inst, backend, t)
    local P, s = inst.P, inst.sig
    local name = "FADE"
    local sw = inst.last_sweep
    if not sw or not sw.big or t - sw.t > P.FADE_MAX_AGE_SEC then return nil end
    local key = inst.sec .. backend .. sw.t0
    if S.fade_used[key] then return nil end
    if since_end(inst, name, backend, t) < P.FADE_COOLDOWN_SEC then return nope(inst, name, "cooldown") end
    local rm = K.ref_move(inst, t)
    if P.FADE_REF_BLOCK and rm and rm * sw.side >= P.REF_QUIET_TICKS then
      S.fade_used[key] = true
      return nope(inst, name, "ref_confirms")
    end
    local side, px
    if sw.side < 0 then          -- пролив (продавцы) -> покупаем
      side = "B"; px = min(s.bb + P.FADE_INSIDE, s.ba - 1)
    else                         -- выкуп -> продаём
      side = "S"; px = max(s.ba - P.FADE_INSIDE, s.bb + 1)
    end
    S.fade_used[key] = true
    local dist = U.clamp(U.round(P.FADE_TP_FRAC * sw.levels), P.FADE_TP_MIN, P.FADE_TP_MAX)
    return {
      setup = name, pair = false,
      legs = { { side = side, px = px, qty = P.QUOTE_SIZE } },
      tp = function(c) return c.pos > 0 and math.ceil(c.avg + dist - 1e-9) or math.floor(c.avg - dist + 1e-9) end,
      info = { levels = sw.levels, vol = sw.vol, ref = rm },
    }
  end

  local function fade_check(c, t)
    local P, s = c.inst.P, c.inst.sig
    if t - c.t0 > P.FADE_TTL_SEC then return "ttl" end
    if not s.valid then return "nobook" end
    for _, o in ipairs(SC.C.live_orders(c)) do
      if o.side == "B" and s.bb > o.px then return "outbid" end
      if o.side == "S" and s.ba < o.px then return "undercut" end
    end
    return nil
  end

  ------------------------------------------------------------------
  -- WALL: заранее перед стеной за пустотой
  ------------------------------------------------------------------
  local function median(levels, n)
    local a = {}
    for i = 1, min(n, #levels) do a[#a + 1] = levels[i].q end
    if #a == 0 then return 0 end
    table.sort(a)
    return a[floor((#a + 1) / 2)]
  end

  -- dir = 1 для бидов (цены вниз), -1 для асков
  local function find_wall(inst, levels, best, dir)
    local P = inst.P
    local med = median(levels, 10)
    local need = max(P.WALL_K * med, P.WALL_MIN_LOTS)
    local void_seen = false
    for i = 2, #levels do
      local l, prev = levels[i], levels[i - 1]
      local dist = abs(best - l.p)
      if dist > P.WALL_MAX_DIST then break end
      if abs(prev.p - l.p) - 1 >= P.WALL_MIN_VOID then void_seen = true end
      if void_seen and l.q >= need then
        local px = l.p + dir           -- на тик впереди стены (бид: выше, аск: ниже)
        if px ~= prev.p then return l, px end
      end
    end
  end

  function S.wall_propose(inst, backend, t)
    local P, s, nb = inst.P, inst.sig, inst.net
    local name = "WALL"
    if since_end(inst, name, backend, t) < P.WALL_COOLDOWN_SEC then return nil end
    local bw, bpx = find_wall(inst, nb.bids, s.bb, 1)
    local aw, apx = find_wall(inst, nb.asks, s.ba, -1)
    if not bw and not aw then return nil end
    local side, wall, px
    if bw and (not aw or (s.bb - bw.p) <= (aw.p - s.ba)) then side, wall, px = "B", bw, bpx
    else side, wall, px = "S", aw, apx end
    return {
      setup = name, pair = false,
      legs = { { side = side, px = px, qty = P.QUOTE_SIZE } },
      tp = function(c) return c.pos > 0 and math.ceil(c.avg + P.WALL_TP_TICKS - 1e-9) or math.floor(c.avg - P.WALL_TP_TICKS + 1e-9) end,
      info = { wall_px = wall.p, wall_q = wall.q },
      wall = { p = wall.p, q = wall.q, side = side },
    }
  end

  local function wall_check(c, t)
    local inst, P, s = c.inst, c.inst.P, c.inst.sig
    if t - c.t0 > P.WALL_TTL_SEC then return "ttl" end
    if not s.valid then return "nobook" end
    local w = c.wall
    if not w then return nil end
    local levels = (w.side == "B") and inst.net.bids or inst.net.asks
    local q = 0
    for _, l in ipairs(levels) do if l.p == w.p then q = l.q end end
    if q < P.WALL_PULL_FRAC * w.q then return "wall_pulled" end
    -- цена подошла медленно (пустота заполнилась) - преимущество пропало
    for _, o in ipairs(SC.C.live_orders(c)) do
      local gap = (o.side == "B") and (s.bb - o.px) or (o.px - s.ba)
      if gap < P.WALL_MIN_VOID then
        local sw = inst.last_sweep
        if not (sw and t - sw.t < 1) then return "approach" end
      end
    end
    return nil
  end

  ------------------------------------------------------------------
  -- TIGHT: пара у самого рынка (дырка 0, 1 или 2 тика), захват 1 тик
  ------------------------------------------------------------------
  -- цены пары по чистому стакану; nil, причина - если правило не выполнено
  function S.tight_prices(inst)
    local P, s, nb = inst.P, inst.sig, inst.net
    local hole = s.spread - 1
    if hole == 2 then
      if not P.TIGHT_HOLE2 then return nil, "hole2_off" end
      return s.bb + 1, s.ba - 1, "hole2"
    elseif hole == 1 then
      local big, small = max(s.bq, s.aq), min(s.bq, s.aq)
      if small <= 0 or big / small < P.TIGHT_HOLE1_RATIO then return nil, "hole1_volumes" end
      if s.aq > s.bq then
        return s.bb, s.bb + 1, "hole1_ask_wall"     -- продажа в дырку перед большим аском, покупка в очередь
      else
        return s.ba - 1, s.ba, "hole1_bid_wall"     -- покупка в дырку перед большим бидом, продажа в очередь
      end
    elseif hole == 0 then
      local a2, b2 = nb.asks[2], nb.bids[2]
      if not a2 or not b2 or a2.p ~= s.ba + 1 or b2.p ~= s.bb - 1 then return nil, "hole0_no_wall" end
      if a2.q < P.TIGHT_HOLE0_K * s.aq or b2.q < P.TIGHT_HOLE0_K * s.bq then return nil, "hole0_volumes" end
      return s.bb, s.ba, "hole0_walls"
    end
    return nil, nil                                  -- дырка 3+ - это PAIR
  end

  function S.tight_propose(inst, backend, t)
    local P, s = inst.P, inst.sig
    local name = "TIGHT"
    if s.spread > 3 then return nil end
    if SC.R.move_paused(inst, t) then return nope(inst, name, "sharp_move") end
    if since_end(inst, name, backend, t) < P.TIGHT_COOLDOWN_SEC then return nope(inst, name, "cooldown") end
    local bid, ask, why = S.tight_prices(inst)
    if not bid then return why and nope(inst, name, why) or nil end
    local q = P.QUOTE_SIZE
    return {
      setup = name, pair = true,
      legs = { { side = "B", px = bid, qty = q }, { side = "S", px = ask, qty = q } },
      tp = function(c)
        for _, o in ipairs(c.legs) do
          if o.side ~= c.entry_side then return o.px end
        end
      end,
      info = { rule = why, spread = s.spread, bq = s.bq, aq = s.aq },
    }
  end

  local function tight_check(c, t)
    local inst, P, s = c.inst, c.inst.P, c.inst.sig
    if not s.valid then return "nobook" end
    if SC.R.move_paused(inst, t) then return "sharp_move" end
    if t - c.t0 < P.TIGHT_MIN_LIFE_SEC then return nil end
    local bid, ask = S.tight_prices(inst)
    for _, o in ipairs(SC.C.live_orders(c)) do
      local want = (o.side == "B") and bid or ask
      if want ~= o.px then return "book_changed" end
    end
    return nil
  end

  ------------------------------------------------------------------
  -- ОБХОД СЕТАПОВ
  ------------------------------------------------------------------
  local PROPOSE = { PAIR = S.pair_propose, TIGHT = S.tight_propose, FADE = S.fade_propose, WALL = S.wall_propose }
  local CHECK = { PAIR = pair_check, TIGHT = tight_check, FADE = fade_check, WALL = wall_check }
  S.ORDER = { "FADE", "PAIR", "TIGHT", "WALL" }

  function S.entry_check(c, t)
    local f = CHECK[c.setup]
    if f then return f(c, t) end
    return nil
  end

  function S.backend_for(inst, setup)
    local mode = (inst.P.SETUPS or {})[setup] or "off"
    if mode == "off" then return nil end
    if SC.cfg.MODE == "LIVE" and mode == "live" then return "real" end
    return "virtual"
  end

  function S.scan(inst, t)
    if not inst.sig.valid then return end
    for _, name in ipairs(S.ORDER) do
      local backend = S.backend_for(inst, name)
      if backend then
        local ok, why = SC.R.can_open(inst, backend, name, t)
        if not ok and backend == "real" and why == "foreign_orders" then
          -- контракт котирует другой робот: реально не торгуем, но статистику копим виртуально
          backend = "virtual"
          ok, why = SC.R.can_open(inst, backend, name, t)
        end
        inst.gate = inst.gate or {}
        inst.gate[name] = ok and "" or why
        if ok then
          local spec = PROPOSE[name](inst, backend, t)
          if spec then
            local fits, why = SC.R.fits(inst, backend, spec, t)
            if fits then
              spec.backend = backend
              local c = SC.C.open(inst, spec, t)
              c.wall = spec.wall
            else
              nope(inst, name, why)
            end
          end
        end
      end
    end
  end

  return S
end
