; =============================================================================
; TurboACE hardware equates  -  see register-map.md (v0.4)
; =============================================================================

; ---- Control port $E3 (register-map.md section 2) ---------------------------
; Write: OUT ($E3),A with A = cccddddd.  Read: LD A,ccc00000 / IN A,($E3)
; (the read selector is taken from A15-A13).
PORT_CTRL       EQU $E3

CMD_BG_CPU      EQU %00000000   ; BG-RAM page seen by the CPU   (text)
CMD_BG_VIEW     EQU %00100000   ; page shown (text: BG page, hi-res: RAM page)
CMD_CHR_CPU     EQU %01000000   ; CHR-RAM page seen by the CPU
CMD_CHR_VIEW    EQU %01100000   ; CHR-RAM page used by video
CMD_MODE        EQU %10000000   ; bit 0: 0 = text, 1 = hi-res bitmap
CMD_RESERVED5   EQU %10100000   ; reserved (RAMPAGE until v0.4; now port $E1)
CMD_ROMPAGE     EQU %11000000   ; 8K ROM page at $0000-$1FFF (0-7)
CMD_XCFG        EQU %11100000   ; write: b0 ATTR. read: 1010100a (ID + ATTR)

XCFG_ATTR       EQU $01         ; 1 = BG window addresses colour RAM
XCFG_MIRROR     EQU $02         ; 1 = $3000-$3BFF mirrors $3C00 as on a stock Ace
                                ; (write-only; set by -1 and -2 TURBO, cleared by reset)
XCFG_OPAQUE     EQU $04         ; 1 = hi-res text overlay: non-space cells opaque
                                ; (write-only; the ROM keeps a copy in XS_XCFG)
XCFG_KEEP       EQU $08         ; with MIRROR: $3B00-$3BFF stay extension RAM, the SD
                                ; code's state (write-only; set by -1 TURBO)
XCFG_ID         EQU $A8         ; read of CMD_XCFG, bits 7-1: TurboACE present
XCFG_ID_MASK    EQU $FE

PARAM_MASK      EQU %00011111

; ---- User-RAM page port $E1 (register-map.md section 2.5) ------------------
; Write: OUT ($E1),A with A = w0pppppp: window w (0 = $C000, 1 = $E000) shows
; 8K page p (0-63). Read: LD A,w0000000 / IN A,($E1) -> 00pppppp (the window
; is selected by A15). Reset: window 0 = page 0, window 1 = page 1.
PORT_PAGE       EQU $E1
PAGE_WIN1       EQU $80         ; window bit: 0 = $C000-$DFFF, 1 = $E000-$FFFF
PAGE_MASK       EQU $3F         ; 64 x 8K = 512K

; ---- SD card ports $E5 / $E7 (register-map.md section 2.6) -------------------
PORT_SDCMD      EQU $E5         ; write: command; read: status
PORT_SDDATA     EQU $E7         ; arguments, results, data
SDS_BUSY        EQU 7           ; status bits
SDS_ERROR       EQU 6
SDC_DIRFIRST    EQU $02         ; commands used so far
SDC_DIRNEXT     EQU $03
SDC_CHDIR       EQU $04
SDC_DELETE      EQU $05
SDC_OPENR       EQU $10
SDC_OPENW       EQU $11
SDC_READ        EQU $12
SDC_WRITE       EQU $13
SDC_CLOSE       EQU $14
SD_XFER_MAX     EQU 8192        ; most bytes per READ / WRITE
SDC_TINSERT     EQU $20
SDC_TEJECT      EQU $21
SDC_TREAD       EQU $22
SDC_TWRITE      EQU $23
SD_CHUNK        EQU 512         ; data phases move at most this many bytes per wait
SDE_IO          EQU 5           ; error codes used by the ROM itself
SDE_BADNAME     EQU 6
SD_NAME_MAX     EQU 63          ; longest file name
SDE_BADBLOCK    EQU 9
SDE_ENDTAPE     EQU 10

; ---- ROM pages (register-map.md section 5) ----------------------------------
ROMPG_STOCK     EQU 0           ; stock Ace ROM, byte-identical (-2 TURBO)
ROMPG_MAIN      EQU 1           ; stock ROM + 4-byte boot hook (reset value)
ROMPG_BOOT      EQU 2           ; boot page + extension code
ROMPG_EXT3      EQU 3
ROMPG_EXT4      EQU 4
ROMPG_EXT5      EQU 5
ROMPG_EXT6      EQU 6
ROMPG_RESERVED  EQU 7

; ---- AY-3-8910 (section 4.1) -------------------------------------------------
PORT_AY_REG     EQU $FD
PORT_AY_VAL     EQU $FF
AY_R_ENABLE     EQU 7           ; b7-b6 = 11: ports A and B are outputs
AY_R_PORTA      EQU 14          ; PAPER (b7-4) : INK (b3-0)
AY_R_PORTB      EQU 15          ; BORDER (b7-4), b3-0 unused

; ---- Memory map (section 3) --------------------------------------------------
XDICT_BASE      EQU $3000       ; 3K RAM, extension words (TurboACE boot)
XDICT_END       EQU $3C00       ; first byte after the area
XSTATE_SIZE     EQU $0100       ; state lives at the top of the area
XSTATE          EQU XDICT_END - XSTATE_SIZE   ; $3B00-$3BFF
RAMTOP_TURBO    EQU $C000       ; RAMTOP in 1 TURBO (stack below the paged windows)
TURBO_ROOM      EQU $0100       ; 1 TURBO needs SPARE + this below RAMTOP_TURBO
HIRES_WINDOW    EQU $C000       ; screen n = 8K pages 2n ($C000) and 2n+1 ($E000):
                                ; bitmap at $C000, colour at $D800, 4K free at $F000
HIRES_ATTR_OFS  EQU $1800

; ---- Extension state ($3B00-$3BFF), zeroed by the boot page -----------------
XS_WORKPG       EQU XSTATE + 0  ; hi-res page drawn into (0-31)
XS_PLOTX        EQU XSTATE + 1  ; last PLOT position (hi-res), x
XS_PLOTY        EQU XSTATE + 2  ;                              y
XS_GFLAGS       EQU XSTATE + 3  ; b0 INVERSE, b1 FLIP
XS_PMODE        EQU XSTATE + 4  ; pixel mode for PIXEL: 0 unplot 1 plot 2 move 3 invert
XS_SAVEPG       EQU XSTATE + 5  ; user's page in window 0 while a graphics routine runs
XS_COLOUR       EQU XSTATE + 6  ; PAPER:INK (AY R14) latched at routine entry
XS_SAVEPG1      EQU XSTATE + 7  ; user's page in window 1 while a graphics routine runs
; DRAW (2 bytes each)
XS_DX           EQU XSTATE + $08 ; |dx|
XS_DY           EQU XSTATE + $0A ; |dy|
XS_SX           EQU XSTATE + $0C ; x step, +1 / -1
XS_SY           EQU XSTATE + $0E ; y step, +1 / -1
XS_MSX          EQU XSTATE + $10 ; major-axis step (x, y)
XS_MSY          EQU XSTATE + $12
XS_NSX          EQU XSTATE + $14 ; minor-axis step (x, y)
XS_NSY          EQU XSTATE + $16
XS_DMAJ         EQU XSTATE + $18
XS_DMIN         EQU XSTATE + $1A
XS_ERR          EQU XSTATE + $1C
XS_CNT          EQU XSTATE + $1E
; CIRCLE (2 bytes each)
XS_CX           EQU XSTATE + $20
XS_CY           EQU XSTATE + $22
XS_XO           EQU XSTATE + $24
XS_YO           EQU XSTATE + $26
XS_D            EQU XSTATE + $28
; PAINT
XS_PY           EQU XSTATE + $2A ; y of the span being filled
XS_PTGT         EQU XSTATE + $2B ; $00: fill PAPER pixels, $FF: fill INK pixels
XS_PCNT         EQU XSTATE + $2E ; seeds on the Z80 stack (2 bytes)
XS_PSP          EQU XSTATE + $30 ; SP at entry, for the out-of-memory exit (2 bytes)
XS_PSX          EQU XSTATE + $32 ; seed x
XS_PSM          EQU XSTATE + $33 ; seed bit mask
XS_PSA          EQU XSTATE + $34 ; seed byte address (2 bytes)
XS_PXL          EQU XSTATE + $36 ; span: first and last x
XS_PXR          EQU XSTATE + $37
XS_PBL          EQU XSTATE + $38 ; span: first and last byte column (0-31)
XS_PBR          EQU XSTATE + $39
XS_PLM          EQU XSTATE + $3A ; span: masks of the first and last byte
XS_PRM          EQU XSTATE + $3B
XS_PROW         EQU XSTATE + $3C ; span row address (2 bytes)
XS_PNROW        EQU XSTATE + $3E ; neighbour row address (2 bytes)
XS_PNY          EQU XSTATE + $40 ; neighbour row y
XS_PCARRY       EQU XSTATE + $41 ; neighbour scan: last pixel of the previous byte
XS_PRET         EQU XSTATE + $42 ; PNEIGH return address (2 bytes)
XS_PNLIM        EQU XSTATE + $44 ; -(SPARE + PAINT_MARGIN): SP + this carries if room (2 bytes)
; DRAW arcs and LINE_TO (2 bytes each unless noted)
XS_LX           EQU XSTATE + $46 ; current line position (16-bit, may be off screen)
XS_LY           EQU XSTATE + $48
XS_LTX          EQU XSTATE + $4A ; LINE_TO target
XS_LTY          EQU XSTATE + $4C
XS_EX           EQU XSTATE + $4E ; DRAW end point
XS_EY           EQU XSTATE + $50
XS_ADX          EQU XSTATE + $52 ; DRAW dx, dy
XS_ADY          EQU XSTATE + $54
XS_AA           EQU XSTATE + $56 ; angle, degrees, reduced to -359..359
XS_SH           EQU XSTATE + $58 ; sin(a/2), cos(a/2) (Q14)
XS_CH           EQU XSTATE + $5A
XS_AVX          EQU XSTATE + $5C ; v0 = start - centre (Q2: 1/4 pixel)
XS_AVY          EQU XSTATE + $5E
XS_ATH          EQU XSTATE + $60 ; current turn, half-degrees
XS_AEND         EQU XSTATE + $62 ; |a| in half-degrees
XS_ASTEP        EQU XSTATE + $64 ; +10 or -10 (5 degrees)
XS_TC           EQU XSTATE + $66 ; cos, sin of the current turn (Q14)
XS_TS           EQU XSTATE + $68
XS_T32          EQU XSTATE + $6A ; 32-bit temporary (4 bytes)
XS_CX32         EQU XSTATE + $6E ; centre x * 2^16 + 2^15, 32-bit (4 bytes)
XS_CY32         EQU XSTATE + $72 ; centre y, the same (4 bytes)
; TURBO
XS_RAMTOP0      EQU XSTATE + $76 ; RAMTOP found by the stock RAM test at reset (2 bytes)
XS_XCFG         EQU XSTATE + $78 ; XCFG as last written by the ROM (ATTR, OPAQUE)
; SD card
XS_SDTAPE       EQU XSTATE + $79 ; 0 = tape words use the cassette, else the SD card
XS_SDERR        EQU XSTATE + $7A ; last SD error code (0 = none since reset)
XS_TDST         EQU XSTATE + $7B ; tape read: destination address (2 bytes)
XS_TLOAD        EQU XSTATE + $7D ; tape read: entry flags (bit 0 = carry = load)
XS_DIRBUF       EQU XSTATE + $80 ; DIR entry: flags, size (4), name length, name (63)
XS_DIRBUF_END   EQU XS_DIRBUF + 1 + 4 + 1 + 63
XS_NAMEBUF      EQU XS_DIRBUF   ; file name with its extension (shares DIR's buffer)
XS_XLEFT        EQU XSTATE + $C8 ; SD transfer: bytes still to move (2 bytes)
XS_XREQ         EQU XSTATE + $CA ; SD read: bytes asked for this READ (2 bytes)
XS_SDPAGE       EQU XSTATE + $CC ; SD page/screen words: the page (or screen)
XS_SAVECHR      EQU XSTATE + $CD ; FONTLOAD: the user's CHR_CPU
XS_SEED         EQU XSTATE + $CE ; RND: the random-number seed (2 bytes)
CHR_WINDOW      EQU $2C00       ; character memory as the ROM uses it (128 x 8 bytes)
FONT_SIZE       EQU 1024
        ASSERT XS_DIRBUF_END <= XSTATE + XSTATE_SIZE
