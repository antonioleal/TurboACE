; =============================================================================
; Stock Jupiter Ace ROM internals that are not dictionary words.
; Every value was checked against the stock ROM image
; (SHA-1 597ba8a15a292688333c84dc9fd35172abe5e7e6); the evidence is noted.
; Dictionary words (code field addresses) are in ace_words.inc (generated).
; =============================================================================

; ---- System variables (RAM) --------------------------------------------------
SV_RAMTOP       EQU $3C18   ; reset: LD ($3C18),HL / LD SP,HL at $002F
SV_SPARE        EQU $3C3B   ; Forth data-stack pointer; RST $10/$18 use it
SV_ERRNO        EQU $3C3D   ; error code; RST $20 stores it here ($0022)
SV_FORTH_LINK   EQU $3C47   ; link field of the RAM word FORTH (from ROM $0130)
SV_FORTH_LINK0  EQU $1FFF   ; its stock value: an empty header at $1FFD-$1FFF
                            ; whose link is $1D58 (UFLOAT, the last ROM word)

ERR_TAPE        EQU 10      ; the ROM's tape error (LOAD: $1AB6); also all SD errors
ERR_NO_MEMORY   EQU 1       ; the ROM's own check at $0F8C: RST $20 / DB 1 when
                            ; SPARE + n + 30 reaches SP
ACE_CHARSET     EQU $2C00   ; character set, 128 x 8 bytes (video-priority copy)
ACE_SCREEN      EQU $2400   ; text screen, 32 x 24, used by the ROM (video-priority copy)

; ---- Inner interpreter -------------------------------------------------------
; On entry to a code word: DE = parameter field, IY = NEXT. Return with JP (IY).
ACE_NEXT        EQU $04B9   ; NEXT: POP HL / fetch / JP (HL). Reset sets IY = $04C8
                            ; ($0047: stack-underflow check, then NEXT); the
                            ; error path sets IY = $04B9 ($00AF). Code words
                            ; must return with JP (IY), never JP ACE_NEXT.
ACE_DOCOLON     EQU $0EC3   ; code-field contents of all 34 ROM colon words
ACE_ENDDEF      EQU $04B6   ; end of colon definition (compiled by ;); appears in 26 ROM colon
                            ; bodies (CF contains $04B8: POP HL, then NEXT)
ACE_LIT_WORD    EQU $1011   ; inline 16-bit literal follows (13 uses in ROM)
ACE_LIT_BYTE    EQU $104B   ; inline 8-bit literal follows  (24 uses in ROM)

; ---- Compiler words and the run-time parts they compile ------------------------
; A compiler word (IF, CASE, ...) has the IMMEDIATE bit and the code field $1108;
; its body is the run-time part's code field, then the compile-time cells. The
; run-time part is preceded by [operand count][offset]: LIST skips the operands
; and prints the name at (offset field + offset + 1). Checked by compiling
; 0 COMPILER .. RUNS> .. and IF/ELSE/THEN/DO/+LOOP words with the stock ROM in
; the harness (test/gfxtest.c, Forth sessions).
ACE_DOCOMPILER  EQU $1108   ; code-field contents of IF, ELSE, THEN, DO, RUNS>, ...
ACE_RT_IF       EQU $1283   ; ?branch: [2][-199] before it; offset follows
ACE_RT_ELSE     EQU $1271   ; branch: offset follows
ACE_RT_THEN     EQU $12A4   ; no-op (code field $04B9, NEXT)
ACE_RT_DO       EQU $1323   ; ( limit start -- ) to the return stack
ACE_RT_PLUSLOOP EQU $133C   ; ( n -- ) offset follows
ACE_RT_LOOP     EQU $1332   ; offset follows
ACE_LIT_FLOAT   EQU $1064   ; inline floating-point literal follows (4 bytes, [4] before it)
ACE_BRANCH_CODE EQU $1278   ; POP HL / LD E,(HL) / INC HL / LD D,(HL) / ADD HL,DE /
                            ; JP $04BA: IP = offset field + 1 + offset
ACE_NEXT_HL     EQU $04BA   ; NEXT with HL = the new IP (the branch runtimes end here)
; branch target T from an offset field: DW T - $ - 1, on its own line (in sjasmplus
; $ is the start of the statement, not of the second value of a DW list)
SV_STKBOT       EQU $3C37   ; HERE: the next free dictionary byte
SV_FRAMES       EQU $3C2B   ; 50 Hz frame counter (4 bytes)
ERR_STRUCTURE   EQU 5       ; the ROM's "not properly structured" (IF without THEN at ;)
ERR_FLOAT       EQU 8       ; the ROM's floating-point error (1. 0. F/ gives ERROR 8)
ERR_NOT_FOUND   EQU 13      ; the ROM's "word not found" (LIST, EDIT, FORGET)

; ---- Routines ----------------------------------------------------------------
ACE_POPBC       EQU $084E   ; LD HL,($3C3B) / DEC HL x2 / LD BC / store / RET
                            ; (page 1 only: not copied into extension pages)
ACE_ERROR_ENTRY EQU $00AD   ; target of RST $20 after storing the code
ACE_QUIT_CODE   EQU $009B   ; LD SP,($3C18) / EI / JP $04F2
ACE_PLOT_CODE   EQU $0B4C   ; machine code of stock PLOT (CF at $0B4A -> $0B4C;
                            ; begins CALL $084E, so HL/A on entry are not used)
ACE_CLS_CODE    EQU $0A1F   ; machine code of stock CLS (CF at $0A1D -> $0A1F):
                            ; CALL $0A24 / JP (IY); $0A24 loads DE itself

; ---- Boot hook ---------------------------------------------------------------
ACE_BOOT_HOOK   EQU $008E   ; stock: ED 56 18 09 (IM 1 / JR $009B)
BOOT_ENTRY      EQU $0092   ; first fetch from page 2 after the hook's OUT
BOOT_EXIT       EQU $0097   ; page 2 exit sequence; next fetch is $009B, page 1
; ---- Tape block routines (register-map.md section 5, "Tape hooks") ---------
ACE_TAPE_WRITE  EQU $1820   ; block write: HL addr, DE length, C flag ($00/$FF)
ACE_TAPE_WRITE_RESUME EQU $182C ; first instruction after the 12 bytes the
                            ; cassette path repeats ($1820-$182B)
ACE_TAPE_READ   EQU $18A7   ; block read: HL, DE, C flag, carry set = load
ACE_TAPE_READ_RESUME EQU $18AB ; after DI / PUSH IY / PUSH HL ($18A7-$18AA)
ACE_TAPE_EXIT   EQU $1892   ; shared exit both routines push: POP IY, BREAK
                            ; check, EI, EX AF,AF' / RET ($18A5/$18A6)
ACE_TAPE_RET    EQU $18A6   ; that RET: returns to the routine's caller
ACE_TAPE_LEADER EQU $E000   ; HL loaded at $1829 (leader counter, header)
ACE_LOAD_SEARCH EQU $1A81   ; return address of LOAD's header-search read
ACE_LOAD_WANTED EQU $2301   ; the header LOAD looks for (= $2701); its name at +1,
                            ; 10 characters: blank (0, or spaces) for LOAD with no name
ACE_ERROR10     EQU $1AB6   ; RST $20 / DB 10 (tape error)
ACE_BREAK       EQU $04F0   ; RST $20 / DB 3 (BREAK)
BOOT_EXIT_OUT   EQU $0099   ; its OUT ($E3),A: enter with A = CMD_ROMPAGE | page
                            ; to continue at QUIT ($009B) in that ROM page
