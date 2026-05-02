;; LAYOUTTAB.LSP v1.0.3
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

(if (not *KP-RUNNING*) (setq *KP-RUNNING* nil))

(defun KP-CORE (layout_name / clean_name macro_func_name cmdFunc result)
  (if (and (not *KP-RUNNING*) layout_name (/= layout_name ""))
    (progn
      (setq *KP-RUNNING* t)
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
      (setq *KP-RUNNING* nil)
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
                                    / lyrData lyrName targetName foundTarget xrefName
                                      matchesThaw acadDoc layerColl lyr
                                      savedRegenauto)
  (princ (strcat "\n[LAYOUTTAB] Engine Init. Target: " targetPattern))

  ;; Step 1: Scan all layers to find targetPattern — prefer direct layer over xref-prefixed
  (setq foundTarget nil  targetName nil  xrefName nil)
  (setq lyrData (tblnext "LAYER" t))
  (while lyrData
    (setq lyrName (cdr (assoc 2 lyrData)))
    (cond
      ((= (strcase lyrName) (strcase targetPattern))
       (setq targetName lyrName  foundTarget t))
      ((and (not targetName)
            (wcmatch (strcase lyrName) (strcat "*|" (strcase targetPattern))))
       (setq xrefName lyrName  foundTarget t))
    )
    (setq lyrData (tblnext "LAYER"))
  )
  (if (not targetName) (setq targetName xrefName))

  (if foundTarget
    (progn
      ;; Suppress auto-regen during batch layer changes
      (setq savedRegenauto (getvar "REGENMODE"))
      (setvar "REGENMODE" 0)

      ;; Safety: park CLAYER on layer 0 before modifying any layer states
      (setvar "CLAYER" "0")

      ;; Step 2: ActiveX layer state — vla-* methods don't trigger per-call regens
      ;;   vla-put-LayerOn: turns layer on/off (display only, no regen)
      ;;   vla-put-Freeze:  thaws frozen layers when they need to become visible
      (setq acadDoc   (vla-get-ActiveDocument (vlax-get-acad-object)))
      (setq layerColl (vla-get-Layers acadDoc))

      (vlax-for lyr layerColl
        (setq lyrName (vla-get-Name lyr))
        (if (not (member (strcase lyrName) (list "0" "DEFPOINTS")))
          (progn
            (setq matchesThaw nil)
            (if (= (strcase lyrName) (strcase targetName))
              (setq matchesThaw t)
              (foreach p thawList
                (if (wcmatch (strcase lyrName) (strcase p))
                  (setq matchesThaw t)
                )
              )
            )

            (vl-catch-all-apply
              '(lambda ()
                 (if matchesThaw
                   (progn
                     (if (= (vla-get-Freeze lyr) :vlax-true)
                       (vla-put-Freeze lyr :vlax-false))
                     (if (= (vla-get-LayerOn lyr) :vlax-false)
                       (vla-put-LayerOn lyr :vlax-true))
                   )
                   (if (= (vla-get-LayerOn lyr) :vlax-true)
                     (vla-put-LayerOn lyr :vlax-false))
                 )
               )
            )

            (if (and matchesThaw (= (strcase lyrName) (strcase targetName)))
              (princ (strcat "\n[LAYOUTTAB] TARGET: " lyrName))
            )
          )
        )
      )

      ;; Step 3: Set CLAYER — skip if target is an XREF-dependent layer (contains |)
      (if (not (vl-string-search "|" targetName))
        (progn
          (princ (strcat "\n[LAYOUTTAB] CMD: setvar CLAYER " targetName))
          (setvar "CLAYER" targetName)
        )
        (princ (strcat "\n[LAYOUTTAB] INFO: CLAYER not set — " targetName " is XREF-dependent"))
      )

      ;; Step 4: Restore auto-regen and do single final regen
      ;; vla-Regen runs synchronously and bypasses the command queue —
      ;; required because vl-cmdf inside a reactor only QUEUES the command
      ;; for later execution, which is unreliable after ActiveX layer changes.
      ;; Argument 1 = acAllViewports (regen across model + all layout viewports).
      (setvar "REGENMODE" savedRegenauto)
      (princ "\n[LAYOUTTAB] CMD: vla-Regen acAllViewports")
      (vla-Regen acadDoc 1)
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

;; Tab: A-114 1st-EqpT_FMMISC
(defun L_A1141STEQPT_FMMISC ()
  (Apply-Layer-State-Universal
    "1st-EqpT-cont4"
    '("0"          "0-NONZ-*"
      "0_BDR2TTL"  "0_ARTAG_PS"
      "0_PS_ARTAG" "0_PS_NOTES" "0_PS_SCHED" "0_PS_REV*" "0_NONPLOT"
      "1st-titl-*" "1st-Com1-*" "1st-EqpT-*" "1st-flr-argrid" "1st-FLR-FM*")
  )
)

;; Tab: A-112 RCP
(defun L_A112RCP ()
  (Apply-Layer-State-Universal
    "1st-RCP-cont4"
    '("0" "0-NONZ-*" "0_BDR2TTL" "0_ARTAG_PS" "0_PS_ARTAG" "0_PS_NOTES" "0_PS_SCHED" "0_PS_REV*" "0_NONPLOT" "1st-titl-*" "1st-com1-*" "1st-RCP-*" "1st-flr-argrid" "1st-lght-*" "1st-rcp-arCLGTXT")
)

(princ "\nLAYOUTTAB (v1.0.3) Loaded. Ready for Floor Plan switch.")
(princ)
