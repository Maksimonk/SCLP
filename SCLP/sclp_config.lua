-- sclp_config.lua : YOUR settings for SCLP (manual market making). Read at start.
-- Everything not listed here comes from lib/defaults.lua (all parameters with comments).
-- Instrument, offset, volume, take-profit and limits are changed on the fly in the SCLP window and remembered.
return {
  ACCOUNT = "SPBFUT17Y1j",       -- FORTS account
  -- ACCOUNTS = { TQBR = "L01-00000F00" }, CLIENT_CODE = "12345",   -- for equities

  DEFAULT_INSTRUMENT = "SPBFUT BR",   -- first start only
  OFFSET_TICKS = 0,
  QTY = 1,
  MAX_DAY_LOSS_RUB = 3000,

  -- Broker fee per contract (one side): 0 at the current tariff.
  FEES = {
    SPBFUT = { BROKER_RUB = 0, EXCH_MAKER_PCT = 0, EXCH_TAKER_PCT = 0.0132 },
  },

  -- If SCLP/tools/probe_passive.lua showed other universal-format field names, put them here, e.g.:
  -- TX = { COND = "Тип по остатку" },
}
