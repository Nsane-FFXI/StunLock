# StunLock

Windower4 addon that automates stun usage.  
Supports both re-stun chains and optional *start-with-stun* mode.

---

## Features
- Prioritizes stuns in this order:
  1. **Sudden Lunge** (BLU)
  2. **Stun** (BLM/DRK)
  3. **Weapon Skill** (job-dependent)
- Party/alliance claim detection for one-time opener stun.
- Range and recast aware.

---

## Commands
Use `//sl` or `//stunlock`:

- `//sl` — toggle re-stun
- `//sl on|off|status` — control re-stun
- `//sl sws` — toggle start-with-stun
- `//sl sws on|off` — control start-with-stun

---

## Notes
- Each mob is stunned **once** on claim when *SWS* is enabled.
