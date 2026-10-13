-- ui.lua : the SCLP window (settings + live metrics) and keyboard / mouse handling.
--
-- QLua has no global hotkeys: keys reach the script only while the SCLP window has focus
-- (SetTableNotificationCallback -> QTABLE_VKEY / QTABLE_CHAR). The callback runs in QUIK's main thread, so it only
-- queues the event with a timestamp; the script thread prices and sends (no shared-state races).
-- Both QTABLE_VKEY and QTABLE_CHAR are handled and de-duplicated; Cyrillic characters are mapped back to the
-- physical key, so letter hotkeys work in either keyboard layout.
--
-- Editing: double click (or Enter) on a settings row -> type -> Enter applies (validated), Esc cancels.
-- While editing, trading keys are disabled.
return function(X)
  local W = {}
  X.W = W
  local U = X.U
  local floor, abs = math.floor, math.abs

  local VK = { BACK = 8, ENTER = 13, ESC = 27, SPACE = 32, LEFT = 37, UP = 38, RIGHT = 39,
               DOWN = 40, DEL = 46, F2 = 113, NUM_PLUS = 107, NUM_MINUS = 109, NUM_DOT = 110, PLUS = 187,
               MINUS = 189, DOT = 190 }

  local function rgb(r, g, b) return b * 65536 + g * 256 + r end
  local CL = { green = rgb(214, 245, 214), yellow = rgb(255, 243, 196), red = rgb(255, 200, 200), blue = rgb(220, 232, 255),
               grey = rgb(235, 235, 235), pos = rgb(0, 128, 0), neg = rgb(200, 0, 0), white = rgb(255, 255, 255) }

  ------------------------------------------------------------------
  -- LAYOUT: left = settings / controls / state, right = metrics
  ------------------------------------------------------------------
  local LEFT = {
    { id = "inst", label = "Инструмент [2xклик]", edit = "text" },
    { id = "offset", label = "Отступ, тиков [Влево/Вправо]", edit = "int" },
    { id = "qty", label = "Объём, лотов [+/-]", edit = "int" },
    { id = "tp", label = "Тейк-профит, тиков [T]", edit = "int" },
    { id = "requote", label = "Перестановка закрытия [R]" },
    { id = "skew", label = "Перекос от позиции [K]" },
    { id = "max_pos", label = "Лимит позиции" },
    { id = "max_loss", label = "Лимит убытка дня, руб", edit = "num" },
    { id = "mode", label = "Исполнение" },
    { id = "state", label = "Состояние" },
    { id = "book", label = "Стакан без своих" },
    { id = "status", label = "Торги" },
    { id = "work", label = "Мои заявки" },
    { id = "pos", label = "Позиция / средняя" },
    { id = "panic", label = "PANIC [P,P или 2xклик]" },
    { id = "msg", label = "Событие" },
    { id = "keys1", label = "Клавиши" },
    { id = "keys2", label = "" },
    { id = "keys3", label = "" },
  }
  local RIGHT = {
    "Реализ. P&L гросс / нетто", "Нереализ. P&L гросс / нетто", "ИТОГО нетто / за сессию", "P&L в час / на сделку",
    "Комиссии, руб", "Сделок (закрытий) / win rate", "Ср. выигрыш / ср. проигрыш", "Profit factor",
    "Макс. просадка, руб", "Макс. позиция / экспозиция", "Заявок: отпр/исп/снято/откл", "Fill ratio / OTR",
    "Заявок за минуту / лимит", "Отказы BoC / ошибочные tx", "Клавиша -> отправка, мс", "Отправка -> ответ, мс",
    "Спред / сигма, тиков", "Маркаут 1/5/30 с, тиков", "Тейкерских исполнений",
  }
  local ROW = {}
  for i, r in ipairs(LEFT) do ROW[r.id] = i end
  local NROWS = math.max(#LEFT, #RIGHT)

  local T = { id = nil, rows = {}, cache = {} }
  local REP = { id = nil }

  local function api() return AllocTable and AddColumn and CreateWindow and SetCell and QTABLE_STRING_TYPE end
  local function enc(x) return U.to_cp1251(tostring(x == nil and "" or x)) end

  local function set(row, col, text)
    local k = row * 8 + col
    text = tostring(text or "")
    if T.cache[k] == text then return end                  -- SetCell only on change (GUI thread is shared with QUIK)
    T.cache[k] = text
    SetCell(T.id, T.rows[row], col, enc(text))
  end
  local function color(row, col, bg, fg)
    if not SetColor then return end
    local k = "c" .. row .. ":" .. tostring(col)
    local v = tostring(bg) .. "/" .. tostring(fg)
    if T.cache[k] == v then return end
    T.cache[k] = v
    local d = QTABLE_DEFAULT_COLOR or -1
    pcall(SetColor, T.id, T.rows[row], col or (QTABLE_NO_INDEX or -1), bg or d, fg or d, bg or d, fg or d)
  end
  function W.flash(id, bg, ms)
    if T.id and Highlight and ROW[id] then pcall(Highlight, T.id, T.rows[ROW[id]], QTABLE_NO_INDEX or -1, bg, CL.neg, ms or 800) end
  end

  ------------------------------------------------------------------
  -- WINDOW
  ------------------------------------------------------------------
  local function callback(t_id, msg, par1, par2)
    X.push({ k = "ui", msg = msg, p1 = par1, p2 = par2, tbl = t_id, t = U.now() })
  end

  function W.open()
    if X.cfg.SHOW_WINDOW == false or not api() then return end
    local ok, err = pcall(function()
      local id = AllocTable()
      AddColumn(id, 1, enc("Параметр"), true, QTABLE_STRING_TYPE, 30)
      AddColumn(id, 2, enc("Значение"), true, QTABLE_STRING_TYPE, 44)
      AddColumn(id, 3, enc("Метрика"), true, QTABLE_STRING_TYPE, 28)
      AddColumn(id, 4, enc("Значение"), true, QTABLE_STRING_TYPE, 30)
      CreateWindow(id)
      SetWindowCaption(id, enc("SCLP"))
      local p = X.cfg.UI_POS or { 20, 20, 1080, 470 }
      if SetWindowPos then pcall(SetWindowPos, id, p[1], p[2], p[3], p[4]) end
      T.id, T.rows, T.cache = id, {}, {}
      for i = 1, NROWS do T.rows[i] = InsertRow(id, -1) end
      for i, r in ipairs(LEFT) do set(i, 1, r.label) end
      for i, l in ipairs(RIGHT) do set(i, 3, l) end
      if SetTableNotificationCallback then SetTableNotificationCallback(id, callback) end
    end)
    if not ok then U.log("UI open error: " .. tostring(err)) end
  end

  function W.close()
    if T.id and DestroyTable then pcall(DestroyTable, T.id) end
    if REP.id and DestroyTable then pcall(DestroyTable, REP.id) end
    T.id, REP.id = nil, nil
  end

  -- recovery report window (one text column); append = add lines to the open report
  function W.report(lines, title, append)
    for _, l in ipairs(lines) do U.log("REPORT " .. l) end
    if X.cfg.SHOW_WINDOW == false or not api() or #lines == 0 then return end
    if append and REP.id then
      pcall(function()
        for _, l in ipairs(lines) do SetCell(REP.id, InsertRow(REP.id, -1), 1, enc(l)) end
      end)
      return
    end
    pcall(function()
      if REP.id and DestroyTable then DestroyTable(REP.id) end
      local id = AllocTable()
      AddColumn(id, 1, enc("Отчёт о восстановлении (" .. U.stamp() .. ")"), true, QTABLE_STRING_TYPE, 160)
      CreateWindow(id)
      SetWindowCaption(id, enc(title or "SCLP: восстановление после запуска"))
      local p = X.cfg.UI_POS or { 20, 20, 1080, 470 }
      if SetWindowPos then pcall(SetWindowPos, id, p[1], p[2] + p[4] + 10, p[3], 40 + 18 * math.min(#lines + 1, 25)) end
      for _, l in ipairs(lines) do
        local r = InsertRow(id, -1)
        SetCell(id, r, 1, enc(l))
        if SetColor and (l:find("РАСХОЖДЕНИЕ", 1, true) or l:find("ПОВРЕЖД", 1, true) or l:find("ВНИМАНИЕ", 1, true)) then
          pcall(SetColor, id, r, QTABLE_NO_INDEX or -1, CL.red, QTABLE_DEFAULT_COLOR or -1, CL.red, QTABLE_DEFAULT_COLOR or -1)
        end
      end
      REP.id = id
    end)
  end

  ------------------------------------------------------------------
  -- KEYS
  ------------------------------------------------------------------
  -- Cyrillic layout -> physical key (ЙЦУКЕН -> QWERTY)
  local RU = {}
  do
    local ru = "йцукенгшщзхъфывапролджэячсмитьбю"
    local en = "qwertyuiop[]asdfghjkl;'zxcvbnm,."
    local i = 1
    for _, cp in (utf8 and utf8.codes or function() return function() end end)(ru) do
      RU[cp] = en:sub(i, i):upper():byte(); i = i + 1
    end
  end
  local function char_to_vk(c)
    if c >= 97 and c <= 122 then return c - 32 end
    if (c >= 65 and c <= 90) or (c >= 48 and c <= 57) or c == 32 then return c end
    if c == 43 then return VK.PLUS elseif c == 45 then return VK.MINUS elseif c == 46 then return VK.DOT end
    local cp = c
    if c >= 0xC0 and c <= 0xFF then cp = c - 0xC0 + 0x410 end              -- CP1251 code
    if cp >= 0x410 and cp <= 0x42F then cp = cp + 0x20 end                  -- upper -> lower
    return RU[cp]
  end
  local function vk_to_char(vk)
    if (vk >= 65 and vk <= 90) or (vk >= 48 and vk <= 57) or vk == 32 then return string.char(vk) end
    if vk >= 96 and vk <= 105 then return string.char(48 + vk - 96) end
    if vk == VK.MINUS or vk == VK.NUM_MINUS then return "-" end
    if vk == VK.DOT or vk == VK.NUM_DOT then return "." end
    if vk == VK.PLUS or vk == VK.NUM_PLUS then return "+" end
    return nil
  end

  local last_vk, last_vk_t = nil, -1e9
  local armed = {}                 -- double-press confirmations: armed[name] = time
  local function confirm(name, t, text)
    if t - (armed[name] or -1e9) <= 2 then armed[name] = nil; return true end
    armed[name] = t
    X.say(text, "warn")
    return false
  end

  local function value_text(id)
    local st = X.st
    if id == "inst" then return st.inst_text or "" end
    if id == "max_loss" then return tostring(st.max_loss or "") end
    return tostring(st[id] or 0)
  end

  local function start_edit(id)
    for _, r in ipairs(LEFT) do
      if r.id == id and r.edit then
        X.edit = { id = id, kind = r.edit, buf = "" }
        X.say("Ввод: " .. r.label .. " - наберите значение, Enter - применить, Esc - отмена")
        return
      end
    end
  end

  -- validate + apply an edited value
  local function apply_edit(t)
    local e = X.edit
    X.edit = nil
    local s = (e.buf or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then X.say("Пустое значение - без изменений"); return end
    local st = X.st
    if e.id == "inst" then X.switch_instrument(s, t); return end
    local v = tonumber(s)
    if not v or (e.kind == "int" and v ~= floor(v)) then X.say("Нужно " .. (e.kind == "int" and "целое " or "") .. "число: " .. s, "err"); return end
    local cfg = X.cfg
    if e.id == "offset" then
      if v < 0 or v > (cfg.OFFSET_MAX or 50) then X.say("Отступ: 0.." .. (cfg.OFFSET_MAX or 50) .. " (0 - лучшая цена, больше - внутрь спреда)", "err"); return end
      st.offset = v
    elseif e.id == "qty" then
      if v < 1 or v > (cfg.MAX_ORDER_QTY or 100) then X.say("Объём 1.." .. (cfg.MAX_ORDER_QTY or 100), "err"); return end
      st.qty = v
    elseif e.id == "tp" then
      if v < 0 or v > 1000 then X.say("Тейк 0..1000 тиков (0 - выкл.)", "err"); return end
      st.tp = v
      if v > 0 then st.tp_last = v end
    elseif e.id == "max_loss" then
      if v <= 0 then X.say("Лимит убытка должен быть > 0", "err"); return end
      st.max_loss = v
      X.R.on_limit_changed()
    end
    X.S.mark_settings()
    X.say("Установлено: " .. e.id .. " = " .. tostring(v))
  end

  local function edit_key(vk, t)
    local e = X.edit
    if vk == VK.ENTER then apply_edit(t)
    elseif vk == VK.ESC then X.edit = nil; X.say("Ввод отменён")
    elseif vk == VK.BACK then e.buf = e.buf:sub(1, -2)
    elseif vk == VK.DEL then e.buf = ""
    else
      local c = vk_to_char(vk)
      if c and #e.buf < 32 then e.buf = e.buf .. c end
    end
  end

  local function bump(field, d)
    local st, cfg = X.st, X.cfg
    if field == "offset" then st.offset = U.clamp((st.offset or 0) + d, 0, cfg.OFFSET_MAX or 50)
    else st.qty = U.clamp((st.qty or 1) + d, 1, cfg.MAX_ORDER_QTY or 100) end
    X.S.mark_settings()
    X.say(field == "offset" and ("Отступ " .. st.offset) or ("Объём " .. st.qty))
  end

  local function toggle(id)
    local st = X.st
    if id == "requote" then st.requote = not st.requote; X.say("Перестановка закрывающих заявок " .. (st.requote and "ВКЛ" or "ВЫКЛ"))
    elseif id == "skew" then st.skew = not st.skew; X.say("Перекос от позиции " .. (st.skew and "ВКЛ" or "ВЫКЛ"))
    elseif id == "tp" then
      if (st.tp or 0) > 0 then st.tp_last = st.tp; st.tp = 0 else st.tp = st.tp_last or X.cfg.TP_TICKS_DEFAULT or 2 end
      X.say("Тейк-профит " .. ((st.tp > 0) and (st.tp .. " тиков") or "ВЫКЛ"))
    end
    X.S.mark_settings()
  end

  local function panic_key(t)
    if confirm("panic", t, "PANIC: нажмите P ещё раз в течение 2 секунд") then
      X.T.panic("клавиша P,P", t, X.block and { position = "broker" } or nil)
    end
  end

  local function command(vk, e, t)
    local T_ = X.T
    if vk == VK.UP then T_.key_order("B", e.t, t)
    elseif vk == VK.DOWN then T_.key_order("S", e.t, t)
    elseif vk == VK.LEFT then bump("offset", -1)
    elseif vk == VK.RIGHT then bump("offset", 1)
    -- volume: the "=/+" and "-" keys of the main row (no Shift needed) or numpad + / -
    elseif vk == VK.PLUS or vk == VK.NUM_PLUS then bump("qty", 1)
    elseif vk == VK.MINUS or vk == VK.NUM_MINUS then bump("qty", -1)
    elseif vk == 66 then T_.cancel_side("B", t)                    -- B
    elseif vk == 83 then T_.cancel_side("S", t)                    -- S
    elseif vk == 67 or vk == VK.ESC then T_.cancel_all(t)          -- C / Esc
    elseif vk == 70 then T_.flatten_passive(t)                     -- F
    elseif vk == 80 then panic_key(t)                              -- P
    elseif vk == 84 then toggle("tp")                              -- T
    elseif vk == 82 then toggle("requote")                         -- R
    elseif vk == 75 then toggle("skew")                            -- K
    elseif vk == 65 then                                           -- A: adopt exchange position after a mismatch
      if X.block and confirm("adopt", t, "Принять позицию QUIK: нажмите A ещё раз в течение 2 секунд") then X.S.adopt_exchange(t) end
    elseif vk == 72 then                                           -- H: pause / resume
      if X.paused then
        if X.panic and X.panic.stage ~= "done" and X.panic.stage ~= "failed" then X.say("Идёт PANIC", "warn"); return end
        X.paused = false; X.say("Торговля разрешена")
      else
        X.paused = true; X.say("ПАУЗА: новые заявки запрещены (H - продолжить)", "warn")
      end
    elseif vk == VK.ENTER or vk == VK.F2 then
      local r = LEFT[X.sel_row or 0]
      if r and r.edit then start_edit(r.id) end
    end
  end

  -- one queued UI event (from callback)
  function W.on_event(e, t)
    local msg = e.msg
    if msg == QTABLE_CLOSE then
      if e.tbl == T.id then T.id = nil; X.ui_closed_t = t end
      if e.tbl == REP.id then REP.id = nil end
      return
    end
    if e.tbl ~= T.id then return end
    if msg == QTABLE_SELCHANGED then X.sel_row = e.p1; return end
    if msg == QTABLE_LBUTTONDBLCLK then
      local r = LEFT[e.p1 or 0]
      if not r or (e.p2 or 1) > 2 then return end
      if r.id == "panic" then X.T.panic("двойной клик PANIC", t, X.block and { position = "broker" } or nil)
      elseif r.id == "skew" or r.id == "requote" then toggle(r.id)
      elseif r.edit then start_edit(r.id) end
      return
    end
    local vk
    if msg == QTABLE_VKEY then
      vk = tonumber(e.p2)
      last_vk, last_vk_t = vk, e.t
      if e.p1 and tonumber(e.p1) and tonumber(e.p1) > 0 then X.sel_row = tonumber(e.p1) end
    elseif msg == QTABLE_CHAR then
      vk = char_to_vk(tonumber(e.p2) or 0)
      if not vk or (vk == last_vk and e.t - last_vk_t <= 0.15) then return end   -- the same key already came as VKEY
    else
      return
    end
    if not vk then return end
    if X.edit then edit_key(vk, t) else command(vk, e, t) end
  end

  ------------------------------------------------------------------
  -- REFRESH
  ------------------------------------------------------------------
  local function state_text(t)
    local inst = X.inst
    if X.recovering then return "ВОССТАНОВЛЕНИЕ после запуска...", CL.yellow end
    if X.block then return string.format("РАСХОЖДЕНИЕ: SCLP %+d, QUIK %+d. A,A - принять, P,P - PANIC", X.block.computed, X.block.real), CL.red end
    if X.O.halt then return "ОСТАНОВ: " .. X.O.halt, CL.red end
    local p = X.panic
    if p and p.stage == "failed" then return "PANIC НЕ ЗАКРЫЛ ПОЗИЦИЮ - вручную!", CL.red end
    if p and p.stage ~= "done" then return "PANIC: " .. p.stage, CL.red end
    if X.R.day_stop then return "СТОП: дневной лимит убытка", CL.red end
    if X.edit then return "РЕДАКТИРОВАНИЕ (Enter/Esc), клавиши торговли выключены", CL.blue end
    if X.paused then return "ПАУЗА (H - продолжить)", CL.yellow end
    if not inst then return "выберите инструмент", CL.yellow end
    local mb = X.R.market_block(inst, t)
    if mb then return "нельзя входить: " .. mb, CL.yellow end
    return "ТОРГОВЛЯ (окно должно быть в фокусе)", CL.green
  end

  local function orders_text(inst, side)
    local r, n = {}, 0
    for _, o in ipairs(X.O.working(inst, side)) do
      n = n + 1
      if #r < 3 then r[#r + 1] = inst:px_str(o.px) .. "x" .. (o.qty - o.filled) .. (o.src == "tp" and "tp" or "") end
    end
    return string.format("%s %d%s", side == "B" and "Пок" or "Прод", n, n > 0 and (": " .. table.concat(r, " ")) or "")
  end

  local function lat_text(kind)
    local last, avg, p95 = X.M.lat_stats(kind)
    if not last then return "-" end
    return string.format("%.0f / ср %.0f / p95 %.0f", last, avg, p95)
  end

  local function update(t)
    local st, inst = X.st, X.inst
    local vals = {}
    if X.edit then
      vals[X.edit.id] = "> " .. X.edit.buf .. "_"
    end
    vals.inst = vals.inst or (inst and X.I.describe(inst) or (st.inst_text or "не выбран"))
    vals.offset = vals.offset or string.format("%d  (покупка = бид+%d, продажа = аск-%d)", st.offset, st.offset, st.offset)
    vals.qty = vals.qty or tostring(st.qty)
    vals.tp = vals.tp or (((st.tp or 0) > 0) and (st.tp .. " тиков от исполнения") or "ВЫКЛ")
    vals.requote = st.requote and "ВКЛ: только закрывающие, не хуже безубытка" or "ВЫКЛ: все заявки стоят на месте"
    vals.skew = st.skew and string.format("ВКЛ (%.2f тика на лот)", X.cfg.SKEW_TICKS_PER_LOT or 0.5) or "ВЫКЛ"
    vals.max_pos = "нет (контроль позиции - ваш; лимит убытка дня действует)"
    vals.max_loss = vals.max_loss or tostring(st.max_loss)
    local stt, stc = state_text(t)
    vals.state = stt
    vals.panic = "PANIC: снять заявки и закрыть позицию (единственная тейкерская операция)"
    vals.msg = X.last_msg or ""
    vals.keys1 = "Вверх - КУПИТЬ, Вниз - ПРОДАТЬ, Влево/Вправо - отступ -/+, + / - - объём"
    vals.keys2 = "B/S - снять покупки/продажи, C или Esc - снять все, F - закрыть пассивно, H - пауза"
    vals.keys3 = "R - перестановка закрытия, T - тейк, K - перекос, P,P - PANIC, A,A - принять позицию QUIK"
    local R = {}
    if inst then
      local bk = inst.bk
      vals.mode = "Только пассивная (BoC биржи)" .. (X.O.passive_checked[inst.class] and ", признак подтверждён" or
        ", признак проверится на первой заявке") .. "; PANIC - IOC"
      vals.book = (bk.bb and bk.ba) and string.format("%s x%s | %s x%s | спред %s", inst:px_str(bk.bb), U.fmt(bk.bq, 0),
        inst:px_str(bk.ba), U.fmt(bk.aq, 0), bk.valid and tostring(bk.spread) or "-") or "нет данных"
      vals.status = string.format("%s%s, лимиты %s..%s", tostring(inst.status_text or "?"),
        X.R.connected() and "" or ", НЕТ СВЯЗИ", inst.pmin and inst:px_str(inst.pmin) or "-", inst.pmax and inst:px_str(inst.pmax) or "-")
      vals.work = orders_text(inst, "B") .. " | " .. orders_text(inst, "S")
      local m, v = X.M.get(inst), X.M.values(inst)
      local real = X.R.broker_pos(inst)
      vals.pos = string.format("%+d @ %s%s", m.pos, m.avg and U.fmt(m.avg * inst.tick, inst.scale + 2) or "-",
        real and string.format("  (QUIK %+d)", real) or "")
      local hours = math.max((t - (m.t0 or t)) / 3600, 1 / 60)
      local st_ = X.O.st
      local mk1, mk5, mk30, mkn = X.M.markouts(inst)
      local pf = m.sum_loss > 0 and m.sum_win / m.sum_loss or nil
      R = {
        U.money(v.real_gross) .. " / " .. U.money(v.real_net),
        U.money(v.unreal_gross) .. " / " .. U.money(v.unreal_net),
        U.money(v.equity) .. " / все инстр. " .. U.money(X.M.total_equity()),
        U.money(v.equity / hours) .. " / " .. (m.n > 0 and U.money(v.real_net / m.n) or "-"),
        U.fmt(v.fees, 2),
        string.format("%d / %s", m.n, m.n > 0 and string.format("%.0f%%", 100 * m.wins / m.n) or "-"),
        (m.wins > 0 and U.money(m.sum_win / m.wins) or "-") .. " / " .. (m.losses > 0 and U.money(-m.sum_loss / m.losses) or "-"),
        pf and U.fmt(pf, 2) or (m.sum_win > 0 and "беск." or "-"),
        U.fmt(m.max_dd, 2),
        string.format("%d / %s руб", m.max_abs_pos, U.fmt(v.exposure, 0)),
        string.format("%d / %d / %d / %d", st_.sent, st_.filled, st_.cancelled, st_.rejected),
        string.format("%s / %.1f", st_.sent > 0 and string.format("%.0f%%", 100 * st_.filled / st_.sent) or "-", X.M.otr()),
        string.format("%d / %d", X.O.orders_last_min(t), X.cfg.MAX_ORDERS_PER_MIN or 60),
        string.format("%d / %d", st_.rej_boc, st_.rej_other + st_.rej_cross + st_.kill_err + st_.local_err),
        lat_text("key_send"),
        lat_text("send_reply"),
        string.format("%s / %s (ср. спред %s)", bk.valid and tostring(bk.spread) or "-", U.fmt(X.B.sigma(inst), 2), U.fmt(bk.spread_avg, 1)),
        mk1 and string.format("%+.2f / %+.2f / %+.2f (n=%d)", mk1, mk5, mk30, mkn) or "-",
        tostring(st_.taker_suspect),
      }
      local otr_bad = st_.sent >= 50 and X.M.otr() > (X.cfg.OTR_WARN or 20)
      color(12, 4, otr_bad and CL.yellow or nil)
      color(3, 4, nil, v.equity >= 0 and CL.pos or CL.neg)
      color(1, 4, nil, v.real_net >= 0 and CL.pos or CL.neg)
      color(19, 4, st_.taker_suspect > 0 and CL.red or nil)
      color(18, 4, (mk5 and mk5 < 0) and CL.yellow or nil)
      SetWindowCaption(T.id, enc(string.format("SCLP | %s | %s | поз %+d | итог %s руб | заявок %d",
        inst.sec, stt, m.pos, U.money(v.equity), #X.O.working(inst))))
    else
      SetWindowCaption(T.id, enc("SCLP | " .. stt))
    end
    for i, r in ipairs(LEFT) do set(i, 2, vals[r.id] or "") end
    for i = 1, #RIGHT do set(i, 4, R[i] or "") end
    color(ROW.state, 2, stc)
    color(ROW.panic, nil, CL.red)
    if X.edit then color(ROW[X.edit.id], 2, CL.blue) end
    for _, r in ipairs(LEFT) do
      if r.edit and not (X.edit and X.edit.id == r.id) then color(ROW[r.id], 2, nil) end
    end
  end

  local t_ui = 0
  function W.tick(t)
    if not T.id then
      -- the window was closed: the only control surface must come back (orders may be live)
      if X.cfg.SHOW_WINDOW ~= false and api() and X.ui_closed_t and t - X.ui_closed_t >= 1 then
        X.ui_closed_t = nil
        W.open()
        X.say("Окно SCLP закрыто - открыто заново. Остановка скрипта: Сервисы -> Lua скрипты -> Остановить", "warn")
      end
      return
    end
    if IsWindowClosed and t - t_ui >= 0.2 then
      local ok, closed = pcall(IsWindowClosed, T.id)
      if ok and closed then T.id = nil; X.ui_closed_t = t; return end
    end
    if t - t_ui < (X.cfg.UI_REFRESH_SEC or 0.2) then return end
    t_ui = t
    local ok, err = pcall(update, t)
    if not ok then U.log_every("ui_err", 60, "UI update error: " .. tostring(err)) end
  end

  W.CL = CL
  return W
end
