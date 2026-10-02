-- ui.lua : окна в QUIK (подписи по-русски, CP1251). Ошибки окон не мешают торговле.
--   "Скальпер"            - строка на инструмент: фаза (цветом), стакан, спред, дисбаланс, BR, текущая дырка,
--                           позиция реал/вирт, циклы, итог дня; в заголовке - режим, окно торговли, итог, лимит.
--   "Скальпер: сетапы"    - статистика дня по каждому сетапу (реальные и виртуальные отдельно).
--   "Скальпер: сделки"    - последние исполнения с итогом цикла.
-- Положение и размер окон запоминаются в scalp_ui.lua. SHOW_TABLE = false - без окон.
return function(SC)
  local W = {}
  SC.W = W
  local U = SC.U
  local floor = math.floor

  local T = {}
  local function rgb(r, g, b) return b * 65536 + g * 256 + r end
  local CL = {
    green = rgb(214, 245, 214), yellow = rgb(255, 243, 196), red = rgb(255, 214, 214),
    grey = rgb(232, 232, 232), blue = rgb(220, 232, 255),
    pos = rgb(0, 128, 0), neg = rgb(200, 0, 0),
  }
  local function api() return AllocTable and AddColumn and CreateWindow and SetCell and QTABLE_STRING_TYPE end
  local function enc(x) return U.to_cp1251(tostring(x == nil and "" or x)) end

  local function set(name, row, col, text)
    local tb = T[name]
    if tb and tb.rows[row] then SetCell(tb.id, tb.rows[row], col, enc(text)) end
  end
  local function color(name, row, col, bg, fg)
    local tb = T[name]
    if not (tb and tb.rows[row] and SetColor) then return end
    local d = QTABLE_DEFAULT_COLOR or -1
    pcall(SetColor, tb.id, tb.rows[row], col or (QTABLE_NO_INDEX or -1), bg or d, fg or d, bg or d, fg or d)
  end
  -- рубли с копейками до 1000 (тик BM ~0.83 руб - без копеек +0.83 выглядело бы как +1)
  local function money(v)
    v = v or 0
    if math.abs(v) < 1000 then return string.format("%+.2f", v) end
    return string.format("%+.0f", v)
  end
  local function sgn_color(v) return (v or 0) >= 0 and CL.pos or CL.neg end

  ------------------------------------------------------------------
  -- положение окон
  ------------------------------------------------------------------
  local function ui_path() return U.path(U.fname("scalp_ui.lua")) end
  local saved
  local function load_pos()
    if saved then return saved end
    local ok, t = pcall(dofile, ui_path())
    saved = (ok and type(t) == "table") and t or {}
    return saved
  end
  local function rect(id)
    if not GetWindowRect then return nil end
    local ok, top, left, bottom, right = pcall(GetWindowRect, id)
    top, left, bottom, right = tonumber(top), tonumber(left), tonumber(bottom), tonumber(right)
    if not ok or not (top and left and bottom and right) then return nil end
    local w, h = right - left, bottom - top
    if w < 50 or h < 30 or w > 10000 or h > 10000 then return nil end
    return { left, top, w, h }
  end
  function W.save_pos()
    local parts, any = {}, false
    for name, tb in pairs(T) do
      local r = rect(tb.id) or (saved and saved[name])
      if r then any = true; parts[#parts + 1] = string.format("%s = { %d, %d, %d, %d },", name, r[1], r[2], r[3], r[4]) end
    end
    if any then U.write_file_atomic(ui_path(), "return {\n" .. table.concat(parts, "\n") .. "\n}\n") end
  end

  local function make(name, caption, cols, widths, nrows, x, y, w, h)
    local id = AllocTable()
    for i, cn in ipairs(cols) do AddColumn(id, i, enc(cn), true, QTABLE_STRING_TYPE, widths[i]) end
    CreateWindow(id)
    SetWindowCaption(id, enc(caption))
    local sp = load_pos()[name]
    if type(sp) == "table" and tonumber(sp[1]) and tonumber(sp[4]) then x, y, w, h = sp[1], sp[2], sp[3], sp[4] end
    if SetWindowPos then pcall(SetWindowPos, id, x, y, w, h) end
    local rows = {}
    for i = 1, nrows do rows[i] = InsertRow(id, -1) end
    T[name] = { id = id, rows = rows }
  end

  ------------------------------------------------------------------
  -- подписи
  ------------------------------------------------------------------
  local WHY = {
    startup = "старт: догрузка таблиц", session_closed = "вне торгового окна", session_tail = "конец окна: только закрытие",
    no_book = "нет стакана", disconnected = "нет связи", book_frozen = "стакан замёрз", book_stale = "стакан не меняется",
    data_recover = "данные восстанавливаются", disabled = "контракт у экспирации", halt = "ОСТАНОВЛЕН",
    reject_pause = "пауза после отказов", day_loss = "дневной лимит убытка", err_tx_limit = "много ошибочных транзакций",
    foreign_orders = "чужие заявки на контракте - виртуально", inst_loss = "лимит убытка инструмента",
    busy = "цикл уже идёт", streak_pause = "пауза после серии убытков", loss_cooldown = "пауза после убытка",
    cooldown = "пауза между входами", gap_by_sweep = "дырка от выноса (не тихая)", recent_sweep = "недавно был вынос",
    imbalance = "дисбаланс стакана", ofi = "поток заявок против", burst = "всплеск сделок", ref_unknown = "нет данных BR",
    ref_moving = "BR движется", no_room = "мало места в спреде", ref_confirms = "BR подтверждает вынос",
    max_pos = "лимит позиции", tx_limit = "лимит транзакций",
    ttl = "время вышло", outbid = "встали впереди", undercut = "встали впереди", imb = "дисбаланс", sweep = "вынос",
    ref = "BR двинулся", reject_boc = "отказ: стала бы тейкером", reject_other = "отказ биржи", wall_pulled = "стену сняли",
    approach = "цена подошла медленно", nobook = "нет стакана", ["?"] = "?",
    sharp_move = "пауза: резкое движение", hole1_volumes = "дырка 1 тик: объёмы различаются < 1.4 раза",
    hole0_no_wall = "нет дырки: за лучшими ценами пусто", hole0_volumes = "нет дырки: за лучшими ценами нет объёма x3",
    hole2_off = "дырка 2 тика выключена", book_changed = "стакан изменился - переставляем",
    max_cycles = "позиция набрана (MAX_POS)", self_cross = "встали бы против своей заявки", cmd_pause = "пауза командой",
    cmd = "снято командой", requote = "перестановка", add_side = "снята нога набора", extra = "лишняя",
    partial_rest = "остаток после частичного", stop = "остановка робота",
  }
  local function why(w) return WHY[w] or tostring(w or "") end
  local SETUP = { PAIR = "пара в дырке 3+", TIGHT = "пара у рынка", FADE = "ловля выноса", WALL = "у стены", ADOPT = "принятая позиция" }
  local PHASE = { ENTRY = "заявки", TP = "тейк", DECAY = "тейк↓", HOLD = "+1 тик", BE = "безубыток", STOP = "СТОП",
                  CLOSE = "закрытие", POS = "позиция" }

  local function phase(inst, t)
    if SC.O.halt then return "ОСТАНОВЛЕН", CL.red end
    if SC.R.day_stop then return "ЛИМИТ ДНЯ", CL.red end
    local ss = SC.R.session(t)
    if ss == "closed" then return "ВНЕ ТОРГОВ", CL.grey end
    if ss == "tail" then return "ТОЛЬКО ЗАКРЫТИЕ", CL.yellow end
    local ok, w = SC.R.data_ok(inst, t)
    if not ok then return "НЕТ ДАННЫХ", CL.red, w end
    local real = SC.C.active(inst, "real")
    for _, c in ipairs(real) do if c.state ~= "ENTRY" then return "В ПОЗИЦИИ", CL.blue end end
    if #real > 0 then return "ЗАЯВКИ В СТАКАНЕ", CL.green end
    if inst.foreign_block then return "ЧУЖИЕ ЗАЯВКИ", CL.yellow end
    if SC.flatten then return "ЗАКРЫТИЕ (команда)", CL.yellow end
    if SC.paused then return "ПАУЗА (команда)", CL.yellow end
    if SC.R.move_paused(inst, t) then return "ПАУЗА: РЕЗКОЕ ДВИЖЕНИЕ", CL.yellow end
    if SC.cfg.MODE ~= "LIVE" then return "БУМАГА", CL.grey end
    return "ЖДЁТ ДЫРКУ", nil
  end

  -- короткие причины для узких колонок (ячейки QUIK не переносят текст)
  local SHORT = {
    startup = "старт", session_closed = "вне торгов", session_tail = "конец окна", no_book = "нет стакана",
    disconnected = "нет связи", book_frozen = "стакан замёрз", book_stale = "стакан стоит", data_recover = "данные",
    disabled = "экспирация", halt = "СТОП", reject_pause = "пауза: отказы", day_loss = "лимит дня",
    err_tx_limit = "ошибки tx", foreign_orders = "чужие заявки", inst_loss = "лимит инстр.", busy = "цикл идёт",
    max_cycles = "позиция = MAX", streak_pause = "серия убытков", loss_cooldown = "после убытка",
    cooldown = "пауза", gap_by_sweep = "дырка от выноса", recent_sweep = "был вынос", imbalance = "дисбаланс",
    ofi = "поток против", burst = "всплеск", ref_unknown = "нет BR", ref_moving = "BR движется",
    no_room = "мало места", ref_confirms = "BR за выносом", max_pos = "лимит позиции", tx_limit = "лимит tx",
    sharp_move = "резкое движ.", hole1_volumes = "объёмы < 1.4", hole0_no_wall = "нет стен",
    hole0_volumes = "стены < x3", hole2_off = "выкл", self_cross = "против своей", cmd_pause = "пауза (команда)",
  }
  local function reason(inst, name)
    local mode = (inst.P.SETUPS or {})[name]
    if not mode or mode == "off" then return "выкл" end
    local g = inst.gate and inst.gate[name]
    local w = (g and g ~= "") and g or (inst.skip and inst.skip[name])
    if not w then return "ждёт" end
    return SHORT[w] or why(w)
  end

  local function cycles_str(inst)
    local r = {}
    for _, c in ipairs(SC.C.active(inst)) do
      local legs = {}
      for _, o in ipairs(SC.C.live_orders(c)) do
        legs[#legs + 1] = (o.side == "B" and "Б" or "П") .. inst:price_str(o.px)
      end
      r[#r + 1] = string.format("%s%s %s %s", c.setup, c.backend == "real" and "" or "(в)",
        PHASE[c.phase or c.state] or (c.phase or c.state), table.concat(legs, " "))
    end
    return table.concat(r, " | ")
  end

  ------------------------------------------------------------------
  -- ОКНА
  ------------------------------------------------------------------
  local MAIN_COLS = { "Инструмент", "Фаза", "Бид / Аск", "Спред", "Дисбаланс", "BR, тиков", "Спред 3+ сейчас",
                      "Спредов 3+ за день (снятие/вынос)", "Позиция реал/вирт", "Итог реал, руб",
                      "Открытые, руб", "Реал + открытые", "Итог вирт, руб", "TIGHT", "PAIR 3+", "FADE", "WALL" }
  local MAIN_W = { 10, 18, 15, 7, 10, 10, 16, 12, 12, 12, 13, 14, 12, 15, 15, 15, 15 }

  -- нереализованный результат реальных позиций по середине спреда (висящие тейки)
  local function unreal(inst)
    local s, u = inst.sig, 0
    if not s.valid then return 0 end
    for _, c in ipairs(SC.C.active(inst, "real")) do
      if c.pos ~= 0 and c.avg then u = u + (s.mid - c.avg) * c.pos * (inst.step_price or 0) end
    end
    return u
  end
  local ST_COLS = { "Инструмент", "Сетап", "Режим", "Поставлено", "Отказ BoC", "Снято", "Исполнено", "Пара: обе ноги",
                    "Приб./убыт.", "Доля приб.", "Итог, тиков", "Итог, руб", "Тиков на цикл", "Фазы выхода",
                    "Маркаут 1/5/30 с", "Почему снимали" }
  local ST_W = { 10, 16, 9, 11, 10, 8, 10, 12, 11, 10, 11, 10, 12, 30, 18, 40 }
  local ST_N = 12
  local TR_COLS = { "Время", "Инструмент", "Сетап", "Реал/вирт", "Направление", "Кол-во", "Цена", "Роль",
                    "Позиция после", "Итог цикла, тиков", "Итог цикла, руб" }
  local TR_W = { 12, 10, 16, 10, 12, 7, 10, 9, 12, 15, 14 }
  local TR_N = 15

  function W.open()
    if SC.cfg.SHOW_TABLE == false or not api() or (SC.clock and not SC.ui_test) then return end
    local ok, err = pcall(function()
      local n = #SC.insts
      make("main", SC.name ~= "scalp" and SC.name or "Скальпер", MAIN_COLS, MAIN_W, n + 1, 10, 10, 1500, 70 + 22 * (n + 1))
      if SC.cfg.SHOW_STATS ~= false then
        make("stats", "Скальпер: сетапы (за день)", ST_COLS, ST_W, ST_N, 10, 110 + 22 * (n + 1), 1500, 60 + 22 * ST_N)
      end
      if SC.cfg.SHOW_TRADES ~= false then
        make("trades", "Скальпер: последние " .. TR_N .. " исполнений", TR_COLS, TR_W, TR_N,
          10, 190 + 22 * (n + 1 + ST_N), 1100, 60 + 22 * TR_N)
      end
    end)
    if not ok then U.log("UI open error: " .. tostring(err)) end
  end

  local function window_text(t)
    local ss = SC.R.session(t)
    local list = (U.weekday(t) == 1 or U.weekday(t) == 7) and SC.cfg.SESSIONS_WEEKEND or SC.cfg.SESSIONS
    local now = U.msk_sec(t)
    for _, w in ipairs(list or {}) do
      local a, b = U.hms(w[1]), U.hms(w[2])
      if a and b and now >= a and now < b then
        local left = b - now
        return string.format("окно до %s (%d:%02d)%s", w[2], floor(left / 3600), floor(left / 60) % 60,
          ss == "tail" and ", только закрытие" or "")
      end
    end
    return "вне торгового окна"
  end

  local function update_main(t)
    local n = #SC.insts
    local tot_r, tot_v, tot_u = 0, 0, 0
    for i, inst in ipairs(SC.insts) do
      local s = inst.sig
      local ph, bg = phase(inst, t)
      local rm = SC.K.ref_move(inst, t)
      local ep = inst.ep
      local g = inst.gaps or {}
      local key_r, key_v = inst.sec .. "real", inst.sec .. "virtual"
      local pr, pv = SC.R.inst_pnl[key_r] or 0, SC.R.inst_pnl[key_v] or 0
      local un = unreal(inst)
      tot_r, tot_v, tot_u = tot_r + pr, tot_v + pv, tot_u + un
      local vals = {
        inst.sec, ph,
        s.valid and (inst:price_str(s.bb) .. " / " .. inst:price_str(s.ba)) or "-",
        s.valid and tostring(s.spread) or "-",
        s.valid and string.format("%+.2f", s.imb1) or "-",
        rm and string.format("%+.1f", rm) or (inst.ref and "нет данных" or "-"),
        ep and string.format("%s, %.1f с", ep.cause == "sweep" and "от выноса" or (ep.cause == "cancel" and "от снятия" or "?"), t - ep.t0) or "",
        string.format("%d / %d", g.cancel or 0, g.sweep or 0),
        string.format("%d / %d", SC.C.position(inst, "real"), SC.C.position(inst, "virtual")),
        money(pr), money(un), money(pr + un), money(pv),
        reason(inst, "TIGHT"), reason(inst, "PAIR"), reason(inst, "FADE"), reason(inst, "WALL"),
      }
      if inst.skip then inst.skip = {} end
      for col, v in ipairs(vals) do set("main", i, col, v) end
      color("main", i, 2, bg)
      color("main", i, 7, ep and (ep.cause == "cancel" and CL.green or CL.yellow) or nil)
      color("main", i, 10, nil, sgn_color(pr))
      color("main", i, 11, nil, sgn_color(un))
      color("main", i, 12, (pr + un) < 0 and CL.red or nil, sgn_color(pr + un))
      color("main", i, 13, nil, sgn_color(pv))
    end
    local st = SC.O.stats
    set("main", n + 1, 1, "ВСЕГО")
    set("main", n + 1, 2, SC.O.halt and "ОСТАНОВЛЕН" or "")
    set("main", n + 1, 10, money(tot_r))
    set("main", n + 1, 11, money(tot_u))
    set("main", n + 1, 12, money(tot_r + tot_u))
    set("main", n + 1, 13, money(tot_v))
    if T.stats then
      SetWindowCaption(T.stats.id, enc(SC.O.halt and ("ОСТАНОВЛЕН: " .. SC.O.halt) or
        string.format("Сетапы за день | транзакций %d (заявок %d, снятий %d), отказов BoC %d, прочих %d, ошибочных %d",
          st.tx, st.new, st.kill, st.rej_boc, st.rej_other, st.err_tx)))
    end
    color("main", n + 1, 2, SC.O.halt and CL.red or nil)
    color("main", n + 1, 10, nil, sgn_color(tot_r))
    color("main", n + 1, 11, nil, sgn_color(tot_u))
    color("main", n + 1, 12, (tot_r + tot_u) < 0 and CL.red or nil, sgn_color(tot_r + tot_u))
    color("main", n + 1, 13, nil, sgn_color(tot_v))
    SetWindowCaption(T.main.id, enc(string.format("Скальпер %s %s | %s | закрыто %s, открытые %s, ИТОГО %s руб | вирт %s | лимит убытка -%s",
      SC.cfg.MODE == "LIVE" and "БОЕВОЙ" or "БУМАГА", SC.cfg.ACCOUNT, window_text(t),
      money(SC.R.pnl.real), money(tot_u), money((SC.R.pnl.real or 0) + tot_u), money(SC.R.pnl.virtual), tostring(SC.cfg.DAILY_LOSS_LIMIT_RUB))))
  end

  local function update_stats()
    local keys = {}
    for k in pairs(SC.ST.agg) do keys[#keys + 1] = k end
    table.sort(keys)
    for i = 1, ST_N do
      local a = SC.ST.agg[keys[i] or ""]
      if a then
        local n = a.wins + a.losses + a.flat
        local ph = {}
        for _, p in ipairs({ "TP", "DECAY", "HOLD", "BE", "STOP" }) do
          if a.phase[p] then ph[#ph + 1] = (PHASE[p] or p) .. " " .. a.phase[p] end
        end
        local rs = {}
        for w, cnt in pairs(a.cancel) do rs[#rs + 1] = { w, cnt } end
        table.sort(rs, function(x, y) return x[2] > y[2] end)
        local rt = {}
        for j = 1, math.min(3, #rs) do rt[#rt + 1] = why(rs[j][1]) .. " " .. rs[j][2] end
        local vals = {
          a.sec, SETUP[a.setup] or a.setup, a.backend == "real" and "реал" or "вирт",
          a.open, a.rej_boc, a.nofill, a.filled, a.both,
          string.format("%d / %d", a.wins, a.losses), n > 0 and string.format("%.0f%%", 100 * a.wins / n) or "-",
          string.format("%+.1f", a.ticks), money(a.rub), n > 0 and string.format("%+.2f", a.ticks / n) or "-",
          table.concat(ph, ", "),
          a.mk_n > 0 and string.format("%+.1f / %+.1f / %+.1f", a.mk[1] / a.mk_n, a.mk[2] / a.mk_n, a.mk[3] / a.mk_n) or "-",
          table.concat(rt, ", "),
        }
        for col, v in ipairs(vals) do set("stats", i, col, v) end
        color("stats", i, 3, a.backend == "real" and CL.green or CL.grey)
        color("stats", i, 12, nil, sgn_color(a.rub))
      else
        for col = 1, #ST_COLS do set("stats", i, col, "") end
      end
    end
  end

  local function update_trades()
    local fl = SC.fills_log or {}
    for i = 1, TR_N do
      local f = fl[#fl - i + 1]
      if f then
        local vals = { os.date("%H:%M:%S", floor(f.t)) .. string.format(".%03d", floor((f.t % 1) * 1000)),
          f.sec, SETUP[f.setup] or f.setup, f.backend == "real" and "реал" or "вирт",
          f.side == "B" and "покупка" or "продажа", tostring(f.q), f.px, f.role == "exit" and "выход" or "вход",
          tostring(f.pos), f.ticks and string.format("%+.1f", f.ticks) or "", f.net and money(f.net) or "" }
        for col, v in ipairs(vals) do set("trades", i, col, v) end
        color("trades", i, 4, f.backend == "real" and CL.green or CL.grey)
        color("trades", i, 5, nil, f.side == "B" and CL.pos or CL.neg)
        color("trades", i, 11, nil, f.net and sgn_color(f.net) or nil)
      end
    end
  end

  local t_ui, t_pos, t_stats, fills_n = 0, 0, 0, -1
  function W.tick(t)
    if not T.main or t - t_ui < 0.5 then return end
    t_ui = t
    if t - t_pos >= 10 then t_pos = t; pcall(W.save_pos) end
    local ok, err = pcall(update_main, t)
    if ok and T.stats and t - t_stats >= 2 then t_stats = t; ok, err = pcall(update_stats) end
    if ok and T.trades and (SC.fills_seq or 0) ~= fills_n then
      fills_n = SC.fills_seq or 0
      ok, err = pcall(update_trades)
    end
    if not ok then U.log_every("ui_err", 60, "UI update error: " .. tostring(err)) end
  end

  function W.close()
    pcall(W.save_pos)
    for name, tb in pairs(T) do
      if DestroyTable then pcall(DestroyTable, tb.id) end
      T[name] = nil
    end
  end

  return W
end
