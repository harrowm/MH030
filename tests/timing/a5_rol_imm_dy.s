; tests/timing/a5_rol_imm_dy.s -- Phase 161 Part A Stage A5: SHIFT_ROTATE 'ROd #(data),Dy'
; MC68030UM.pdf 11-45/46/47: ROL.L #1,Dy NCC=6(0/1/0)
;
;   rol.l   #1,d2
        org     0
        dc.l    $00010000
        dc.l    start

start:
        move.l  #1,d2
        bra.w   target

        org     $200
target:
        rol.l   #1,d2
after:
        stop    #$2700
        dc.w    $2700
