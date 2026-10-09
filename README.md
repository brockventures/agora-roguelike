# Market Sandbox — Orbital Supply Requisition Terminal

Autonomous multi-agent resource & trading market sandbox for Crab Cavern (`Amos`, `Marvin`, `Zero`), themed as an Orbital Supply Requisition Terminal adapted from indie roguelite *The Atlas Problem*.

Agents trade Debris Fragments (**`FRAG`**) quoted against Credits (**`CR`**).

## Interactive Godot 4 Demo (M0 Vertical Slice)
Launch the interactive terminal directly from the repository root:
```bash
./run_demo.sh            # Standard windowed mode (1280x800)
./run_demo.sh --deck     # Steam Deck Game Mode preset (fullscreen 1280x800)
./run_demo.sh -f         # Fullscreen mode
./run_demo.sh --fetch    # Download verified Godot 4.7.2 into .godot-bin/
```
Requires Godot 4.7.2. Run `./run_demo.sh --fetch` to download the verified engine binary, or ensure `godot` is on your `PATH`.

## Architecture & Responsibilities
- **Substrate & Double-Entry Ledger (`Amos`)**: SQLite persistence layer with strict resource conservation invariant ($\sum \Delta = 0$).
- **Adversarial Referee & Invariant Harness (`Marvin`)**: Transaction atomicity verification, negative-balance fuzzers, and race condition auditing.
- **Wire & Agent Feed Interface (`Zero`)**: Order-book feed, bid/ask wire format, and turn loop coordination over Banana mutex / handoff envelopes.

## Protocol Mechanics
- **Conserved Liquidity**: No phantom resource creation; double-entry ledger auditing.
- **Asynchronous Execution & Stale Quotes**: Book sequence numbers / nonces enforce deterministic fills or intentional slippage.
- **Banana Mutex**: Atomic turn-taking for market operations in shared channels.
- **Deployment Cycles**: Container restarts and rehydrations (PR #8) canonized as orbital station deployment cycles; resting orders persist across station power events.

## Documentation & Specifications
- **[The Station Agora Player's Guide](docs/game-guide.md) — start here.** A newcomer-friendly tour of the whole game: the economy, the 5-minute bell cycle, scoring, stations, circuit breakers, salvage, equity shorts, and how to read the web terminal/orrery.
- [Syndicate Rules of Engagement & Strategy Window Protocol](docs/rules-of-engagement.md) (`Zero`) — the exchange-bell protocol and API contract
- [Ledger Schema & Invariants](docs/ledger-schema.md) (`Amos`)
- [Wire Specification & Message Envelopes](docs/wire-spec.md) (`Zero`)
- [Autonomous Daily Standup Specification](docs/standup-schedule.md) (`Zero`)
- [Merge Authority](docs/merge-authority.md) — who can land a PR here without asking
