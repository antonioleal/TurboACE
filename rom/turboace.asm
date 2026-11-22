; =============================================================================
; TurboACE ROM - 8 x 8K pages (register-map.md v0.4, section 5)
;
;   page 0  stock Jupiter Ace ROM, byte-identical      (-2 TURBO: stock until reset)
;   page 1  stock ROM + boot hook at $008E and tape hooks at $1820, $18A7
;           (reset; 0, 1 and -1 TURBO)
;   page 2  boot page: setup, XDICT image, graphics
;   page 3  SD page: tape-hook handlers (cassette and SD paths)
;   page 4  maths: RND, the FSQRT first guess (src/mathpage.asm)
;   page 5-6 extension code (empty for now)
;   page 7  reserved
;
; Assembler: sjasmplus 1.20.3 (in ../tools/sjasmplus). Build with the Makefile, which
; first checks the stock ROM image and copies it to build/stock.rom.
; Static checks: tools/misc/romcheck.py (make check). DRAW/CIRCLE: ../test.
; =============================================================================

        DEVICE NOSLOT64K

        INCLUDE "inc/hw.inc"
        INCLUDE "inc/ace_internal.inc"
        INCLUDE "inc/ace_words.inc"
        INCLUDE "src/lowcopy.asm"

; ---- Page 0: stock ROM --------------------------------------------------------
        ORG $0000
        INCBIN "build/stock.rom"
        SAVEBIN "build/page0.bin", $0000, $2000

; ---- Page 1: stock ROM + boot hook ----------------------------------------------
        ORG $0000
        INCBIN "build/stock.rom"
        ORG ACE_BOOT_HOOK           ; replaces ED 56 18 09 (IM 1 / JR $009B)
        LD  A,CMD_ROMPAGE | ROMPG_BOOT
        OUT (PORT_CTRL),A           ; next fetch comes from page 2, $0092
        ASSERT $ == BOOT_ENTRY
        ORG ACE_TAPE_WRITE          ; replaces PUSH IY / PUSH HL / first byte of POP IY
        LD  A,CMD_ROMPAGE | ROMPG_EXT3
        OUT (PORT_CTRL),A           ; next fetch: page 3, $1824 (JP TWRITE_HOOK)
        ASSERT $ == ACE_TAPE_WRITE + 4
        ORG ACE_TAPE_READ           ; replaces DI / PUSH IY / PUSH HL
        LD  A,CMD_ROMPAGE | ROMPG_EXT3
        OUT (PORT_CTRL),A           ; next fetch: page 3, $18AB (JP TREAD_HOOK)
        ASSERT $ == ACE_TAPE_READ_RESUME
        SAVEBIN "build/page1.bin", $0000, $2000

; ---- Page 2: boot page ----------------------------------------------------------
        ORG $0000
        BLOCK $2000, $FF
        LOWCOPY

        ORG BOOT_ENTRY
        JP  BOOT_SETUP
        ASSERT $ <= BOOT_EXIT
        ORG BOOT_EXIT
        LD  A,CMD_ROMPAGE | ROMPG_MAIN
        ASSERT $ == BOOT_EXIT_OUT   ; also entered here by HSTOCK, A = page 0
        OUT (PORT_CTRL),A           ; next fetch is $009B (QUIT) in the new page
        ASSERT $ == ACE_QUIT_CODE

        ORG LOWFREE_F               ; main code area $0865-$1FFF
XDICT_IMAGE:
        DISP XDICT_BASE
        INCLUDE "src/xdict.asm"
XDICT_IMAGE_END:
        ENT
XDICT_LEN       EQU XDICT_IMAGE_END - XDICT_BASE
        ASSERT XDICT_LEN <= XSTATE - XDICT_BASE     ; must stay below $3B00

        INCLUDE "src/boot.asm"
        INCLUDE "src/gfx.asm"
PAGE2_END:
        ASSERT PAGE2_END <= $2000
        SAVEBIN "build/page2.bin", $0000, $2000

; ---- Page 3: SD page -------------------------------------------------------------
        ORG $0000
        BLOCK $2000, $FF
        LOWCOPY
        INCLUDE "src/sdpage.asm"
        SAVEBIN "build/page3.bin", $0000, $2000

; ---- Page 4: maths ----------------------------------------------------------------
        ORG $0000
        BLOCK $2000, $FF
        LOWCOPY
        ORG LOWFREE_F
        INCLUDE "src/mathpage.asm"
PAGE4_END:
        ASSERT PAGE4_END <= $2000
        SAVEBIN "build/page4.bin", $0000, $2000

; ---- Pages 5-7: interrupt-safe, otherwise empty ---------------------------------
        ORG $0000
        BLOCK $2000, $FF
        LOWCOPY
        SAVEBIN "build/page5.bin", $0000, $2000
        SAVEBIN "build/page6.bin", $0000, $2000
        SAVEBIN "build/page7.bin", $0000, $2000
