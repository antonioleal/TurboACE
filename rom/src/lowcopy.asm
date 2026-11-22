; =============================================================================
; Copy of the stock ROM interrupt path and the Forth-stack RSTs, placed at the
; same addresses in every extension page (2-7).  register-map.md section 5,
; "Copy ranges".  Ranges were found with tools/misc/z80trace.py.
;
; Use:  LOWCOPY   (after ORG 0 of an extension page)
; =============================================================================

    MACRO LOWCOPY
        ORG $0010                   ; RST $10 (push DE), RST $18 (pop DE)
        INCBIN "build/stock.rom",$0010,16
        ORG $0038                   ; IM 1 vector: JP $013A
        INCBIN "build/stock.rom",$0038,3
        ORG $013A                   ; interrupt handler: FRAMES, keyboard
        INCBIN "build/stock.rom",$013A,$44  ; $013A-$017D
        ORG $0153                   ; JR Z,$0176 -> JR $0176: the line-editor
        DB  $18                     ; branch can never be taken here
        ORG $0310                   ; keyboard scan $0310-$0375 and the three
        INCBIN "build/stock.rom",$0310,$DE  ; key tables $0376-$03ED
        ORG $0859                   ; tails of RST $18 / RST $10
        INCBIN "build/stock.rom",$0859,12
    ENDM

; Free areas in an extension page (everything else is the copy above):
LOWFREE_A       EQU $0000   ; - $000F
LOWFREE_B       EQU $0020   ; - $0037
LOWFREE_C       EQU $003B   ; - $0139   (page 2: $0092-$009A reserved)
LOWFREE_D       EQU $017E   ; - $030F
LOWFREE_E       EQU $03EE   ; - $0858
LOWFREE_F       EQU $0865   ; - $1FFF   main code area
