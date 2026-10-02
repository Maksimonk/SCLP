-- ui.lua : окно состояния в QUIK (необязательно; ошибки окна не мешают торговле).
return function(SC)
  local W = {}
  SC.W = W
  local U = SC.U
  local tid, rows = nil, {}
  local COLS = { "SEC", "MODE", "SPREAD", "IMB", "REF", "POS", "STATE", "PNL RUB", "CYCLES", "NOTE" }

  function W.open()
    if not SC.cfg.SHOW_TABLE or not AllocTable or SC.clock then return end
    local ok = pcall(function()
      tid = AllocTable()
      for i, name in ipairs(COLS) do AddColumn(tid, i, name, true, QTABLE_STRING_TYPE, (i == 10) and 40 or 11) end
      CreateWindow(tid)
      SetWindowCaption(tid, "SCALP " .. SC.cfg.MODE)
      for i, inst in ipairs(SC.insts) do rows[inst.sec] = InsertRow(tid, -1) end
    end)
    if not ok then tid = nil end
  end

  local last = 0
  function W.tick(t)
    if not tid or t - last < 0.5 then return end
    last = t
    pcall(function()
      if IsWindowClosed(tid) then return end
      for _, inst in ipairs(SC.insts) do
        local r = rows[inst.sec]
        local s = inst.sig
        local rm = SC.K.ref_move(inst, t)
        local cyc = SC.C.active(inst)
        local st = {}
        for _, c in ipairs(cyc) do st[#st + 1] = c.setup:sub(1, 1) .. (c.backend == "real" and "" or "v") .. ":" .. (c.phase or c.state) end
        local vals = { inst.sec, SC.cfg.MODE, s.valid and tostring(s.spread) or "-", s.valid and U.fmt(s.imb1, 2) or "-",
          rm and U.fmt(rm, 1) or "-", tostring(SC.C.position(inst, "real")) .. "/" .. tostring(SC.C.position(inst, "virtual")),
          table.concat(st, " "), U.fmt(SC.R.pnl.real or 0, 0) .. "/" .. U.fmt(SC.R.pnl.virtual or 0, 0),
          tostring(#cyc), SC.O.halt and "HALT" or (inst.foreign_block and "foreign orders" or "") }
        for i, v in ipairs(vals) do SetCell(tid, r, i, U.to_cp1251(v)) end
      end
    end)
  end

  function W.close()
    if tid then pcall(DestroyTable, tid) end
    tid = nil
  end

  return W
end
