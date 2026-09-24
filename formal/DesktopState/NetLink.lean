-- What this models, for formal/anchors.mjs (which lists stale models):
-- @models src/dingbat.nim: load_rom process_pending_state load_state_slot handle_input render_imgui render_link_window render_link_advanced teardown_netlink finish_link establish_netlink link_ready link_cancel_setup link_auto_stop link_mid_frame service_netlink service_link_setup update_link_auto main
-- @models src/dingbat/frontend/link_cable.nim: init_link_cable auto_start auto_stop start_host start_join auto_listen cancel_setup finish_link service_setup update_auto teardown parse_host_port
-- @models src/dingbat/gba/netlink.nim: step_frame poll_socket new_net_link close
-- @models src/dingbat/gba/netcore.nim: try_advance handle_msg master_complete new_net_core

/-
# The desktop network link cable (src/dingbat.nim @ a2e038f82)

Written against a2e038f82. Line numbers are `src/dingbat.nim` unless marked.

The desktop app is one thread. `main`'s `while app.running` loop (2426) runs
the same phases in the same order every iteration:

1. emulate (2429-2485): rewind pop, else one frame if `not paused`. A linked
   GBA frame is `app.netlink.step_frame()` (2460), which **blocks inside
   netlink.nim** (`pump(1)` loop, netlink.nim 123-150) while the core is
   parked on the peer, for up to `STALL_TIMEOUT_MS` = 30 s, then raises.
   A `NetLinkError` or a BYE (`peer_done`) ends in `teardown_netlink` (2462-2467).
2. `process_pending_state` (2487-2489, 925-940).
3. `handle_input` (1628-1773): every queued SDL event (keys, drops, quit).
4. `update_link_auto` (2094-2103), then `service_link_setup` (1986-2032),
   which may call `finish_link` (1826-1848): a **blocking** HELLO handshake
   (`new_net_link`, netlink.nim 153-175, up to `HELLO_TIMEOUT_MS` = 30 s).
5. present + `render_imgui` (1265-1520): menu clicks and the Link Cable
   window's buttons (`render_link_window` 2054-2092, `render_link_advanced`
   2034-2052) and the Save States window's `on_load` (2274-2282) run here.
6. After the loop (2606-2607): `flush_gb_save`, `input_log_close`. Nothing
   touches `app.netlink` or `app.link_server`.

So the model is a program counter over those phases. User events are only
accepted where the code receives them (SDL events in phase 3, ImGui clicks in
phase 5); the network and the other process act only where the code touches a
socket (phase 1's `step_frame`, phase 4's accept/connect/handshake, phase 5's
Disconnect), as the parameter of that phase's event.

## Three parts

* **Part A, one process** (`St`, `step`): the frontend state plus the
  protocol state visible to it. The peer is the environment: every outcome
  it can cause at a socket touch is a constructor of `LinkOut` / `SvcOut` /
  `Hs`. This is where properties (a)-(e) live.
* **Part B, two processes over one socket** (`Pair`, `pstep`): the emulated
  clocks, the bounded lead, the blocking `step_frame`, pause, quit and BYE.
* **Part C, the zero-config auto-pair race** (`Race`, `rstep`): two
  instances probing 127.0.0.1:47810 and binding it without SO_REUSEADDR.

Each part has the code as it is (`step`, `pstep`, `rstep`), counterexample
traces (`bug_*`, checked by `decide`), and the code with a proposed minimal
fix (`stepF`, `pstepF`, `rstepF`) with the broken properties proved for
every reachable state.

## Abstractions (and why they do not affect the properties)

* A core is `gba g` / `gb g`, `g` = which `load_rom` call built it (a fresh
  `new_gba`/`new_gb` object each time, 707/723), so "the core on screen" and
  "the core `app.netlink` drives" (`NetLink.gba`, netlink.nim 30) can be
  compared. The home screen is `none`; nothing on the desktop unloads a game.
* `load_rom`'s failure exits (file missing, bad zip, 695-701) change nothing
  and are omitted. Reset (Ctrl+R 1647, menu 1370) is `load_rom(recents[0])`,
  a fresh core of the same kind: modelled as a load of kind `k`.
* The accept/connect throttle (`link_attempts`, 2011-2031) only decides
  *when* an outcome happens: `SvcOut.idle` is a throttled or empty poll;
  `refused limit ..` says whether the retry limit was reached. Port numbers
  are not modelled (every listener here is on the one port the peer uses).
* `step_frame`'s inner protocol (CLOCK/TRANSFER/REPLY, netcore.nim) is the
  outcome of the phase-1 event: a frame, a BYE read during it (`peer_done`),
  or a `NetLinkError` (EOF/reset, or the stall timeout), with whether the
  core was parked at S+D of an exchange (`reply_wait`, netcore.nim 482-503)
  when it raised. Part B models the clocks behind that outcome.
* ImGui's skip condition (1272-1285) is abstracted to: a menu item needs the
  menu bar (`menu`, set by mouse movement in phase 3) or the home screen;
  a Link Cable button needs the window open. The other `not X` terms only
  make ImGui render *more* often, so the fixed-model proofs, which allow a
  click whenever those two hold, cover every real schedule.
* Pending save, frame advance, turbo/fast-forward inside Part A: they do not
  touch the link state. Frame advance and fast forward cannot desync the
  link: `step_frame` is bounded by the peer's clock whatever the pacing
  (Part B `lead_bounded`, proved for every `ff` setting).
* Freezes (the UI thread blocked on the network) are a ghost `freeze` naming
  the last blocking wait; they are by-construction facts of the code, recorded
  so the traces show them.
* An uncaught Nim exception or a nil dereference ends the process:
  `pc = crashed`. On disk that loses at most one frame of battery RAM (GBA
  `handle_saves` writes the .sav every frame, gba.nim 1530; GB flushes once per
  frame), and all unsaved in-game progress.

## Results

Proved for the code as it is: rewind never runs while linked
(`rewind_gated`); frame advance and fast forward, from the menu, Tab or the
right trigger, keep the two clocks within one frame of each other
(`lead_bounded`); two auto-pairing instances never both host and never pair
as the same unit (`race_inv`).

Refuted (`bug_*`, Part A):
(a) Reset or a new GBA game while linked leaves the link driving the old,
    hidden core (`bug_reset_while_linked_drives_hidden_core`); a GB game keeps
    a dead link with no way to disconnect (`bug_gb_switch_keeps_dead_link`).
(b) A GB game dropped while the Link Cable window is still pairing crashes the
    process when the peer arrives (`bug_gb_switch_during_setup_crashes`,
    manual-host variant `bug_manual_host_gb_switch_crashes`).
(c) File > Quick Load and the Save States window load into a linked core
    (`bug_menu_quick_load_while_linked`, `bug_slot_load_while_linked`); so does
    Ctrl+L in the iteration the link completes (`bug_ctrl_l_races_link`).
(d) A failed accept leaks the listening socket, which the next auto probe then
    connects to (`bug_accept_error_leaks_listener`).
(e) A peer lost mid-exchange leaves the SIO transfer busy forever
    (`bug_lost_peer_leaves_transfer_busy`); the window keeps saying "Linked as
    ..." (`bug_link_lost_ui_says_linked`); Quit sends no BYE
    (`bug_quit_while_linked_sends_no_bye`).
Also: a failed auto handshake strands "Waiting to pair..."
(`bug_handshake_fail_strands_auto`); auto-pair probes whatever the Join box
last held (`bug_auto_probes_typed_host`); a manual Host keeps listening after
the window is closed (`bug_manual_host_survives_window_close`); a vanished ROM
file or a bad `--connect` port crashes (`bug_rom_file_gone_crashes`,
`bug_cli_bad_port_crashes`).
Part B: pausing freezes the *other* player's whole window, then drops the link
after 30 s (`bug_peer_pause_freezes_other_window`,
`bug_peer_pause_ends_link`); a quit ends the peer's link through the error
path (`bug_quit_ends_peer_link_without_bye`).
Part C: after a session the port stays in TIME_WAIT (31 s measured on macOS)
and nobody can auto-host (`bug_repair_waits_for_time_wait`); the leaked
listener freezes both probers for 30 s (`bug_leaked_listener_freezes_both`).

The fixes (`stepF`, `pstepF`, `rstepF`), as shipped on the fix branch
(`frontend/link_cable.nim`, `gba/netlink.nim`, `gba/netcore.nim` and the
link procs in `dingbat.nim`; `load_rom` and the after-the-loop teardown are
the GameLifecycle fix), are proved to keep every one of those properties in
every reachable state: `safeF_reachable` (Part A's
(a)-(e) plus an honest window, and no crash), `pairF_reachable` (lead kept,
no pause-kill, every end a BYE) with `pairF_responsive` (Quit and Pause work
while waiting on the peer), `raceF_reachable` (the port is held exactly by
the listener, nobody frozen or stranded). `regress_partA`,
`regress_partA_rest`, `regress_peer_pause` and `regress_race` replay the
traces on the fixes. The freezes on the network (`freeze`: the CLI wait,
the HELLO wait, a manual Join's connect to a SYN-dropping host, the 3 s
close drain) are recorded, not fixed, in `stepF`; the 30 s stall wait is
gone (`step_frame_for` hands back to the loop).

## Found by reading, not modelled

* The retry throttles count main-loop iterations, not time
  (`link_attempts mod 10`, 2012; `> 300`, 2029; `LINK_AUTO_CONNECT_TRIES * 10`,
  2026). The loop sleeps only `delay(1)` when idle (2603-2605), so it turns
  over roughly once a millisecond: ~100 connects/s rather than "~6/sec", and a
  manual Join gives up after ~0.3 s rather than "~5 s".
* A malformed frame after the handshake raises `LinkProtoError` from
  `feed` (netlink.nim 111), which is not a `NetLinkError`: step_frame's caller
  (2462) does not catch it and the process dies. Anyone who can reach a
  hosting port and send a valid HELLO can do it.
* `app.link_client` (450) is never assigned; `link_cancel_setup`'s
  lsConnecting branch closes nothing.
-/
namespace DesktopState.NetLink

set_option linter.unusedVariables false
set_option linter.unusedSimpArgs false

/-! ## Part A: one process -/

inductive Kind where
  | gba | gb
  deriving DecidableEq, Repr

/-- `app.emu_kind` with the core object (`app.gba_emu` / `app.gb_emu`). -/
inductive Core where
  | none
  | gba (g : Nat)
  | gb (g : Nat)
  deriving DecidableEq, Repr

def Core.isGba : Core → Bool
  | .gba _ => true
  | _ => false

/-- `app.link_setup` (391-394). -/
inductive Setup where
  | none | listening | connecting
  deriving DecidableEq, Repr

/-- Where `main` is: before the loop (`boot`, 2285-2311), the loop's phases,
    after it (`exited`), or dead (`crashed`). -/
inductive Phase where
  | boot | emu | pend | input | svc | ui | exited | crashed
  deriving DecidableEq, Repr

/-- `app.link_status` (453), by which sentence it holds. `ended` is new in
    the fix ("Link ended: ..."). -/
inductive Status where
  | empty | linked | hsFailed | reachFail | acceptFail | hostFail | ended
  deriving DecidableEq, Repr

/-- `app.link_host_buf` (452): the default "127.0.0.1" (2283) or anything typed. -/
inductive Host where
  | localhost | other
  deriving DecidableEq, Repr

/-- Ghost: the last time the UI thread blocked on the network (no events, no
    redraw, the OS "not responding" cursor). -/
inductive Freeze where
  | none
  | cliWait      -- establish_netlink: selectRead up to 120 s / 40 connects, before the loop (1865-1892)
  | helloWait    -- new_net_link's handshake loop, up to 30 s (netlink.nim 163-170)
  | connectHang  -- a blocking connect() to a host that drops SYNs (2016): ~75 s on macOS
  | stallWait    -- step_frame parked on the peer, up to 30 s (netlink.nim 138-146)
  | closeDrain   -- NetLink.close waits up to 3 s for the peer's EOF (netlink.nim 177-197)
  deriving DecidableEq, Repr

structure St where
  pc        : Phase := .boot
  core      : Core := .none        -- app.emu_kind + app.gba_emu / app.gb_emu
  gen       : Nat := 0             -- ghost: load_rom calls so far (names the next core)
  nl        : Option Nat := none   -- app.netlink (440); some g = NetLink.gba is core g
  setup     : Setup := .none       -- app.link_setup (445)
  auto      : Bool := false        -- app.link_auto (448)
  win       : Bool := false        -- app.link_window (443)
  winPrev   : Bool := false        -- app.link_window_prev (444)
  server    : Bool := false        -- app.link_server (449) is an open listening socket
  host      : Host := .localhost   -- app.link_host_buf (452)
  status    : Status := .empty     -- app.link_status (453)
  paused    : Bool := false        -- app.paused
  pendLoad  : Bool := false        -- app.pending_load
  rewinding : Bool := false        -- app.rewinding
  running   : Bool := true         -- app.running
  menu      : Bool := false        -- show_menu_bar() (1215): the mouse moved recently
  -- ghosts
  desync    : Bool := false        -- the linked core's state was replaced outside the link protocol
  stuck     : Option Nat := none   -- core g's SIOCNT busy was left set by a teardown mid-exchange
  byeOwed   : Bool := false        -- the process exited holding a live link without sending BYE
  freeze    : Freeze := .none
  deriving DecidableEq, Repr

/-- The HELLO handshake's outcome (finish_link -> new_net_link). -/
inductive Hs where
  | ok        -- the peer's HELLO arrived and was accepted
  | rejected  -- refused (version/system/unit), a BYE, or the peer hung up
  | timeout   -- no HELLO within HELLO_TIMEOUT_MS
  | romGone   -- readFile(current_rom_path()) raises IOError (1833): the ROM file moved
  deriving DecidableEq, Repr

/-- Outcome of `app.netlink.step_frame()` (2460), when a linked frame runs. -/
inductive LinkOut where
  | frame                                   -- naFrame, no BYE read
  | frameBye                                -- a BYE arrived during the frame: peer_done (2465)
  | lost (parked : Bool) (stalled : Bool)   -- NetLinkError (2462): EOF/reset, or (stalled) the 30 s
                                            -- stall timeout; parked = reply_wait when it raised
  deriving DecidableEq, Repr

/-- Outcome of one `service_link_setup` poll (1986-2032). -/
inductive SvcOut where
  | idle                                             -- throttled, or nothing to accept
  | accept (h : Hs)                                  -- select readable, accept ok, handshake h
  | acceptErr                                        -- select readable, accept raised OSError
  | connect (h : Hs)                                 -- connect ok, handshake h
  | refused (limit : Bool) (bindOk : Bool) (hung : Bool)
      -- connect raised; limit = the retry threshold was reached (2026 / 2029);
      -- bindOk = link_auto_listen's bind succeeded; hung = the connect blocked first
  deriving DecidableEq, Repr

/-- What `main` does before the loop (2285-2311). -/
inductive Boot where
  | none
  | rom (k : Kind)
  | link (k : Kind) (peer : Bool) (h : Hs)   -- --listen PORT / --connect HOST:PORT
  | auto (k : Kind)                          -- --link-auto
  | badPort                                  -- --connect HOST:x (parseInt, 1881)
  deriving DecidableEq, Repr

inductive Ev where
  | boot (b : Boot)
  -- phase 1
  | emu (o : LinkOut)
  | emuSkip                     -- no frame due (pacing gate) or paused
  -- phase 2
  | pend (ok : Bool)            -- ok = load_state_slot(0) succeeds
  -- phase 3: SDL events (handle_input)
  | keyPause                    -- Ctrl+P (1649)
  | keyQuickLoad                -- Ctrl+L (1657)
  | keyRewind (down : Bool)     -- ` (1674)
  | keyReset (k : Kind)         -- Ctrl+R (1647)
  | drop (k : Kind)             -- DropFile (1761)
  | quit                        -- QuitEvent (1769), Ctrl+Q (1665)
  | mouse (active : Bool)       -- MouseMotion / idle: the menu bar shows or hides
  | endInput
  -- phase 4
  | svc (o : SvcOut)
  -- phase 5: ImGui clicks (render_imgui)
  | mOpen (k : Kind)            -- File > Open ROM / Recent (1295-1299, 1473)
  | mReset (k : Kind)           -- Emulation > Reset (1328, 1370)
  | mQuickLoad                  -- File > Quick Load (1311)
  | mSlotLoad (ok : Bool)       -- Save States window > Load (on_load, 2274)
  | mPause                      -- Emulation > Pause (1330)
  | mLinkMenu                   -- Emulation > Link Cable... (1377)
  | mQuit                       -- File > Exit (1322)
  | wClose                      -- the Link Cable window's close box (2060)
  | wDisconnect (slow : Bool)   -- Disconnect (2066); slow = the peer is not reading
  | wCancel                     -- Cancel (2080, 2084)
  | wHost (bindOk : Bool)       -- Advanced > Host game (2042)
  | wJoin                       -- Advanced > Join game (2051)
  | wEditHost (h : Host)        -- Advanced > the address box (2047)
  | endUi
  deriving DecidableEq, Repr

def ready (s : St) : Bool := s.core.isGba   -- link_ready (1909)

def menuOk (s : St) : Bool := s.menu || s.core == .none

def Kind.mk : Kind → Nat → Core
  | .gba, g => .gba g
  | .gb, g => .gb g

/-- The GBA a `NetLink` built on this core would drive (`NetLink.gba`). -/
def linkOf : Core → Option Nat
  | .gba g => some g
  | _ => none

-- The helpers below are written field by field (each field an `if`), which is
-- the same function as the Nim's branch-by-branch shape and keeps the proofs
-- about single fields small. The `decide` traces pin the behaviour.

/-- `load_rom` (694-767): a fresh core; rewind, pause and pending states
    reset. Nothing link-related. -/
def loadRom (s : St) (k : Kind) : St :=
  { s with core := k.mk s.gen, gen := s.gen + 1, rewinding := false, paused := false,
           pendLoad := false }

/-- `teardown_netlink` (1806-1818): BYE, close, nil; `link_status` untouched. -/
def teardown (s : St) : St := { s with nl := none }

/-- `link_cancel_setup` (1912-1922): closes `link_server` only from lsListening. -/
def cancelSetup (s : St) : St :=
  { s with server := (if s.setup = .listening then false else s.server), setup := .none }

/-- `link_auto_stop` (1937-1940): `if link_auto: link_cancel_setup(); link_auto = false`. -/
def autoStop (s : St) : St :=
  { s with server := (if s.auto = true ∧ s.setup = .listening then false else s.server),
           setup := (if s.auto = true then .none else s.setup), auto := false }

/-- `link_auto_start`'s guard (1927). -/
def startsAuto (s : St) : Prop :=
  s.core.isGba = true ∧ s.nl = none ∧ s.auto = false ∧ s.setup = .none

instance (s : St) : Decidable (startsAuto s) := by unfold startsAuto; infer_instance

/-- `link_auto_start` (1924-1935). `link_host_buf` is NOT reset: the probe in
    service_link_setup (2013) connects to whatever it holds. -/
def autoStart (s : St) : St :=
  { s with auto := (if startsAuto s then true else s.auto),
           setup := (if startsAuto s then .connecting else s.setup),
           status := (if startsAuto s then .empty else s.status) }

/-- `update_link_auto` (2094-2103): edge-triggered on the window. The open
    edge starts auto-pairing when nothing is in progress (2099); the close
    edge runs `link_auto_stop` (2102), which only acts under auto. -/
def opens (s : St) : Prop := s.win = true ∧ s.winPrev = false ∧ startsAuto s
def closes (s : St) : Prop := s.win = false ∧ s.winPrev = true ∧ s.auto = true

instance (s : St) : Decidable (opens s) := by unfold opens; infer_instance
instance (s : St) : Decidable (closes s) := by unfold closes; infer_instance

def updateAuto (s : St) : St :=
  { s with auto := (if opens s then true else if closes s then false else s.auto),
           setup := (if opens s then .connecting else if closes s then .none else s.setup),
           server := (if closes s ∧ s.setup = .listening then false else s.server),
           status := (if opens s then .empty else s.status),
           winPrev := s.win }

/-- `app.netlink` drives the loaded core. -/
def linkedHere (s : St) : Prop := s.nl.isSome = true ∧ linkOf s.core = s.nl

instance (s : St) : Decidable (linkedHere s) := by unfold linkedHere; infer_instance

/-- `load_state_slot` (844-853) succeeded on the loaded core. -/
def loadState (s : St) : St := { s with desync := (if linkedHere s then true else s.desync) }

/-- `finish_link` (1826-1848). `readFile(current_rom_path())` (1833) runs
    first: IOError if the file is gone. Then `new_net_link(app.gba_emu, ...)`:
    with a GB core `app.gba_emu` is nil and `new_net_core` dereferences it
    (`gba.set_sio_driver`, netcore.nim 910). Only `NetLinkError` is caught. -/
def finishLink (s : St) (h : Hs) : St :=
  { s with pc := (if s.core.isGba = false ∨ h = .romGone then .crashed else s.pc),
           nl := (if s.core.isGba = true ∧ h = .ok then linkOf s.core else s.nl),
           rewinding := (if s.core.isGba = true ∧ h = .ok then false else s.rewinding),
           status := (if s.core.isGba = true ∧ h = .ok then .linked
                      else if s.core.isGba = true ∧ (h = .rejected ∨ h = .timeout) then .hsFailed
                      else s.status),
           auto := (if s.core.isGba = true ∧ h = .ok then false else s.auto),
           freeze := (if s.core.isGba = true ∧ h = .timeout then .helloWait else s.freeze) }

/-- `service_link_setup`'s connect failure (2019-2031); under auto, after the
    probe limit, `link_auto_listen` (1967-1984), whose bind fails while our
    own listener holds the port. -/
def refusedStep (s : St) (limit bindOk hung : Bool) : St :=
  { s with freeze := (if hung = true ∧ s.host = .other then .connectHang else s.freeze),
           server := (if s.auto = true ∧ limit = true ∧ bindOk = true ∧ s.server = false then true
                      else s.server),
           setup := (if s.auto = true ∧ limit = true ∧ bindOk = true ∧ s.server = false then .listening
                     else if s.auto = false ∧ limit = true then .none else s.setup),
           status := (if s.auto = false ∧ limit = true then .reachFail else s.status) }

/-- `service_link_setup` (1986-2032). Nothing re-checks `link_ready()`. -/
def serviceSetup (s : St) (o : SvcOut) : St :=
  match s.setup, o with
  | .listening, .accept h => finishLink { s with server := false, setup := .none } h   -- 1995-2007
  | .listening, .acceptErr =>                                                          -- 1997-2005
      -- link_server is not closed on either branch
      { s with setup := (if s.auto = true then .connecting else .none),
               status := (if s.auto = true then s.status else .acceptFail) }
  | .connecting, .connect h => finishLink { s with setup := .none } h                  -- 2015-2018
  | .connecting, .refused limit bindOk hung => refusedStep s limit bindOk hung         -- 2019-2031
  | _, _ => s

/-- Phase 1 runs `app.netlink.step_frame()` (2455-2467): not paused, a GBA
    loaded, and linked (the rewind branch, 2432, needs `netlink == nil`).
    It drives `NetLink.gba`, whichever core that is. A GB core never steps
    `app.netlink` (2474 is `run_until_frame`). -/
def linkActive (s : St) : Prop := s.paused = false ∧ s.core.isGba = true ∧ s.nl.isSome = true

instance (s : St) : Decidable (linkActive s) := by unfold linkActive; infer_instance

def emuStep (s : St) (o : LinkOut) : St :=
  if linkActive s then
    match o with
    | .frame => s
    | .frameBye => teardown s                                     -- 2465-2467
    | .lost parked stalled =>                                     -- 2462-2464
        { s with nl := none,
                 stuck := (if parked = true ∧ linkedHere s then s.nl else s.stuck),
                 freeze := (if stalled = true then .stallWait else s.freeze) }
  else s

/-- Phase 2: `process_pending_state` (925-940). -/
def pendStep (s : St) (ok : Bool) : St :=
  { s with pendLoad := (if s.pendLoad = true ∧ s.core ≠ .none then false else s.pendLoad),
           desync := (if s.pendLoad = true ∧ s.core ≠ .none ∧ ok = true ∧ linkedHere s then true
                      else s.desync) }

/-- `link_start_host` after the caller's cancel (1942-1957). -/
def hostStart (s : St) (ok : Bool) : St :=
  { s with server := (if ok = true then true else s.server),
           setup := (if ok = true then .listening else s.setup),
           status := (if ok = true then .empty else .hostFail) }

def toEmu (t : St) : St := { t with pc := (if t.pc = .crashed then .crashed else .emu) }
def toUi (t : St) : St := { t with pc := (if t.pc = .crashed then .crashed else .ui) }

/-- `main`'s start (2285-2311) and `establish_netlink` (1850-1907). -/
def bootStep (s : St) : Boot → St
  | .none => { s with pc := .emu }
  | .rom k => { loadRom s k with pc := .emu }
  | .link .gb _ _ => { loadRom s .gb with pc := .emu }             -- 1855: "needs a GBA ROM"
  | .link .gba peer h =>
      -- the window exists but no events are pumped (1865-1892)
      if peer = true then toEmu (finishLink { loadRom s .gba with freeze := .cliWait } h)
      else { loadRom s .gba with freeze := .cliWait, pc := .emu }  -- 120 s / 40 tries: single-player
  | .auto k => { loadRom s k with win := (k.mk s.gen).isGba, pc := .emu }   -- 2301-2307
  | .badPort => { s with pc := .crashed }               -- ValueError escapes `except OSError` (1898)

/-- Phase 5 clicks. -/
def uiStep (s : St) : Ev → St
  | .mOpen k => if menuOk s = true then loadRom s k else s
  | .mReset k => if menuOk s = true then loadRom s k else s
  | .mQuickLoad =>                                                                 -- no link gate
      if menuOk s = true ∧ s.core ≠ .none then { s with pendLoad := true } else s
  | .mSlotLoad ok => if s.core ≠ .none ∧ ok = true then loadState s else s          -- no link gate
  | .mPause => if menuOk s = true then { s with paused := !s.paused } else s
  | .mLinkMenu =>                                                                  -- greyed out unless GBA (1378)
      if menuOk s = true ∧ s.core.isGba = true then { s with win := !s.win } else s
  | .mQuit => if menuOk s = true then { s with running := false } else s
  | .wClose => if s.win = true then { s with win := false } else s
  | .wDisconnect slow =>
      if s.win = true ∧ s.nl.isSome = true then
        { s with nl := none, status := .empty,
                 freeze := (if slow = true then .closeDrain else s.freeze) }
      else s
  | .wCancel =>
      if s.win = true ∧ s.nl = none ∧ ready s = true ∧ s.auto = false ∧ s.setup ≠ .none then
        cancelSetup s
      else s
  | .wHost ok =>
      if s.win = true ∧ s.nl = none ∧ ready s = true then hostStart (cancelSetup (autoStop s)) ok
      else s
  | .wJoin =>
      if s.win = true ∧ s.nl = none ∧ ready s = true then
        { cancelSetup (autoStop s) with setup := .connecting, status := .empty }
      else s
  | .wEditHost h =>
      if s.win = true ∧ s.nl = none ∧ ready s = true then { s with host := h } else s
  | .endUi =>
      -- `while app.running` (2426); after the loop only flush_gb_save/input_log_close (2606)
      if s.running = true then { s with pc := .emu }
      else { s with pc := .exited, byeOwed := s.nl.isSome }
  | _ => s

def step (s : St) (e : Ev) : St :=
  match e with
  | .boot b => if s.pc = .boot then bootStep s b else s
  | .emu o => if s.pc = .emu then { emuStep s o with pc := .pend } else s
  | .emuSkip => if s.pc = .emu then { s with pc := .pend } else s
  | .pend ok => if s.pc = .pend then { pendStep s ok with pc := .input } else s
  | .keyPause => if s.pc = .input then { s with paused := !s.paused } else s
  | .keyQuickLoad =>                                                  -- 1659: gated when pressed
      if s.pc = .input ∧ s.core ≠ .none ∧ s.nl = none then { s with pendLoad := true } else s
  | .keyRewind d =>                                                   -- 1676-1677
      if s.pc = .input then
        { s with rewinding := (if d = true ∧ s.core ≠ .none ∧ s.nl = none then true else false) }
      else s
  | .keyReset k => if s.pc = .input then loadRom s k else s
  | .drop k => if s.pc = .input then loadRom s k else s
  | .quit => if s.pc = .input then { s with running := false } else s
  | .mouse b => if s.pc = .input then { s with menu := b } else s
  | .endInput => if s.pc = .input then { s with pc := .svc } else s
  | .svc o => if s.pc = .svc then toUi (serviceSetup (updateAuto s) o) else s
  | e => if s.pc = .ui then uiStep s e else s

def run (s : St) (es : List Ev) : St := es.foldl step s

def init : St := {}

inductive Reachable : St → Prop where
  | init : Reachable init
  | step {s} (e : Ev) : Reachable s → Reachable (step s e)

/-- One main-loop iteration: phase 1, phase 2, SDL events, phase 4, clicks. -/
def it (emu : Ev) (pendOk : Bool) (inp : List Ev) (o : SvcOut) (ui : List Ev) : List Ev :=
  [emu, .pend pendOk] ++ inp ++ [.endInput, .svc o] ++ ui ++ [.endUi]

/-- A GBA game; the user opens Emulation > Link Cable...; next iteration the
    auto-pair probe of 127.0.0.1:47810 finds the other instance hosting. -/
def tLinked : List Ev :=
  [.boot (.rom .gba)] ++
  it .emuSkip false [.mouse true] .idle [.mLinkMenu] ++
  it .emuSkip false [] (.connect .ok) []

theorem linked_ok :
    let s := run init tLinked
    s.nl = some 0 ∧ s.core = .gba 0 ∧ s.status = .linked ∧ s.pc = .emu := by decide

/-- The link drives a core that is not the one on screen. -/
def hiddenLink (s : St) : Bool :=
  match s.nl with
  | some n => s.core != .gba n
  | none => false

/-! ### Proved for the code as it is -/

/-- Never rewinding while linked. -/
def RG (s : St) : Prop := s.nl.isSome = true → s.rewinding = false

/-- Rewind is gated correctly (1676, 2432, 2476, 1837): it never runs while linked. -/
theorem rewind_gated_step {s : St} (h : RG s) (e : Ev) : RG (step s e) := by
  unfold RG at *
  cases e <;> simp only [step, uiStep, bootStep, serviceSetup, emuStep] <;> (repeat' split) <;>
    simp_all [loadRom, teardown, cancelSetup, autoStop, autoStart, updateAuto, loadState,
      finishLink, refusedStep, pendStep, hostStart, toEmu, toUi] <;>
    (repeat' split) <;> simp_all

theorem rewind_gated {s : St} (h : Reachable s) : RG s := by
  induction h with
  | init => simp [RG, init]
  | step e _ ih => exact rewind_gated_step ih e

/-- A GBA -> GBA switch while hosting is fine: the peer links to the new game. -/
theorem ok_gba_switch_while_hosting_links_new_game :
    let s := run init ([.boot (.rom .gba)] ++
      it .emuSkip false [.mouse true] .idle [.mLinkMenu] ++
      it .emuSkip false [] (.refused true true false) [] ++       -- nobody answered: auto hosts
      it .emuSkip false [.drop .gba] (.accept .ok) [])
    s.nl = some 1 ∧ s.core = .gba 1 := by decide

/-! ### Counterexamples -/

/-- (a) Ctrl+R while linked: `load_rom` builds core 1, `app.netlink` still
    drives core 0. Core 1 never runs (2455 takes the linked branch), so the
    screen freezes on its first frame; keys go to core 1; core 0 keeps
    playing, linked to the peer, and queues ITS audio on the shared SDL
    device (apu.nim 134-139 reopens device 1), which also paces 2455. -/
theorem bug_reset_while_linked_drives_hidden_core :
    let s := run init (tLinked ++ it (.emu .frame) false [.keyReset .gba] .idle [] ++
                        it (.emu .frame) false [] .idle [])
    hiddenLink s = true ∧ s.nl = some 0 ∧ s.core = .gba 1 := by decide

/-- (a) Dropping a GB game while linked: the GB core runs, `app.netlink`
    stays set forever (never stepped: 2453 is the ekGBA branch), no BYE is
    sent, the peer stalls 30 s. Ctrl+L and rewind stay disabled in the GB
    game, and Emulation > Link Cable... is greyed out for GB (1378), so once
    the window is closed there is no Disconnect. -/
theorem bug_gb_switch_keeps_dead_link :
    let s := run init (tLinked ++ it (.emu .frame) false [.drop .gb] .idle [.wClose] ++
                        it (.emu .frame) false [.keyQuickLoad] .idle [.mLinkMenu])
    s.nl = some 0 ∧ s.core = .gb 1 ∧ s.pendLoad = false ∧ s.win = false := by decide

/-- (b) The Link Cable window is pairing (auto-pair fell back to hosting);
    the user drops a .gb ROM and leaves the window open (it now says "Load a
    GBA ROM, then reopen this window"). The listener is still polled; the
    other instance opens its Link Cable window, its probe is accepted, and
    `finish_link` hands a nil `app.gba_emu` to `new_net_core`: crash. -/
theorem bug_gb_switch_during_setup_crashes :
    let s := run init ([.boot (.rom .gba)] ++
      it .emuSkip false [.mouse true] .idle [.mLinkMenu] ++
      it .emuSkip false [] (.refused true true false) [] ++
      it .emuSkip false [.drop .gb] (.accept .ok) [])
    s.pc = .crashed := by decide

/-- (b) The same with the window closed: a manual Host keeps listening. -/
theorem bug_manual_host_gb_switch_crashes :
    let s := run init ([.boot (.rom .gba)] ++
      it .emuSkip false [.mouse true] .idle [.mLinkMenu] ++
      it .emuSkip false [] .idle [.wHost true, .wClose] ++
      it .emuSkip false [.drop .gb] .idle [] ++
      it .emuSkip false [] (.accept .ok) [])
    s.pc = .crashed := by decide

/-- (c) File > Quick Load is not gated on the link (1311); only Ctrl+L is. -/
theorem bug_menu_quick_load_while_linked :
    let s := run init (tLinked ++ it (.emu .frame) false [] .idle [.mQuickLoad] ++
                        [.emu .frame, .pend true])
    s.desync = true := by decide

/-- (c) The Save States window's Load (on_load, 2274) is not gated either. -/
theorem bug_slot_load_while_linked :
    let s := run init (tLinked ++ it (.emu .frame) false [] .idle [.mSlotLoad true])
    s.desync = true := by decide

/-- (c) Ctrl+L is gated when pressed (1659), not when serviced: pressed in the
    iteration the link completes, it loads into the linked core next
    iteration. Window: one loop iteration (about 1 ms). -/
theorem bug_ctrl_l_races_link :
    let s := run init ([.boot (.rom .gba)] ++
      it .emuSkip false [.mouse true] .idle [.mLinkMenu] ++
      it .emuSkip false [.keyQuickLoad] (.connect .ok) [] ++
      [.emu .frame, .pend true])
    s.desync = true := by decide

/-- (d) An accept that raises (1997) leaves `link_server` open on both
    branches. Under auto-pair the next bind fails on our own listener, and
    the next probe connects to it: nobody accepts, so the handshake blocks
    the UI 30 s, fails, and auto-pair is stranded (see below). -/
theorem bug_accept_error_leaks_listener :
    let s := run init ([.boot (.rom .gba)] ++
      it .emuSkip false [.mouse true] .idle [.mLinkMenu] ++
      it .emuSkip false [] (.refused true true false) [] ++
      it .emuSkip false [] .acceptErr [] ++
      it .emuSkip false [] (.refused true true false) [] ++
      it .emuSkip false [] (.connect .timeout) [])
    s.server = true ∧ s.setup = .none ∧ s.auto = true ∧ s.nl = none ∧
      s.freeze = .helloWait := by decide

/-- A failed handshake under auto-pair leaves `link_auto` set with nothing in
    progress: the window shows "Waiting to pair..." forever (2072), and the
    open edge never re-fires. E.g. two builds with different LINKPROTO_VERSION. -/
theorem bug_handshake_fail_strands_auto :
    let s := run init ([.boot (.rom .gba)] ++
      it .emuSkip false [.mouse true] .idle [.mLinkMenu] ++
      it .emuSkip false [] (.connect .rejected) [] ++
      it .emuSkip false [] .idle [])
    s.auto = true ∧ s.setup = .none ∧ s.nl = none ∧ s.win = true := by decide

/-- (e) A NetLinkError while parked at S+D (`reply_wait`) tears the link down
    with the exchange unfinished: the BYE path completes it as a yanked cable
    (netcore.nim 696-704), the error path does not, and `NullSioDriver` never
    sees the completion that already fired. SIOCNT stays busy. -/
theorem bug_lost_peer_leaves_transfer_busy :
    let s := run init (tLinked ++ it (.emu (.lost true false)) false [] .idle [])
    s.stuck = some 0 ∧ s.core = .gba 0 ∧ s.nl = none := by decide

/-- After a lost link the window still says "Linked as guest (unit 1)" (2089-2091). -/
theorem bug_link_lost_ui_says_linked :
    let s := run init (tLinked ++ it (.emu (.lost false false)) false [] .idle [])
    s.status = .linked ∧ s.nl = none := by decide

/-- Quit (window close, Ctrl+Q, File > Exit) while linked: the loop ends and
    nothing sends BYE; the OS closes the socket and the peer takes the error
    path (Part B). -/
theorem bug_quit_while_linked_sends_no_bye :
    let s := run init (tLinked ++ it (.emu .frame) false [.quit] .idle [])
    s.pc = .exited ∧ s.byeOwed = true := by decide

/-- Auto-pair probes `link_host_buf`, not 127.0.0.1: after a Join to another
    address, reopening the window auto-pairs against that address, and a
    host that drops SYNs blocks connect() (~75 s) with the UI frozen. -/
theorem bug_auto_probes_typed_host :
    let s := run init ([.boot (.rom .gba)] ++
      it .emuSkip false [.mouse true] .idle [.mLinkMenu] ++
      it .emuSkip false [] .idle [.wEditHost .other, .wJoin, .wCancel, .wClose] ++
      it .emuSkip false [] .idle [.mLinkMenu] ++
      it .emuSkip false [] (.refused false false true) [])
    s.auto = true ∧ s.setup = .connecting ∧ s.host = .other ∧ s.freeze = .connectHang := by decide

/-- A manual Host survives closing the window (only auto stops on close,
    2101), and a peer later links with the window closed. -/
theorem bug_manual_host_survives_window_close :
    let s := run init ([.boot (.rom .gba)] ++
      it .emuSkip false [.mouse true] .idle [.mLinkMenu] ++
      it .emuSkip false [] .idle [.wHost true, .wClose] ++
      it .emuSkip false [] .idle [] ++
      it .emuSkip false [] (.accept .ok) [])
    s.nl = some 0 ∧ s.win = false := by decide

/-- The ROM file moved or deleted after loading: `readFile` in finish_link
    raises IOError, which `except NetLinkError` does not catch. -/
theorem bug_rom_file_gone_crashes :
    let s := run init ([.boot (.rom .gba)] ++
      it .emuSkip false [.mouse true] .idle [.mLinkMenu] ++
      it .emuSkip false [] (.connect .romGone) [])
    s.pc = .crashed := by decide

/-- `--connect host:x`: parseInt's ValueError escapes `except OSError`. -/
theorem bug_cli_bad_port_crashes : (run init [.boot .badPort]).pc = .crashed := by decide

/-- `--listen` blocks before the loop with the window already open (up to
    120 s + 30 s): no events, no redraw, Quit ignored. -/
theorem cli_link_freezes_window :
    (run init [.boot (.link .gba false .ok)]).freeze = .cliWait := by decide

/-! ### The fix, as shipped

The pairing code moved to `frontend/link_cable.nim` (`LinkCable`); the
wrappers in `dingbat.nim` keep the old names.

1. `load_rom`: `teardown_netlink(); link_auto_stop(); link_cancel_setup()`.
   A new game, GBA or GB, or a Reset, ends the link and any pairing in
   progress (the GameLifecycle fix; `loadRomF`).
2. `load_state_slot`: `if app.netlink != nil: return false`, and
   `state_reject_sentence` says "can't be loaded while the link cable is
   connected"; File > Quick Load greys out while linked. The check sits at
   the consumer, so it also closes Ctrl+L's same-iteration race and covers
   the Save States window's Load.
3. `LinkCable.service_setup`: an accept error closes the listener before
   branching.
4. `LinkCable.finish_link`: refuses with no GBA core (`gba == nil`),
   `except CatchableError` (IOError from readFile, OSError from
   setSockOpt), and `auto = false` on every outcome, so the window shows
   the error instead of "Waiting to pair...".
5. `LinkCable.teardown`: `NetLink.shutdown` (BYE, close, the no-cable
   driver) and "Link ended: <why>". netcore.nim: `RemoteSioDriver.
   sio_detached` completes a `reply_wait` round as the BYE branch does.
6. After the loop: `teardown_netlink(); link_auto_stop();
   link_cancel_setup()`, so the peer gets its BYE (the GameLifecycle fix).
7. `LinkCable.update_auto`: level-triggered; a closed window hosts and
   joins nothing.
8. Auto-pair connects to `LINK_AUTO_HOST` = "127.0.0.1", not the Join box.
9. `establish_netlink`: `parse_host_port` refuses `HOST:x`.
10. `step_frame_for` hands back to the loop while parked on the peer
   (Part B), so a stall timeout is a teardown but never a freeze.
-/

def teardownF (s : St) : St :=
  { s with nl := none, status := (if s.nl.isSome = true then .ended else s.status) }

def loadRomF (s : St) (k : Kind) : St := loadRom (cancelSetup (autoStop (teardownF s))) k

def loadStateF (s : St) : St := if s.nl = none then loadState s else s

def finishLinkF (s : St) (h : Hs) : St :=
  { s with nl := (if s.core.isGba = true ∧ h = .ok then linkOf s.core else s.nl),
           rewinding := (if s.core.isGba = true ∧ h = .ok then false else s.rewinding),
           status := (if s.core.isGba = true ∧ h = .ok then .linked else .hsFailed),
           auto := false,
           freeze := (if h = .timeout then .helloWait else s.freeze) }

def updateAutoF (s : St) : St :=
  { s with auto := (if opens s then true else if s.win = false then false else s.auto),
           setup := (if opens s then .connecting else if s.win = false then .none else s.setup),
           server := (if s.win = false ∧ s.setup = .listening then false else s.server),
           status := (if opens s then .empty else s.status),
           winPrev := s.win }

def refusedStepF (s : St) (limit bindOk hung : Bool) : St :=
  { refusedStep s limit bindOk hung with
      freeze := (if hung = true ∧ s.host = .other ∧ s.auto = false then .connectHang else s.freeze) }

def serviceSetupF (s : St) (o : SvcOut) : St :=
  match s.setup, o with
  | .listening, .accept h => finishLinkF { s with server := false, setup := .none } h
  | .listening, .acceptErr =>
      { s with server := false, setup := (if s.auto = true then .connecting else .none),
               status := (if s.auto = true then s.status else .acceptFail) }
  | .connecting, .connect h => finishLinkF { s with setup := .none } h
  | .connecting, .refused limit bindOk hung => refusedStepF s limit bindOk hung
  | _, _ => s

def emuStepF (s : St) (o : LinkOut) : St :=
  if linkActive s then
    match o with
    | .frame => s
    | .frameBye => teardownF s
    | .lost _ _ => teardownF s     -- step_frame_for returned to the loop meanwhile
  else s

/-- `process_pending_state` with fix 2: `load_state_slot` refuses while
    linked, so the pending load is consumed and, linked, does nothing. -/
def pendStepF (s : St) (ok : Bool) : St :=
  if s.pendLoad = true ∧ s.core ≠ .none then
    (if ok = true then loadStateF { s with pendLoad := false } else { s with pendLoad := false })
  else s

def bootStepF (s : St) : Boot → St
  | .none => { s with pc := .emu }
  | .rom k => { loadRom s k with pc := .emu }
  | .link .gb _ _ => { loadRom s .gb with pc := .emu }
  | .link .gba peer h =>
      if peer = true then { finishLinkF { loadRom s .gba with freeze := .cliWait } h with pc := .emu }
      else { loadRom s .gba with freeze := .cliWait, pc := .emu }
  | .auto k => { loadRom s k with win := (k.mk s.gen).isGba, pc := .emu }
  | .badPort => { s with pc := .emu }

def uiStepF (s : St) : Ev → St
  | .mOpen k => if menuOk s = true then loadRomF s k else s
  | .mReset k => if menuOk s = true then loadRomF s k else s
  | .mQuickLoad =>
      if menuOk s = true ∧ s.core ≠ .none ∧ s.nl = none then { s with pendLoad := true } else s
  | .mSlotLoad ok => if s.core ≠ .none ∧ ok = true then loadStateF s else s
  | .mPause => if menuOk s = true then { s with paused := !s.paused } else s
  | .mLinkMenu =>
      if menuOk s = true ∧ s.core.isGba = true then { s with win := !s.win } else s
  | .mQuit => if menuOk s = true then { s with running := false } else s
  | .wClose => if s.win = true then { s with win := false } else s
  | .wDisconnect slow =>
      if s.win = true ∧ s.nl.isSome = true then
        { teardownF s with status := .empty,
                           freeze := (if slow = true then .closeDrain else s.freeze) }
      else s
  | .wCancel =>
      if s.win = true ∧ s.nl = none ∧ ready s = true ∧ s.auto = false ∧ s.setup ≠ .none then
        cancelSetup s
      else s
  | .wHost ok =>
      if s.win = true ∧ s.nl = none ∧ ready s = true then hostStart (cancelSetup (autoStop s)) ok
      else s
  | .wJoin =>
      if s.win = true ∧ s.nl = none ∧ ready s = true then
        { cancelSetup (autoStop s) with setup := .connecting, status := .empty }
      else s
  | .wEditHost h =>
      if s.win = true ∧ s.nl = none ∧ ready s = true then { s with host := h } else s
  | .endUi =>
      if s.running = true then { s with pc := .emu }
      else { cancelSetup (autoStop (teardownF s)) with pc := .exited }
  | _ => s

def stepF (s : St) (e : Ev) : St :=
  match e with
  | .boot b => if s.pc = .boot then bootStepF s b else s
  | .emu o => if s.pc = .emu then { emuStepF s o with pc := .pend } else s
  | .emuSkip => if s.pc = .emu then { s with pc := .pend } else s
  | .pend ok => if s.pc = .pend then { pendStepF s ok with pc := .input } else s
  | .keyPause => if s.pc = .input then { s with paused := !s.paused } else s
  | .keyQuickLoad =>
      if s.pc = .input ∧ s.core ≠ .none ∧ s.nl = none then { s with pendLoad := true } else s
  | .keyRewind d =>
      if s.pc = .input then
        { s with rewinding := (if d = true ∧ s.core ≠ .none ∧ s.nl = none then true else false) }
      else s
  | .keyReset k => if s.pc = .input then loadRomF s k else s
  | .drop k => if s.pc = .input then loadRomF s k else s
  | .quit => if s.pc = .input then { s with running := false } else s
  | .mouse b => if s.pc = .input then { s with menu := b } else s
  | .endInput => if s.pc = .input then { s with pc := .svc } else s
  | .svc o => if s.pc = .svc then { serviceSetupF (updateAutoF s) o with pc := .ui } else s
  | e => if s.pc = .ui then uiStepF s e else s

def runF (s : St) (es : List Ev) : St := es.foldl stepF s

inductive ReachableF : St → Prop where
  | init : ReachableF init
  | step {s} (e : Ev) : ReachableF s → ReachableF (stepF s e)

/-- (a)-(e), plus the window telling the truth. -/
structure Inv (s : St) : Prop where
  onScreen   : ∀ n, s.nl = some n → s.core = .gba n                 -- (a)
  setupGba   : s.setup ≠ .none → s.core.isGba = true                -- (b)
  noDesync   : s.desync = false                                     -- (c)
  serverOwn  : s.server = true ↔ s.setup = .listening               -- (d)
  noStuck    : s.stuck = none                                       -- (e)
  statusTrue : s.status = .linked → s.nl.isSome = true              -- "Linked as ..." is true
  autoLive   : s.auto = true → s.setup ≠ .none                      -- "Waiting to pair" is true
  byeSent    : s.byeOwed = false                                    -- the peer always gets a BYE
  noRewind   : s.nl.isSome = true → s.rewinding = false

structure Safe (s : St) : Prop where
  inv       : Inv s
  noCrash   : s.pc ≠ .crashed
  exitClean : s.pc = .exited → s.nl = none ∧ s.server = false      -- (d) at exit
  bootClean : s.pc = .boot → s.nl = none ∧ s.setup = .none ∧ s.server = false ∧ s.auto = false

@[simp] theorem linkOf_eq_some {c : Core} {n : Nat} : linkOf c = some n ↔ c = .gba n := by
  cases c <;> simp [linkOf]

@[simp] theorem isSome_linkOf {c : Core} : (linkOf c).isSome = c.isGba := by
  cases c <;> rfl

@[simp] theorem Kind.mk_ne_none {k : Kind} {g : Nat} : k.mk g ≠ .none := by
  cases k <;> simp [Kind.mk]

theorem Inv.congr {s t : St} (h : Inv s) (h1 : t.nl = s.nl) (h2 : t.core = s.core)
    (h3 : t.setup = s.setup) (h4 : t.desync = s.desync) (h5 : t.server = s.server)
    (h6 : t.stuck = s.stuck) (h7 : t.status = s.status) (h8 : t.auto = s.auto)
    (h9 : t.byeOwed = s.byeOwed) (h10 : t.rewinding = s.rewinding) : Inv t := by
  obtain ⟨a1, a2, a3, a4, a5, a6, a7, a8, a9⟩ := h
  constructor <;> simp_all

/-- Fields the invariant does not read. -/
theorem Inv.frame {s t : St} (h : Inv s)
    (e : t = { s with pc := t.pc, paused := t.paused, pendLoad := t.pendLoad, running := t.running,
                      menu := t.menu, win := t.win, winPrev := t.winPrev, host := t.host,
                      freeze := t.freeze, gen := t.gen }) : Inv t := by
  rw [e]; exact h.congr rfl rfl rfl rfl rfl rfl rfl rfl rfl rfl

theorem Inv.withStatus {s : St} (h : Inv s) (st : Status) (hst : st ≠ .linked) :
    Inv { s with status := st } := by
  obtain ⟨a1, a2, a3, a4, a5, a6, a7, a8, a9⟩ := h
  constructor <;> simp_all

theorem inv_teardownF {s : St} (h : Inv s) : Inv (teardownF s) := by
  obtain ⟨a1, a2, a3, a4, a5, a6, a7, a8, a9⟩ := h
  constructor <;> simp only [teardownF] <;> (repeat' split) <;> simp_all

theorem inv_autoStop {s : St} (h : Inv s) : Inv (autoStop s) := by
  obtain ⟨a1, a2, a3, a4, a5, a6, a7, a8, a9⟩ := h
  constructor <;> simp only [autoStop] <;> (repeat' split) <;> simp_all

theorem inv_cancel {s : St} (h : Inv s) (ha : s.auto = false) : Inv (cancelSetup s) := by
  obtain ⟨a1, a2, a3, a4, a5, a6, a7, a8, a9⟩ := h
  constructor <;> simp only [cancelSetup] <;> (repeat' split) <;> simp_all

theorem cancel_autoStop_clean (s : St) (h : Inv s) :
    (cancelSetup (autoStop s)).setup = .none ∧ (cancelSetup (autoStop s)).server = false ∧
    (cancelSetup (autoStop s)).auto = false ∧ (cancelSetup (autoStop s)).nl = s.nl ∧
    (cancelSetup (autoStop s)).core = s.core ∧ (cancelSetup (autoStop s)).pc = s.pc := by
  have := h.serverOwn
  simp only [cancelSetup, autoStop]
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_⟩ <;> (repeat' split) <;> simp_all

theorem inv_cancel_autoStop {s : St} (h : Inv s) : Inv (cancelSetup (autoStop s)) :=
  inv_cancel (inv_autoStop h) (by simp [autoStop])

theorem inv_loadRom {s : St} (h : Inv s) (hn : s.nl = none) (hs : s.setup = .none) (k : Kind) :
    Inv (loadRom s k) := by
  obtain ⟨a1, a2, a3, a4, a5, a6, a7, a8, a9⟩ := h
  constructor <;> simp_all [loadRom]

theorem inv_loadRomF {s : St} (h : Inv s) (k : Kind) : Inv (loadRomF s k) := by
  have ht := inv_teardownF h
  have hc := cancel_autoStop_clean _ ht
  apply inv_loadRom (inv_cancel_autoStop ht) _ hc.1
  rw [hc.2.2.2.1]; simp [teardownF]

theorem loadRomF_pc (s : St) (k : Kind) : (loadRomF s k).pc = s.pc := by
  simp [loadRomF, loadRom, cancelSetup, autoStop, teardownF]

theorem inv_updateAutoF {s : St} (h : Inv s) : Inv (updateAutoF s) := by
  obtain ⟨a1, a2, a3, a4, a5, a6, a7, a8, a9⟩ := h
  constructor <;> simp only [updateAutoF] <;> (repeat' split) <;> simp_all [opens, startsAuto]

theorem inv_finishLinkF_accept {s : St} (h : Inv s) (hh : Hs) :
    Inv (finishLinkF { s with server := false, setup := .none } hh) := by
  obtain ⟨a1, a2, a3, a4, a5, a6, a7, a8, a9⟩ := h
  constructor <;> simp only [finishLinkF] <;> (repeat' split) <;> simp_all

theorem inv_serviceSetupF {s : St} (h : Inv s) (o : SvcOut) : Inv (serviceSetupF s o) := by
  unfold serviceSetupF
  split
  · exact inv_finishLinkF_accept h _
  · obtain ⟨a1, a2, a3, a4, a5, a6, a7, a8, a9⟩ := h
    constructor <;> (repeat' split) <;> simp_all
  · rename_i hs
    have e : ({ s with setup := .none } : St) = { s with server := false, setup := .none } := by
      have := h.serverOwn; cases s; simp_all
    rw [e]; exact inv_finishLinkF_accept h _
  · obtain ⟨a1, a2, a3, a4, a5, a6, a7, a8, a9⟩ := h
    constructor <;> simp only [refusedStepF, refusedStep] <;> (repeat' split) <;> simp_all
  · exact h

theorem inv_emuStepF {s : St} (h : Inv s) (o : LinkOut) : Inv (emuStepF s o) := by
  unfold emuStepF
  split
  · split
    · exact h
    · exact inv_teardownF h
    · exact inv_teardownF h
  · exact h

theorem inv_loadStateF {s : St} (h : Inv s) : Inv (loadStateF s) := by
  obtain ⟨a1, a2, a3, a4, a5, a6, a7, a8, a9⟩ := h
  constructor <;> simp only [loadStateF, loadState] <;> (repeat' split) <;> simp_all [linkedHere]

theorem inv_pendStepF {s : St} (h : Inv s) (ok : Bool) : Inv (pendStepF s ok) := by
  unfold pendStepF
  split
  · split
    · exact inv_loadStateF (h.frame rfl)
    · exact h.frame rfl
  · exact h

theorem loadStateF_pc (s : St) : (loadStateF s).pc = s.pc := by
  unfold loadStateF; split <;> rfl

theorem inv_host {s : St} (h : Inv s) (hg : s.core.isGba = true) (ok : Bool) :
    Inv (hostStart (cancelSetup (autoStop s)) ok) := by
  have hc := cancel_autoStop_clean s h
  have hi := inv_cancel_autoStop h
  obtain ⟨a1, a2, a3, a4, a5, a6, a7, a8, a9⟩ := hi
  constructor <;> simp only [hostStart] <;> (repeat' split) <;> simp_all

theorem inv_join {s : St} (h : Inv s) (hg : s.core.isGba = true) :
    Inv { cancelSetup (autoStop s) with setup := .connecting, status := .empty } := by
  have hc := cancel_autoStop_clean s h
  have hi := inv_cancel_autoStop h
  obtain ⟨a1, a2, a3, a4, a5, a6, a7, a8, a9⟩ := hi
  constructor <;> simp_all

theorem inv_rewindKey {s : St} (h : Inv s) (d : Bool) :
    Inv { s with rewinding := (if d = true ∧ s.core ≠ .none ∧ s.nl = none then true else false) } := by
  obtain ⟨a1, a2, a3, a4, a5, a6, a7, a8, a9⟩ := h
  constructor <;> (repeat' split) <;> simp_all

theorem safe_init : Safe init := by
  refine ⟨?_, ?_, ?_, ?_⟩
  · constructor <;> simp [init]
  all_goals simp [init]

/-- Anything that keeps `Inv` and lands in a loop phase is safe. -/
theorem safe_of_inv {t : St} (hi : Inv t) (hp : t.pc = .emu ∨ t.pc = .pend ∨ t.pc = .input ∨
    t.pc = .svc ∨ t.pc = .ui) : Safe t := by
  refine ⟨hi, ?_, ?_, ?_⟩ <;> rcases hp with hp | hp | hp | hp | hp <;> simp [hp]

theorem safe_bootStepF {s : St} (h : Safe s) (hb : s.pc = .boot) (b : Boot) : Safe (bootStepF s b) := by
  obtain ⟨hi, _, _, hbc⟩ := h
  obtain ⟨n0, s0, v0, a0⟩ := hbc hb
  have hl : ∀ k, Inv (loadRom s k) := fun k => inv_loadRom hi n0 s0 k
  cases b with
  | none => exact safe_of_inv (hi.frame rfl) (by simp [bootStepF])
  | rom k => exact safe_of_inv ((hl k).frame rfl) (by simp [bootStepF])
  | link k peer hh =>
    cases k with
    | gb => exact safe_of_inv ((hl .gb).frame rfl) (by simp [bootStepF])
    | gba =>
      simp only [bootStepF]
      split
      · have hl' : Inv { loadRom s .gba with freeze := .cliWait } := (hl .gba).frame rfl
        have e : ({ loadRom s .gba with freeze := .cliWait } : St) =
                 { { loadRom s .gba with freeze := .cliWait } with server := false, setup := .none } := by
          simp [loadRom, v0, s0]
        have hf : Inv (finishLinkF { loadRom s .gba with freeze := .cliWait } hh) := by
          rw [e]; exact inv_finishLinkF_accept hl' hh
        exact safe_of_inv (hf.frame rfl) (by simp)
      · exact safe_of_inv ((hl .gba).frame rfl) (by simp)
  | auto k => exact safe_of_inv ((hl k).frame rfl) (by simp [bootStepF])
  | badPort => exact safe_of_inv (hi.frame rfl) (by simp [bootStepF])

theorem safe_uiStepF {s : St} (h : Safe s) (hu : s.pc = .ui) (e : Ev) : Safe (uiStepF s e) := by
  have hi := h.inv
  cases e <;> simp only [uiStepF] <;> (try exact h) <;> split <;> (try exact h)
  -- mOpen, mReset
  · exact safe_of_inv (inv_loadRomF hi _) (by simp [loadRomF_pc, hu])
  · exact safe_of_inv (inv_loadRomF hi _) (by simp [loadRomF_pc, hu])
  -- mQuickLoad
  · exact safe_of_inv (hi.frame rfl) (by simp [hu])
  -- mSlotLoad
  · exact safe_of_inv (inv_loadStateF hi) (by simp [loadStateF_pc, hu])
  -- mPause, mLinkMenu, mQuit, wClose
  · exact safe_of_inv (hi.frame rfl) (by simp [hu])
  · exact safe_of_inv (hi.frame rfl) (by simp [hu])
  · exact safe_of_inv (hi.frame rfl) (by simp [hu])
  · exact safe_of_inv (hi.frame rfl) (by simp [hu])
  -- wDisconnect
  · exact safe_of_inv (((inv_teardownF hi).withStatus .empty (by simp)).frame rfl)
      (by simp [teardownF, hu])
  -- wCancel
  · rename_i hc
    exact safe_of_inv (inv_cancel hi hc.2.2.2.1) (by simp [cancelSetup, hu])
  -- wHost
  · rename_i hc
    exact safe_of_inv (inv_host hi (by simpa [ready] using hc.2.2) _)
      (by simp [hostStart, cancelSetup, autoStop, hu])
  -- wJoin
  · rename_i hc
    exact safe_of_inv (inv_join hi (by simpa [ready] using hc.2.2))
      (by simp [cancelSetup, autoStop, hu])
  -- wEditHost
  · exact safe_of_inv (hi.frame rfl) (by simp [hu])
  -- endUi
  · exact safe_of_inv (hi.frame rfl) (by simp)
  · have ht := inv_teardownF hi
    have hc := cancel_autoStop_clean _ ht
    refine ⟨(inv_cancel_autoStop ht).frame rfl, by simp, ?_, by simp⟩
    intro _
    exact ⟨by rw [hc.2.2.2.1]; simp [teardownF], hc.2.1⟩

theorem safe_stepF {s : St} (h : Safe s) (e : Ev) : Safe (stepF s e) := by
  have hi := h.inv
  cases e <;> simp only [stepF] <;> split <;> (try exact h)
  · exact safe_bootStepF h (by assumption) _
  · exact safe_of_inv ((inv_emuStepF hi _).frame rfl) (by simp)
  · exact safe_of_inv (hi.frame rfl) (by simp)
  · exact safe_of_inv ((inv_pendStepF hi _).frame rfl) (by simp)
  · exact safe_of_inv (hi.frame rfl) (by simp_all)
  · exact safe_of_inv (hi.frame rfl) (by simp_all)
  · exact safe_of_inv (inv_rewindKey hi _) (by simp_all)
  · exact safe_of_inv (inv_loadRomF hi _) (by simp_all [loadRomF_pc])
  · exact safe_of_inv (inv_loadRomF hi _) (by simp_all [loadRomF_pc])
  · exact safe_of_inv (hi.frame rfl) (by simp_all)
  · exact safe_of_inv (hi.frame rfl) (by simp_all)
  · exact safe_of_inv (hi.frame rfl) (by simp)
  · exact safe_of_inv ((inv_serviceSetupF (inv_updateAutoF hi) _).frame rfl) (by simp)
  all_goals exact safe_uiStepF h (by assumption) _

theorem safeF_reachable {s : St} (h : ReachableF s) : Safe s := by
  induction h with
  | init => exact safe_init
  | step e _ ih => exact safe_stepF ih e

/-- Every Part A counterexample, replayed on the fixed step, ends safely. -/
theorem regress_partA :
    (runF init (tLinked ++ it (.emu .frame) false [.keyReset .gba] .idle [])).nl = none ∧
    (runF init ([.boot (.rom .gba)] ++
      it .emuSkip false [.mouse true] .idle [.mLinkMenu] ++
      it .emuSkip false [] (.refused true true false) [] ++
      it .emuSkip false [.drop .gb] (.accept .ok) [])).pc = .emu ∧
    (runF init (tLinked ++ it (.emu .frame) false [] .idle [.mQuickLoad] ++
                [.emu .frame, .pend true])).desync = false ∧
    (runF init (tLinked ++ it (.emu (.lost true false)) false [] .idle [])).stuck = none ∧
    (runF init (tLinked ++ it (.emu (.lost false false)) false [] .idle [])).status = .ended ∧
    (runF init (tLinked ++ it (.emu .frame) false [.quit] .idle [])).byeOwed = false := by
  decide

/-- The rest of Part A's counterexamples on the fixed step: each ends with
    the property the bug broke restored. -/
theorem regress_partA_rest :
    -- bug_gb_switch_keeps_dead_link: the GB game ends the link
    (runF init (tLinked ++ it (.emu .frame) false [.drop .gb] .idle [.wClose] ++
                it (.emu .frame) false [.keyQuickLoad] .idle [.mLinkMenu])).nl = none ∧
    -- bug_manual_host_gb_switch_crashes: no crash, nothing linked
    (let s := runF init ([.boot (.rom .gba)] ++
      it .emuSkip false [.mouse true] .idle [.mLinkMenu] ++
      it .emuSkip false [] .idle [.wHost true, .wClose] ++
      it .emuSkip false [.drop .gb] .idle [] ++
      it .emuSkip false [] (.accept .ok) [])
     s.pc = .emu ∧ s.nl = none) ∧
    -- bug_slot_load_while_linked
    (runF init (tLinked ++ it (.emu .frame) false [] .idle [.mSlotLoad true])).desync = false ∧
    -- bug_ctrl_l_races_link
    (runF init ([.boot (.rom .gba)] ++
      it .emuSkip false [.mouse true] .idle [.mLinkMenu] ++
      it .emuSkip false [.keyQuickLoad] (.connect .ok) [] ++
      [.emu .frame, .pend true])).desync = false ∧
    -- bug_accept_error_leaks_listener: the port is held only by the listener
    (let s := runF init ([.boot (.rom .gba)] ++
      it .emuSkip false [.mouse true] .idle [.mLinkMenu] ++
      it .emuSkip false [] (.refused true true false) [] ++
      it .emuSkip false [] .acceptErr [] ++
      it .emuSkip false [] (.refused true true false) [] ++
      it .emuSkip false [] (.connect .timeout) [])
     (s.server = true ↔ s.setup = .listening) ∧ s.freeze = .none) ∧
    -- bug_handshake_fail_strands_auto
    (let s := runF init ([.boot (.rom .gba)] ++
      it .emuSkip false [.mouse true] .idle [.mLinkMenu] ++
      it .emuSkip false [] (.connect .rejected) [] ++
      it .emuSkip false [] .idle [])
     s.auto = false ∧ s.status = .hsFailed) ∧
    -- bug_auto_probes_typed_host: auto never connects to the typed host
    (runF init ([.boot (.rom .gba)] ++
      it .emuSkip false [.mouse true] .idle [.mLinkMenu] ++
      it .emuSkip false [] .idle [.wEditHost .other, .wJoin, .wCancel, .wClose] ++
      it .emuSkip false [] .idle [.mLinkMenu] ++
      it .emuSkip false [] (.refused false false true) [])).freeze = .none ∧
    -- bug_manual_host_survives_window_close
    (runF init ([.boot (.rom .gba)] ++
      it .emuSkip false [.mouse true] .idle [.mLinkMenu] ++
      it .emuSkip false [] .idle [.wHost true, .wClose] ++
      it .emuSkip false [] .idle [] ++
      it .emuSkip false [] (.accept .ok) [])).nl = none ∧
    -- bug_rom_file_gone_crashes
    (let s := runF init ([.boot (.rom .gba)] ++
      it .emuSkip false [.mouse true] .idle [.mLinkMenu] ++
      it .emuSkip false [] (.connect .romGone) [])
     s.pc = .emu ∧ s.status = .hsFailed) ∧
    -- bug_cli_bad_port_crashes
    (runF init [.boot .badPort]).pc = .emu ∧
    -- a stall timeout ends the link without freezing the window first
    (runF init (tLinked ++ it (.emu (.lost false true)) false [] .idle [])).freeze = .none := by
  decide

/-! ## Part B: two processes over one socket

Both processes have linked (Part A's `tLinked` on each side). What is left
is the clock discipline (linkproto.nim 7-11, netcore.nim 12-27): each side
free-runs but never more than `NETLINK_LEAD` (16384 cycles, ~1 ms) past the
newest peer clock it has heard. That lead is far below one frame (280896
cycles), so in frames: a side may start a frame only while its clock is not
ahead of the peer's.

`step_frame` (netlink.nim 123-150) does not return while the core is parked
on the peer: it loops `pump(1)` until the peer's clock moves, a BYE arrives,
EOF/reset raises, or 30 s pass. The whole main loop, input, ImGui and
present included, waits with it: `blocked`.

Fast forward and 2x speed only make frames due more often (`gba_frame_due`,
2369-2373); they are `ff` here and change nothing else. That is the point:
the Tab key's suppression while linked (1681) is not needed for sync, and
the menu (1353-1368) and the right trigger (1592-1602), which are not
suppressed, cannot desync the pair either (`lead_bounded`). -/

structure Side where
  linked  : Bool := true    -- app.netlink ≠ nil
  paused  : Bool := false   -- app.paused: phase 1 does not run (2452), nothing pumps the socket
  blocked : Bool := false   -- inside step_frame's stall loop: this process's main loop is stopped
  clock   : Nat := 0        -- link frames emulated (NetCore.now() in frames)
  ff      : Bool := false   -- apu.sync = false or turbo (menu 1353-1368, trigger 1592, not Tab)
  bye     : Bool := false   -- our BYE is on the wire (teardown_netlink sends it, 1812)
  gone    : Bool := false   -- the process has exited; the OS closed the socket
  deriving DecidableEq, Repr

structure Pair where
  a : Side := {}
  b : Side := {}
  pauseKill : Bool := false  -- ghost: a stall timeout ended the link while the peer was only paused
  eofKill   : Bool := false  -- ghost: a link ended on EOF with no BYE (the error path, 2462)
  deriving DecidableEq, Repr

inductive PEv where
  | frame (i : Bool)               -- i's phase 1 with a linked frame due
  | wake (i : Bool)                -- i's stall loop sees the peer's clock, BYE or EOF
  | timeout (i : Bool)             -- i's STALL_TIMEOUT_MS expires (netlink.nim 144-146)
  | pause (i : Bool)               -- Ctrl+P / Emulation > Pause (phase 3 / 5)
  | setFF (i : Bool) (on : Bool)   -- Emulation > Fast Forward / 2x Speed, the right trigger
  | quit (i : Bool)                -- window close / Ctrl+Q / File > Exit
  | disconnect (i : Bool)          -- Link Cable > Disconnect
  deriving DecidableEq, Repr

def PEv.side : PEv → Bool
  | .frame i | .wake i | .timeout i | .pause i | .setFF i _ | .quit i | .disconnect i => i

/-- One side's effect: its new state, and the ghosts it raises. -/
structure Out where
  me  : Side
  eof : Bool
  pk  : Bool

/-- The link ends on this side: `teardown_netlink` sends BYE (1812) and drops it. -/
def Side.down (me : Side) : Side := { me with linked := false, blocked := false, bye := true }

/-- Phase 1 with a linked frame due (2452-2467): the frame, the peer's BYE
    (`peer_done`), EOF ("peer disconnected"), or a park on the peer. -/
def frameS (me o : Side) : Out :=
  if me.linked = false ∨ me.gone = true ∨ me.paused = true ∨ me.blocked = true then ⟨me, false, false⟩
  else if o.bye = true then ⟨me.down, false, false⟩
  else if o.gone = true then ⟨me.down, true, false⟩
  else if me.clock ≤ o.clock then ⟨{ me with clock := me.clock + 1 }, false, false⟩
  else ⟨{ me with blocked := true }, false, false⟩

/-- The stall loop's `pump(1)` (netlink.nim 143). A BYE sets
    `peer_clock` to infinity (netcore.nim 698), so the frame completes and
    the main loop tears down. -/
def wakeS (me o : Side) : Out :=
  if me.blocked = false then ⟨me, false, false⟩
  else if o.bye = true then ⟨me.down, false, false⟩
  else if o.gone = true then ⟨me.down, true, false⟩
  else if me.clock ≤ o.clock then ⟨{ me with blocked := false, clock := me.clock + 1 }, false, false⟩
  else ⟨me, false, false⟩

/-- A blocked process takes no input: every user event needs `blocked = false`. -/
def evS (e : PEv) (me o : Side) : Out :=
  match e with
  | .frame _ => frameS me o
  | .wake _ => wakeS me o
  | .timeout _ => if me.blocked = true then ⟨me.down, false, o.paused⟩ else ⟨me, false, false⟩
  | .pause _ =>
      if me.blocked = true ∨ me.gone = true then ⟨me, false, false⟩
      else ⟨{ me with paused := !me.paused }, false, false⟩
  | .setFF _ on =>
      if me.blocked = true ∨ me.gone = true then ⟨me, false, false⟩
      else ⟨{ me with ff := on }, false, false⟩
  | .quit _ =>                                                  -- no BYE (2606)
      if me.blocked = true ∨ me.gone = true then ⟨me, false, false⟩
      else ⟨{ me with gone := true }, false, false⟩
  | .disconnect _ =>
      if me.blocked = true ∨ me.gone = true ∨ me.linked = false then ⟨me, false, false⟩
      else ⟨me.down, false, false⟩

def upd (p : Pair) (i : Bool) (r : Out) : Pair :=
  match i with
  | false => { p with a := r.me, eofKill := p.eofKill || r.eof, pauseKill := p.pauseKill || r.pk }
  | true => { p with b := r.me, eofKill := p.eofKill || r.eof, pauseKill := p.pauseKill || r.pk }

def pstep (p : Pair) (e : PEv) : Pair :=
  match e.side with
  | false => upd p false (evS e p.a p.b)
  | true => upd p true (evS e p.b p.a)

def prun (p : Pair) (es : List PEv) : Pair := es.foldl pstep p

inductive PReach : Pair → Prop where
  | init : PReach {}
  | step {p} (e : PEv) : PReach p → PReach (pstep p e)

/-- The clocks stay within one frame of each other. -/
def Lead (p : Pair) : Prop := p.a.clock ≤ p.b.clock + 1 ∧ p.b.clock ≤ p.a.clock + 1

theorem lead_step {p : Pair} (h : Lead p) (e : PEv) : Lead (pstep p e) := by
  unfold Lead at *
  obtain ⟨h1, h2⟩ := h
  rcases e with ⟨i⟩ | ⟨i⟩ | ⟨i⟩ | ⟨i⟩ | ⟨i, on⟩ | ⟨i⟩ | ⟨i⟩ <;> cases i <;>
    simp only [pstep, PEv.side, upd, evS, frameS, wakeS, Side.down] <;>
    (repeat' split) <;> simp_all <;> omega

/-- Frame advance and fast forward (menu, trigger, Tab) never let one side run
    more than a frame ahead: they cannot desync the link. -/
theorem lead_bounded {p : Pair} (h : PReach p) : Lead p := by
  induction h with
  | init => simp [Lead]
  | step e _ ih => exact lead_step ih e

/-- A pauses. B runs one frame ahead and parks in step_frame: B's whole
    window stops (no input, no redraw, macOS's spinning cursor). Quit,
    Pause and Disconnect on B do nothing until A unpauses. Anything else
    that stops A's loop does the same: dragging A's window on macOS, A's own
    blocking connect or handshake, A's 3 s `close` drain. -/
theorem bug_peer_pause_freezes_other_window :
    let p := prun {} [.pause false, .frame true, .frame true]
    p.a.paused = true ∧ p.b.blocked = true ∧
      pstep p (.quit true) = p ∧ pstep p (.disconnect true) = p ∧ pstep p (.pause true) = p := by
  decide

/-- ...and after 30 s B drops the link ("stalled waiting for peer"), though A
    only paused. A reads the BYE when it unpauses. -/
theorem bug_peer_pause_ends_link :
    let p := prun {} [.pause false, .frame true, .frame true, .timeout true]
    p.pauseKill = true ∧ p.b.linked = false ∧ p.a.linked = true := by decide

/-- A quits while linked: no BYE (Part A `bug_quit_while_linked_sends_no_bye`),
    so B's link ends on the error path, where a parked exchange is left busy
    (Part A `bug_lost_peer_leaves_transfer_busy`). -/
theorem bug_quit_ends_peer_link_without_bye :
    (prun {} [.quit false, .frame true]).eofKill = true := by decide

/-! ### The fix, as shipped

* The desktop steps a linked frame with `step_frame_for(8 ms)`: parked on
  the peer, it returns to the main loop with the frame still in progress
  (`try_advance` resumes it) and the stall deadline kept in the NetLink
  across calls. The loop keeps handling input and drawing; the Link Cable
  window says "Waiting for the other player...". The harness keeps the
  blocking `step_frame`. So a blocked side takes input: `evSF` lets Pause,
  Quit and Disconnect act while `blocked`.
* While paused the loop still pumps the socket (`service_netlink`:
  `NetLink.idle`), and CLOCK carries bit 2 "paused" (`LINK_CLOCK_PAUSED`,
  docs/multiplayer.md) from `NetLink.set_paused`; the peer's stall deadline
  is re-armed while that bit is set. Builds without the bit ignore it
  (only SO is read from CLOCK's flags), so they time out as before.
* Part A fix 6: a quit sends BYE. -/

def evSF (e : PEv) (me o : Side) : Out :=
  match e with
  | .frame _ => frameS me o
  | .wake _ => wakeS me o
  | .timeout _ =>
      if me.blocked = true ∧ o.paused = false then ⟨me.down, false, o.paused⟩ else ⟨me, false, false⟩
  | .pause _ => if me.gone = true then ⟨me, false, false⟩ else ⟨{ me with paused := !me.paused }, false, false⟩
  | .setFF _ on => if me.gone = true then ⟨me, false, false⟩ else ⟨{ me with ff := on }, false, false⟩
  | .quit _ =>
      if me.gone = true then ⟨me, false, false⟩
      else ⟨{ me with gone := true, blocked := false, linked := false, bye := me.bye || me.linked },
            false, false⟩
  | .disconnect _ => if me.gone = true ∨ me.linked = false then ⟨me, false, false⟩ else ⟨me.down, false, false⟩

def pstepF (p : Pair) (e : PEv) : Pair :=
  match e.side with
  | false => upd p false (evSF e p.a p.b)
  | true => upd p true (evSF e p.b p.a)

inductive PReachF : Pair → Prop where
  | init : PReachF {}
  | step {p} (e : PEv) : PReachF p → PReachF (pstepF p e)

def PSafe (p : Pair) : Prop :=
  Lead p ∧ p.pauseKill = false ∧ p.eofKill = false ∧
  (p.a.gone = true → p.a.bye = true) ∧ (p.b.gone = true → p.b.bye = true) ∧
  (p.a.linked = false → p.a.bye = true) ∧ (p.b.linked = false → p.b.bye = true)

theorem psafeF_step {p : Pair} (h : PSafe p) (e : PEv) : PSafe (pstepF p e) := by
  unfold PSafe Lead at *
  obtain ⟨⟨h1, h2⟩, h3, h4, h5, h6, h7, h8⟩ := h
  rcases e with ⟨i⟩ | ⟨i⟩ | ⟨i⟩ | ⟨i⟩ | ⟨i, on⟩ | ⟨i⟩ | ⟨i⟩ <;> cases i <;>
    simp only [pstepF, PEv.side, upd, evSF, frameS, wakeS, Side.down] <;>
    (repeat' split) <;> simp_all <;> (try omega) <;>
    (by_cases hx : p.a.linked = true <;> by_cases hy : p.b.linked = true <;> simp_all)

/-- With the fix: the clocks stay in lead, a pause never ends the link, and
    every end reaches the peer as a BYE. -/
theorem pairF_reachable {p : Pair} (h : PReachF p) : PSafe p := by
  induction h with
  | init => simp [PSafe, Lead]
  | step e _ ih => exact psafeF_step ih e

/-- With the fix, Quit and Pause always act on B, blocked or not. -/
theorem pairF_responsive (p : Pair) (h : p.b.gone = false) :
    (pstepF p (.quit true)).b.gone = true ∧ (pstepF p (.pause true)).b.paused = !p.b.paused := by
  simp [pstepF, PEv.side, upd, evSF, h]

theorem regress_peer_pause :
    let q := [PEv.pause false, .frame true, .frame true, .timeout true, .quit true].foldl pstepF {}
    q.b.blocked = false ∧ q.pauseKill = false ∧ q.b.gone = true ∧ q.b.bye = true ∧
      q.a.linked = true := by decide

/-! ## Part C: the zero-config auto-pair race

Two instances on one machine, both auto-pairing (Link Cable window open, or
`--link-auto`). Each probes 127.0.0.1:47810 (`service_link_setup`
lsConnecting, 2008-2031); after `LINK_AUTO_CONNECT_TRIES` = 3 refused probes
it binds 47810 WITHOUT SO_REUSEADDR and listens (`link_auto_listen`,
1967-1984); if the bind fails it goes back to probing.

Kernel facts, measured on this Mac (macOS, 2026-09-23, Python sockets):
* a bind without SO_REUSEADDR fails (EADDRINUSE) while the port has a
  listener, an established connection's endpoint, or a TIME_WAIT endpoint;
* TIME_WAIT on 47810 lasts 30.9 s when the host side closes first;
* with SO_REUSEADDR the bind succeeds during TIME_WAIT or an established
  connection, and STILL fails while another socket listens on the port
  (with or without SO_REUSEADDR). So the comment at 1969-1972 ("On macOS
  SO_REUSEADDR lets a second bind to the same port silently succeed") is
  not what this Mac does; it describes Windows, where SO_REUSEADDR allows a
  second bind and SO_EXCLUSIVEADDRUSE prevents it.

A connect succeeds whenever some socket listens on the port, whether or not
anything will ever `accept` it: the kernel completes the handshake into the
backlog. -/

inductive AP where
  | off              -- not pairing
  | probe (n : Nat)  -- lsConnecting under link_auto; n refused probes since the last reset
  | listen           -- lsListening under link_auto
  | linked (unit : Nat)
  | frozen           -- in finish_link's handshake with nobody on the other end (UI frozen, 30 s)
  | stuck            -- finish_link failed: link_auto, lsNone, "Waiting to pair..." forever
  deriving DecidableEq, Repr

structure Race where
  a    : AP := .off
  b    : AP := .off
  port : Option Bool := none  -- which process holds a listening socket on 47810 (false = a)
  held : Bool := false        -- an established connection's endpoint is on 47810
  tw   : Bool := false        -- a TIME_WAIT endpoint is on 47810
  deriving DecidableEq, Repr

inductive REv where
  | open (i : Bool)               -- the Link Cable window opens: link_auto_start
  | probe (i : Bool)              -- one probe (2014-2018)
  | bind (i : Bool)               -- link_auto_listen after 3 refusals (2026-2028)
  | acceptErr (i : Bool)          -- accept raised (1997-2001)
  | helloTimeout (i : Bool)       -- HELLO_TIMEOUT_MS in finish_link
  | close (i : Bool)              -- the window closes: link_auto_stop
  | endSession (hostFirst : Bool) -- the pair unlinks; the side that closes first keeps TIME_WAIT
  | twExpire
  deriving DecidableEq, Repr

/-- `rprobe me other mine theirs`: one probe by `me`. `theirs` = the other
    process holds the listener, `mine` = we do (a leaked one). Returns the
    new (me, other, port cleared and held). -/
def rprobe (me o : AP) (theirs : Bool) (portFree : Bool) : AP × AP × Bool :=
  match me with
  | .probe n =>
      if theirs = true ∧ o = .listen then (.linked 1, .linked 0, true)  -- accept + both handshakes
      else if portFree = true then (.probe (n + 1), o, false)          -- refused
      else (.frozen, o, false)                                         -- into a backlog nobody accepts
  | _ => (me, o, false)

def rstep (r : Race) : REv → Race
  | .open false => if r.a = .off then { r with a := .probe 0 } else r
  | .open true => if r.b = .off then { r with b := .probe 0 } else r
  | .probe false =>
      let x := rprobe r.a r.b (r.port == some true) (r.port == none)
      if x.2.2 = true then { r with a := x.1, b := x.2.1, port := none, held := true }
      else { r with a := x.1 }
  | .probe true =>
      let x := rprobe r.b r.a (r.port == some false) (r.port == none)
      if x.2.2 = true then { r with b := x.1, a := x.2.1, port := none, held := true }
      else { r with b := x.1 }
  | .bind false =>
      match r.a with
      | .probe n =>
          if n ≥ 3 then
            if r.port = none ∧ r.held = false ∧ r.tw = false then { r with a := .listen, port := some false }
            else { r with a := .probe 0 }
          else r
      | _ => r
  | .bind true =>
      match r.b with
      | .probe n =>
          if n ≥ 3 then
            if r.port = none ∧ r.held = false ∧ r.tw = false then { r with b := .listen, port := some true }
            else { r with b := .probe 0 }
          else r
      | _ => r
  | .acceptErr false => if r.a = .listen then { r with a := .probe 0 } else r   -- link_server stays open
  | .acceptErr true => if r.b = .listen then { r with b := .probe 0 } else r
  | .helloTimeout false => if r.a = .frozen then { r with a := .stuck } else r
  | .helloTimeout true => if r.b = .frozen then { r with b := .stuck } else r
  | .close false =>
      match r.a with
      | .probe _ | .stuck => { r with a := .off }                  -- a leaked listener stays open
      | .listen => { r with a := .off, port := none }
      | _ => r
  | .close true =>
      match r.b with
      | .probe _ | .stuck => { r with b := .off }
      | .listen => { r with b := .off, port := none }
      | _ => r
  | .endSession hostFirst =>
      match r.a, r.b with
      | .linked _, .linked _ => { r with a := .off, b := .off, held := false, tw := r.tw || hostFirst }
      | _, _ => r
  | .twExpire => { r with tw := false }

def rrun (r : Race) (es : List REv) : Race := es.foldl rstep r

inductive RReach : Race → Prop where
  | init : RReach {}
  | step {r} (e : REv) : RReach r → RReach (rstep r e)

def AP.isLinked : AP → Bool
  | .linked _ => true
  | _ => false

def AP.unit : AP → Nat
  | .linked u => u
  | _ => 0

/-- At most one listener, and it holds the port; pairs are unit 0 + unit 1. -/
def RInv (r : Race) : Prop :=
  (r.a = .listen → r.port = some false) ∧ (r.b = .listen → r.port = some true) ∧
  r.a.isLinked = r.b.isLinked ∧ (r.a.isLinked = true → r.a.unit ≠ r.b.unit)

theorem rinv_step {r : Race} (h : RInv r) (e : REv) : RInv (rstep r e) := by
  unfold RInv at *
  obtain ⟨ha, hb, hl, hu⟩ := h
  rcases e with ⟨i⟩ | ⟨i⟩ | ⟨i⟩ | ⟨i⟩ | ⟨i⟩ | ⟨i⟩ | ⟨hf⟩ | ⟨⟩ <;> (try cases i) <;>
    simp only [rstep, rprobe] <;>
    (repeat' split) <;> simp_all [AP.isLinked, AP.unit] <;>
    (repeat' split) <;> simp_all [AP.isLinked, AP.unit]

/-- The code as it is: two instances never both host and never pair as the same unit. -/
theorem race_inv {r : Race} (h : RReach r) : RInv r := by
  induction h with
  | init => simp [RInv, AP.isLinked]
  | step e _ ih => exact rinv_step ih e

/-- Symmetric start: both probe, both reach the bind; the loser's bind fails
    on the winner's listener and its next probe pairs. -/
theorem ok_symmetric_start_pairs :
    let r := rrun {} [.open false, .open true, .probe false, .probe true, .probe false, .probe true,
                      .probe false, .probe true, .bind false, .bind true, .probe true]
    r.a = .linked 0 ∧ r.b = .linked 1 := by decide

/-- After a session the host's end of 47810 sits in TIME_WAIT (30.9 s
    measured), so neither instance can auto-host: both show "Waiting to
    pair..." until it expires. A delay, not a deadlock
    (`ok_repair_after_time_wait`). -/
theorem bug_repair_waits_for_time_wait :
    let r := rrun {} [.open false, .open true, .probe false, .probe false, .probe false, .bind false,
                      .probe true, .endSession true,
                      .open false, .open true, .probe false, .probe false, .probe false,
                      .probe true, .probe true, .probe true, .bind false, .bind true]
    r.a = .probe 0 ∧ r.b = .probe 0 ∧ r.port = none ∧ r.tw = true := by decide

theorem ok_repair_after_time_wait :
    let r := rrun {} [.open false, .open true, .probe false, .probe false, .probe false, .bind false,
                      .probe true, .endSession true,
                      .open false, .open true, .twExpire, .probe false, .probe false, .probe false,
                      .bind false, .probe true]
    r.a = .linked 0 ∧ r.b = .linked 1 := by decide

/-- An accept error leaves A's listener open while A probes again (Part A
    `bug_accept_error_leaks_listener`). A's own probe and B's both connect
    into that backlog, nobody accepts, both windows freeze 30 s, and both
    are then stranded on "Waiting to pair...". -/
theorem bug_leaked_listener_freezes_both :
    let r := rrun {} [.open false, .probe false, .probe false, .probe false, .bind false,
                      .acceptErr false, .open true, .probe true, .probe false]
    r.a = .frozen ∧ r.b = .frozen ∧
      (rrun r [.helloTimeout false, .helloTimeout true]).a = .stuck ∧
      (rrun r [.helloTimeout false, .helloTimeout true]).b = .stuck := by decide

/-! ### The fix, designed

* Close `link_server` on an accept error (Part A fix 3).
* Bind the auto listener WITH SO_REUSEADDR on POSIX (a second listener is
  still refused, measured above, so the race is still broken, but TIME_WAIT
  and a live session's endpoint no longer block it), and with
  SO_EXCLUSIVEADDRUSE on Windows. -/

def rstepF (r : Race) : REv → Race
  | .bind false =>
      match r.a with
      | .probe n => if n ≥ 3 then (if r.port = none then { r with a := .listen, port := some false }
                                   else { r with a := .probe 0 }) else r
      | _ => r
  | .bind true =>
      match r.b with
      | .probe n => if n ≥ 3 then (if r.port = none then { r with b := .listen, port := some true }
                                   else { r with b := .probe 0 }) else r
      | _ => r
  | .acceptErr false => if r.a = .listen then { r with a := .probe 0, port := none } else r
  | .acceptErr true => if r.b = .listen then { r with b := .probe 0, port := none } else r
  | e => rstep r e

inductive RReachF : Race → Prop where
  | init : RReachF {}
  | step {r} (e : REv) : RReachF r → RReachF (rstepF r e)

/-- The port is held exactly by the listening side; nobody is frozen or stranded. -/
def RSafe (r : Race) : Prop :=
  (r.port = some false ↔ r.a = .listen) ∧ (r.port = some true ↔ r.b = .listen) ∧
  r.a.isLinked = r.b.isLinked ∧ (r.a.isLinked = true → r.a.unit ≠ r.b.unit) ∧
  r.a ≠ .frozen ∧ r.b ≠ .frozen ∧ r.a ≠ .stuck ∧ r.b ≠ .stuck

theorem rsafeF_step {r : Race} (h : RSafe r) (e : REv) : RSafe (rstepF r e) := by
  unfold RSafe at *
  obtain ⟨ha, hb, hl, hu, hfa, hfb, hsa, hsb⟩ := h
  rcases e with ⟨i⟩ | ⟨i⟩ | ⟨i⟩ | ⟨i⟩ | ⟨i⟩ | ⟨i⟩ | ⟨hf⟩ | ⟨⟩ <;> (try cases i) <;>
    simp only [rstepF, rstep, rprobe] <;>
    (repeat' split) <;> simp_all [AP.isLinked, AP.unit] <;>
    (repeat' split) <;> (try simp_all [AP.isLinked, AP.unit]) <;>
    (cases hp : r.port with
     | none => simp_all
     | some x => cases x <;> simp_all)

theorem raceF_reachable {r : Race} (h : RReachF r) : RSafe r := by
  induction h with
  | init => simp [RSafe, AP.isLinked]
  | step e _ ih => exact rsafeF_step ih e

theorem regress_race :
    let r := [REv.open false, .open true, .probe false, .probe false, .probe false, .bind false,
              .probe true, .endSession true,
              .open false, .open true, .probe false, .probe false, .probe false, .bind false,
              .probe true].foldl rstepF {}
    r.a = .linked 0 ∧ r.b = .linked 1 := by decide

end DesktopState.NetLink
