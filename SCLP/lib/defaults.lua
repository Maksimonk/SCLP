-- defaults.lua : every SCLP parameter with its default. Do not edit - override in sclp_config.lua.
-- Prices / distances in ticks, money in rubles, time in seconds unless the name says _MS.
return {
  ACCOUNT = "",                -- trading account (FORTS: SPBFUT...). Per class: ACCOUNTS = { TQBR = "L01-..." }
  ACCOUNTS = {},
  CLIENT_CODE = "",            -- client code (equities need it; FORTS usually empty)
  TZ_TO_MSK_HOURS = 0,         -- MSK = PC time + N hours

  ------------------------------------------------------------------
  -- Settings window start values (then the window values are saved and restored)
  ------------------------------------------------------------------
  DEFAULT_INSTRUMENT = "SPBFUT BR",   -- "CLASS CODE", "CODE", or a FORTS base ("BR" = nearest contract)
  OFFSET_TICKS = 0,            -- buy = best bid - N, sell = best ask + N (0 = join the best price, never < 0)
  QTY = 1,
  TP_TICKS = 0,                -- counter order after a fill: 0 = off, 1 = on (T toggles); distance = OFFSET
  SKEW = false,                -- inventory skew (K toggles)
  MAX_DAY_LOSS_RUB = 3000,     -- session equity (realized + open, net of fees) <= -N -> stop (+ PANIC)

  ------------------------------------------------------------------
  -- Hard limits (fat-finger protection)
  ------------------------------------------------------------------
  OFFSET_MAX = 50,
  MAX_TX_PER_SEC = 30,         -- transactions per second (MOEX login base: 30)
  KEY_COOLDOWN_MS = 0,         -- min pause between orders of one side, ms (0 = every press; HOLDING an arrow then
                               -- sends an order per keyboard auto-repeat, ~30/s - set e.g. 150 to guard against it)
  OTR_WARN = 20,               -- warn above N transactions (orders + cancels) per fill

  ------------------------------------------------------------------
  -- PASSIVE-ONLY EXECUTION: EVERY order except PANIC goes with "Условие исполнения = Только пассивная"
  -- (exchange Book-or-Cancel) in the universal transaction format - the fixed format has no BoC value
  -- (ARQA, 17.06.2026). There is no plain-limit fallback: if QUIK refuses the fields, SCLP stops (HALT).
  -- Verified for FORTS with this broker (reject [GW][82]); for other classes run SCLP/tools/probe_passive.lua first.
  ------------------------------------------------------------------
  CHECK_PASSIVE_FLAG = true,   -- first accepted order of each class must show orders.passive_only_order <> 0, else HALT
  TX_BY_CLASS = {},            -- per-class field name overrides, e.g. { TQBR = { COND = "Тип по остатку" } }
  TX = {                       -- universal-format field names: as in the order entry dialog of YOUR QUIK
    ACTION = "Ввод заявки",
    ACCOUNT = "Торговый счет",
    CLIENT_CODE = "Код клиента",
    SIDE = "К/П", BUY = "Покупка", SELL = "Продажа",
    TYPE = "Тип", TYPE_LIMIT = "Лимитированная",
    SEC = "Инструмент",
    PRICE = "Цена",
    QTY = "Количество",
    COND = "Условие исполнения", COND_PASSIVE = "Только пассивная",
    COMMENT = nil,             -- e.g. "Комментарий" - ONLY after checking with a .tri file: an unknown field = reject
  },
  ORDER_TAG = "SCLP",          -- COMMENT of fixed-format orders (orders.brokerref): finds SCLP orders after a restart

  -- CLOSING-ORDER REQUOTE (R toggles): only orders that reduce the position (arrow key or F) follow the market,
  -- never below break-even. Cancel -> confirmed -> new, so there are never two orders at once.
  REQUOTE = true,
  REQUOTE_MIN_LIFE_MS = 300,   -- do not touch an order younger than N ms (queue priority)

  SKEW_TICKS_PER_LOT = 0.5,    -- quotes shift by -N * position ticks (long -> both quotes lower)

  ------------------------------------------------------------------
  -- PANIC (the only taker orders: IOC limit at opposite best +- slip, clamped to the exchange price limits)
  ------------------------------------------------------------------
  PANIC_SLIP_TICKS = 20,
  PANIC_MAX_ATTEMPTS = 10,
  PANIC_RETRY_SEC = 0.3,
  PANIC_CANCEL_WAIT_SEC = 2,   -- wait for cancel confirmations before flattening (avoids self-cross)
  PANIC_KILL_SCOPE = "own",    -- "own" - SCLP orders only; "account" - every order of the instrument on the account
  PANIC_POSITION = "own",      -- "own" - SCLP position; "broker" - the account position (manual trades too)
  AUTO_PANIC_ON_LOSS = true,

  ------------------------------------------------------------------
  -- MARKET STATE
  ------------------------------------------------------------------
  CLASS_PRIORITY = { "SPBFUT", "TQBR", "TQTF", "CETS", "SPBOPT" },
  EXPIRY_SKIP_DAYS = 1,        -- base code -> nearest contract with more than N days left
  MAX_SPREAD_TICKS = 0,        -- no new entries if spread > N (0 = off)
  SPREAD_WIDE_K = 5,           -- ... or spread > K x its 5-minute average (and >= 3 ticks)
  CANCEL_ON_PAUSE = false,     -- true: cancel your ARROW-KEY orders when a pause window starts (counters and the
                               -- F close are never cancelled by a pause window)
  -- MSK time windows without NEW orders. FORTS since 23.03.2026 (unified trading session, moex.com/s3886): no
  -- intraday clearing, trading 07:00-23:50 without pauses, opening auction 06:50-07:00, clearing 23:50-00:30,
  -- expirations at 14:00 / 19:00 without a halt.
  PAUSE_WINDOWS = {
    SPBFUT = { { "06:49:30", "07:00:00", "аукцион открытия" }, { "23:49:30", "23:59:59", "конец сессии / клиринг" } },
    SPBOPT = { { "06:49:30", "07:00:00", "аукцион открытия" }, { "23:49:30", "23:59:59", "конец сессии / клиринг" } },
    TQBR = { { "06:49:00", "07:00:30", "аукцион утренней сессии" }, { "09:49:00", "10:00:30", "аукцион открытия" },
             { "18:39:00", "18:50:30", "аукцион закрытия" } },
  },
  PARAM_REFRESH_SEC = 30,      -- step price, price limits, trading status
  VOL_TAU_SEC = 300,
  SPREAD_TAU_SEC = 300,
  STEPPRICE_FALLBACK = {},     -- { BRX6 = 7.6 } if QUIK does not give STEPPRICE

  ------------------------------------------------------------------
  -- FEES (rubles; fill in from YOUR tariff). Maker = passive orders, taker = PANIC.
  --   BROKER_RUB per lot, BROKER_PCT / EXCH_*_PCT percent of notional, EXCH_*_RUB per lot
  ------------------------------------------------------------------
  FEES = {
    SPBFUT = { BROKER_RUB = 0, EXCH_MAKER_PCT = 0, EXCH_TAKER_PCT = 0.0132 },
    default = { BROKER_PCT = 0, EXCH_MAKER_PCT = 0, EXCH_TAKER_PCT = 0 },
  },

  ------------------------------------------------------------------
  -- ORDERS, RESTART, JOURNAL
  ------------------------------------------------------------------
  PENDING_LOST_SEC = 10,
  KILL_TIMEOUT_SEC = 3,
  KILL_RETRIES = 3,
  GC_KEEP_SEC = 1800,
  STARTUP_SETTLE_SEC = 3,      -- wait for QUIK tables before reconciling
  CANCEL_ON_STOP = false,      -- false: orders stay in the book and are re-attached on the next start
  MARKOUT_SEC = { 1, 5, 30 },
  SNAPSHOT_SEC = 60,
  LOOP_MS = 1,                 -- main loop pause, ms (key -> send = queue wait <= this + Windows timer)
  UI_REFRESH_SEC = 0.2,
  UI_POS = { 20, 20, 1080, 470 },
  UI_COL_WIDTHS = { main = { 30, 44, 28, 30 }, avg = { 30, 24 }, report = { 160 } },   -- column widths, characters
  SHOW_WINDOW = true,
}
