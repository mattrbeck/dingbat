# GBA binding of the shared input-rollback session (common/rollback_core.nim),
# which holds all the logic and the rationale. This module only pins the two
# core-specific types — the SIO link and its snapshot — and re-exports the
# concrete names the transports already use.

import ../common/rollback_core
export rollback_core

import link

type
  RollbackSession* = RollbackSessionBase[Link, LinkSnapshot]

proc new_rollback_session*(link: Link; local: int; max_ahead = 12): RollbackSession =
  ## See init_session in common/rollback_core.nim. The GBA additionally needs a
  ## deterministic RTC (enable_deterministic_rtc) on both cores, or the
  ## wall-clock reads desync a rolled-back replay.
  init_session[Link, LinkSnapshot](link, local, max_ahead)
