# acad_layout_tab_switcher.md — System Specification

**File:** `LAYOUTTAB.LSP`
**Version:** 1.0.2
**Platform:** AutoCAD (AutoLISP / Visual LISP)
**Role:** Automated layer visibility manager driven by layout (tab) switching

---

## Overview

LAYOUTTAB.LSP is an AutoCAD AutoLISP file that automatically controls layer visibility whenever the user switches between paper space layout tabs. When a tab is activated, the system identifies a matching LISP function by name and runs it. That function calls a universal engine which thaws + turns on a set of visible layers and turns off all others, then regenerates the drawing.

The system has three logical sections:

| Section | Name | Responsibility |
|---------|------|----------------|
| 1 | The Brain | Reactor setup and tab-to-function dispatch |
| 2 | The Body (Universal Engine) | Layer visibility execution via ActiveX |
| 3 | Macros | Per-tab layer state definitions |

---

## Section 1 — The Brain (Reactor Logic)

### Purpose
Listens for AutoCAD layout switch events and routes control to the correct per-tab macro function.

---

### Function: `String-Replace-All`

```lisp
(defun String-Replace-All (old new str / n) ...)
```

**Purpose:** Replaces all occurrences of a substring within a string.

| Parameter | Type | Description |
|-----------|------|-------------|
| `old` | string | Substring to find |
| `new` | string | Replacement value |
| `str` | string | Source string |

**Returns:** Modified string with all occurrences replaced.

**Notes:** Loops until no more matches exist (handles overlapping and repeated replacements).

---

### Re-entrancy Guard: `*KP-RUNNING*`

```lisp
(if (not *KP-RUNNING*) (setq *KP-RUNNING* nil))
```

**Purpose:** Global flag preventing `KP-CORE` from running while a previous invocation is still in progress.

**Why required:** The engine internally calls `setvar` (CLAYER), changes layer properties, and forces a regen. Each of these can fire `:vlr-commandEnded`, which would otherwise re-enter `KP-CORE` and restart the macro mid-execution. The guard short-circuits the re-entrant call so the engine completes once per real layout switch.

**Lifecycle:**
- Initialized to `nil` on first load (`if (not *KP-RUNNING*)` preserves an existing `t` only if reload happens mid-run, which would be an error state).
- Set to `t` at the top of `KP-CORE`'s work block.
- Reset to `nil` at the end of `KP-CORE`'s work block.

---

### Function: `KP-CORE`

```lisp
(defun KP-CORE (layout_name / clean_name macro_func_name cmdFunc result) ...)
```

**Purpose:** Core dispatch function. Converts a layout tab name into a LISP function name, then calls it if it exists.

**Re-entrancy gate:** The function only runs its body if `*KP-RUNNING*` is `nil` and `layout_name` is non-empty. Otherwise it exits silently.

**Name transformation algorithm:**

1. Trim leading/trailing spaces
2. Convert to uppercase
3. Remove all `-` characters
4. Remove all space characters
5. Remove all `.` characters
6. Prepend `L_` prefix

**Example transformations:**

| Layout Tab Name | Cleaned Name | Function Called |
|-----------------|--------------|-----------------|
| `A-110 FLOOR PLAN` | `A110FLOORPLAN` | `L_A110FLOORPLAN` |

**Dispatch behavior:**
- Uses `eval` + `read` to dynamically resolve the function name at runtime.
- Checks that the resolved symbol is a valid function (`SUBR` or `USUBR` type).
- If no matching function exists, prints a warning but does not throw an error.
- Uses `vl-catch-all-apply` to prevent crashes from within a macro from breaking the reactor.
- Resets `*KP-RUNNING*` to `nil` even if the macro returns or errors.

---

### Command: `C:KP_DEBUG`

```lisp
(defun C:KP_DEBUG () ...)
```

**Purpose:** Manual trigger for testing. Reads the current tab (`CTAB` sysvar) and runs `KP-CORE` against it.

**Usage in AutoCAD command line:** `KP_DEBUG`

---

### Reactor Callbacks

#### `TriggerAfterCommand`

```lisp
(defun TriggerAfterCommand (reactorInfo arg / cmdName) ...)
```

**Event:** `:vlr-commandEnded`
**Trigger condition:** Fires after any of these commands complete:
- `LAYOUT_SWITCHED`
- `SETVAR`
- `CTAB`
- `LAYOUT`
- `REGEN`

Reads the current tab via `(getvar "CTAB")` and passes it to `KP-CORE`. The `*KP-RUNNING*` guard prevents re-entry when these commands fire as a side effect of the engine itself.

---

#### `TriggerOnLayoutSwitch`

```lisp
(defun TriggerOnLayoutSwitch (reactorInfo arg / layoutName) ...)
```

**Event:** `:vlr-layoutSwitched`
**Trigger condition:** Fires immediately when any layout tab is activated.

Reads the layout name directly from the reactor argument and passes it to `KP-CORE`.

---

### Reactor Registration

```lisp
(if cmdReactor (vlr-remove cmdReactor))
(setq cmdReactor (vlr-command-reactor nil '((:vlr-commandEnded . TriggerAfterCommand))))

(if layoutReactor (vlr-remove layoutReactor))
(setq layoutReactor (vlr-miscellaneous-reactor nil '((:vlr-layoutSwitched . TriggerOnLayoutSwitch))))
```

- Reactors are re-registered on every file load (safe reload pattern).
- Existing reactors are removed before re-creating to prevent duplicate listeners.
- Stored in global variables `cmdReactor` and `layoutReactor`.

---

## Section 2 — The Body (Universal Engine)

### Function: `Apply-Layer-State-Universal`

```lisp
(defun Apply-Layer-State-Universal (targetPattern thawList
                                    / lyrData lyrName targetName foundTarget xrefName
                                      matchesThaw acadDoc layerColl lyr
                                      savedRegenauto) ...)
```

**Purpose:** The single execution engine for all tab macros. Performs a complete layer visibility reset using **ActiveX layer methods** (`vla-put-LayerOn`, `vla-put-Freeze`).

#### Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `targetPattern` | string | The exact name of the layer to set as current (`CLAYER`). Also matched against xref-prefixed variants using `*\|<name>` wildcard. |
| `thawList` | list of strings | Wildcard patterns. Layers matching any of these are **thawed and turned on**. All others are **turned off** (color sign only — never frozen). |

#### Layer State Mechanism

The engine uses ActiveX (`vla-*`) methods exclusively for layer state changes — **not** `entmod`, **not** the LAYER command, **not** `vl-cmdf`. This decision was made because:

1. **`entmod` triggers a regen per call** when the freeze flag (DXF 70 bit 1) changes, even when `REGENMODE` is set to `0`. This caused unacceptable performance on drawings with many layers.
2. **`vl-cmdf` inside a reactor queues commands** rather than executing them, making sequential layer operations unreliable.
3. **ActiveX property sets are synchronous and do not trigger per-layer regens.**

| ActiveX Method | Effect | Triggers Regen? |
|----------------|--------|-----------------|
| `vla-put-LayerOn lyr :vlax-true` | Turns layer on (display) | No (redraw only) |
| `vla-put-LayerOn lyr :vlax-false` | Turns layer off (display) | No (redraw only) |
| `vla-put-Freeze lyr :vlax-false` | Thaws layer (when needed) | Yes (only when state actually changes) |

The engine never *freezes* layers — only thaws them when a previously-frozen layer needs to become visible. Hidden layers are turned off (not frozen), which avoids regens entirely on subsequent tab switches once the drawing has been "primed."

#### Execution Steps

1. **Scan all layers** in the drawing to find `targetPattern`. The scan prefers a direct layer name match; if none exists, falls back to an xref-prefixed match (`*|<pattern>`). This is done with `tblnext` — read-only and fast.

2. **If a target was found:**

   a. Save the current `REGENMODE` value into `savedRegenauto`, then set `REGENMODE` to `0` to suppress any incidental auto-regens during the layer pass.

   b. Park `CLAYER` on layer `0` — always safe — before modifying any layer states.

   c. Acquire the ActiveX layer collection:
      ```lisp
      (setq acadDoc   (vla-get-ActiveDocument (vlax-get-acad-object)))
      (setq layerColl (vla-get-Layers acadDoc))
      ```

   d. Iterate every layer with `vlax-for`:
      - Skip layers `0` and `DEFPOINTS`.
      - Determine `matchesThaw` by checking the target name (exact match) and then each pattern in `thawList` via `wcmatch` (case-insensitive).
      - Wrap the visibility change in `vl-catch-all-apply` so a single restricted layer cannot abort the loop:
        - **If `matchesThaw`** → if frozen, `vla-put-Freeze :vlax-false`; if off, `vla-put-LayerOn :vlax-true`.
        - **If not** → if currently on, `vla-put-LayerOn :vlax-false`. Freeze flag is left untouched.
      - State changes are only issued when the property is actually different from the desired state — avoiding unnecessary writes.
      - Print `TARGET: <name>` to the terminal for the target layer.

   e. **Set `CLAYER`** to `targetName`, but only if `targetName` does **not** contain `|` (XREF-dependent layers cannot be made current — AutoCAD will reject the `setvar`). If skipped, an info line is logged instead.

   f. **Restore `REGENMODE`** to `savedRegenauto`.

   g. **Regenerate** via ActiveX:
      ```lisp
      (vla-Regen acadDoc 1)
      ```
      Argument `1` corresponds to `acAllViewports` (regen model + all paper-space viewports). `vla-Regen` is used instead of `(vl-cmdf "REGENALL")` because the engine runs inside reactor callbacks, where `vl-cmdf` only queues commands for later execution. `vla-Regen` runs synchronously, bypasses the command queue, and reliably commits the visual update.

3. **If `targetPattern` not found:** print an error message and exit without modifying any layers.

#### Layer Matching Rules

- Pattern matching uses AutoLISP `wcmatch` (wildcard match — supports `*`, `?`, `#`, `~`, etc.).
- All comparisons are case-insensitive via `strcase`.
- Layers `0` and `DEFPOINTS` are always protected from modification.
- Only the target search supports xref-prefixed (`*|<name>`) matching. The thaw-list patterns match against the literal layer name as it appears in the drawing.

#### Layer Visibility Matrix

| Condition | Result |
|-----------|--------|
| Layer is `0` or `DEFPOINTS` | Unchanged (skipped) |
| Layer is `targetPattern` | Thawed (if frozen) + On + set as CLAYER (unless XREF-dependent) |
| Matches `thawList` | Thawed (if frozen) + On |
| Matches neither | **Off** (color sign flipped negative; freeze state untouched) |

> **Note:** This is a deliberate deviation from the original AutoCAD macro (`-layer;f;*;t;list;;`), which froze non-matching layers. The engine uses on/off instead because freeze-state changes trigger regens regardless of the underlying mechanism (`entmod`, `vla-put-Freeze`, or `-LAYER`), which made tab switching unacceptably slow on real drawings.

---

## Section 3 — Macros (Tab Definitions)

Each macro is a zero-argument function named using the `L_<cleaned_tab_name>` convention. Each calls `Apply-Layer-State-Universal` with tab-specific arguments.

---

### `L_A-110 FLOOR PLAN` — Floor Plan

**Tab name:** `A-110 FLOOR PLAN`

**Source macro (original AutoCAD command-line form):**
```
^C^C^C-layer;on;*;t;*;m;1st-flr-cont4;f;*;t;0-NONZ-*,0_BDR2TTL,0_ARTAG_PS,0_PS_ARTAG,0_PS_NOTES,0_PS_SCHED,0_PS_REV*,0_NONPLOT,0,1st-titl-*,1st-com1-*,1st-flr-*;;
```

| Argument | Value |
|----------|-------|
| Target layer | `1st-flr-cont4` |
| Thaw patterns | `"0"`, `"0-NONZ-*"`, `"0_BDR2TTL"`, `"0_ARTAG_PS"`, `"0_PS_ARTAG"`, `"0_PS_NOTES"`, `"0_PS_SCHED"`, `"0_PS_REV*"`, `"0_NONPLOT"`, `"1st-titl-*"`, `"1st-com1-*"`, `"1st-flr-*"` |

**Intent:** Shows all first-floor plan layers, title block, common annotation, and paper space elements. All other layers are turned off.

---

## Adding a New Tab Macro

To support a new layout tab, add a function to Section 3 following this template:

```lisp
;; Tab: <exact-tab-name-in-autocad>
(defun L_<CLEANED_TAB_NAME> ()
  (Apply-Layer-State-Universal
    "<target-layer-name>"
    '("<thaw-pattern-1>" "<thaw-pattern-2>" ...)   ; layers to show
  ))
```

**Name cleaning rules (must match `KP-CORE` logic):**
- Uppercase entire name
- Remove: `-`, `.`, spaces
- Prepend: `L_`

No reactor changes are required. The dispatch system resolves function names dynamically.

---

## Known Behaviors and Constraints

| Item | Detail |
|------|--------|
| Case sensitivity | All layer name comparisons are case-insensitive. |
| Xref target lookup | Target layer lookup supports `*\|<pattern>` syntax for xref-nested layers, with direct (non-xref) matches preferred. |
| Xref CLAYER protection | If the target resolves to an xref-dependent layer (contains `\|`), `CLAYER` is left on `0` because AutoCAD rejects setvar of xref layers. The visibility pass still runs normally. |
| Protected layers | `0` and `DEFPOINTS` are never modified. |
| Re-entrancy | `*KP-RUNNING*` guard prevents the engine from being re-triggered by its own internal `setvar` and regen calls. |
| Dual reactor redundancy | Both `:vlr-commandEnded` and `:vlr-layoutSwitched` are registered to ensure reliability across AutoCAD versions. |
| Safe reload | Reactors are removed and re-registered each load. Loading the file twice does not create duplicates. |
| Missing macro | If no function matches the tab name, a warning is printed and no layer changes occur. |
| Crash isolation (macro level) | `vl-catch-all-apply` wraps every macro call in `KP-CORE`. Errors within a macro are logged and do not break the reactor. |
| Crash isolation (per-layer) | Each `vla-put-*` call is wrapped in `vl-catch-all-apply`. A single restricted/locked layer cannot abort the entire loop. |
| ActiveX-only layer changes | All layer visibility changes use `vla-put-LayerOn` and `vla-put-Freeze`. `entmod` is never used for layer state. `vl-cmdf` and `command` are never used for layer operations. |
| Synchronous regen | Final regen uses `vla-Regen acadDoc 1` (synchronous, ActiveX). `vl-cmdf "REGENALL"` is unreliable inside reactor callbacks because it queues commands rather than executing them. |
| REGENMODE handling | `REGENMODE` is saved at engine start, set to `0` for the layer pass, and restored before the final regen. |

---

## File Load Message

On successful load, the file prints:

```
LAYOUTTAB (v1.0.2) Loaded. Ready for Floor Plan switch.
```

---

*Specification updated to match `LAYOUTTAB.LSP` v1.0.2.*
