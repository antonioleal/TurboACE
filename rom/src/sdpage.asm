; =============================================================================
; ROM page 3, the SD page (register-map.md section 5, "Tape hooks").
;
; The stock tape block routines in page 1 begin with a page-flip hook into
; this page:   $1820 block write -> $1824 here,   $18A7 block read -> $18AB here.
; With SDTAPE off (the cassette) each handler repeats exactly the stock
; instructions its hook replaced and flips back to page 1 just after them, so
; the cassette behaves, and is timed, exactly as on a stock Ace.
; With SDTAPE on, the block goes to or comes from the virtual tape player of the
; soft CPU (section 2.6): flag and length as arguments, then a data phase in
; chunks of SD_CHUNK bytes, waiting for BUSY = 0 after each chunk and at the end.
; Error 9 (bad block) returns carry clear, as a bad cassette block does, so
; LOAD's header search moves on; any other error leaves through ERROR 10.
;
; Every exit is a fixed-address stub "LD A,$C1 / OUT ($E3),A" ending where the
; code must continue in page 1. The stubs below must not move.
; =============================================================================

        MACRO TO_PAGE1              ; 4 bytes; the next fetch is from page 1
        LD  A,CMD_ROMPAGE | ROMPG_MAIN
        OUT (PORT_CTRL),A
        ENDM

; ---- Fixed entries and exits --------------------------------------------------
        ORG ACE_BREAK - 4           ; BREAK: continue at $04F0 (ERROR 3)
TX_BREAK:
        TO_PAGE1
        ASSERT $ == ACE_BREAK

        ORG ACE_TAPE_WRITE + 4      ; $1824: entry from the block-write hook
        JP  TWRITE_HOOK
        ORG ACE_TAPE_WRITE_RESUME - 4   ; $1828: cassette write, on to $182C
TX_WRITE_TAPE:
        TO_PAGE1
        ASSERT $ == ACE_TAPE_WRITE_RESUME

        ORG ACE_TAPE_RET - 4        ; $18A2: SD done, on to the RET at $18A6
TX_RET:
        TO_PAGE1
        ASSERT $ == ACE_TAPE_RET
        ASSERT $ + 1 == ACE_TAPE_READ    ; the next stub starts at $18A7
        ORG ACE_TAPE_READ           ; $18A7: cassette read, on to $18AB
TX_READ_TAPE:
        TO_PAGE1
        ASSERT $ == ACE_TAPE_READ_RESUME
        JP  TREAD_HOOK              ; $18AB: entry from the block-read hook

        ORG ACE_ERROR10 - 4         ; $1AB2: end of tape, on to ERROR 10
TX_ERROR10:
        TO_PAGE1
        ASSERT $ == ACE_ERROR10

; ---- Handlers -------------------------------------------------------------------
        ORG LOWFREE_F               ; $0865 onwards, below the stubs at $1824

; TWRITE_HOOK: block write. In: HL address, DE length, C flag. A is free (the
; hook used it; the stock routine writes A before reading it).
TWRITE_HOOK:
        LD  A,(XS_SDTAPE)
        OR  A
        JR  NZ,twrite_sd
twrite_tape:                        ; repeat $1820-$182B exactly
        PUSH IY
        PUSH HL
        POP IY
        LD  HL,ACE_TAPE_EXIT
        PUSH HL
        LD  HL,ACE_TAPE_LEADER
        JP  TX_WRITE_TAPE
twrite_sd:                          ; TWRITE: flag, length; then the data phase
        LD  A,C
        OUT (PORT_SDDATA),A
        LD  A,E
        OUT (PORT_SDDATA),A
        LD  A,D
        OUT (PORT_SDDATA),A
        LD  A,SDC_TWRITE
        CALL SD_COMMAND
        JP  C,tape_sd_err10
twr_chunk:
        LD  A,D
        OR  E
        JP  Z,tape_sd_ok
        LD  BC,SD_CHUNK
twr_byte:
        LD  A,(HL)
        OUT (PORT_SDDATA),A
        INC HL
        DEC DE
        LD  A,D
        OR  E
        JR  Z,twr_last
        DEC BC
        LD  A,B
        OR  C
        JR  NZ,twr_byte
        CALL SD_WAIT                ; chunk written
        JP  C,tape_sd_err10
        JR  twr_chunk
twr_last:
        CALL SD_WAIT                ; last chunk written and flushed
        JP  C,tape_sd_err10
        JP  tape_sd_ok

; TREAD_HOOK: block read. In: HL address, DE length, C flag, carry set = load
; (must survive). A is free.
TREAD_HOOK:
        PUSH AF                     ; keep the carry argument
        LD  A,(XS_SDTAPE)
        OR  A
        JR  NZ,tread_sd
        POP AF
tread_tape:                         ; repeat $18A7-$18AA exactly
        DI
        PUSH IY
        PUSH HL
        JP  TX_READ_TAPE
tread_sd:                           ; stack: entry AF, caller's return address
        LD  (XS_TDST),HL
        POP HL                      ; entry AF
        LD  A,L
        LD  (XS_TLOAD),A            ; bit 0: carry = load, else verify
        POP HL                      ; the caller's return address ...
        PUSH HL                     ; ... stays stacked
        LD  B,0                     ; search = 1 when called from LOAD's search,
        LD  A,L                     ; 2 when that LOAD has no name (from the start)
        CP  LOW ACE_LOAD_SEARCH
        JR  NZ,trd_args
        LD  A,H
        CP  HIGH ACE_LOAD_SEARCH
        JR  NZ,trd_args
        INC B
        LD  HL,ACE_LOAD_WANTED + 1  ; the wanted name
        LD  A,(HL)
        OR  A
        JR  Z,trd_blank
        PUSH BC
        LD  B,10
        LD  A,' '
trd_name:
        CP  (HL)
        JR  NZ,trd_named
        INC HL
        DJNZ trd_name
        POP BC                      ; all spaces
trd_blank:
        LD  B,2
        JR  trd_args
trd_named:
        POP BC
trd_args:                           ; TREAD: flag, length, search
        LD  A,C
        OUT (PORT_SDDATA),A
        LD  A,E
        OUT (PORT_SDDATA),A
        LD  A,D
        OUT (PORT_SDDATA),A
        LD  A,B
        OUT (PORT_SDDATA),A
        LD  A,SDC_TREAD
        CALL SD_COMMAND
        JR  C,trd_fail
        LD  HL,(XS_TDST)
        LD  A,(XS_TLOAD)
        RRA
        JR  NC,trd_verify
trd_load:
        LD  A,D
        OR  E
        JR  Z,trd_end
        LD  BC,SD_CHUNK
trd_lbyte:
        IN  A,(PORT_SDDATA)
        LD  (HL),A
        INC HL
        DEC DE
        LD  A,D
        OR  E
        JR  Z,trd_end
        DEC BC
        LD  A,B
        OR  C
        JR  NZ,trd_lbyte
        CALL SD_WAIT                ; next chunk ready
        JR  C,trd_fail
        JR  trd_load
trd_verify:
        LD  A,D
        OR  E
        JR  Z,trd_end
        LD  BC,SD_CHUNK
trd_vbyte:
        IN  A,(PORT_SDDATA)
        CP  (HL)
        JP  NZ,tape_sd_no           ; differs (the next command drops the rest)
        INC HL
        DEC DE
        LD  A,D
        OR  E
        JR  Z,trd_end
        DEC BC
        LD  A,B
        OR  C
        JR  NZ,trd_vbyte
        CALL SD_WAIT
        JR  C,trd_fail
        JR  trd_verify
trd_end:
        CALL SD_WAIT                ; final status: the checksum
        JP  NC,tape_sd_ok
trd_fail:                           ; A = error code
        CP  SDE_BADBLOCK
        JP  Z,tape_sd_no
        ; fall into tape_sd_err10

; ---- SD exits back to page 1 ----------------------------------------------------
tape_sd_err10:                      ; any error but a bad block: ERROR 10
        POP HL                      ; drop the return address, as the ROM does
        EI
        JP  TX_ERROR10
tape_sd_ok:
        LD  C,1                     ; success: carry set on return
        JR  tape_sd_ret
tape_sd_no:
        LD  C,0                     ; failed block: carry clear
tape_sd_ret:
        LD  A,$7F                   ; BREAK (SPACE), as the ROM's exit at $1892
        IN  A,($FE)
        RRA
        JR  NC,tape_sd_break
        LD  A,C
        RRA                         ; carry = result
        EI
        JP  TX_RET                  ; on to the RET at $18A6
tape_sd_break:
        EI
        JP  TX_BREAK                ; ERROR 3, return address still stacked

; ---- Routines for the SD words (reached through XDISPATCH) -------------------
; Return carry clear, or carry set with A = ERR_TAPE (ERROR 10); the SD error
; code is in XS_SDERR. They keep IX and IY.

; SD_TAPE_INSERT: DE = counted name (TAPE). TINSERT, then SDTAPE on.
SD_TAPE_INSERT:
        LD  C,SDC_TINSERT
        CALL sd_name_command
        RET C
        LD  A,1
        LD  (XS_SDTAPE),A
        OR  A                       ; carry clear
        RET

; SD_CD / SD_DELETE: DE = counted name (CD, DELETE).
SD_CD:
        LD  C,SDC_CHDIR
        JR  sd_name_command
SD_DELETE:
        LD  C,SDC_DELETE
        ; fall into sd_name_command

; sd_name_command: send the counted name at DE, then command C.
sd_name_command:
        LD  A,(DE)
        OR  A
        JR  Z,sd_bad_name           ; no name
        CP  SD_NAME_MAX + 1
        JR  NC,sd_bad_name          ; too long
        EX  DE,HL
        LD  B,A
        INC B                       ; the length byte and the characters
sdnc_send:
        LD  A,(HL)
        OUT (PORT_SDDATA),A
        INC HL
        DJNZ sdnc_send
        LD  A,C
        CALL SD_COMMAND
        RET NC
        JR  sd_word_error

; SD_DIR_ENTRY: E = 0 first entry (DIRFIRST, all names), else the next one.
; The entry goes to XS_DIRBUF: flags ($FF = no more), size (4), name (counted).
SD_DIR_ENTRY:
        LD  A,E
        OR  A
        LD  A,SDC_DIRNEXT
        JR  NZ,sdde_cmd
        XOR A
        OUT (PORT_SDDATA),A         ; pattern: empty = all
        LD  A,SDC_DIRFIRST
sdde_cmd:
        CALL SD_COMMAND
        JR  C,sd_word_error
        LD  HL,XS_DIRBUF
        IN  A,(PORT_SDDATA)         ; flags
        LD  (HL),A
        INC HL
        CP  $FF
        JR  Z,sdde_done
        LD  B,4                     ; size
sdde_size:
        IN  A,(PORT_SDDATA)
        LD  (HL),A
        INC HL
        DJNZ sdde_size
        IN  A,(PORT_SDDATA)         ; name length
        CP  SD_NAME_MAX + 1
        JR  C,sdde_len
        LD  A,SD_NAME_MAX           ; keep at most 63 characters
sdde_len:
        LD  (HL),A
        INC HL
        OR  A
        JR  Z,sdde_done
        LD  B,A
sdde_name:
        IN  A,(PORT_SDDATA)
        LD  (HL),A
        INC HL
        DJNZ sdde_name
sdde_done:
        AND A                       ; carry clear
        RET

; SD_TAPE_EJECT: TEJECT (EJECT). SDTAPE stays as it is.
SD_TAPE_EJECT:
        LD  A,SDC_TEJECT
        CALL SD_COMMAND
        RET NC
        JR  sd_word_error

sd_bad_name:
        LD  A,SDE_BADNAME
        LD  (XS_SDERR),A
sd_word_error:
        LD  A,ERR_TAPE
        SCF
        RET

; ---- Pages and screens (PGSAVE, PGLOAD, SCRSAVE, SCRLOAD) -----------------------
; In: B = page (0-63) or screen (0-31), DE = counted name from WORD.
; The user's two windows are restored on every way out.

SD_PG_SAVE:
        LD  HL,ext_pg
        CALL sd_page_setup          ; name.PG, window 0 = page B
        RET C
        LD  C,SDC_OPENW
        LD  DE,SD_PAGE_SIZE
        JR  sd_save_common
SD_SCR_SAVE:
        LD  HL,ext_scr
        CALL sd_screen_setup        ; name.SCR, windows = pages 2n, 2n+1
        RET C
        LD  DE,SD_SCREEN_SIZE
sd_save_common:
        PUSH DE
        LD  C,SDC_OPENW
        LD  DE,XS_NAMEBUF
        CALL sd_name_command
        POP DE
        JR  C,sd_xfer_fail
        LD  HL,HIRES_WINDOW
        CALL sd_write_mem
        JR  sd_xfer_close

SD_PG_LOAD:
        LD  HL,ext_pg
        CALL sd_page_setup
        RET C
        LD  DE,SD_PAGE_SIZE
        JR  sd_load_common
SD_SCR_LOAD:
        LD  HL,ext_scr
        CALL sd_screen_setup
        RET C
        LD  DE,SD_SCREEN_SIZE
sd_load_common:
        PUSH DE
        LD  C,SDC_OPENR
        LD  DE,XS_NAMEBUF
        CALL sd_name_command
        POP DE
        JR  C,sd_xfer_fail
        LD  B,4                     ; the file's size: not needed
sdlc_size:
        IN  A,(PORT_SDDATA)
        DJNZ sdlc_size
        LD  HL,HIRES_WINDOW
        CALL sd_read_mem            ; a shorter file loads only what it has
sd_xfer_close:
        JR  C,sd_xfer_fail
        LD  A,SDC_CLOSE
        CALL SD_COMMAND
        JR  C,sd_xfer_fail
        CALL sd_restore_windows
        AND A                       ; carry clear
        RET
sd_xfer_fail:
        CALL sd_restore_windows
        JP  sd_word_error

; sd_page_setup: name.ext from DE (ext at HL); window 0 = page B. Carry: error.
sd_page_setup:
        LD  A,B
        AND PAGE_MASK
        LD  (XS_SDPAGE),A
        CALL sd_make_name
        RET C
        CALL sd_save_windows
        LD  A,(XS_SDPAGE)
        OUT (PORT_PAGE),A
        AND A
        RET

; sd_screen_setup: name.ext; windows 0/1 = pages 2n, 2n+1 of screen B.
sd_screen_setup:
        LD  A,B
        AND PARAM_MASK
        ADD A,A
        LD  (XS_SDPAGE),A
        CALL sd_make_name
        RET C
        CALL sd_save_windows
        LD  A,(XS_SDPAGE)
        OUT (PORT_PAGE),A
        INC A
        OR  PAGE_WIN1
        OUT (PORT_PAGE),A
        AND A
        RET

sd_save_windows:
        XOR A
        IN  A,(PORT_PAGE)
        AND PAGE_MASK
        LD  (XS_SAVEPG),A
        LD  A,PAGE_WIN1
        IN  A,(PORT_PAGE)
        AND PAGE_MASK
        LD  (XS_SAVEPG1),A
        RET

sd_restore_windows:                 ; keeps the flags
        PUSH AF
        LD  A,(XS_SAVEPG)
        OUT (PORT_PAGE),A
        LD  A,(XS_SAVEPG1)
        OR  PAGE_WIN1
        OUT (PORT_PAGE),A
        POP AF
        RET

; sd_make_name: XS_NAMEBUF = counted name at DE + counted extension at HL.
; Carry set (ERROR 10, SDERR 6) if the name is empty or too long.
sd_make_name:
        LD  A,(DE)
        OR  A
        JP  Z,sd_bad_name
        LD  C,A
        ADD A,(HL)
        CP  SD_NAME_MAX + 1
        JP  NC,sd_bad_name
        LD  (XS_NAMEBUF),A
        PUSH HL
        EX  DE,HL
        INC HL
        LD  DE,XS_NAMEBUF + 1
        LD  B,0
        LDIR                        ; the name
        POP HL
        LD  C,(HL)
        INC HL
        LDIR                        ; the extension
        AND A
        RET

; SD_FONT_LOAD: B = font (0-31), DE = counted name. Loads name.FNT into the
; character memory of font B, through CHR_CPU, which is restored afterwards.
SD_FONT_LOAD:
        LD  A,B
        AND PARAM_MASK
        LD  (XS_SDPAGE),A
        LD  HL,ext_fnt
        CALL sd_make_name
        RET C
        LD  A,CMD_CHR_CPU
        IN  A,(PORT_CTRL)           ; 000ppppp
        AND PARAM_MASK
        LD  (XS_SAVECHR),A
        LD  C,SDC_OPENR
        LD  DE,XS_NAMEBUF
        CALL sd_name_command
        JP  C,sd_word_error
        LD  B,4                     ; the file's size: not needed
sdfl_size:
        IN  A,(PORT_SDDATA)
        DJNZ sdfl_size
        LD  A,(XS_SDPAGE)
        OR  CMD_CHR_CPU
        OUT (PORT_CTRL),A           ; the CPU now writes font B
        LD  HL,CHR_WINDOW
        LD  DE,FONT_SIZE
        CALL sd_read_mem            ; a shorter file loads only what it has
        JR  C,sdfl_fail
        LD  A,SDC_CLOSE
        CALL SD_COMMAND
        JR  C,sdfl_fail
        CALL sdfl_restore
        AND A
        RET
sdfl_fail:
        CALL sdfl_restore
        JP  sd_word_error
sdfl_restore:                       ; the user's CHR_CPU back; keeps the flags
        PUSH AF
        LD  A,(XS_SAVECHR)
        OR  CMD_CHR_CPU
        OUT (PORT_CTRL),A
        POP AF
        RET

ext_fnt: DB  4, ".FNT"
ext_pg:  DB  3, ".PG"
ext_scr: DB  4, ".SCR"

SD_PAGE_SIZE    EQU 8192
SD_SCREEN_SIZE  EQU 12288           ; bitmap 6K + colour 6K at $C000-$EFFF

; sd_write_mem: WRITE DE bytes from HL, as WRITE commands of at most 8192
; bytes, each with its data phase. Carry set on error (A = code).
sd_write_mem:
        LD  (XS_XLEFT),DE
swm_loop:
        LD  DE,(XS_XLEFT)
        LD  A,D
        OR  E
        RET Z                       ; done (carry clear)
        LD  A,D
        CP  HIGH SD_XFER_MAX
        JR  C,swm_count
        LD  DE,SD_XFER_MAX
swm_count:
        PUSH HL
        LD  HL,(XS_XLEFT)
        AND A
        SBC HL,DE
        LD  (XS_XLEFT),HL
        POP HL
        LD  A,E
        OUT (PORT_SDDATA),A
        LD  A,D
        OUT (PORT_SDDATA),A
        LD  A,SDC_WRITE
        CALL SD_COMMAND
        RET C
swm_chunk:                          ; data phase: DE bytes from HL
        LD  BC,SD_CHUNK
swm_byte:
        LD  A,(HL)
        OUT (PORT_SDDATA),A
        INC HL
        DEC DE
        LD  A,D
        OR  E
        JR  Z,swm_last
        DEC BC
        LD  A,B
        OR  C
        JR  NZ,swm_byte
        CALL SD_WAIT
        RET C
        JR  swm_chunk
swm_last:
        CALL SD_WAIT                ; written and flushed
        RET C
        JR  swm_loop

; sd_read_mem: READ up to DE bytes to HL, as READ commands of at most 8192
; bytes; stops early at the end of the file. Carry set on error.
sd_read_mem:
        LD  (XS_XLEFT),DE
srm_loop:
        LD  DE,(XS_XLEFT)
        LD  A,D
        OR  E
        RET Z
        LD  A,D
        CP  HIGH SD_XFER_MAX
        JR  C,srm_count
        LD  DE,SD_XFER_MAX
srm_count:
        LD  (XS_XREQ),DE
        LD  A,E
        OUT (PORT_SDDATA),A
        LD  A,D
        OUT (PORT_SDDATA),A
        LD  A,SDC_READ
        CALL SD_COMMAND
        RET C
        IN  A,(PORT_SDDATA)         ; the count actually read
        LD  E,A
        IN  A,(PORT_SDDATA)
        LD  D,A
        PUSH HL
        LD  HL,(XS_XLEFT)
        AND A
        SBC HL,DE
        LD  (XS_XLEFT),HL
        POP HL
        LD  A,D
        OR  E
        RET Z                       ; end of the file
        PUSH DE
srm_chunk:                          ; data phase: DE bytes to HL
        LD  BC,SD_CHUNK
srm_byte:
        IN  A,(PORT_SDDATA)
        LD  (HL),A
        INC HL
        DEC DE
        LD  A,D
        OR  E
        JR  Z,srm_last
        DEC BC
        LD  A,B
        OR  C
        JR  NZ,srm_byte
        CALL SD_WAIT
        JR  C,srm_fail
        JR  srm_chunk
srm_last:
        CALL SD_WAIT
        POP DE                      ; the count read
        RET C
        PUSH HL
        LD  HL,(XS_XREQ)
        AND A
        SBC HL,DE
        POP HL
        JR  Z,srm_loop              ; got all it asked for: go on
        AND A                       ; fewer: the end of the file
        RET
srm_fail:
        POP DE
        RET                         ; carry still set

; ---- SD protocol --------------------------------------------------------------

; SD_COMMAND: start command A, wait until done. Carry set on error, A = code.
SD_COMMAND:
        OUT (PORT_SDCMD),A
        ; fall into SD_WAIT

; SD_WAIT: wait until BUSY = 0 (gives up after roughly 20 seconds: error 5).
; Carry clear if all is well; carry set on error with A = the error code, which
; is also kept in XS_SDERR. Preserves BC, DE, HL.
SD_WAIT:
        PUSH BC
        PUSH DE
        LD  BC,0
        LD  D,32
sd_wait_loop:
        IN  A,(PORT_SDCMD)
        BIT SDS_BUSY,A
        JR  Z,sd_wait_done
        DEC BC
        LD  A,B
        OR  C
        JR  NZ,sd_wait_loop
        DEC D
        JR  NZ,sd_wait_loop
        LD  A,SDE_IO                ; no answer: I/O error
        JR  sd_wait_err
sd_wait_done:
        AND 1 << SDS_ERROR          ; clears the carry
        JR  Z,sd_wait_ret
        IN  A,(PORT_SDDATA)         ; the error code
sd_wait_err:
        LD  (XS_SDERR),A
        SCF
sd_wait_ret:
        POP DE
        POP BC
        RET

SDPAGE_END:
        ASSERT SDPAGE_END <= ACE_TAPE_WRITE + 4    ; handlers stay below the $1824 entry
