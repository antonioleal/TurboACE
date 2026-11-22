; =============================================================================
; Boot page setup (ROM page 2). register-map.md section 5, "Boot hook".
; Entered from BOOT_ENTRY ($0092) after page 1's hook at $008E has mapped
; page 2. Interrupts are disabled (reset starts with DI; QUIT does EI).
; =============================================================================

BOOT_SETUP:
        ; ---- AY: ports A/B outputs, sound off, default colours --------------
        LD  B,14                    ; registers 13..0 = 0 (R7 set below)
        LD  C,13
boot_ay_clear:
        LD  A,C
        OUT (PORT_AY_REG),A
        XOR A
        OUT (PORT_AY_VAL),A
        DEC C
        DJNZ boot_ay_clear
        LD  A,AY_R_ENABLE
        OUT (PORT_AY_REG),A
        LD  A,$FF                   ; b7-b6 ports out, b5-b0 channels off
        OUT (PORT_AY_VAL),A
        LD  A,AY_R_PORTA
        OUT (PORT_AY_REG),A
        LD  A,$0F                   ; PAPER black, INK white
        OUT (PORT_AY_VAL),A
        LD  A,AY_R_PORTB
        OUT (PORT_AY_REG),A
        XOR A                       ; BORDER black
        OUT (PORT_AY_VAL),A

        ; ---- user RAM: linear 16K at $C000 (as at reset) ---------------------
        XOR A
        OUT (PORT_PAGE),A           ; window 0 = page 0
        LD  A,PAGE_WIN1 | 1
        OUT (PORT_PAGE),A           ; window 1 = page 1

        ; ---- XCFG: colour RAM not mapped -------------------------------------
        LD  A,CMD_XCFG
        OUT (PORT_CTRL),A           ; XCFG = 0

        ; ---- extension dictionary into RAM, state cleared, linked -----------
        LD  HL,XDICT_IMAGE
        LD  DE,XDICT_BASE
        LD  BC,XDICT_LEN
        LDIR
        LD  HL,XSTATE
        LD  DE,XSTATE + 1
        LD  BC,XSTATE_SIZE - 1
        LD  (HL),0
        LDIR
        CALL XLINKS0                ; 0 TURBO: TURBO and the SD words linked in
        LD  HL,XDICT_LAST_NLF
        LD  (SV_FORTH_LINK),HL

        ; ---- RAMTOP stays where the stock RAM test put it (51K: 0 TURBO) ----
        LD  HL,(SV_RAMTOP)
        LD  (XS_RAMTOP0),HL

        IM  1                       ; replaces the stock IM 1 the hook overwrote
        JP  BOOT_EXIT

; HSTOCK: the end of -2 TURBO, reached through XDISPATCH. The RAM part has
; already reset the hardware, RAMTOP and the FORTH link ($1FFF). Turn on the
; $3000 mirror (the extension's RAM disappears, so this must run from ROM)
; and continue at QUIT in the stock ROM page 0. Stays so until reset.
HSTOCK:
        LD  A,CMD_XCFG | XCFG_MIRROR
        OUT (PORT_CTRL),A
        LD  A,CMD_ROMPAGE | ROMPG_STOCK
        JP  BOOT_EXIT_OUT

; HSTOCK1: the end of -1 TURBO, as HSTOCK, but $3B00-$3BFF (the SD code's state)
; stay extension RAM (XCFG KEEP) and QUIT continues in ROM page 1, the stock ROM
; with the tape hooks, so the tape words keep using the card when SDTAPE is on.
HSTOCK1:
        LD  A,CMD_XCFG | XCFG_MIRROR | XCFG_KEEP
        OUT (PORT_CTRL),A
        LD  A,CMD_ROMPAGE | ROMPG_MAIN
        JP  BOOT_EXIT_OUT
