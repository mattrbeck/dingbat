# GB/GBC binding of the shared input-rollback session
# (common/rollback_core.nim), which holds all the logic and the rationale. This
# module only pins the two core-specific types — the GB serial link and its
# snapshot — and re-exports the concrete names the transports already use.

import ../common/rollback_core
export rollback_core

import link

type
  GbRollbackSession* = RollbackSessionBase[GbLink, GbLinkSnapshot]

proc new_gb_rollback_session*(link: GbLink; local: int;
                              max_ahead = 12): GbRollbackSession =
  ## See init_session in common/rollback_core.nim. The GB needs no extra
  ## determinism setup — its MBC3 RTC is already deterministic.
  init_session[GbLink, GbLinkSnapshot](link, local, max_ahead)
