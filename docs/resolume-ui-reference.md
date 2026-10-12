# Resolume Arena UI — extracted reference

**For:** Codex (front-end owner). **By:** Claude. **Date:** 2026-10-12.
**Source:** `/Applications/Resolume Arena/default/Presets/Interface/*.xml` and
`default/Presets/Animation/*.xml` — Arena's own shipped layout and parameter presets, read directly.
Arena 7.23.0. **This is observed structure, not guesswork.**

Aiden: *"grid needs to copy resolume"*, *"especially the front end"*. This is the data to build to.

---

## 1. Arena's layout model — and it matches what we already specified

```xml
<Layout version="2">
  <Desktop>
    <Window panel_id="515" main="1" full_screen="0" x="-1" y="66" width="1728" height="942">
      <FlexContainer panel_id="516" orientation="0">
        <FlexContainer panel_id="517" orientation="1">
          <FlexContainer panel_id="514" height_desired="339" orientation="0">
            <LayersAndClips width_desired="1000" height_desired="318"/>
          </FlexContainer>
          <Toolbar width_desired="1000" height_desired="36"/>
          ...
          <TabbedContainer panel_id="508">
            <Monitor instance="0" subject_type="Composition" checker_board="0" showUI="0"/>
          </TabbedContainer>
          <TabbedContainer panel_id="502">
            <Composition/><Layer/>
          </TabbedContainer>
          <TabbedContainer panel_id="504">
            <Files/><Effects/>
          </TabbedContainer>
```

**A nested `FlexContainer` tree with `orientation` and `*_desired` sizes, stable integer
`panel_id`s, and `TabbedContainer`s grouping related panels.**

> That is *exactly* the "declarative struct tree with stable serialisable panel IDs" we specified
> for UI templates (`scaffold.md` §2c, V3 §3.5.1b) — arrived at independently, then confirmed
> against the real thing. Build the same shape and template files become trivially expressible.

**Arena ships nine named layouts, which is the UI-templates concept exactly:**
`Minimal` · `Big Monitor` · `Dual Display` · `Triple Display` · `Many Layers` ·
`Many Monitors Left` · `Many Monitors Top` · `Panels Left & Right` · `Panels On Top`

---

## 2. Panel inventory (element name → what it is)

Counts are occurrences across all nine shipped layouts.

| Element | × | What it is |
|---|---|---|
| **`LayersAndClips`** | 9 | **THE GRID.** Layers *and* clips are **one panel**, not two — note this. |
| `Toolbar` | 9 | Transport / global controls |
| `Monitor` | 25 | Preview surfaces — see subject types below |
| `TabbedContainer` | 60 | Groups panels into tabs |
| `FlexContainer` | 112 | Layout nodes |
| `Composition` / `Layer` / `Group` / `Clip` / `Column` | 7–9 | Inspectors, one per selection scope |
| `Files` / `Effects` / `Sources` / `Compositions` | 9 | Browser tabs |
| `Slices` | 9 | Output mapping |
| `Shortcuts` | 9 | Keyboard/MIDI mapping |
| `RenderQueue` / `Recording` | 8–9 | Export |
| `Clock` | 16 | BPM/time display |
| `SMPTE` | 8 | Timecode |
| `ClipTime` | 8 | Position/remaining |
| `Notes` | 8 | Show notes |
| `Params` / `Param` | 9 / 322 | Parameter containers and leaves |

**`Monitor` subject types** — six distinct preview scopes:
`Composition` · `Preview` · `Clip Preview` · `Layer` · `Layer Preview` · `Group Preview`

Monitors carry `instance`, `checker_board` (alpha checkerboard) and `showUI` flags. The `Minimal`
layout runs **two**: `Composition` (program, `showUI=0`) and `Preview` (`checker_board=1`,
`showUI=1`).

---

## 3. Feature inventory — the 34 `Show *` toggles

These are Arena's full optional-UI surface, straight from `Minimal.xml`:

> Ableton Link · Audio Controls · Autopilot · Beat Looper · **Big Column Triggers** ·
> **Clip Speed Sliders on Layers** · Clip Time · Clip · Column · Composition · Compositions ·
> **Crossfader** · **Cue Points** · Dashboard · **Denon DJ StageLinQ** · Effects · **FFT Gain** ·
> Files · FPS & Stats · Group · Help · **Layer Transition Controls** · **Layer Transport Controls** ·
> Layer · Monitor · Notes · **Pioneer DJ TCNet** · Recordings · Render Queue · Shortcuts · Slices ·
> SMPTE · Sources · Undo Toolbar

**Three worth flagging for our plan:**
- **Ableton Link is a first-class toggle** — confirms it's expected in this product category.
- **Pioneer DJ TCNet** and **Denon DJ StageLinQ** — Arena integrates DJ-deck sync protocols
  directly. This is the real-world answer to the rekordbox phase problem (V3 §2.4b2): the category
  standard is a dedicated DJ-link integration, not Ableton Link alone.
- **FFT Gain** — audio-reactive modulation is a shipped, surfaced feature, as we assumed.

---

## 4. Arena's parameter model — richer than ours, worth copying

From `default/Presets/Animation/BPM - 4 to the Floor.xml`:

```xml
<DurationSource defaultDuration="4b" scale="1"/>
<PhaseSourceTimeline phase="0.7206856..." defaultMillisecondsDuration="5000"
                     defaultBeatsDuration="8" hardSynced="1">
  <ParamRange name="Speed" T="DOUBLE" default="1" value="1">
    <PhaseSourceStatic/>
    <BehaviourDouble/>
    <ValueRange name="defaultRange" min="0" max="10"/>
    <ValueRange name="minMax"       min="0" max="10"/>
    <ValueRange name="startStop"    min="0" max="10"/>
  </ParamRange>
  <ParamRange name="Multiplier" altName="Speed" .../>
```

**What to take from this:**

1. **Durations are expressed in beats as a string literal — `"4b"`.** Musical time is a first-class
   unit in the document, not a derived number. Our `Rational` + beats model should serialise the
   same way.
2. **Every parameter carries THREE ranges**, not one:
   - `defaultRange` — the parameter's natural bounds
   - `minMax` — the user-narrowed usable bounds
   - `startStop` — the animation's sweep endpoints *within* those bounds

   **Our modulation binding only has `depth`/`offset`/`curve`** (V3 §2.4c), which is strictly less
   expressive. A VJ who wants "this LFO sweeps opacity between 0.3 and 0.7, and I've also clamped
   this parameter to never exceed 0.8" needs both. **Recommend adopting the three-range model
   before the parameter system is written** — retrofitting ranges into every parameter is the kind
   of change that touches everything.
3. **`PhaseSourceTimeline` vs `PhaseSourceStatic`** — phase is a *pluggable source per parameter*,
   with `hardSynced` as an explicit flag. This directly corroborates V3's **separable tempo/phase**
   decision, and goes further: phase source is per-animation, not just global.
4. **`altName`** — parameters have aliases, so a renamed parameter keeps resolving.
5. **`T="DOUBLE"`** — explicit type tags on every parameter.

---

## 5. Recommendations for the grid

1. **`LayersAndClips` is one panel.** The layer strip and the clip grid share a panel and scroll
   together — they are not independent surfaces. Build it as one component.
2. **Two monitors by default**, Composition (program) and Preview, with Preview showing an alpha
   checkerboard and UI overlays, program showing neither.
3. **Inspectors are tabbed by scope** — Composition / Layer / Group / Clip / Column in one
   `TabbedContainer`, switching with selection.
4. **Browser is tabbed** — Files / Effects / Sources / Compositions.
5. **Ship named layouts, not a docking engine** — Arena proves the templates approach is sufficient
   for a professional tool in this exact category.
6. **Stable integer panel IDs** persisted in the layout file.

---

## 6. Method note

No decompiler was needed. Arena ships its layout and preset model as **plain XML** in
`default/Presets/`, so this is read from files the application itself installs — not extracted from
a binary. Faster and more reliable than disassembly, and it yields the *authoritative* structure
rather than an inference about it.

Binary analysis (REA/Ghidra) remains the right tool for the parts that genuinely aren't in files —
e.g. attributing Arena's render path. Not required for any of the above.
