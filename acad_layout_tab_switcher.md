# acad_layout_tab_switcher.md — System Specification

**File:** `LAYOUTTAB.LSP`
**Version:** 1.0
**Platform:** AutoCAD (AutoLISP / Visual LISP)
**Role:** Automated layer visibility manager driven by layout (tab) switching

---

## Overview

LAYOUTTAB.LSP is an AutoCAD AutoLISP file that automatically controls layer visibility whenever the user switches between paper space layout tabs. When a tab is activated, the system identifies a matching LISP function by name and runs it. That function calls a universal engine which thaws a set of visible layers and freezes all others, then regenerates the drawing.

The system has three logical sections:

| Section | Name | Responsibility |
|---------|------|----------------|
| 1 | The Brain | Reactor setup and tab-to-function dispatch |
| 2 | The Body (Universal Engine) | Layer freeze/thaw execution |
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

### Function: `LAOUTTAB`

```lisp
(defun KP-CORE (layout_name / clean_name macro_func_name cmdFunc) ...)
```

**Purpose:** Core dispatch function. Converts a layout tab name into a LISP function name, then calls it if it exists.

**Name transformation algorithm:**

1. Trim leading/trailing spaces
2. Convert to uppercase
3. Remove all `-` characters
4. Remove all space characters
5. Remove all `.` characters
6. Remove any remaining non-standard characters (empty-string loop)
7. Prepend `L_` prefix

**Example transformations:**

| Layout Tab Name | Cleaned Name | Function Called |
|-----------------|--------------|-----------------|
| `A-110 FLOOR PLAN` | `A110FLOORPLAN` | `L_A110FLOORPLAN` |

**Dispatch behavior:**
- Uses `eval` + `read` to dynamically resolve the function name at runtime.
- Checks that the resolved symbol is a valid function (`SUBR` or `USUBR` type).
- If no matching function exists, prints a warning but does not throw an error.
- Uses `vl-catch-all-apply` to prevent crashes from within a macro from breaking the reactor.

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

Reads the current tab via `(getvar "CTAB")` and passes it to `KP-CORE`.

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
                                    / lyrData lyrName targetName foundTarget
                                      matchesThaw lyrEnt lyrEntData lyrFlags lyrColor) ...)
```

**Purpose:** The single execution engine for all tab macros. Performs a complete layer visibility reset using direct entity modification (`entmod`) — bypassing the AutoCAD command processor entirely for all layer operations.

#### Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `targetPattern` | string | The exact name of the layer to set as current (`CLAYER`). Also matched against xref-prefixed variants using `*\|<name>` wildcard. |
| `thawList` | list of strings | Wildcard patterns. Layers matching any of these are **thawed and turned on**. All others are frozen. |

#### DXF Entity Codes Modified

| Code | Field | Operation |
|------|-------|-----------|
| `70` | Layer flags | `(logand flags -2)` clears bit 1 → **thaw**. `(logior flags 1)` sets bit 1 → **freeze**. |
| `62` | Color number | `(abs color)` makes positive → **layer on**. Negative values mean layer is off. |

#### Execution Steps

1. Scan all layers in the drawing to find `targetPattern` (supports xref-prefixed layers via `*|pattern`).
2. If found:
   a. Park `CLAYER` on layer `0` — always safe — before modifying any layer states: `(setvar "CLAYER" "0")`.
   b. Single-pass `entmod` loop over all layers (excluding `0` and `DEFPOINTS`):
      - **Target layer** → thaw (clear DXF 70 bit 1) + on (abs DXF 62). Print `TARGET:` to terminal.
      - **Matches `thawList`** → thaw + on via `entmod`. Print `THAW:` to terminal.
      - **All others** → freeze (set DXF 70 bit 1) via `entmod`. No terminal output.
   c. Set `CLAYER` to target — guaranteed thawed by step b: `(setvar "CLAYER" targetName)`.
   d. Regenerate: `(vl-cmdf "REGENALL")`.
3. If targetPattern not found: print an error message.

> **Layer state changes use `entmod` only — never `vl-cmdf` or `command` for layer operations.** The engine runs inside reactor callbacks where `vl-cmdf` queues commands asynchronously rather than executing them immediately, making sequential layer operations unreliable. `entmod` modifies the layer table directly in memory and is always synchronous. `vl-cmdf` is used only for `REGENALL` at the end, where execution order does not matter.

#### Layer Matching Rules

- Pattern matching uses AutoLISP `wcmatch` (wildcard match — supports `*`, `?`, `#`, `~`).
- All comparisons are case-insensitive via `strcase`.
- Layers `0` and `DEFPOINTS` are always protected from modification.

#### Layer Visibility Matrix

| Condition | Result |
|-----------|--------|
| Layer is `0` or `DEFPOINTS` | Unchanged (skipped) |
| Layer is `targetPattern` | Thawed + On + set as CLAYER |
| Matches `thawList` | Thawed + On |
| Matches neither | Frozen |

---

## Section 3 — Macros (Tab Definitions)

Each macro is a zero-argument function named using the `L_<cleaned_tab_name>` convention. Each calls `Apply-Layer-State-Universal` with tab-specific arguments.

---

### `L_A-110 FLOOR PLAN` — Floor Plan

**Tab name:** `A-110 FLOOR PLAN`

**Source macro:**
```
^C^C^C-layer;on;*;t;*;m;1st-flr-cont4;f;*;t;0-NONZ-*,0_BDR2TTL,0_ARTAG_PS,0_PS_ARTAG,0_PS_NOTES,0_PS_SCHED,0_PS_REV*,0_NONPLOT,0,1st-titl-*,1st-com1-*,1st-flr-*;;
```

| Argument | Value |
|----------|-------|
| Target layer | `1st-flr-cont4` |
| Thaw patterns | `"0"`, `"0-NONZ-*"`, `"0_BDR2TTL"`, `"0_ARTAG_PS"`, `"0_PS_ARTAG"`, `"0_PS_NOTES"`, `"0_PS_SCHED"`, `"0_PS_REV*"`, `"0_NONPLOT"`, `"1st-titl-*"`, `"1st-com1-*"`, `"1st-flr-*"` |

**Intent:** Shows all first-floor plan layers, title block, common annotation, and paper space elements. All other layers are frozen. No freeze-override list is needed — the thaw list is exclusive by design.

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

**Name cleaning rules (must match `LAYOUTTAB` logic):**
- Uppercase entire name
- Remove: `-`, `.`, spaces, and any other non-alphanumeric/underscore characters
- Prepend: `L_`

No reactor changes are required. The dispatch system resolves function names dynamically.

---

## Known Behaviors and Constraints

| Item | Detail |
|------|--------|
| Case sensitivity | All layer name comparisons are case-insensitive. |
| Xref layer support | Target layer lookup supports `*\|<pattern>` syntax for xref-nested layers. |
| Protected layers | `0` and `DEFPOINTS` are never modified. |
| Dual reactor redundancy | Both `:vlr-commandEnded` and `:vlr-layoutSwitched` are registered to ensure reliability across AutoCAD versions. |
| Safe reload | Reactors are removed and re-registered each load — loading the file twice does not create duplicates. |
| Missing macro | If no function matches the tab name, a warning is printed and no layer changes occur. |
| Crash isolation | `vl-catch-all-apply` wraps every macro call. The return value must be checked with `vl-catch-all-error-p` and the message logged via `vl-catch-all-error-message` — otherwise errors are silently discarded. |
| `entmod` for layer ops | All layer freeze/thaw/on operations use `entmod` directly on DXF codes 70 and 62. `vl-cmdf` queues commands asynchronously in reactor callbacks, making layer state changes unreliable when sequenced with LISP logic. `entmod` is synchronous and bypasses the command processor entirely. |
| `vl-cmdf` for REGENALL only | `vl-cmdf` is used exclusively for `REGENALL` at the end of the engine. It is never used for layer operations. `command` must not be used anywhere in the engine. |

---

## File Load Message

On successful load, the file prints:

```
LAYOUTTAB (v1.0) Loaded. Ready for Floor Plan switch.
```

---

*Specification generated from source: `KP_MASTER.LSP` v56.6*
