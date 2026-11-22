; =============================================================================
; XDICT - the extension dictionary that runs from RAM at $3000-$3AFF.
; Assembled with DISP $3000 inside ROM page 2; the boot page copies it to RAM.
; register-map.md section 5, "Where the extension code lives".
;
; Layout: shared code first, then words in order. Words are only ever
; appended, so addresses compiled into saved programs stay valid.
; State lives at $3B00-$3BFF (hw.inc, XS_*), outside this image.
;
; Word kinds:
;   - small code words and colon words: complete here (page 1 is mapped);
;   - large routines: an 8-byte stub here, the code in a ROM page, reached
;     through XDISPATCH.
;
; Several word bodies are adapted from the Jupiter-II Expansion XROM:
;   MIT License, Copyright (c) 2020 Ricardo Fernandes Lopes
;   (https://github.com/ricaflops/Jupiter-II-Expansion, xrom/xrom.z)
;   Permission is hereby granted, free of charge, to any person obtaining a
;   copy of this software and associated documentation files (the
;   "Software"), to deal in the Software without restriction, including
;   without limitation the rights to use, copy, modify, merge, publish,
;   distribute, sublicense, and/or sell copies of the Software, and to permit
;   persons to whom the Software is furnished to do so, subject to the
;   following conditions: The above copyright notice and this permission
;   notice shall be included in all copies or substantial portions of the
;   Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
;   EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
;   MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN
;   NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
;   DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
;   OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE
;   USE OR OTHER DEALINGS IN THE SOFTWARE.
; =============================================================================

; ---- Header macros -----------------------------------------------------------
; Ace header: name (DC sets bit 7 of the last char), link (previous word's
; name-length field), name-length field, code field.
XLINK = SV_FORTH_LINK0              ; first word links to the stock chain

    MACRO XHEADER _name
XNAME = $
        DC  _name
        DW  XLINK
XLINK = $
        DB  XLINK - XNAME - 2
    ENDM

    MACRO XCODE _name               ; machine-code word, body follows
        XHEADER _name
        DW  $ + 2
    ENDM

    MACRO XCOLON _name              ; colon word, cell list follows
        XHEADER _name
        DW  ACE_DOCOLON
    ENDM

    MACRO XIHEADER _name            ; IMMEDIATE header (compiler words)
XNAME = $
        DC  _name
        DW  XLINK
XLINK = $
        DB  (XLINK - XNAME - 2) | $40
    ENDM

    MACRO XCOMPILER _name, _rt      ; compiler word: run-time part _rt,
        XIHEADER _name              ; compile-time cells follow
        DW  ACE_DOCOMPILER
        DW  _rt
    ENDM

    MACRO XRUNTIME _n, _name        ; before a run-time part's code field: its
        DB  _n                      ; operand count and, for LIST, an offset to
        DW  _name - 1 - $           ; the byte before the compiler word's name
    ENDM

    MACRO XSTUB _name, _page, _routine   ; word whose code is in a ROM page
        XCODE _name
        LD  A,CMD_ROMPAGE | _page
        LD  HL,_routine
        JP  XDISPATCH
    ENDM

    MACRO XCONST _name, _value      ; constant 0-255
        XCODE _name
        LD  E,_value
        JP  XPUSHBYTE
    ENDM

; ==== Shared code ($3000) =====================================================

; XDISPATCH: run a routine in a ROM page with interrupts enabled.
;   In:  A = CMD_ROMPAGE | page, HL = routine, DE/IX/IY as left by the
;        interpreter. The routine must preserve IX and IY.
;   The routine returns with carry clear (OK), or carry set and A = Ace error
;   code, which is raised through a genuine RST $20 so error handling, and the
;   emulator's error trap at $0020, behave exactly as for stock errors.
XDISPATCH:
        LD  (XD_JP + 1),HL
        OUT (PORT_CTRL),A
        CALL XD_JP
        PUSH AF
        LD  A,CMD_ROMPAGE | ROMPG_MAIN
        OUT (PORT_CTRL),A
        POP AF
        JR  C,XD_ERR
        JP  (IY)
; XDCALL: as XDISPATCH, but returns to the caller (carry clear) instead of
; continuing the Forth program; an error is raised the same way.
XDCALL:
        LD  (XD_JP + 1),HL
        OUT (PORT_CTRL),A
        CALL XD_JP
        PUSH AF
        LD  A,CMD_ROMPAGE | ROMPG_MAIN
        OUT (PORT_CTRL),A
        POP AF
        RET NC
        POP HL                      ; drop XDCALL's return address
XD_ERR:
        LD  (XD_ERRCODE),A
        RST $20                     ; pops the address of XD_ERRCODE
XD_ERRCODE:
        DB  0
XD_JP:
        JP  0                       ; target patched by XDISPATCH

; Push E (D = 0) to the Forth stack and continue.
XPUSHBYTE:
        LD  D,0
        RST $10
        JP  (IY)

; Drop 3 / 2 Forth stack items and continue (hi-res words in MODE 0).
XDROP3: RST $18
XDROP2: RST $18
        RST $18
        JP  (IY)

; POINT in MODE 0: drop x y, push 0.
XPOINT0:
        RST $18
        RST $18
        LD  DE,0
        RST $10
        JP  (IY)

; XGFLAG: DE = flag, C = bit in XS_GFLAGS
XGFLAG: LD  HL,XS_GFLAGS
        LD  A,D
        OR  E
        LD  A,C
        JR  Z,xgflag_clr
        OR  (HL)
        LD  (HL),A
        JP  (IY)
xgflag_clr:
        CPL
        AND (HL)
        LD  (HL),A
        JP  (IY)

; Read the current MODE into the Z80 carry flag (C = hi-res). Affects A.
XGETMODE:
        LD  A,CMD_MODE
        IN  A,(PORT_CTRL)
        RRA
        RET

; Read-modify-write an AY port register.
;   In: A = register, C = mask of bits to keep, E = new bits (already shifted)
XAYMERGE:
        OUT (PORT_AY_REG),A
        IN  A,(PORT_AY_VAL)
        AND C
        OR  E
        OUT (PORT_AY_VAL),A
        JP  (IY)

; XRESETHW: the stock look for 0, -1 and -2 TURBO: text mode, text page and
; font 0, colour RAM unmapped, windows on pages 0/1 (linear 16K at $C000),
; sound off, white INK on black PAPER and BORDER, RAMTOP as found at reset.
XRESETHW:
        XOR A
        OUT (PORT_CTRL),A           ; BG_CPU = 0
        LD  A,CMD_BG_VIEW
        OUT (PORT_CTRL),A
        LD  A,CMD_CHR_CPU
        OUT (PORT_CTRL),A
        LD  A,CMD_CHR_VIEW
        OUT (PORT_CTRL),A
        LD  A,CMD_MODE
        OUT (PORT_CTRL),A           ; text
        LD  A,CMD_XCFG
        OUT (PORT_CTRL),A           ; ATTR, OPAQUE (and MIRROR) off
        XOR A
        LD  (XS_XCFG),A
        XOR A
        OUT (PORT_PAGE),A           ; window 0 = page 0
        LD  A,PAGE_WIN1 | 1
        OUT (PORT_PAGE),A           ; window 1 = page 1
        LD  A,AY_R_ENABLE
        OUT (PORT_AY_REG),A
        LD  A,$FF                   ; ports out, all channels off
        OUT (PORT_AY_VAL),A
        LD  A,AY_R_PORTA
        OUT (PORT_AY_REG),A
        LD  A,$0F                   ; PAPER black, INK white
        OUT (PORT_AY_VAL),A
        LD  A,AY_R_PORTB
        OUT (PORT_AY_REG),A
        XOR A                       ; BORDER black
        OUT (PORT_AY_VAL),A
        LD  HL,(XS_RAMTOP0)
        LD  (SV_RAMTOP),HL
        RET

; ==== TURBO (always the first word: it links straight to the stock chain) ====

; TURBO ( n -- )   n > 0: 1 TURBO, n = 0: 0 TURBO, n = -1: -1 TURBO, n < -1: -2 TURBO.
;    1  all extension words; RAMTOP = $C000, so the stack moves below the
;       paged windows. ERROR 1 if the data stack is within TURBO_ROOM of $C000.
;    0  (power-up) a 51K Ace, like a 48K RAM pack: only TURBO is linked in,
;       stock look (XRESETHW), RAMTOP as found at reset.
;       0 TURBO also links the SD words SDTAPE TAPE EJECT DIR CD DELETE SDERR
;       (XLINKS0), so a 51K Ace can use the card; 1 TURBO restores the full chain.
;   -1  a stock Ace with the card, until reset: as 0, then the FORTH link goes
;       back to $1FFF, $3000-$3AFF mirrors $3C00 (XCFG MIRROR + KEEP: $3B00-$3BFF,
;       the SD code's state, stay) and ROM page 1 (stock + tape hooks) is used,
;       so the tape words keep using the card when SDTAPE is on.
;   -2  (and below) a stock Ace until reset: as -1, but all of $3000-$3BFF
;       mirrors $3C00 and ROM page 0 (byte-identical stock) is used.
; All end like QUIT: the return stack is reset (and the rest of the
; input line is not run); the data stack and the dictionary are kept.
        XCODE "TURBO"
        RST $18                     ; DE = n
        BIT 7,D
        JR  NZ,turbo_stock
        LD  A,D
        OR  E
        JR  Z,turbo_off
        LD  HL,(SV_SPARE)           ; room for the stack below $C000?
        LD  DE,TURBO_ROOM
        ADD HL,DE
        JR  C,turbo_full
        LD  DE,RAMTOP_TURBO
        OR  A
        SBC HL,DE
        JR  NC,turbo_full
        CALL XLINKS1
        LD  HL,XDICT_LAST_NLF
        LD  (SV_FORTH_LINK),HL
        LD  HL,RAMTOP_TURBO
        LD  (SV_RAMTOP),HL
        JP  ACE_QUIT_CODE
turbo_full:
        LD  A,ERR_NO_MEMORY
        JP  XD_ERR
turbo_off:
        CALL XRESETHW
        CALL XLINKS0
        LD  HL,XDICT_LAST_NLF
        LD  (SV_FORTH_LINK),HL
        JP  ACE_QUIT_CODE
turbo_stock:                        ; n < 0: DE = $FFFF is -1 TURBO
        LD  A,D
        AND E
        INC A
        LD  HL,HSTOCK1              ; -1: page 1, mirror with the SD state kept
        JR  Z,turbo_stock_go
        LD  HL,HSTOCK               ; -2 and below: page 0, the whole mirror
turbo_stock_go:
        PUSH HL
        CALL XRESETHW
        LD  HL,SV_FORTH_LINK0
        LD  (SV_FORTH_LINK),HL
        POP HL
        LD  A,CMD_ROMPAGE | ROMPG_BOOT
        JP  XDISPATCH
TURBO_NLF       EQU XLINK

; XLINKS0 / XLINKS1: the dictionary chain for 0 TURBO / 1 TURBO. In 0 TURBO the
; FORTH link ($3C47) still points at SDERR, the last word, but the chain from it is
; SDERR DELETE CD DIR EJECT TAPE SDTAPE TURBO, then the stock words: TAPE to DELETE
; are consecutive already, so only SDTAPE's and SDERR's links change.
XLINKS0:
        LD  HL,TURBO_NLF
        LD  (SDTAPE_NLF - 2),HL
        LD  HL,DELETE_NLF
        LD  (SDERR_NLF - 2),HL
        RET
XLINKS1:
        LD  HL,SDTAPE_PREV
        LD  (SDTAPE_NLF - 2),HL
        LD  HL,SDERR_PREV
        LD  (SDERR_NLF - 2),HL
        RET

; ==== Utility words (colon words: the Jupiter Ace manual's definitions) =======

; COUNT ( addr -- addr+1 c )        : COUNT DUP 1+ SWAP C@ ;
        XCOLON "COUNT"
        DW  ACE_DUP, ACE_1_PLUS, ACE_SWAP, ACE_C_FETCH, ACE_ENDDEF

; +! ( n addr -- )                  : +! SWAP OVER @ + SWAP ! ;
        XCOLON "+!"
        DW  ACE_SWAP, ACE_OVER, ACE_FETCH, ACE_PLUS, ACE_SWAP, ACE_STORE
        DW  ACE_ENDDEF

; ? ( addr -- )                     : ? @ . ;
        XCOLON "?"
        DW  ACE_FETCH, ACE_DOT, ACE_ENDDEF

; DEPTH ( -- n )                    : DEPTH 15419 @ HERE 12 + - 2 / ;
        XCOLON "DEPTH"
        DW  ACE_LIT_WORD, SV_SPARE, ACE_FETCH, ACE_HERE
        DW  ACE_LIT_WORD, 12, ACE_PLUS, ACE_MINUS
        DW  ACE_LIT_WORD, 2, ACE_SLASH, ACE_ENDDEF

; HEX ( -- )                        : HEX 16 BASE C! ;
        XCOLON "HEX"
        DW  ACE_LIT_BYTE
        DB  16
        DW  ACE_BASE, ACE_C_STORE, ACE_ENDDEF

; CMOVE ( addr1 addr2 n -- )  move n bytes, overlap-safe
        XCODE "CMOVE"
        CALL ACE_POPBC              ; BC = n
        RST $18                     ; DE = addr2
        PUSH DE
        RST $18                     ; DE = addr1
        EX  DE,HL                   ; HL = source
        POP DE                      ; DE = destination
        LD  A,B
        OR  C
        JR  Z,cmove_done
        PUSH HL                     ; source
        PUSH DE                     ; destination
        EX  DE,HL                   ; HL = dest, DE = source
        AND A
        SBC HL,DE                   ; dest - source (unsigned)
        AND A
        SBC HL,BC                   ; C: dest inside (source, source+n)
        POP DE                      ; DE = destination
        POP HL                      ; HL = source
        JR  NC,cmove_up
        ADD HL,BC                   ; overlap with dest above source:
        DEC HL                      ; copy from the top down
        EX  DE,HL
        ADD HL,BC
        DEC HL
        EX  DE,HL
        LDDR
        JP  (IY)
cmove_up:
        LDIR
cmove_done:
        JP  (IY)

; FILL ( addr n byte -- )  memory fill (the graphics fill is PAINT)
        XCODE "FILL"
        RST $18                     ; E = byte
        LD  A,E
        CALL ACE_POPBC              ; BC = n
        RST $18                     ; DE = addr
        EX  DE,HL
        LD  E,A
fill_loop:
        LD  A,B
        OR  C
        JR  Z,fill_done
        LD  (HL),E
        INC HL
        DEC BC
        JR  fill_loop
fill_done:
        JP  (IY)

; ==== Programming words =======================================================

; 2* ( n -- 2n )
        XCODE "2*"
        RST $18
        EX  DE,HL
        ADD HL,HL
        EX  DE,HL
        RST $10
        JP  (IY)

; 2/ ( n -- n/2 )   arithmetic shift: rounds towards minus infinity (-3 2/ = -2)
        XCODE "2/"
        RST $18
        SRA D
        RR  E
        RST $10
        JP  (IY)

; 0<> ( n -- f )   1 if n is not zero
        XCODE "0<>"
        RST $18
        LD  A,D
        OR  E
        LD  DE,0
        JR  Z,ne0_push
        INC E
ne0_push:
        RST $10
        JP  (IY)

; ' ( -- pfa )   ' name: the parameter field of the next word (for a VARIABLE,
;                its address); ERROR 13 if there is no such word
        XCOLON "'"
        DW  ACE_FIND, xtick, ACE_ENDDEF
xtick:  DW  $ + 2
        RST $18
        LD  A,D
        OR  E
        JR  Z,xtick_err
        INC DE
        INC DE
        RST $10
        JP  (IY)
xtick_err:
        RST $20
        DB  ERR_NOT_FOUND

; .S ( -- )   print the stack, bottom first, without changing it.
;   : .S 15419 @ HERE 12 + OVER OVER - IF DO I @ . 2 +LOOP ELSE DROP DROP THEN ;
;   (the cells the ROM compiles for that source)
        XCOLON ".S"
        DW  ACE_LIT_WORD, SV_SPARE, ACE_FETCH, ACE_HERE
        DW  ACE_LIT_WORD, 12, ACE_PLUS, ACE_OVER, ACE_OVER, ACE_MINUS
        DW  ACE_RT_IF
        DW  dots_empty - $ - 1          ; offset: target - field - 1 ($ = this DW)
        DW  ACE_RT_DO
dots_loop:
        DW  ACE_I, ACE_FETCH, ACE_DOT, ACE_LIT_WORD, 2
        DW  ACE_RT_PLUSLOOP
        DW  dots_loop - $ - 1
        DW  ACE_RT_ELSE
        DW  dots_end - $ - 1
dots_empty:
        DW  ACE_DROP, ACE_DROP, ACE_RT_THEN
dots_end:
        DW  ACE_ENDDEF

; Random numbers. RND ( n -- r ): 0 <= r < n (n unsigned; 0 RND gives 0).
; The seed steps as seed' = ((seed + 1) * 75 mod 65537) - 1, which visits all
; 65536 values; r = seed' * n / 65536. RAND ( n -- ): seed = n, or with 0 a
; seed from FRAMES (different each run).
        XSTUB "RND", ROMPG_EXT4, PRND    ; src/mathpage.asm

        XCODE "RAND"
        RST $18
        LD  A,D
        OR  E
        JR  NZ,rand_set
        LD  DE,(SV_FRAMES)
rand_set:
        LD  (XS_SEED),DE
        JP  (IY)

; Double-cell (and floating-point) stack words: a double or a floating-point
; number is two cells.
; 2DUP ( d -- d d )   2OVER ( d1 d2 -- d1 d2 d1 )
        XCODE "2DUP"
FW_2DUP_PF:
        LD  BC,-4
        JR  x2copy
        XCODE "2OVER"
FW_2OVER_PF:
        LD  BC,-8
x2copy: LD  HL,(SV_SPARE)
        ADD HL,BC
        LD  DE,(SV_SPARE)
        LD  BC,4
        LDIR
        LD  (SV_SPARE),DE
        JP  (IY)

; 2DROP ( d -- )
        XCODE "2DROP"
FW_2DROP_PF:
        LD  HL,(SV_SPARE)
        LD  BC,-4
        ADD HL,BC
        LD  (SV_SPARE),HL
        JP  (IY)

; 2SWAP ( d1 d2 -- d2 d1 )
        XCODE "2SWAP"
FW_2SWAP_PF:
        LD  HL,(SV_SPARE)
        LD  BC,-8
        ADD HL,BC                   ; HL -> d1
        LD  D,H
        LD  E,L
        INC DE
        INC DE
        INC DE
        INC DE                      ; DE -> d2
        LD  B,4
swap2_l:
        LD  A,(DE)
        LD  C,(HL)
        LD  (HL),A
        LD  A,C
        LD  (DE),A
        INC HL
        INC DE
        DJNZ swap2_l
        JP  (IY)

; 2ROT ( d1 d2 d3 -- d2 d3 d1 )
        XCODE "2ROT"
FW_2ROT_PF:
        LD  HL,(SV_SPARE)
        LD  BC,-12
        ADD HL,BC                   ; HL -> d1
        LD  DE,(SV_SPARE)
        PUSH HL
        LD  BC,4
        LDIR                        ; d1 copied above the top
        POP DE                      ; DE -> where d1 was
        LD  H,D
        LD  L,E
        LD  BC,4
        ADD HL,BC                   ; HL -> d2
        LD  BC,12
        LDIR                        ; d2 d3 d1 moved down one place
        JP  (IY)

; Double numbers (the ROM has D+ DNEGATE D< U* U/MOD; the high cell is on top).
; D- ( d1 d2 -- d1-d2 )             : D- DNEGATE D+ ;
        XCOLON "D-"
DMINUS_PF:
        DW  ACE_DNEGATE, ACE_D_PLUS, ACE_ENDDEF

; D= ( d1 d2 -- f )                 : D= D- OR 0= ;
        XCOLON "D="
        DW  DMINUS_PF - 2, ACE_OR, ACE_0_EQ, ACE_ENDDEF

; D0= ( d -- f )                    : D0= OR 0= ;
        XCOLON "D0="
        DW  ACE_OR, ACE_0_EQ, ACE_ENDDEF

; DABS ( d -- |d| )
        XCODE "DABS"
DABS_PF:
        LD  HL,(SV_SPARE)
        DEC HL
        BIT 7,(HL)
        JR  Z,dabs_done
        DEC HL
        DEC HL
        DEC HL                      ; the low byte of the low cell
        LD  B,4
        AND A
dabs_l: LD  A,0
        SBC A,(HL)
        LD  (HL),A
        INC HL
        DJNZ dabs_l
dabs_done:
        JP  (IY)

; S->D ( n -- d )   sign-extend
        XCODE "S->D"
        LD  HL,(SV_SPARE)
        DEC HL
        LD  A,(HL)
        RLA
        SBC A,A
        LD  D,A
        LD  E,A
        RST $10
        JP  (IY)

; D. ( d -- )   print a signed double and a space, like .
;   : D. DUP >R DABS <# #S R> SIGN #> TYPE SPACE ;
        XCOLON "D."
        DW  ACE_DUP, ACE_GT_R, DABS_PF - 2, ACE_LT_SHARP, ACE_SHARP_S
        DW  ACE_R_GT, ACE_SIGN, ACE_SHARP_GT, ACE_TYPE, ACE_SPACE, ACE_ENDDEF

; D.R ( d n -- )   print a signed double right-aligned in n characters
;   : D.R >R DUP >R DABS <# #S R> SIGN #> R> OVER - 0 MAX SPACES TYPE ;
        XCOLON "D.R"
        DW  ACE_GT_R, ACE_DUP, ACE_GT_R, DABS_PF - 2, ACE_LT_SHARP, ACE_SHARP_S
        DW  ACE_R_GT, ACE_SIGN, ACE_SHARP_GT, ACE_R_GT, ACE_OVER, ACE_MINUS
        DW  ACE_LIT_BYTE
        DB  0
        DW  ACE_MAX, ACE_SPACES, ACE_TYPE, ACE_ENDDEF

; ==== Floating point =========================================================
; An Ace floating-point number is two cells: on top [sign + exponent (excess $40)]
; [digits 1-2], under it [digits 3-6] (BCD): 0.d1d2d3d4d5d6 x 10^(exponent - $40).
; 1.5 is $4115 $0000, -1.5 is $C115 $0000, zero is $0000 $0000. The ROM has F+ F-
; F* F/ FNEGATE F. INT UFLOAT.

; F0< ( f -- flag )   1 if f is negative
        XCODE "F0<"
FW_F0LT_PF:
        RST $18
        PUSH DE                     ; top cell: D = sign and exponent
        RST $18
        POP AF                      ; A = D
        RLCA
        AND 1
        LD  E,A
        JP  XPUSHBYTE

; F0= ( f -- flag )   1 if f is zero
        XCODE "F0="
FW_F0EQ_PF:
        RST $18
        LD  A,E                     ; digits 1-2 (0 only for zero)
        PUSH AF
        RST $18
        POP AF
        OR  D
        OR  E
        LD  E,0
        JR  NZ,f0eq_push
        INC E
f0eq_push:
        JP  XPUSHBYTE

; FABS ( f -- |f| )
        XCODE "FABS"
FW_FABS_PF:
        LD  HL,(SV_SPARE)
        DEC HL
        RES 7,(HL)
        JP  (IY)

; XGUESS ( f -- f g )   FSQRT's first guess (headerless; ERROR 8 if f < 0)
FW_XGUESS_PF EQU $ + 2
        DW  $ + 2
        LD  A,CMD_ROMPAGE | ROMPG_EXT4
        LD  HL,PSQRTG
        JP  XDISPATCH

; The rest are the cells the ROM compiles for this source (tools/misc/acecomp.py turns
; a harness session into these lines):
;   : PI 3.14159 ;
;   : F< F- F0< ;                   ( f1 f2 -- flag )  1 if f1 < f2
;   : F> 2SWAP F< ;                 ( f1 f2 -- flag )  1 if f1 > f2
;   : FSQRT 2DUP F0= IF EXIT THEN 2DUP XGUESS
;     5 0 DO 2OVER 2OVER F/ F+ .5 F* LOOP 2SWAP 2DROP ;
;   : XSINR ( r -- sin r, |r| <= pi/2: Taylor series to r^13; headerless )
;     2DUP 2DUP F* FNEGATE 2SWAP 2DUP
;     13 2 DO 2ROT 2DUP 2ROT F* I I 1+ * UFLOAT F/ 2ROT 2OVER F+ 2SWAP 2 +LOOP
;     2DROP 2SWAP 2DROP ;
;   : FSIN 2DUP F0< >R FABS 2DUP 6.28319 F/ INT UFLOAT 6.28319 F* F-
;     2DUP 3.14159 F> IF 3.14159 F- R> 0= >R THEN
;     2DUP 1.5708 F> IF 3.14159 2SWAP F- THEN XSINR R> IF FNEGATE THEN ;
;   : FCOS 1.5708 F+ FSIN ;
;   : FTAN 2DUP FSIN 2SWAP FCOS F/ ;
; FSIN reduces x to 0..2pi with INT, so |x| up to about 200000 (INT's range).

; PI
        XCOLON "PI"
FW_PI_PF:
        DW  ACE_LIT_FLOAT
        DB  $59, $41, $31, $41
        DW  ACE_ENDDEF

; F<
        XCOLON "F<"
FW_FLT_PF:
        DW  ACE_F_MINUS
        DW  FW_F0LT_PF - 2
        DW  ACE_ENDDEF

; F>
        XCOLON "F>"
FW_FGT_PF:
        DW  FW_2SWAP_PF - 2
        DW  FW_FLT_PF - 2
        DW  ACE_ENDDEF

; FSQRT
        XCOLON "FSQRT"
FW_FSQRT_PF:
        DW  FW_2DUP_PF - 2
        DW  FW_F0EQ_PF - 2
        DW  ACE_RT_IF
        DW  5
        DW  ACE_EXIT
        DW  ACE_RT_THEN
        DW  FW_2DUP_PF - 2
        DW  FW_XGUESS_PF - 2
        DW  ACE_LIT_WORD, $0005
        DW  ACE_LIT_WORD, $0000
        DW  ACE_RT_DO
        DW  FW_2OVER_PF - 2
        DW  FW_2OVER_PF - 2
        DW  ACE_F_SLASH
        DW  ACE_F_PLUS
        DW  ACE_LIT_FLOAT
        DB  $00, $00, $50, $40
        DW  ACE_F_STAR
        DW  ACE_RT_LOOP
        DW  -19
        DW  FW_2SWAP_PF - 2
        DW  FW_2DROP_PF - 2
        DW  ACE_ENDDEF

; XSINR
FW_XSINR_PF EQU $ + 2
        DW  ACE_DOCOLON
        DW  FW_2DUP_PF - 2
        DW  FW_2DUP_PF - 2
        DW  ACE_F_STAR
        DW  ACE_FNEGATE
        DW  FW_2SWAP_PF - 2
        DW  FW_2DUP_PF - 2
        DW  ACE_LIT_WORD, $000D
        DW  ACE_LIT_WORD, $0002
        DW  ACE_RT_DO
        DW  FW_2ROT_PF - 2
        DW  FW_2DUP_PF - 2
        DW  FW_2ROT_PF - 2
        DW  ACE_F_STAR
        DW  ACE_I
        DW  ACE_I
        DW  ACE_1_PLUS
        DW  ACE_STAR
        DW  ACE_UFLOAT
        DW  ACE_F_SLASH
        DW  FW_2ROT_PF - 2
        DW  FW_2OVER_PF - 2
        DW  ACE_F_PLUS
        DW  FW_2SWAP_PF - 2
        DW  ACE_LIT_WORD, $0002
        DW  ACE_RT_PLUSLOOP
        DW  -35
        DW  FW_2DROP_PF - 2
        DW  FW_2SWAP_PF - 2
        DW  FW_2DROP_PF - 2
        DW  ACE_ENDDEF

; FSIN
        XCOLON "FSIN"
FW_FSIN_PF:
        DW  FW_2DUP_PF - 2
        DW  FW_F0LT_PF - 2
        DW  ACE_GT_R
        DW  FW_FABS_PF - 2
        DW  FW_2DUP_PF - 2
        DW  ACE_LIT_FLOAT
        DB  $19, $83, $62, $41
        DW  ACE_F_SLASH
        DW  ACE_INT
        DW  ACE_UFLOAT
        DW  ACE_LIT_FLOAT
        DB  $19, $83, $62, $41
        DW  ACE_F_STAR
        DW  ACE_F_MINUS
        DW  FW_2DUP_PF - 2
        DW  ACE_LIT_FLOAT
        DB  $59, $41, $31, $41
        DW  FW_FGT_PF - 2
        DW  ACE_RT_IF
        DW  17
        DW  ACE_LIT_FLOAT
        DB  $59, $41, $31, $41
        DW  ACE_F_MINUS
        DW  ACE_R_GT
        DW  ACE_0_EQ
        DW  ACE_GT_R
        DW  ACE_RT_THEN
        DW  FW_2DUP_PF - 2
        DW  ACE_LIT_FLOAT
        DB  $80, $70, $15, $41
        DW  FW_FGT_PF - 2
        DW  ACE_RT_IF
        DW  13
        DW  ACE_LIT_FLOAT
        DB  $59, $41, $31, $41
        DW  FW_2SWAP_PF - 2
        DW  ACE_F_MINUS
        DW  ACE_RT_THEN
        DW  FW_XSINR_PF - 2
        DW  ACE_R_GT
        DW  ACE_RT_IF
        DW  5
        DW  ACE_FNEGATE
        DW  ACE_RT_THEN
        DW  ACE_ENDDEF

; FCOS
        XCOLON "FCOS"
FW_FCOS_PF:
        DW  ACE_LIT_FLOAT
        DB  $80, $70, $15, $41
        DW  ACE_F_PLUS
        DW  FW_FSIN_PF - 2
        DW  ACE_ENDDEF

; FTAN
        XCOLON "FTAN"
FW_FTAN_PF:
        DW  FW_2DUP_PF - 2
        DW  FW_FSIN_PF - 2
        DW  FW_2SWAP_PF - 2
        DW  FW_FCOS_PF - 2
        DW  ACE_F_SLASH
        DW  ACE_ENDDEF

; GR ( b1 b2 b3 b4 b5 b6 b7 b8 c -- )   define character c (0-127) from eight
;   row bytes, b1 the top row, in the character set being written (FONT)
        XCODE "GR"
        RST $18
        LD  A,E
        AND $7F
        LD  L,A
        LD  H,0
        ADD HL,HL
        ADD HL,HL
        ADD HL,HL
        LD  DE,ACE_CHARSET + 7
        ADD HL,DE                   ; HL -> the bottom row
        LD  B,8
gr_l:   PUSH HL
        RST $18
        POP HL
        LD  (HL),E
        DEC HL
        DJNZ gr_l
        JP  (IY)

; CASE ... OF ... ENDOF ... ENDCASE, compiler words built like the ROM's IF:
;   x CASE  a OF ... ENDOF  b OF ... ENDOF  ( default, x still there ) ENDCASE
; OF compares x with the value on top: equal, both are dropped and the words up
; to ENDOF run, then execution continues after ENDCASE; different, only the
; value is dropped and the next OF is tried. ENDCASE drops x. Wrong nesting gives
; ERROR 5. LIST and EDIT show them like any other word.
CASE_TAG        EQU $CA5E           ; on the stack while compiling
OF_TAG          EQU $0F0F

        XCOMPILER "CASE", case_rt
CASE_NAME       EQU XNAME
        DW  ACE_LIT_BYTE            ; ( -- 0 CASE_TAG ): 0 ends the ENDOF chain
        DB  0
        DW  ACE_LIT_WORD, CASE_TAG, ACE_ENDDEF
        XRUNTIME 0, CASE_NAME
case_rt:
        DW  case_code
case_code:
        JP  (IY)

        XCOMPILER "OF", of_rt
OF_NAME         EQU XNAME
        DW  ACE_LIT_WORD, CASE_TAG, xpairs
        DW  ACE_HERE, ACE_LIT_BYTE  ; ( -- F OF_TAG ): F, the offset to fill in
        DB  0
        DW  ACE_COMMA, ACE_LIT_WORD, OF_TAG, ACE_ENDDEF
        XRUNTIME 2, OF_NAME
of_rt:  DW  $ + 2
        RST $18                     ; DE = the value
        LD  HL,(SV_SPARE)
        DEC HL
        LD  A,(HL)
        DEC HL
        CP  D
        JR  NZ,of_no
        LD  A,(HL)
        CP  E
        JR  NZ,of_no
        LD  (SV_SPARE),HL           ; equal: drop x too
        POP HL
        INC HL
        INC HL                      ; and skip the offset
        JP  ACE_NEXT_HL
of_no:  JP  ACE_BRANCH_CODE         ; different: on to after ENDOF

        XCOMPILER "ENDOF", endof_rt
ENDOF_NAME      EQU XNAME
        DW  ACE_LIT_WORD, OF_TAG, xpairs
        DW  ACE_HERE, ACE_LIT_BYTE  ; ( Fof -- Fof Fe )
        DB  0
        DW  ACE_COMMA
        DW  ACE_SWAP, ACE_HERE, ACE_OVER, ACE_MINUS, ACE_1_MINUS, ACE_SWAP, ACE_STORE
        DW  ACE_LIT_WORD, CASE_TAG, ACE_ENDDEF  ; ( -- Fe CASE_TAG ): OF branches here
        XRUNTIME 2, ENDOF_NAME
endof_rt:
        DW  ACE_BRANCH_CODE         ; on to after ENDCASE

        XCOMPILER "ENDCASE", endcase_rt
ENDCASE_NAME    EQU XNAME
        DW  ACE_LIT_WORD, CASE_TAG, xpairs, xresolve, ACE_ENDDEF
        XRUNTIME 0, ENDCASE_NAME
endcase_rt:
        DW  $ + 2
        RST $18                     ; drop x
        JP  (IY)

; xpairs ( found expected -- ): ERROR 5 if they differ
xpairs: DW  $ + 2
        RST $18
        PUSH DE
        RST $18
        POP HL
        AND A
        SBC HL,DE
        JR  NZ,xpairs_err
        JP  (IY)
xpairs_err:
        RST $20
        DB  ERR_STRUCTURE

; xresolve ( 0 F1 .. Fk -- ): every ENDOF branches to HERE (after ENDCASE's drop)
xresolve:
        DW  $ + 2
xres_l: RST $18
        LD  A,D
        OR  E
        JR  Z,xres_done
        LD  HL,(SV_STKBOT)
        SCF
        SBC HL,DE                   ; offset = HERE - F - 1
        EX  DE,HL
        LD  (HL),E
        INC HL
        LD  (HL),D
        JR  xres_l
xres_done:
        JP  (IY)

; ==== Sound ===================================================================

; PLAY! ( value reg -- )
        XCODE "PLAY!"
        RST $18
        LD  A,E
        OUT (PORT_AY_REG),A
        RST $18
        LD  A,E
        OUT (PORT_AY_VAL),A
        JP  (IY)

; PLAY@ ( reg -- value )
        XCODE "PLAY@"
        RST $18
        LD  A,E
        OUT (PORT_AY_REG),A
        IN  A,(PORT_AY_VAL)
        LD  E,A
        JP  XPUSHBYTE

; ==== Colour (AY R14/R15) ======================================================

; INK ( c -- )   R14 bits 3-0
        XCODE "INK"
        RST $18
        LD  A,E
        AND $0F
        LD  E,A
        LD  C,$F0
        LD  A,AY_R_PORTA
        JP  XAYMERGE

; PAPER ( c -- )   R14 bits 7-4
        XCODE "PAPER"
        RST $18
        LD  A,E
        ADD A,A
        ADD A,A
        ADD A,A
        ADD A,A
        LD  E,A
        LD  C,$0F
        LD  A,AY_R_PORTA
        JP  XAYMERGE

; BORDER ( c -- )   R15 bits 7-4
        XCODE "BORDER"
        RST $18
        LD  A,E
        ADD A,A
        ADD A,A
        ADD A,A
        ADD A,A
        LD  E,A
        LD  C,$0F
        LD  A,AY_R_PORTB
        JP  XAYMERGE

; DARK ( c -- c' )   clear the intensity bit
        XCODE "DARK"
        RST $18
        LD  A,E
        AND $07
        LD  E,A
        JP  XPUSHBYTE

        XCONST "BLACK", 0
        XCONST "GREY", 8
        XCONST "BLUE", 9
        XCONST "GREEN", 10
        XCONST "CYAN", 11
        XCONST "RED", 12
        XCONST "PURPLE", 13
        XCONST "YELLOW", 14
        XCONST "WHITE", 15

; ==== Screen and memory ($E3) =================================================

; MODE ( n -- )   0 = text, 1 = hi-res bitmap
        XCODE "MODE"
        RST $18
        LD  A,E
        AND 1
        OR  CMD_MODE
        OUT (PORT_CTRL),A
        JP  (IY)

; PG0 ( p -- )   8K user-RAM page p (0-63) into window 0, $C000-$DFFF
        XCODE "PG0"
        RST $18
        LD  A,E
        AND PAGE_MASK
        OUT (PORT_PAGE),A
        JP  (IY)

; PG1 ( p -- )   8K user-RAM page p (0-63) into window 1, $E000-$FFFF
        XCODE "PG1"
        RST $18
        LD  A,E
        AND PAGE_MASK
        OR  PAGE_WIN1
        OUT (PORT_PAGE),A
        JP  (IY)

; FONT ( n -- )   character set 0-31, for the CPU and the display
        XCODE "FONT"
        RST $18
        LD  A,E
        AND PARAM_MASK
        LD  E,A
        OR  CMD_CHR_CPU
        OUT (PORT_CTRL),A
        LD  A,E
        OR  CMD_CHR_VIEW
        OUT (PORT_CTRL),A
        JP  (IY)

; VIEW ( n -- )   page shown: text page n, and in hi-res screen n (8K pages
;                 2n, 2n+1) with text page n overlaid (BG_VIEW)
        XCODE "VIEW"
        RST $18
        LD  A,E
        AND PARAM_MASK
        OR  CMD_BG_VIEW
        OUT (PORT_CTRL),A
        JP  (IY)

; WORK ( n -- )   page written: text page n for printing (BG_CPU), and hi-res
;                 screen n for the graphics words
        XCODE "WORK"
        RST $18
        LD  A,E
        AND PARAM_MASK
        LD  (XS_WORKPG),A
        OR  CMD_BG_CPU
        OUT (PORT_CTRL),A
        JP  (IY)

; SCREEN ( n -- )   VIEW and WORK together
        XCODE "SCREEN"
        RST $18
        LD  A,E
        AND PARAM_MASK
        LD  (XS_WORKPG),A
        LD  E,A
        OR  CMD_BG_VIEW
        OUT (PORT_CTRL),A
        LD  A,E
        OR  CMD_BG_CPU
        OUT (PORT_CTRL),A
        JP  (IY)

; ==== Graphics ================================================================

; PLOT ( x y n -- )   superset of the stock word.
;   MODE 0: the stock 64x48 block PLOT, unchanged (jumps into its code).
;   MODE 1: hi-res 256x192, origin bottom-left; n: 0 unplot, 1 plot,
;           2 move only, 3 invert. Code in ROM page 2 (HPLOT, gfx.asm).
        XCODE "PLOT"
        CALL XGETMODE
        JP  NC,ACE_PLOT_CODE
        LD  A,CMD_ROMPAGE | ROMPG_BOOT
        LD  HL,HPLOT
        JP  XDISPATCH

; Graphics. DRAW, CIRCLE, POINT and PAINT work in hi-res only; in MODE 0 they
; drop their arguments (POINT returns 0). DRAW, CIRCLE and PAINT use the pixel
; mode set by INVERSE and FLIP:
;   neither = plot, INVERSE = unplot, FLIP = invert, both = move only.

; DRAW ( dx dy a -- )   from the last plotted point to
;   point + (dx, dy), turning through a degrees (0 = straight line)
        XCODE "DRAW"
        CALL XGETMODE
        JP  NC,XDROP3
        LD  A,CMD_ROMPAGE | ROMPG_BOOT
        LD  HL,HDRAW
        JP  XDISPATCH

; CIRCLE ( x y r -- )
        XCODE "CIRCLE"
        CALL XGETMODE
        JP  NC,XDROP3
        LD  A,CMD_ROMPAGE | ROMPG_BOOT
        LD  HL,HCIRCLE
        JP  XDISPATCH

; POINT ( x y -- f )   1 if the hi-res pixel is INK, else 0
        XCODE "POINT"
        CALL XGETMODE
        JP  NC,XPOINT0
        LD  A,CMD_ROMPAGE | ROMPG_BOOT
        LD  HL,HPOINT
        JP  XDISPATCH

; PAINT ( x y -- )   flood fill from (x, y) in hi-res; nothing in MODE 0.
        XCODE "PAINT"
        CALL XGETMODE
        JP  NC,XDROP2
        LD  A,CMD_ROMPAGE | ROMPG_BOOT
        LD  HL,HPAINT
        JP  XDISPATCH

; INVERSE ( f -- )   DRAW, CIRCLE and PAINT erase (unplot) instead of drawing
        XCODE "INVERSE"
        RST $18
        LD  C,1
        JP  XGFLAG

; FLIP ( f -- )   DRAW, CIRCLE and PAINT invert (flip) pixels
        XCODE "FLIP"
        RST $18
        LD  C,2
        JP  XGFLAG

; CLS ( -- )   superset of the stock word.
;   MODE 0: the stock CLS, unchanged (jumps into its code).
;   MODE 1: clears the work screen to the current PAPER:INK, PLOT position
;           0,0, then the text overlay with the stock CLS (spaces are
;           transparent; the print position goes home).
        XCODE "CLS"
        CALL XGETMODE
        JP  NC,ACE_CLS_CODE
        LD  A,CMD_ROMPAGE | ROMPG_BOOT
        LD  HL,HCLS
        CALL XDCALL
        JP  ACE_CLS_CODE

; ATTR ( x y -- c )   the PAPER:INK colour byte (0 if out of range).
;   MODE 1: x 0-255, y 0-191 (origin bottom-left, as POINT): the 8x1 colour
;           byte holding that pixel. Code in ROM page 2 (HATTR, gfx.asm).
;   MODE 0: x = column 0-31, y = line 0-23 from the top: the character cell's
;           colour, read through XCFG.ATTR (colour RAM in the BG window).
        XCODE "ATTR"
        CALL XGETMODE
        JR  C,attr_hires
        RST $18                     ; DE = line
        PUSH DE
        RST $18                     ; DE = column
        POP HL                      ; HL = line
        LD  A,H
        OR  D
        JR  NZ,attr_out
        LD  A,L
        CP  24
        JR  NC,attr_out
        LD  A,E
        CP  32
        JR  NC,attr_out
        ADD HL,HL
        ADD HL,HL
        ADD HL,HL
        ADD HL,HL
        ADD HL,HL                   ; line * 32
        ADD HL,DE                   ; + column (D = 0)
        LD  DE,ACE_SCREEN
        ADD HL,DE
        DI                          ; colour RAM mapped in: keep it short
        LD  A,(XS_XCFG)             ; XCFG as the ROM last wrote it
        LD  C,A
        OR  CMD_XCFG | XCFG_ATTR
        OUT (PORT_CTRL),A
        LD  E,(HL)                  ; colour byte of the cell
        LD  A,C
        OR  CMD_XCFG
        OUT (PORT_CTRL),A
        EI
        JP  XPUSHBYTE
attr_out:
        LD  E,0
        JP  XPUSHBYTE
attr_hires:
        LD  A,CMD_ROMPAGE | ROMPG_BOOT
        LD  HL,HATTR
        JP  XDISPATCH

; OPAQUE ( f -- )   hi-res text overlay: f = 0 transparent (default: only the
;   INK pixels of characters cover the picture), f <> 0 opaque (every non-space
;   character cell covers its 8x8 cell in its text PAPER). XCFG bit 2.
        XCODE "OPAQUE"
        RST $18
        LD  A,D
        OR  E
        LD  A,(XS_XCFG)
        JR  Z,opaque_off
        OR  XCFG_OPAQUE
        JR  opaque_set
opaque_off:
        AND $FF - XCFG_OPAQUE
opaque_set:
        LD  (XS_XCFG),A
        OR  CMD_XCFG
        OUT (PORT_CTRL),A
        JP  (IY)

; ==== SD card ===================================================================

; SDTAPE ( f -- )   the stock tape words use the SD card (f <> 0) or the cassette
SDTAPE_PREV     EQU XLINK           ; the full chain: SDTAPE links to OPAQUE ...
        XCODE "SDTAPE"
SDTAPE_NLF      EQU XLINK
        RST $18
        LD  A,D
        OR  E
        LD  (XS_SDTAPE),A
        JP  (IY)

; TAPE ( -- )   TAPE name: put a tape file in the virtual player, turn SDTAPE on.
;   : TAPE 32 WORD (TAPE) ;   WORD leaves the name as a counted string at $2701.
        XCOLON "TAPE"
        DW  ACE_LIT_BYTE
        DB  32
        DW  ACE_WORD, XTAPE_CF, ACE_ENDDEF

; (TAPE) ( addr -- )   headerless: the counted name to the SD page
XTAPE_CF:
        DW  $ + 2
        RST $18                     ; DE = counted name
        LD  A,CMD_ROMPAGE | ROMPG_EXT3
        LD  HL,SD_TAPE_INSERT
        JP  XDISPATCH

; EJECT ( -- )   empty the virtual tape player
        XCODE "EJECT"
        LD  A,CMD_ROMPAGE | ROMPG_EXT3
        LD  HL,SD_TAPE_EJECT
        JP  XDISPATCH

; (name) words: headerless code words that take a counted name ( addr -- )
; from WORD and hand it to a page-3 routine in DE.
    MACRO XNAMECODE _routine
        DW  $ + 2
        RST $18                     ; DE = counted name
        LD  A,CMD_ROMPAGE | ROMPG_EXT3
        LD  HL,_routine
        JP  XDISPATCH
    ENDM

; DIR ( -- )   list the current folder: name, then "/" for a folder or the size
;   (bytes, or nnnK from 64K up; 65535K+ from 64M up); one entry per line.
;   SPACE stops the listing.
        XCODE "DIR"
        LD  E,0                     ; 0 = first entry
dir_loop:
        LD  A,CMD_ROMPAGE | ROMPG_EXT3
        LD  HL,SD_DIR_ENTRY
        CALL XDCALL                 ; the entry into XS_DIRBUF (error: ERROR 10)
        LD  A,(XS_DIRBUF)
        CP  $FF
        JR  Z,dir_end               ; no more entries
        LD  HL,XS_DIRBUF + 5
        LD  B,(HL)                  ; name length
        INC HL
        INC B
        JR  dir_name_next
dir_name:
        LD  A,(HL)
        CALL XEMIT
        INC HL
dir_name_next:
        DJNZ dir_name
        LD  A,(XS_DIRBUF)
        RRA
        JR  NC,dir_file
        LD  A,'/'                   ; a folder
        CALL XEMIT
        JR  dir_cr
dir_file:
        LD  A,' '
        CALL XEMIT
        LD  HL,(XS_DIRBUF + 3)      ; size bits 31-16
        LD  A,H
        OR  L
        JR  NZ,dir_kilo
        LD  HL,(XS_DIRBUF + 1)      ; under 64K: in bytes
        CALL XPRDEC
        JR  dir_cr
dir_kilo:
        LD  HL,(XS_DIRBUF + 2)      ; size bits 23-8
        LD  A,(XS_DIRBUF + 4)       ; bits 31-24
        SRL A                       ; size >> 10 = bits 25-10
        RR  H
        RR  L
        SRL A
        RR  H
        RR  L
        PUSH AF                     ; A <> 0: 64M or more
        OR  A
        JR  Z,dir_kprint
        LD  HL,65535
dir_kprint:
        CALL XPRDEC
        LD  A,'K'
        CALL XEMIT
        POP AF
        OR  A
        JR  Z,dir_cr
        LD  A,'+'
        CALL XEMIT
dir_cr:
        LD  A,13
        CALL XEMIT
        LD  A,$7F                   ; SPACE stops the listing
        IN  A,($FE)
        RRA
        JR  NC,dir_end
        LD  E,1                     ; 1 = next entry
        JR  dir_loop
dir_end:
        JP  (IY)

; XEMIT: print the character in A (stock RST $08; page 1 is mapped here).
; Preserves BC, DE, HL.
XEMIT:
        PUSH HL
        PUSH DE
        PUSH BC
        RST $08
        POP BC
        POP DE
        POP HL
        RET

; XPRDEC: print HL as an unsigned decimal number, without leading zeros.
XPRDEC:
        LD  C,0                     ; 1 once a digit has been printed
        LD  DE,-10000
        CALL prdec_digit
        LD  DE,-1000
        CALL prdec_digit
        LD  DE,-100
        CALL prdec_digit
        LD  DE,-10
        CALL prdec_digit
        LD  A,L
        ADD A,'0'
        JR  XEMIT
prdec_digit:
        LD  A,'0' - 1
prdec_sub:
        INC A
        ADD HL,DE                   ; carry while HL was >= the power of ten
        JR  C,prdec_sub
        SBC HL,DE                   ; one subtraction too many (carry is clear)
        CP  '0'
        JR  NZ,prdec_print
        BIT 0,C
        RET Z                       ; a leading zero
prdec_print:
        LD  C,1
        JR  XEMIT

; CD ( -- )   CD name: change the current folder ("..": up, "/": the top)
;   : CD 32 WORD (CD) ;
        XCOLON "CD"
        DW  ACE_LIT_BYTE
        DB  32
        DW  ACE_WORD, XCD_CF, ACE_ENDDEF
XCD_CF:
        XNAMECODE SD_CD

; DELETE ( -- )   DELETE name: delete a file
;   : DELETE 32 WORD (DELETE) ;
        XCOLON "DELETE"
DELETE_NLF      EQU XLINK
        DW  ACE_LIT_BYTE
        DB  32
        DW  ACE_WORD, XDELETE_CF, ACE_ENDDEF
XDELETE_CF:
        XNAMECODE SD_DELETE

; (number name) words: headerless code words taking ( n addr -- ): the
; number in B and the counted name in DE, to a page-3 routine.
    MACRO XNUMNAMECODE _routine
        DW  $ + 2
        RST $18                     ; DE = counted name
        PUSH DE
        RST $18                     ; DE = number
        LD  B,E
        POP DE
        LD  A,CMD_ROMPAGE | ROMPG_EXT3
        LD  HL,_routine
        JP  XDISPATCH
    ENDM

; PGSAVE ( p -- )   p PGSAVE name: save 8K RAM page p (0-63) as name.PG
        XCOLON "PGSAVE"
        DW  ACE_LIT_BYTE
        DB  32
        DW  ACE_WORD, XPGSAVE_CF, ACE_ENDDEF
XPGSAVE_CF:
        XNUMNAMECODE SD_PG_SAVE

; PGLOAD ( p -- )   p PGLOAD name: load name.PG into RAM page p
        XCOLON "PGLOAD"
        DW  ACE_LIT_BYTE
        DB  32
        DW  ACE_WORD, XPGLOAD_CF, ACE_ENDDEF
XPGLOAD_CF:
        XNUMNAMECODE SD_PG_LOAD

; SCRSAVE ( n -- )   n SCRSAVE name: save hi-res screen n (0-31), picture and
;   colours (12K), as name.SCR
        XCOLON "SCRSAVE"
        DW  ACE_LIT_BYTE
        DB  32
        DW  ACE_WORD, XSCRSAVE_CF, ACE_ENDDEF
XSCRSAVE_CF:
        XNUMNAMECODE SD_SCR_SAVE

; SCRLOAD ( n -- )   n SCRLOAD name: load name.SCR into hi-res screen n
        XCOLON "SCRLOAD"
        DW  ACE_LIT_BYTE
        DB  32
        DW  ACE_WORD, XSCRLOAD_CF, ACE_ENDDEF
XSCRLOAD_CF:
        XNUMNAMECODE SD_SCR_LOAD

; FONTLOAD ( n -- )   n FONTLOAD name: load name.FNT (128 characters x 8 bytes,
;   top row first) into font n (0-31). The font shown does not change.
        XCOLON "FONTLOAD"
        DW  ACE_LIT_BYTE
        DB  32
        DW  ACE_WORD, XFONTLOAD_CF, ACE_ENDDEF
XFONTLOAD_CF:
        XNUMNAMECODE SD_FONT_LOAD

; SDERR ( -- n )   the code of the last SD card failure (0: none since reset)
SDERR_PREV      EQU XLINK           ; ... and SDERR to FONTLOAD (XLINKS1)
        XCODE "SDERR"
SDERR_NLF       EQU XLINK
        LD  A,(XS_SDERR)
        LD  E,A
        JP  XPUSHBYTE

XDICT_LAST_NLF  EQU XLINK           ; goes into $3C47 at boot and by 0 and 1 TURBO
        ASSERT XDICT_LAST_NLF == SDERR_NLF  ; XLINKS0 relies on SDERR being last
