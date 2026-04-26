;; LAYOUTTAB.LSP v1.0
;; Purpose: Detects layout tab switch and calls matching layer macros.

(vl-load-com)

;; ===========================================================================
;; SECTION 1: THE "BRAIN" (Reactor Logic)
;; ===========================================================================

(defun String-Replace-All (old new str / n)
  (while (setq n (vl-string-search old str))
    (setq str (vl-string-subst new old str n))
  )
  str
)

(defun KP-CORE (layout_name / clean_name macro_func_name cmdFunc result)
  (if (and layout_name (/= layout_name ""))
    (progn
      (setq clean_name (vl-string-trim " " (strcase layout_name)))
      (setq clean_name (String-Replace-All "-" "" clean_name))
      (setq clean_name (String-Replace-All " " "" clean_name))
      (setq clean_name (String-Replace-All "." "" clean_name))
      (setq macro_func_name (strcat "L_" clean_name))
      (princ (strcat "\n[LAYOUTTAB] Tab: " layout_name " -> Triggering: " macro_func_name))
      (setq cmdFunc (eval (read macro_func_name)))
      (if (and cmdFunc (or (= (type cmdFunc) 'SUBR) (= (type cmdFunc) 'USUBR)))
        (progn
          (princ "\n[LAYOUTTAB] Running Macro...")
          (setq result (vl-catch-all-apply 'cmdFunc nil))
          (if (vl-catch-all-error-p result)
            (princ (strcat "\n[LAYOUTTAB] ERROR: " (vl-catch-all-error-message result)))
          )
        )
        (princ (strcat "\n[LAYOUTTAB] No LISP function defined for " macro_func_name))
      )
    )
  )
  (princ)
)

(defun C:KP_DEBUG ()
  (princ "\n[KP_DEBUG] Manually triggering reactor...")
  (KP-CORE (getvar "CTAB"))
  (princ)
)

(defun TriggerAfterCommand (reactorInfo arg / cmdName)
  (setq cmdName (car arg))
  (if (member cmdName '("LAYOUT_SWITCHED" "SETVAR" "CTAB" "LAYOUT" "REGEN"))
    (KP-CORE (getvar "CTAB"))
  )
)

(defun TriggerOnLayoutSwitch (reactorInfo arg / layoutName)
  (setq layoutName (car arg))
  (KP-CORE layoutName)
)

(if cmdReactor (vlr-remove cmdReactor))
(setq cmdReactor (vlr-command-reactor nil '((:vlr-commandEnded . TriggerAfterCommand))))
(if layoutReactor (vlr-remove layoutReactor))
(setq layoutReactor (vlr-miscellaneous-reactor nil '((:vlr-layoutSwitched . TriggerOnLayoutSwitch))))

;; ===========================================================================
;; SECTION 2: THE "BODY" (Universal Engine)
;; ===========================================================================

(defun Apply-Layer-State-Universal (targetPattern thawList
                                    / lyrData lyrName targetName foundTarget matchesThaw)
  (princ (strcat "\n[LAYOUTTAB] Engine Init. Target: " targetPattern))

  ;; Step 1: Turn all layers on and thaw all
  (princ "\n[LAYOUTTAB] CMD: -LAYER On * Thaw *")
  (vl-cmdf "-LAYER" "On" "*" "Thaw" "*" "")

  ;; Step 2: Scan all layers to find targetPattern (supports xref-prefixed layers)
  (setq foundTarget nil)
  (setq lyrData (tblnext "LAYER" t))
  (while lyrData
    (setq lyrName (cdr (assoc 2 lyrData)))
    (if (or (= (strcase lyrName) (strcase targetPattern))
            (wcmatch (strcase lyrName) (strcat "*|" (strcase targetPattern))))
      (setq targetName lyrName  foundTarget t)
    )
    (setq lyrData (tblnext "LAYER"))
  )

  (if foundTarget
    (progn
      ;; Step 3a: Set target layer current — use setvar if layer exists, Make to create it if not
      (if (tblsearch "LAYER" targetName)
        (progn
          (princ (strcat "\n[LAYOUTTAB] CMD: setvar CLAYER " targetName))
          (setvar "CLAYER" targetName)
        )
        (progn
          (princ (strcat "\n[LAYOUTTAB] CMD: -LAYER Make " targetName " (creating)"))
          (vl-cmdf "-LAYER" "Make" targetName "")
        )
      )

      ;; Step 3b: Freeze all layers — current layer (targetName) is automatically protected
      (princ "\n[LAYOUTTAB] CMD: -LAYER Freeze *")
      (vl-cmdf "-LAYER" "Freeze" "*" "")

      ;; Step 3c: Thaw layers matching thawList
      (setq lyrData (tblnext "LAYER" t))
      (while lyrData
        (setq lyrName (cdr (assoc 2 lyrData)))
        (if (not (member (strcase lyrName) (list "0" "DEFPOINTS" (strcase targetName))))
          (progn
            (setq matchesThaw nil)
            (foreach p thawList
              (if (wcmatch (strcase lyrName) (strcase p))
                (setq matchesThaw t)
              )
            )
            (if matchesThaw
              (progn
                (princ (strcat "\n[LAYOUTTAB] CMD: -LAYER Thaw/On " lyrName))
                (vl-cmdf "-LAYER" "Thaw" lyrName "On" lyrName "")
              )
            )
          )
        )
        (setq lyrData (tblnext "LAYER"))
      )

      ;; Step 3d: Regenerate
      (princ "\n[LAYOUTTAB] CMD: REGENALL")
      (vl-cmdf "REGENALL")
    )
    (princ (strcat "\n[LAYOUTTAB] Error: Could not find layer '" targetPattern "'"))
  )
  (princ)
)

;; ===========================================================================
;; SECTION 3: MACROS (Tab Definitions)
;; ===========================================================================

;; Tab: A-110 FLOOR PLAN
(defun L_A110FLOORPLAN ()
  (Apply-Layer-State-Universal
    "1st-flr-cont4"
    '("0"          "0-NONZ-*"
      "0_BDR2TTL"  "0_ARTAG_PS"
      "0_PS_ARTAG" "0_PS_NOTES" "0_PS_SCHED" "0_PS_REV*" "0_NONPLOT"
      "1st-titl-*" "1st-com1-*" "1st-flr-*")
  )
)

(princ "\nLAYOUTTAB (v1.0) Loaded. Ready for Floor Plan switch.")
(princ)