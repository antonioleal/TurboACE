; =============================================================================
; Graphics routines (ROM page 2). Reached through XDISPATCH.
; Rules for extension code (register-map.md section 5): preserve IX and IY;
; only RST $10/$18 and the copied interrupt path of the stock ROM exist here;
; return with carry clear, or carry set and A = error code.
;
; Hi-res: 256 x 192, origin bottom-left. Coordinates
; inside the routines are signed 16-bit: x in BC, y in DE. Pixels off the
; screen are skipped (clipped), never wrapped.
; Pixel modes (as the stock PLOT's n): 0 unplot, 1 plot, 2 move only, 3 invert.
; Range: the 16-bit arithmetic is exact for |dx|, |dy| and r up to about 16000;
; beyond that (and dx or dy = -32768) results wrap. Off-screen pixels are
; clipped (skipped), not an error.
; =============================================================================

; ---- Common ------------------------------------------------------------------

; GFX_BEGIN: map work screen n (8K pages 2n and 2n+1) at $C000-$FFFF,
; remembering the user's two pages, and latch PAPER:INK from AY R14.
; Preserves BC, DE, HL.
GFX_BEGIN:
        XOR A                       ; A15 = 0: window 0
        IN  A,(PORT_PAGE)
        AND PAGE_MASK
        LD  (XS_SAVEPG),A
        LD  A,PAGE_WIN1             ; A15 = 1: window 1
        IN  A,(PORT_PAGE)
        AND PAGE_MASK
        LD  (XS_SAVEPG1),A
        LD  A,(XS_WORKPG)
        AND PARAM_MASK
        ADD A,A                     ; page 2n -> $C000
        OUT (PORT_PAGE),A
        INC A                       ; page 2n+1 -> $E000
        OR  PAGE_WIN1
        OUT (PORT_PAGE),A
        LD  A,AY_R_PORTA
        OUT (PORT_AY_REG),A
        IN  A,(PORT_AY_VAL)
        LD  (XS_COLOUR),A
        RET

; GFX_END: restore the user's pages and return to XDISPATCH, no error.
GFX_END:
        CALL GFX_RESTORE
        AND A                       ; carry clear
        RET

; GFX_RESTORE: put the user's pages back in both windows. Affects A.
GFX_RESTORE:
        LD  A,(XS_SAVEPG)
        OUT (PORT_PAGE),A
        LD  A,(XS_SAVEPG1)
        OR  PAGE_WIN1
        OUT (PORT_PAGE),A
        RET

; GFX_DRAWMODE: XS_PMODE = mode from INVERSE (b0) and FLIP (b1):
;   00 -> 1 plot, 01 -> 0 unplot, 10 -> 3 invert, 11 -> 2 move. Affects A.
GFX_DRAWMODE:
        LD  A,(XS_GFLAGS)
        AND 3
        XOR 1
        LD  (XS_PMODE),A
        RET

; PIXADDR: BC = x, DE = y. Carry set if off screen; otherwise carry clear,
; HL = bitmap byte, A = bit mask. Preserves BC, DE.
PIXADDR:
        LD  A,B
        OR  D
        JR  NZ,pixaddr_off
        LD  A,E
        CP  192
        JR  NC,pixaddr_off
        PUSH BC
        LD  A,191                   ; row = 191 - y (row 0 = top)
        SUB E
        LD  L,A
        LD  H,0
        ADD HL,HL
        ADD HL,HL
        ADD HL,HL
        ADD HL,HL
        ADD HL,HL                   ; row * 32
        LD  A,C
        RRCA
        RRCA
        RRCA
        AND $1F
        OR  L
        LD  L,A
        LD  A,H
        OR  HIGH HIRES_WINDOW
        LD  H,A
        LD  A,C                     ; mask = $80 >> (x & 7)
        AND 7
        LD  B,A
        LD  A,$80
        JR  Z,pixaddr_mask
pixaddr_shift:
        RRCA
        DJNZ pixaddr_shift
pixaddr_mask:
        POP BC
        OR  A                       ; carry clear (A is never 0)
        RET
pixaddr_off:
        SCF
        RET

; PIXEL: BC = x, DE = y, mode XS_PMODE; writes XS_COLOUR to the pixel's
; colour byte. Off-screen pixels and mode 2 do nothing. Preserves BC, DE.
PIXEL:
        LD  A,(XS_PMODE)
        CP  2
        RET Z
        CALL PIXADDR
        RET C
        PUSH BC
        LD  C,A                     ; C = mask
        LD  A,(XS_PMODE)
        OR  A
        JR  NZ,pixel_1
        LD  A,C                     ; 0: unplot
        CPL
        AND (HL)
        JR  pixel_store
pixel_1:
        DEC A                       ; Z if mode 1
        LD  A,C
        JR  NZ,pixel_3
        OR  (HL)                    ; 1: plot
        JR  pixel_store
pixel_3:
        XOR (HL)                    ; 3: invert
pixel_store:
        LD  (HL),A
        LD  A,H
        ADD A,HIGH HIRES_ATTR_OFS
        LD  H,A
        LD  A,(XS_COLOUR)
        LD  (HL),A
        POP BC
        RET

; SETPOS: PLOT position = (BC, DE) clamped to the screen.
SETPOS:
        LD  A,B
        OR  A
        LD  A,C
        JR  Z,setpos_x
        LD  A,0
        JP  M,setpos_x              ; x < 0
        LD  A,255                   ; x > 255
setpos_x:
        LD  (XS_PLOTX),A
        LD  A,D
        OR  A
        JP  M,setpos_y0             ; y < 0
        JR  NZ,setpos_ytop
        LD  A,E
        CP  192
        JR  C,setpos_y
setpos_ytop:
        LD  A,191
        JR  setpos_y
setpos_y0:
        XOR A
setpos_y:
        LD  (XS_PLOTY),A
        RET

NEG_HL:
        LD  A,L
        CPL
        LD  L,A
        LD  A,H
        CPL
        LD  H,A
        INC HL
        RET

NEG_BC:
        LD  A,C
        CPL
        LD  C,A
        LD  A,B
        CPL
        LD  B,A
        INC BC
        RET

NEG_DE:
        LD  A,E
        CPL
        LD  E,A
        LD  A,D
        CPL
        LD  D,A
        INC DE
        RET

; ---- PLOT --------------------------------------------------------------------

; HPLOT ( x y n -- )  hi-res pixel, n = pixel mode. An on-screen point becomes
;   the PLOT position (also for n = 2); an off-screen one is ignored.
HPLOT:
        RST $18                     ; DE = n
        LD  A,E
        AND 3
        LD  (XS_PMODE),A
        RST $18                     ; DE = y
        PUSH DE
        RST $18                     ; DE = x
        LD  B,D
        LD  C,E
        POP DE
        CALL GFX_BEGIN
        CALL PIXADDR
        JP  C,GFX_END               ; off screen: no pixel, position unchanged
        CALL PIXEL
        CALL SETPOS
        JP  GFX_END

; ---- POINT -------------------------------------------------------------------

; HPOINT ( x y -- f )  1 if the pixel is set, 0 if clear or off screen.
HPOINT:
        RST $18                     ; DE = y
        PUSH DE
        RST $18                     ; DE = x
        LD  B,D
        LD  C,E
        POP DE
        CALL GFX_BEGIN
        CALL PIXADDR
        LD  DE,0
        JR  C,hpoint_push
        AND (HL)
        JR  Z,hpoint_push
        INC E
hpoint_push:
        RST $10
        JP  GFX_END

; ---- ATTR --------------------------------------------------------------------

; HATTR ( x y -- c )  colour byte of the 8x1 cell holding the pixel; 0 off screen.
HATTR:
        RST $18                     ; DE = y
        PUSH DE
        RST $18                     ; DE = x
        LD  B,D
        LD  C,E
        POP DE
        CALL GFX_BEGIN
        CALL PIXADDR
        LD  DE,0
        JR  C,hattr_push
        LD  A,H
        ADD A,HIGH HIRES_ATTR_OFS
        LD  H,A
        LD  E,(HL)
hattr_push:
        RST $10
        JP  GFX_END

; ---- CLS ---------------------------------------------------------------------

; HCLS ( -- )  clear the work page: bitmap 0, colour = PAPER:INK; position 0,0.
HCLS:
        CALL GFX_BEGIN
        LD  HL,HIRES_WINDOW
        LD  DE,HIRES_WINDOW + 1
        LD  BC,HIRES_ATTR_OFS - 1
        LD  (HL),0
        LDIR
        LD  HL,HIRES_WINDOW + HIRES_ATTR_OFS
        LD  DE,HIRES_WINDOW + HIRES_ATTR_OFS + 1
        LD  BC,HIRES_ATTR_OFS - 1
        LD  A,(XS_COLOUR)
        LD  (HL),A
        LDIR
        XOR A
        LD  (XS_PLOTX),A
        LD  (XS_PLOTY),A
        JP  GFX_END

; ---- DRAW --------------------------------------------------------------------

; HDRAW ( dx dy a -- )  from the PLOT position to
;   position + (dx, dy), turning through a degrees on the way: a = 0 is a
;   straight line, a > 0 an arc turning anticlockwise, a < 0 clockwise
;   (a is taken modulo 360, keeping its sign). The start pixel is not drawn
;   (the PLOT or DRAW that set the position drew it), so INVERSE/FLIP lines
;   join cleanly. The end point, clamped to the screen, becomes the position.
;
;   Arcs are drawn as chords: one every 5 degrees, then a last
;   chord to the exact end point. With h = a/2, the centre is
;   C = S + d/2 + perp(d) * cos h / (2 sin h), and the k-th point is
;   C + rot(S - C, 5k degrees). S - C is kept in 1/4 pixels and each point is
;   computed from it directly (no accumulated error). If the radius is too
;   large for 16-bit arithmetic (about 5600 pixels), a straight line is drawn.
HDRAW:
        RST $18                     ; DE = a
        LD  (XS_AA),DE
        RST $18                     ; DE = dy
        LD  (XS_ADY),DE
        RST $18                     ; DE = dx
        LD  (XS_ADX),DE
        CALL GFX_BEGIN
        CALL GFX_DRAWMODE
        LD  A,(XS_PLOTX)            ; S = the PLOT position
        LD  L,A
        LD  H,0
        LD  (XS_LX),HL
        LD  DE,(XS_ADX)
        ADD HL,DE
        LD  (XS_EX),HL              ; E = S + d
        LD  A,(XS_PLOTY)
        LD  L,A
        LD  H,0
        LD  (XS_LY),HL
        LD  DE,(XS_ADY)
        ADD HL,DE
        LD  (XS_EY),HL
        LD  HL,(XS_AA)
        CALL AREDUCE
        LD  (XS_AA),HL
        LD  A,H
        OR  L
        JR  Z,hdraw_last            ; a = 0: straight line
        CALL ARC_SETUP
        JR  C,hdraw_last            ; radius too large: straight line
hdraw_arc:
        LD  HL,(XS_ATH)             ; next turn
        LD  DE,(XS_ASTEP)
        ADD HL,DE
        LD  (XS_ATH),HL
        BIT 7,H
        CALL NZ,NEG_HL
        LD  DE,(XS_AEND)
        OR  A
        SBC HL,DE
        JR  NC,hdraw_last           ; reached the end angle
        CALL ARC_POINT
        CALL LINE_TO
        JR  hdraw_arc
hdraw_last:
        LD  BC,(XS_EX)
        LD  DE,(XS_EY)
        CALL LINE_TO
        CALL SETPOS
        JP  GFX_END

; LINE_TO: Bresenham line from (XS_LX, XS_LY) to (BC, DE), start pixel not
; drawn; the target becomes (XS_LX, XS_LY). 16-bit signed coordinates;
; off-screen pixels are clipped by PIXEL.
LINE_TO:
        LD  (XS_LTX),BC
        LD  (XS_LTY),DE
        EX  DE,HL
        LD  DE,(XS_LY)
        OR  A
        SBC HL,DE
        PUSH HL                     ; dy
        LD  H,B
        LD  L,C
        LD  DE,(XS_LX)
        OR  A
        SBC HL,DE                   ; HL = dx
        LD  DE,1
        BIT 7,H
        JR  Z,hdraw_xpos
        CALL NEG_HL
        LD  DE,-1
hdraw_xpos:
        LD  (XS_DX),HL
        LD  (XS_SX),DE
        POP HL                      ; HL = dy
        LD  DE,1
        BIT 7,H
        JR  Z,hdraw_ypos
        CALL NEG_HL
        LD  DE,-1
hdraw_ypos:
        LD  (XS_DY),HL
        LD  (XS_SY),DE
        ; major axis: the larger of |dx|, |dy|
        LD  HL,(XS_DX)
        LD  DE,(XS_DY)
        AND A
        SBC HL,DE
        LD  HL,0
        JR  C,hdraw_ymajor
        LD  DE,(XS_SX)              ; x major
        LD  (XS_MSX),DE
        LD  (XS_MSY),HL
        LD  (XS_NSX),HL
        LD  DE,(XS_SY)
        LD  (XS_NSY),DE
        LD  HL,(XS_DX)
        LD  DE,(XS_DY)
        JR  hdraw_go
hdraw_ymajor:
        LD  (XS_MSX),HL             ; y major
        LD  DE,(XS_SY)
        LD  (XS_MSY),DE
        LD  DE,(XS_SX)
        LD  (XS_NSX),DE
        LD  (XS_NSY),HL
        LD  HL,(XS_DY)
        LD  DE,(XS_DX)
hdraw_go:                           ; HL = major length, DE = minor length
        LD  (XS_DMAJ),HL
        LD  (XS_DMIN),DE
        LD  (XS_CNT),HL
        SRL H
        RR  L
        LD  (XS_ERR),HL             ; err = major / 2
        LD  BC,(XS_LX)
        LD  DE,(XS_LY)
hdraw_loop:
        LD  HL,(XS_CNT)
        LD  A,H
        OR  L
        JR  Z,hdraw_end
        DEC HL
        LD  (XS_CNT),HL
        LD  HL,(XS_MSX)             ; step the major axis
        ADD HL,BC
        LD  B,H
        LD  C,L
        LD  HL,(XS_MSY)
        ADD HL,DE
        EX  DE,HL
        PUSH DE                     ; err -= minor
        LD  HL,(XS_ERR)
        LD  DE,(XS_DMIN)
        AND A
        SBC HL,DE
        JP  P,hdraw_nominor
        LD  DE,(XS_DMAJ)            ; err < 0: err += major, step the minor axis
        ADD HL,DE
        LD  (XS_ERR),HL
        POP DE
        LD  HL,(XS_NSX)
        ADD HL,BC
        LD  B,H
        LD  C,L
        LD  HL,(XS_NSY)
        ADD HL,DE
        EX  DE,HL
        JR  hdraw_plot
hdraw_nominor:
        LD  (XS_ERR),HL
        POP DE
hdraw_plot:
        CALL PIXEL
        JR  hdraw_loop
hdraw_end:
        LD  BC,(XS_LTX)
        LD  DE,(XS_LTY)
        LD  (XS_LX),BC
        LD  (XS_LY),DE
        RET

; ---- DRAW arcs -----------------------------------------------------------------

; AREDUCE: HL = HL modulo 360, keeping the sign (-359..359).
AREDUCE:
        BIT 7,H
        JR  Z,areduce_pos
        CALL NEG_HL
        CALL areduce_pos
        JP  NEG_HL
areduce_pos:
        LD  DE,-360
        ADD HL,DE
        JR  C,areduce_pos           ; was >= 360
        LD  DE,360
        ADD HL,DE
        RET

; ARC_SETUP: from XS_AA, XS_ADX/ADY and XS_LX/LY, set up the arc (centre,
; v0 = S - C, turn counter). Carry set if the radius is too large.
;   v0x = -2 dx + 2 dy cos h / sin h,  v0y = -2 dy - 2 dx cos h / sin h  (Q2)
ARC_SETUP:
        LD  HL,(XS_AA)              ; h = a/2 degrees = a half-degrees
        CALL SIN_HD
        LD  (XS_SH),HL
        LD  HL,(XS_AA)
        CALL COS_HD
        LD  (XS_CH),HL
        LD  BC,(XS_ADY)             ; v0x
        LD  DE,(XS_CH)
        CALL MUL16S
        CALL SHL32
        LD  BC,(XS_SH)
        CALL DIVS32
        RET C
        EX  DE,HL                   ; DE = 2 dy cos h / sin h
        LD  HL,(XS_ADX)
        OR  A
        ADC HL,HL
        JP  PE,arc_big              ; 2 dx overflows
        EX  DE,HL
        OR  A
        SBC HL,DE
        JP  PE,arc_big
        CALL CHKMAG
        RET C
        LD  (XS_AVX),HL
        LD  BC,(XS_ADX)             ; v0y
        LD  DE,(XS_CH)
        CALL MUL16S
        CALL SHL32
        LD  BC,(XS_SH)
        CALL DIVS32
        RET C
        EX  DE,HL                   ; DE = 2 dx cos h / sin h
        LD  HL,(XS_ADY)
        OR  A
        ADC HL,HL
        JP  PE,arc_big              ; 2 dy overflows
        OR  A
        ADC HL,DE
        JP  PE,arc_big
        CALL NEG_HL                 ; -(2 dy + ...)
        CALL CHKMAG
        RET C
        LD  (XS_AVY),HL
        LD  HL,(XS_LX)              ; centre x * 2^16 + 2^15 = (4 Sx - v0x) << 14 + 2^15
        LD  DE,(XS_AVX)
        LD  BC,XS_CX32
        CALL ARC_CENTRE
        LD  HL,(XS_LY)
        LD  DE,(XS_AVY)
        LD  BC,XS_CY32
        CALL ARC_CENTRE
        LD  HL,0
        LD  (XS_ATH),HL
        LD  HL,(XS_AA)              ; end = |a| in half-degrees, step = +-10
        LD  DE,10
        BIT 7,H
        JR  Z,arc_dir
        CALL NEG_HL
        LD  DE,-10
arc_dir:
        ADD HL,HL
        LD  (XS_AEND),HL
        LD  (XS_ASTEP),DE
        OR  A                       ; carry clear
        RET
arc_big:
        SCF
        RET

; CHKMAG: carry set if |HL| > 22528 (keeps |v0| and the points in range).
CHKMAG:
        LD  A,H
        BIT 7,A
        JR  Z,chkmag_pos
        CPL
chkmag_pos:
        CP  $58
        CCF
        RET

; ARC_CENTRE: (BC) = ((4 * HL - DE) << 14) + $8000, 32-bit.
ARC_CENTRE:
        PUSH BC
        ADD HL,HL
        ADD HL,HL
        OR  A
        SBC HL,DE                   ; 4 S - v0, Q2
        LD  D,0                     ; sign-extend into DE:HL
        BIT 7,H
        JR  Z,arc_centre_ext
        DEC D
arc_centre_ext:
        LD  E,D
        LD  B,14
arc_centre_shift:
        ADD HL,HL
        RL  E
        RL  D
        DJNZ arc_centre_shift
        LD  BC,$8000                ; + 1/2 pixel: the high word rounds
        ADD HL,BC
        JR  NC,arc_centre_st
        INC DE
arc_centre_st:
        POP BC
        LD  A,L
        LD  (BC),A
        INC BC
        LD  A,H
        LD  (BC),A
        INC BC
        LD  A,E
        LD  (BC),A
        INC BC
        LD  A,D
        LD  (BC),A
        RET

; ARC_POINT: BC, DE = the point at turn XS_ATH (pixels):
;   x = (v0x cos t - v0y sin t + CX32) >> 16,  y = (v0x sin t + v0y cos t + CY32) >> 16
ARC_POINT:
        LD  HL,(XS_ATH)
        CALL COS_HD
        LD  (XS_TC),HL
        LD  HL,(XS_ATH)
        CALL SIN_HD
        LD  (XS_TS),HL
        LD  BC,(XS_AVX)
        LD  DE,(XS_TC)
        CALL MUL16S
        CALL ST32
        LD  BC,(XS_AVY)
        LD  DE,(XS_TS)
        CALL MUL16S
        CALL SUB32T                 ; T32 - DEHL
        LD  BC,XS_CX32
        CALL ADD32P
        PUSH DE                     ; x
        LD  BC,(XS_AVX)
        LD  DE,(XS_TS)
        CALL MUL16S
        CALL ST32
        LD  BC,(XS_AVY)
        LD  DE,(XS_TC)
        CALL MUL16S
        CALL ADD32T                 ; T32 + DEHL
        LD  BC,XS_CY32
        CALL ADD32P                 ; DE = y
        POP BC                      ; BC = x
        RET

; ---- Fixed-point helpers -------------------------------------------------------

; SIN_HD / COS_HD: HL = sin / cos of HL half-degrees (any 16-bit angle with
; |HL| < 32000), Q14. Affect DE.
COS_HD:
        LD  DE,180
        ADD HL,DE
SIN_HD:
        BIT 7,H
        JR  Z,sinhd_pos
        CALL NEG_HL                 ; sin(-x) = -sin(x)
        CALL sinhd_pos
        JP  NEG_HL
sinhd_pos:
        LD  DE,-720                 ; reduce to 0..719
        ADD HL,DE
        JR  C,sinhd_pos
        LD  DE,720
        ADD HL,DE
        LD  DE,-360
        ADD HL,DE
        JR  NC,sinhd_half           ; < 360
        CALL sinhd_half0            ; 360..719: -sin(x - 360)
        JP  NEG_HL
sinhd_half:
        LD  DE,360
        ADD HL,DE
sinhd_half0:                        ; 0..359
        LD  DE,-181
        ADD HL,DE
        JR  NC,sinhd_q1             ; 0..180
        EX  DE,HL                   ; 181..359: sin(360 - x); DE = x - 181
        LD  HL,179
        OR  A
        SBC HL,DE
        JR  sinhd_tab
sinhd_q1:
        LD  DE,181
        ADD HL,DE
sinhd_tab:
        ADD HL,HL
        LD  DE,SINTAB
        ADD HL,DE
        LD  E,(HL)
        INC HL
        LD  D,(HL)
        EX  DE,HL
        RET

; MUL16S: DE:HL = BC * DE, signed. Affects A, BC.
MUL16S:
        LD  A,B
        XOR D
        PUSH AF                     ; sign of the product in bit 7
        BIT 7,B
        CALL NZ,NEG_BC
        BIT 7,D
        CALL NZ,NEG_DE
        CALL MULU16
        POP AF
        AND $80
        RET Z
        JP  NEG32

; MULU16: DE:HL = BC * DE, unsigned. Affects A.
MULU16:
        LD  HL,0
        LD  A,16
mulu16_loop:
        ADD HL,HL
        RL  E
        RL  D
        JR  NC,mulu16_next
        ADD HL,BC
        JR  NC,mulu16_next
        INC DE
mulu16_next:
        DEC A
        JR  NZ,mulu16_loop
        RET

; DIVS32: HL = DE:HL / BC, signed, truncated towards 0. Carry set if the
; quotient does not fit in -32767..32767 (or BC = 0). Affects A, BC, DE.
DIVS32:
        LD  A,D
        XOR B
        PUSH AF                     ; sign of the quotient in bit 7
        BIT 7,D
        CALL NZ,NEG32
        BIT 7,B
        CALL NZ,NEG_BC
        EX  DE,HL                   ; quotient < 65536 needs high word < BC
        OR  A
        SBC HL,BC
        ADD HL,BC
        EX  DE,HL
        JR  NC,divs32_ovf
        CALL DIVU32
        BIT 7,H
        JR  NZ,divs32_ovf           ; > 32767
        POP AF
        AND $80
        RET Z                       ; carry clear
        CALL NEG_HL
        OR  A
        RET
divs32_ovf:
        POP AF
        SCF
        RET

; DIVU32: HL = DE:HL / BC, DE = remainder; needs DE < BC. Affects A.
DIVU32:
        LD  A,16
divu32_loop:
        ADD HL,HL
        RL  E
        RL  D
        JR  C,divu32_sub            ; 17-bit remainder: always >= BC
        EX  DE,HL
        OR  A
        SBC HL,BC
        JR  NC,divu32_bit
        ADD HL,BC
        EX  DE,HL
        JR  divu32_next
divu32_sub:
        EX  DE,HL
        OR  A
        SBC HL,BC
divu32_bit:
        EX  DE,HL
        INC L                       ; quotient bit
divu32_next:
        DEC A
        JR  NZ,divu32_loop
        RET

; NEG32: DE:HL = -DE:HL. Affects A.
NEG32:
        LD  A,L
        CPL
        LD  L,A
        LD  A,H
        CPL
        LD  H,A
        LD  A,E
        CPL
        LD  E,A
        LD  A,D
        CPL
        LD  D,A
        INC HL
        LD  A,H
        OR  L
        RET NZ
        INC DE
        RET

; SHL32: DE:HL = DE:HL * 2.
SHL32:
        ADD HL,HL
        RL  E
        RL  D
        RET

; ST32: XS_T32 = DE:HL.
ST32:
        LD  (XS_T32),HL
        LD  (XS_T32 + 2),DE
        RET

; SUB32T: DE:HL = XS_T32 - DE:HL.
SUB32T:
        PUSH DE
        EX  DE,HL
        LD  HL,(XS_T32)
        OR  A
        SBC HL,DE
        POP DE
        PUSH HL
        LD  HL,(XS_T32 + 2)
        SBC HL,DE
        EX  DE,HL
        POP HL
        RET

; ADD32T: DE:HL = XS_T32 + DE:HL.
ADD32T:
        PUSH DE
        LD  DE,(XS_T32)
        ADD HL,DE
        POP DE
        PUSH HL
        LD  HL,(XS_T32 + 2)
        ADC HL,DE
        EX  DE,HL
        POP HL
        RET

; ADD32P: DE:HL = DE:HL + the 32-bit number at (BC). Affects A, BC.
ADD32P:
        LD  A,(BC)
        ADD A,L
        LD  L,A
        INC BC
        LD  A,(BC)
        ADC A,H
        LD  H,A
        INC BC
        LD  A,(BC)
        ADC A,E
        LD  E,A
        INC BC
        LD  A,(BC)
        ADC A,D
        LD  D,A
        RET

SINTAB:
        INCLUDE "inc/sintab.inc"

; ---- CIRCLE ------------------------------------------------------------------

; HCIRCLE ( x y r -- )  midpoint circle, centre (x, y), radius r. Each pixel
;   is drawn once, so FLIP circles are clean. r < 0 draws nothing. The PLOT
;   position is not changed.
HCIRCLE:
        RST $18                     ; DE = r
        PUSH DE
        RST $18                     ; DE = y
        LD  (XS_CY),DE
        RST $18                     ; DE = x
        LD  (XS_CX),DE
        POP HL                      ; HL = r
        BIT 7,H
        JR  Z,hcircle_ok
        AND A                       ; r < 0: nothing, no error
        RET
hcircle_ok:
        CALL GFX_BEGIN
        CALL GFX_DRAWMODE
        LD  (XS_XO),HL
        LD  A,H
        OR  L
        JR  NZ,hcircle_r
        LD  B,A                     ; r = 0: the centre only
        LD  C,A
        LD  D,A
        LD  E,A
        CALL CPOINT
        JP  GFX_END
hcircle_r:
        EX  DE,HL                   ; DE = r
        LD  HL,1
        AND A
        SBC HL,DE
        LD  (XS_D),HL               ; d = 1 - r
        LD  B,D                     ; axis points (+-r, 0), (0, +-r)
        LD  C,E
        LD  DE,0
        CALL CPOINT
        CALL NEG_BC
        CALL CPOINT
        LD  D,B
        LD  E,C
        LD  BC,0
        CALL CPOINT
        CALL NEG_DE
        CALL CPOINT
        LD  HL,0
        LD  (XS_YO),HL
hcircle_loop:
        LD  HL,(XS_YO)              ; y++
        INC HL
        LD  (XS_YO),HL
        LD  HL,(XS_D)
        BIT 7,H
        JR  Z,hcircle_xdec
        LD  DE,(XS_YO)              ; d < 0: d += 2y + 1
        ADD HL,DE
        ADD HL,DE
        INC HL
        LD  (XS_D),HL
        JR  hcircle_chk
hcircle_xdec:
        LD  DE,(XS_XO)              ; d >= 0: x--, d += 2(y - x) + 1
        DEC DE
        LD  (XS_XO),DE
        PUSH HL
        LD  HL,(XS_YO)
        AND A
        SBC HL,DE
        ADD HL,HL
        INC HL
        POP DE
        ADD HL,DE
        LD  (XS_D),HL
hcircle_chk:
        LD  HL,(XS_XO)              ; stop when y > x
        LD  DE,(XS_YO)
        AND A
        SBC HL,DE
        JP  C,GFX_END
        LD  BC,(XS_XO)              ; (+-x, +-y)
        CALL CQUAD
        LD  HL,(XS_XO)
        LD  DE,(XS_YO)
        AND A
        SBC HL,DE
        JR  Z,hcircle_loop          ; x = y: the diagonal, already drawn
        LD  BC,(XS_YO)              ; (+-y, +-x)
        LD  DE,(XS_XO)
        CALL CQUAD
        JR  hcircle_loop

; CQUAD: BC = a > 0, DE = b > 0: the four points (+-a, +-b) round the centre.
CQUAD:
        CALL CPOINT
        CALL NEG_BC
        CALL CPOINT
        CALL NEG_DE
        CALL CPOINT
        CALL NEG_BC
        JP  CPOINT

; CPOINT: pixel at centre + (BC, DE). Preserves BC, DE.
CPOINT:
        PUSH BC
        PUSH DE
        LD  HL,(XS_CX)
        ADD HL,BC
        LD  B,H
        LD  C,L
        LD  HL,(XS_CY)
        ADD HL,DE
        EX  DE,HL
        CALL PIXEL
        POP DE
        POP BC
        RET

; ---- PAINT -------------------------------------------------------------------

; HPAINT ( x y -- )  flood fill, 4-connected, span method working on bytes.
;   Plot or FLIP mode: the PAPER area containing (x, y) becomes INK.
;   INVERSE mode: the INK area containing (x, y) becomes PAPER.
;   INVERSE + FLIP, a seed of the other kind, or an off-screen seed: nothing.
;   Every byte touched gets the current PAPER:INK, as with PLOT.
;   Seeds (2 bytes: x, y) are kept on the Z80 stack, in the free RAM between
;   the Forth data stack and RAMTOP. If fewer than PAINT_MARGIN bytes would be
;   left, the fill stops with ERROR 1 (the ROM's "not enough memory"); the part
;   already filled stays. The PLOT position is not changed.
;
;   For each seed: find the span [xl, xr] of matching pixels on its row
;   (whole matching bytes are skipped 8 pixels at a time), flip it a byte at a
;   time with edge masks, write each colour byte once, then scan the rows
;   above and below over the same bytes and push one seed per run of matching
;   pixels: run starts = m AND NOT(m >> 1 | last bit of the previous byte).
;   Because seeds live on the stack, the neighbour scan (PNEIGH) is entered
;   with JP and returns through XS_PRET, never with CALL/RET.
PAINT_MARGIN    EQU 64              ; room kept for calls and the interrupt handler

; PAINT_PUSH: push seed DE (D = y, E = x); out of memory -> paint_full.
; Preserves BC, DE. Affects HL.
        MACRO PAINT_PUSH
        PUSH DE
        LD  HL,(XS_PCNT)
        INC HL
        LD  (XS_PCNT),HL
        LD  HL,(XS_PNLIM)
        ADD HL,SP                   ; carry if SP >= SPARE + PAINT_MARGIN
        JP  NC,paint_full
        ENDM

HPAINT:
        RST $18                     ; DE = y
        PUSH DE
        RST $18                     ; DE = x
        LD  B,D
        LD  C,E
        POP DE
        CALL GFX_BEGIN
        CALL GFX_DRAWMODE
        LD  A,(XS_PMODE)
        CP  2
        JP  Z,GFX_END               ; INVERSE + FLIP: nothing
        OR  A                       ; Z: unplot mode, fill INK pixels
        LD  A,0
        JR  NZ,hpaint_tgt
        DEC A
hpaint_tgt:
        LD  (XS_PTGT),A
        CALL PIXADDR
        JP  C,GFX_END               ; seed off screen
        LD  (XS_PSP),SP
        PUSH DE                     ; XS_PNLIM = -(SPARE + PAINT_MARGIN)
        LD  HL,(SV_SPARE)
        LD  DE,PAINT_MARGIN
        ADD HL,DE
        EX  DE,HL
        LD  HL,0
        AND A
        SBC HL,DE
        LD  (XS_PNLIM),HL
        POP DE
        LD  HL,0
        LD  (XS_PCNT),HL
        LD  D,E                     ; D = y
        LD  E,C                     ; E = x
        PAINT_PUSH

paint_next:
        LD  HL,(XS_PCNT)
        LD  A,H
        OR  L
        JP  Z,GFX_END               ; no seeds left (stack balanced)
        DEC HL
        LD  (XS_PCNT),HL
        POP DE                      ; D = y, E = x
        LD  A,D
        LD  (XS_PY),A
        LD  A,191                   ; row address = $C000 + (191 - y) * 32
        SUB D
        LD  L,A
        LD  H,0
        ADD HL,HL
        ADD HL,HL
        ADD HL,HL
        ADD HL,HL
        ADD HL,HL
        LD  A,H
        OR  HIGH HIRES_WINDOW
        LD  H,A
        LD  (XS_PROW),HL
        LD  A,E                     ; C = $80 >> (x & 7)
        AND 7
        OR  LOW PT_BIT
        LD  C,A
        LD  B,HIGH PT_BIT
        LD  A,(BC)
        LD  C,A
        LD  A,E                     ; byte = row + x / 8
        RRCA
        RRCA
        RRCA
        AND $1F
        OR  L
        LD  L,A
        LD  B,E                     ; B = x
        LD  A,(XS_PTGT)
        LD  D,A                     ; D = target pattern
        XOR (HL)
        AND C
        JR  NZ,paint_next           ; already filled
        LD  (XS_PSA),HL
        LD  A,C
        LD  (XS_PSM),A

        ; ---- left end of the span (B = x, C = mask, HL = byte, D = target) ---
paint_left:
        LD  A,B
        OR  A
        JR  Z,paint_left_end        ; x = 0
        LD  A,C
        CP  $80
        JR  NZ,paint_left_pix       ; not at a byte boundary
        DEC HL                      ; whole byte to the left matches?
        LD  A,D
        XOR (HL)
        JR  NZ,paint_left_part
        LD  A,B
        SUB 8
        LD  B,A
        JR  paint_left
paint_left_part:
        INC HL
paint_left_pix:
        RLC C
        JR  NC,paint_left_1
        DEC HL
paint_left_1:
        DEC B
        LD  A,D
        XOR (HL)
        AND C
        JR  Z,paint_left
        INC B                       ; one too far
paint_left_end:
        LD  A,B
        LD  (XS_PXL),A

        ; ---- right end of the span --------------------------------------------
        LD  HL,(XS_PSA)
        LD  A,(XS_PSM)
        LD  C,A
        LD  B,E                     ; seed x
paint_right:
        LD  A,B
        INC A
        JR  Z,paint_right_end       ; x = 255
        LD  A,C
        CP  $01
        JR  NZ,paint_right_pix      ; not at a byte boundary
        INC HL                      ; whole byte to the right matches?
        LD  A,D
        XOR (HL)
        JR  NZ,paint_right_part
        LD  A,B
        ADD A,8
        LD  B,A
        JR  paint_right
paint_right_part:
        DEC HL
paint_right_pix:
        RRC C
        JR  NC,paint_right_1
        INC HL
paint_right_1:
        INC B
        LD  A,D
        XOR (HL)
        AND C
        JR  Z,paint_right
        DEC B                       ; one too far
paint_right_end:
        LD  A,B
        LD  (XS_PXR),A

        ; ---- span bytes and edge masks (tables) -------------------------------
        AND 7                       ; last mask = $FF << (7 - (xr & 7))
        OR  LOW PT_RIGHT
        LD  L,A
        LD  H,HIGH PT_RIGHT
        LD  A,(HL)
        LD  (XS_PRM),A
        LD  A,B
        RRCA
        RRCA
        RRCA
        AND $1F
        LD  (XS_PBR),A
        LD  A,(XS_PXL)              ; first mask = $FF >> (xl & 7)
        LD  C,A
        AND 7
        OR  LOW PT_LEFT
        LD  L,A
        LD  H,HIGH PT_LEFT
        LD  A,(HL)
        LD  (XS_PLM),A
        LD  A,C
        RRCA
        RRCA
        RRCA
        AND $1F
        LD  (XS_PBL),A

        ; ---- fill the span, one colour write per byte -------------------------
        ; B = column, E = this byte's mask, C = PAPER:INK
        LD  B,A
        LD  HL,(XS_PROW)
        OR  L
        LD  L,A
        LD  A,(XS_PLM)
        LD  E,A
        LD  A,(XS_COLOUR)
        LD  C,A
paint_fill:
        LD  A,(XS_PBR)
        CP  B
        JR  NZ,paint_fill_1
        LD  A,(XS_PRM)              ; last byte
        AND E
        LD  E,A
paint_fill_1:
        LD  A,E
        XOR (HL)                    ; the masked pixels all match: flip them
        LD  (HL),A
        LD  A,H
        ADD A,HIGH HIRES_ATTR_OFS
        LD  H,A
        LD  (HL),C
        SUB HIGH HIRES_ATTR_OFS
        LD  H,A
        LD  A,(XS_PBR)
        CP  B
        JR  Z,paint_above
        INC B
        INC HL
        LD  E,$FF
        JR  paint_fill

        ; ---- seeds in the rows above and below --------------------------------
paint_above:
        LD  A,(XS_PY)
        CP  191
        JR  NC,paint_below          ; top row
        INC A
        LD  (XS_PNY),A
        LD  HL,(XS_PROW)
        LD  DE,-32
        ADD HL,DE
        LD  (XS_PNROW),HL
        LD  HL,paint_below
        LD  (XS_PRET),HL
        JP  PNEIGH
paint_below:
        LD  A,(XS_PY)
        OR  A
        JP  Z,paint_next            ; bottom row
        DEC A
        LD  (XS_PNY),A
        LD  HL,(XS_PROW)
        LD  DE,32
        ADD HL,DE
        LD  (XS_PNROW),HL
        LD  HL,paint_next
        LD  (XS_PRET),HL
        ; fall into PNEIGH

; PNEIGH: push a seed at the start of every run of matching pixels in row
; XS_PNROW (y = XS_PNY) between XS_PXL and XS_PXR. Entered with JP; leaves
; with JP (XS_PRET). Run starts = m AND NOT(m >> 1 | carry-in), where m are
; the matching pixels inside the span and carry-in is the previous byte's
; last pixel (RRA shifts it in).
PNEIGH:
        LD  A,(XS_PBL)
        LD  B,A                     ; B = byte column
        LD  HL,(XS_PNROW)
        OR  L
        LD  L,A
        LD  (XS_PNROW),HL           ; now the address of the current byte
        LD  A,(XS_PLM)
        LD  E,A                     ; E = this byte's span mask
        XOR A
        LD  (XS_PCARRY),A
pneigh_byte:
        LD  A,(XS_PBR)
        CP  B
        JR  NZ,pneigh_mask
        LD  A,(XS_PRM)              ; last byte
        AND E
        LD  E,A
pneigh_mask:
        LD  HL,(XS_PNROW)
        LD  A,(XS_PTGT)
        XOR (HL)
        CPL
        AND E
        LD  C,A                     ; C = m: matching pixels in the span
        LD  A,(XS_PCARRY)
        RRA                         ; carry = last pixel of the previous byte
        LD  A,C
        RRA                         ; A = left neighbours; carry = m bit 0
        LD  D,A
        SBC A,A                     ; $FF if m bit 0, else 0
        LD  (XS_PCARRY),A           ; (bit 0 is what RRA reads next time)
        LD  A,D
        CPL
        AND C                       ; run starts
        JR  Z,pneigh_next
        LD  C,A
        LD  A,B                     ; E = x of bit 7
        ADD A,A
        ADD A,A
        ADD A,A
        LD  E,A
        LD  A,(XS_PNY)
        LD  D,A
pneigh_bit:
        SLA C
        JR  NC,pneigh_nobit
        PAINT_PUSH
pneigh_nobit:
        INC E
        LD  A,C
        OR  A
        JR  NZ,pneigh_bit
pneigh_next:
        LD  A,(XS_PBR)
        CP  B
        JR  Z,pneigh_done
        INC B
        LD  HL,(XS_PNROW)
        INC HL
        LD  (XS_PNROW),HL
        LD  E,$FF
        JR  pneigh_byte
pneigh_done:
        LD  HL,(XS_PRET)
        JP  (HL)

paint_full:                         ; out of memory: drop the seeds, ERROR 1
        LD  SP,(XS_PSP)
        CALL GFX_RESTORE
        LD  A,ERR_NO_MEMORY
        SCF
        RET

; Mask tables, 8-aligned so that OR LOW table indexes them.
        ALIGN 8
PT_BIT:   DB  $80,$40,$20,$10,$08,$04,$02,$01   ; pixel x & 7
PT_LEFT:  DB  $FF,$7F,$3F,$1F,$0F,$07,$03,$01   ; from pixel x & 7 to the right
PT_RIGHT: DB  $80,$C0,$E0,$F0,$F8,$FC,$FE,$FF   ; up to pixel x & 7
