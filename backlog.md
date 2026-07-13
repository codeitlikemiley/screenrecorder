# Backlog

Open follow-ups from code review of voice-tracking retune in
`Sources/Teleprompter/SlideVoiceTracker.swift` (2026-07-13).

## Context (what shipped)

Voice tracking was retuned for faster ad-lib detection and re-sync:

| Area | Before | After |
|------|--------|--------|
| Adlib threshold | 6 consecutive misses | 3 |
| Normal lookahead | 2 words | 8 |
| Lookahead evaluation | Once per speech callback | Per spoken word (mid-burst state changes) |
| Adlib enter | After full word loop | Immediately when miss threshold hit |
| Adlib exit | After loop if `consecutiveMisses == 0` | On first match while adlibbing |

Intent: detect ad-libbing sooner, expand search for re-sync, and let a single
recognition batch enter adlib mid-burst so later words get a full-slide scan.

**Dominant risk:** normal-mode lookahead `2 → 8` can overshoot common/fuzzy
matches and skip unspoken script words.

---

## Open items

### BUG — Normal lookahead 8 can overshoot

- **File:** `Sources/Teleprompter/SlideVoiceTracker.swift:134`
- **Status:** open
- **Problem:** Matching takes the first hit in `[pos, pos+8)` and sets
  `confirmedUpTo = idx + 1`, skipping intermediate script words. The previous
  window of 2 was intentional anti-overshoot. Common words (`the`, `and`, `to`,
  `for`, …) or fuzzy matches (prefix-4 / edit-distance in `wordMatch`) can jump
  the tracker forward, mis-highlight, clear `manualScrollTarget`, and trigger
  premature slide completion / auto-advance.
- **Fix ideas:**
  - Keep normal-mode lookahead small (2–3); reserve large/full-slide windows for
    `.adlibbing` only.
  - If wider lookahead is needed for ASR dropouts, require stronger acceptance
    before a skip (e.g. 2 consecutive spoken words match at the jumped
    position, or cap skip distance / prefer nearest match with a cost).
  - Add unit/fixture tests with repeated short words and fuzzy near-misses.

### SUGGESTION — Adlib threshold 3 is aggressive

- **File:** `Sources/Teleprompter/SlideVoiceTracker.swift:40`
- **Status:** open
- **Problem:** Three ASR insertions/mishears enter full-slide resync sooner.
  In adlib mode the next spoken common word can snap to any remaining script
  occurrence (`searchEnd = normalizedWords.count`).
- **Fix ideas:**
  - Validate live with scripts that contain repeated function words.
  - Require a 2-word confirm sequence to leave adlib / accept a long-range snap.
  - Keep threshold at 3 but expand lookahead gradually (2 → 4 → full) rather
    than all-or-nothing.

### SUGGESTION — Early adlib→tracking exit mid-burst

- **File:** `Sources/Teleprompter/SlideVoiceTracker.swift:144`
- **Status:** open
- **Problem:** Exiting `.adlibbing` → `.tracking` on the first mid-burst match
  means subsequent words in the same `newWords` suffix lose full-slide resync
  and fall back to lookahead 8. Old code kept full scan for the entire delta
  even after a hit. Early exit can strand recovery if the first hit was a false
  snap and the true resume point is farther than 8 words away.
- **Fix ideas:**
  - Stay in resync mode for the rest of the current `newWords` batch after
    leaving adlib (local flag `resyncThisBurst`).
  - Or only flip to `.tracking` after the loop (preserve mid-loop enter, delay
    exit).

### SUGGESTION — Paused full-slide resync is still dead

- **File:** `Sources/Teleprompter/SlideVoiceTracker.swift:109`
- **Status:** open
- **Problem:** `if state == .paused { state = .tracking }` runs before the
  match loop, so `isResyncMode = (state == .adlibbing || state == .paused)` can
  never observe `.paused` during matching. Pause-driven full-slide resync
  (user scrolled with ⌘F2 during silence, then resumed speaking) does not work.
  Pre-existing; still documented/computed as if it works.
- **Fix ideas:**
  - Capture `let wasPausedOrAdlib = (state == .paused || state == .adlibbing)`
    before mutating state.
  - Or set a `forceResync` flag when leaving `.paused`, and use that for
    `currentLookAhead` for at least the first matching word/burst after silence.

### NIT — Stale file-level algorithm comment

- **File:** `Sources/Teleprompter/SlideVoiceTracker.swift:12`
- **Status:** open
- **Problem:** Comment still says `lookahead=1`, but live normal-mode value is
  8 (and was already 2 before the retune).
- **Fix ideas:** Update the bullet to describe dual-mode lookahead
  (tight/normal vs full-slide adlib resync) and the actual constants.

### NIT — Unrelated untracked scratch files

- **Files:** `computer_use.md`, `execute_impl_computer_use.md`,
  `impl_computer_use.md`, `test.swift`
- **Status:** open
- **Problem:** Research/plan markdown and a stub test file are unrelated to
  the voice-tracker work. Easy accidental-commit noise.
- **Fix ideas:** Leave untracked, move outside the repo, or add to
  `.gitignore` if temporary.

---

## Recommended priority

1. **Dial back normal lookahead** (or gate long skips) — highest risk.
2. **Keep resync for the rest of the current word batch** after leaving adlib.
3. **Fix paused → full-slide resync** (capture state before clearing `.paused`).
4. Live-validate adlib threshold 3 with real scripts / ASR noise.
5. Refresh algorithm comment; keep scratch files out of commits.
