; =============================================================================
; ROM page 4: maths. Routines called through stubs in the extension dictionary
; (XSTUB, XDISPATCH): they may use RST $10 / RST $18, must keep IX and IY, and
; return with carry clear, or carry set and A = the Ace error code.
; =============================================================================

; PRND ( n -- r ): RND. 0 <= r < n (n unsigned; 0 RND gives 0).
; The seed steps as seed' = ((seed + 1) * 75 mod 65537) - 1, which visits all
; 65536 values; r = seed' * n / 65536.
PRND:
        RST $18
        PUSH DE                     ; n
        LD  HL,(XS_SEED)
        INC HL                      ; m = seed + 1
        LD  A,H
        OR  L
        JR  NZ,prnd_mul
        LD  HL,65461                ; m = 65536: 75 * 65536 mod 65537 - 1
        JR  prnd_got
prnd_mul:
        LD  B,H
        LD  C,L
        LD  HL,0
        LD  D,L                     ; D:HL = m * 75 (at most 23 bits)
        LD  A,75
        LD  E,8
prnd_ml:
        ADD HL,HL
        RL  D
        RLA                         ; next multiplier bit, top first
        JR  NC,prnd_mn
        ADD HL,BC
        JR  NC,prnd_mn
        INC D
prnd_mn:
        DEC E
        JR  NZ,prnd_ml
        LD  E,D
        LD  D,0
        AND A
        SBC HL,DE                   ; low - high = product mod 65537 ...
        JR  C,prnd_got              ; ... + 65537 - 1 if it went negative
        DEC HL                      ; ... - 1
prnd_got:
        LD  (XS_SEED),HL
        EX  DE,HL                   ; DE = seed'
        POP BC                      ; BC = n
        LD  HL,0                    ; HL:DE = seed' * n, top half kept
        LD  A,16
prnd_m2:
        AND A
        BIT 0,E
        JR  Z,prnd_ns
        ADD HL,BC
prnd_ns:
        RR  H
        RR  L
        RR  D
        RR  E
        DEC A
        JR  NZ,prnd_m2
        EX  DE,HL
        RST $10
        AND A
        RET

; PSQRTG ( f -- f g ): FSQRT's first guess, f > 0. An Ace floating-point number
; is two cells, the top one [sign + exponent (excess $40)][digits 1-2] and the
; other [digits 3-6], value 0.d1d2d3d4d5d6 x 10^(exponent - $40). With b the
; exponent: b even, g = 0.6 x 10^(b/2); b odd, g = 0.2 x 10^((b+1)/2). g is
; within a factor of 2 of the root, so 5 Newton steps give all 6 digits.
; A negative f gives ERROR 8 (the ROM's floating-point error).
PSQRTG:
        LD  HL,(SV_SPARE)
        DEC HL
        LD  A,(HL)                  ; sign and exponent
        BIT 7,A
        JR  NZ,psqrtg_neg
        SUB $40                     ; b
        LD  C,$60
        BIT 0,A
        JR  Z,psqrtg_even
        INC A
        LD  C,$20
psqrtg_even:
        SRA A
        ADD A,$40
        PUSH AF
        LD  DE,0
        RST $10                     ; digits 3-6: 0
        POP AF
        LD  D,A
        LD  E,C
        RST $10                     ; exponent, digits 1-2
        AND A
        RET
psqrtg_neg:
        LD  A,ERR_FLOAT
        SCF
        RET
