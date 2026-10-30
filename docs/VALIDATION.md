# Validation — 2.7

- Release build compiles with Swift and passes strict code-signature verification.
- Pointer-entry regression checks cover repeated motion, stationary reveal, re-entry, and re-enabling without activation loops.
- An integration probe shares the production hover monitor, overlay pair, and handoff controller. With a controlled pointer-position provider, its timer detects entry, hits the actual floating panel, activates a separate test app, and confirms the source window is in front. The probe has no mouse-down handoff handler.
- Shared status-button code was checked through UI actions: a 700 ms hold and right-click open a menu without a toggle; an ordinary click toggles once.
- The local user confirmed the updated app was working before publication.

The integration probe is not a substitute for testing every application, display arrangement, or full-screen workflow. Known limitations are documented in the README.
