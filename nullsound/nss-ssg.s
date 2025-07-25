;;;
;;; nullsound - modular sound driver
;;; Copyright (c) 2024-2025 Damien Ciabrini
;;; This file is part of ngdevkit
;;;
;;; ngdevkit is free software: you can redistribute it and/or modify
;;; it under the terms of the GNU Lesser General Public License as
;;; published by the Free Software Foundation, either version 3 of the
;;; License, or (at your option) any later version.
;;;
;;; ngdevkit is distributed in the hope that it will be useful,
;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU Lesser General Public License for more details.
;;;
;;; You should have received a copy of the GNU Lesser General Public License
;;; along with ngdevkit.  If not, see <http://www.gnu.org/licenses/>.

;;; NSS opcode for SSG channels
;;;

        .module nullsound

        .include "align.inc"
        .include "ym2610.inc"
        .include "struct-fx.inc"
        .include "pipeline.inc"


        .lclequ SSG_STATE_SIZE,(state_mirrored_ssg_end-state_mirrored_ssg_start)
        .lclequ SSG_MAX_VOL,0xf

        ;; getters for SSG state
        .lclequ DETUNE,(state_ssg_detune-state_mirrored_ssg)
        .lclequ NOTE_POS16,(state_ssg_note_pos16-state_mirrored_ssg)
        .lclequ NOTE_FINE_COARSE,(state_ssg_note_fine_coarse-state_mirrored_ssg)
        .lclequ PROPS_OFFSET,(state_mirrored_ssg_props-state_mirrored_ssg)
        .lclequ ENVELOPE_OFFSET,(state_mirrored_ssg_envelope-state_mirrored_ssg)
        .lclequ WAVEFORM_OFFSET,(state_mirrored_ssg_waveform-state_mirrored_ssg)
        .lclequ ARPEGGIO,(state_ssg_arpeggio-state_mirrored_ssg)
        .lclequ MACRO_DATA,(state_ssg_macro_data-state_mirrored_ssg)
        .lclequ MACRO_POS,(state_ssg_macro_pos-state_mirrored_ssg)
        .lclequ MACRO_LOAD,(state_ssg_macro_load-state_mirrored_ssg)
        .lclequ REG_VOL, (state_ssg_reg_vol-state_mirrored_ssg)
        .lclequ OUT_VOL, (state_ssg_out_vol-state_mirrored_ssg)

        ;; specific pipeline state for SSG channel
        .lclequ STATE_LOAD_WAVEFORM, 0x20
        .lclequ BIT_LOAD_WAVEFORM,      5



        .area  DATA


;;; SSG playback state tracker
;;; ------
        ;; This padding ensures the entire _state_ssg data sticks into
        ;; a single 256 byte boundary to make 16bit arithmetic faster
        .blkb   ALIGN_OFFSET_SSG

_state_ssg_start:

;;; context: current SSG channel for opcode actions
state_ssg_channel::
        .blkb   1

;;; YM2610 mirrored state
;;; ------
;;; used to compute final register values to be loaded into the YM2610

;;; merged waveforms of all SSG channels for REG_SSG_ENABLE
state_mirrored_enabled:
        .blkb   1

;;; SSG A
state_mirrored_ssg_a:
;;; state
state_mirrored_ssg_start:
;;; additional note and FX state tracker
state_ssg_note_fx:              .blkb   1       ; enabled note FX for this channel
state_ssg_note_cfg:             .blkb   1       ; configured note
state_ssg_note16:               .blkb   2       ; current decimal note
state_ssg_fx_note_slide:        .blkb   SLIDE_SIZE
state_ssg_fx_vibrato:           .blkb   VIBRATO_SIZE
state_ssg_fx_arpeggio:          .blkb   ARPEGGIO_SIZE
state_ssg_fx_legato:            .blkb   LEGATO_SIZE
;;; stream pipeline
state_mirrored_ssg:
state_ssg_pipeline:             .blkb   1       ; actions to run at every tick (eval macro, load note, vol, other regs)
state_ssg_fx:                   .blkb   1       ; enabled FX for this channel
;;; volume state tracker
state_ssg_vol_cfg:              .blkb   1       ; configured volume
state_ssg_vol16:                .blkb   2       ; current decimal volume
;;; FX state trackers
state_ssg_fx_vol_slide:         .blkb   SLIDE_SIZE
state_ssg_trigger:              .blkb   TRIGGER_SIZE
;;; SSG-specific state
;;; Note
state_ssg_note_pos16:           .blkb   2       ; fixed-point note after the FX pipeline
state_ssg_detune:               .blkb   2       ; fixed-point semitone detune
state_ssg_note_fine_coarse:     .blkb   2       ; YM2610 note factors (fine+coarse)
state_mirrored_ssg_props:
state_mirrored_ssg_envelope:    .blkb   1       ; envelope shape
                                .blkb   1       ; vol envelope fine
                                .blkb   1       ; vol envelope coarse
state_ssg_reg_vol:              .blkb   1       ; mode+volume
state_mirrored_ssg_waveform:    .blkb   1       ; noise+tone (shifted per channel)
state_ssg_arpeggio:             .blkb   1       ; arpeggio (semitone shift)
state_ssg_macro_data:           .blkb   2       ; address of the start of the macro program
state_ssg_macro_pos:            .blkb   2       ; address of the current position in the macro program
state_ssg_macro_load:           .blkb   2       ; function to load the SSG registers modified by the macro program
state_ssg_out_vol:              .blkb   1       ; ym2610 volume for SSG channel after the FX pipeline
state_mirrored_ssg_end:
;;; SSG B
state_mirrored_ssg_b:
        .blkb   SSG_STATE_SIZE
;;; SSG C
state_mirrored_ssg_c:
        .blkb   SSG_STATE_SIZE

;;; Global volume attenuation for all SSG channels
state_ssg_volume_attenuation::       .blkb   1

_state_ssg_end:



        .area  CODE


;;; context: channel action functions for SSG
state_ssg_action_funcs:
        .dw     ssg_configure_note_on
        .dw     ssg_configure_vol
        .dw     ssg_stop_playback


;;;  Reset SSG playback state.
;;;  Called before playing a stream
;;; ------
;;; bc, de, hl modified
init_nss_ssg_state_tracker::
        ld      hl, #_state_ssg_start
        ld      d, h
        ld      e, l
        inc     de
        ld      (hl), #0
        ld      bc, #_state_ssg_end-2-_state_ssg_start
        ldir
        ;; init non-zero default values
        ld      d, #4
        ld      iy, #state_mirrored_ssg
        ld      bc, #SSG_STATE_SIZE
_ssg_init:
        ;; FX defaults
        ld      NOTE_CTX+SLIDE_MAX(iy), #((8*12)-1) ; max note
        ld      VOL_CTX+SLIDE_MAX(iy), #SSG_MAX_VOL ; max volume for channel
        ld      ARPEGGIO_SPEED(iy), #1   ; default arpeggio speed
        add     iy, bc
        dec     d
        jr      nz, _ssg_init
        ;; global SSG volume is initialized in the volume state tracker
        ld      a, #0x3f
        ld      (state_mirrored_enabled), a
        ret


;;;
;;; Macro instrument - internal functions
;;;

;;; eval_macro_step
;;; update the mirror state for a SSG channel based on
;;; the macro program configured for this channel
;;; ------
;;; bc, de, hl modified
eval_macro_step::
        ;; de: state_mirrored_ssg_props (8bit add)
        push    ix
        pop     de
        ld      a, e
        add     #PROPS_OFFSET
        ld      e, a

        ;; hl: macro location ptr
        ld      l, MACRO_POS(ix)
        ld      h, MACRO_POS+1(ix)

        ;; update mirrored state with macro values
        ld      a, (hl)
        inc     hl
_upd_macro:
        cp      a, #0xff
        jp      z, _end_upd_macro
        ;; de: next offset in mirrored state (8bit add)
        add     a, e
        ld      e, a
        ;; (de): (hl)
        ldi
        ld      a, (hl)
        inc     hl
        jp      _upd_macro
_end_upd_macro:
        ;; update load flags for this macro step
        ld      a, PIPELINE(ix)
        or      (hl)
        inc     hl
        ld      PIPELINE(ix), a
        ;; did we reached the end of macro
        ld      a, (hl)
        cp      a, #0xff
        jp      nz, _finish_macro_step
        ;; end of macro, set loop/no-loop information
        ;; the load bits have been set in the previous step
        inc     hl
        ld      a, (hl)
        ld      MACRO_POS(ix), a
        inc     hl
        ld      a, (hl)
        ld      MACRO_POS+1(ix), a
        ret
_finish_macro_step:
        ;; keep track of the current location for the next call
        ld      MACRO_POS(ix), l
        ld      MACRO_POS+1(ix), h
        ret


;;; Set the current SSG channel and SSG state context
;;; ------
;;;   a : SSG channel
ssg_ctx_set_current::
        ld      (state_ssg_channel), a
        ld      ix, #state_mirrored_ssg
        push    bc
        bit     0, a
        jr      z, _ssg_ctx_post_bit0
        ld      bc, #SSG_STATE_SIZE
        add     ix, bc
_ssg_ctx_post_bit0:
        bit     1, a
        jr      z, _ssg_ctx_post_bit1
        ld      bc, #SSG_STATE_SIZE*2
        add     ix, bc
_ssg_ctx_post_bit1:
        pop     bc
        ret


;;; run_ssg_pipeline
;;; ------
;;; Run the entire SSG pipeline once. for each SSG channels:
;;;  - run a single round of macro steps configured
;;;  - update the state of all enabled FX
;;;  - load specific parts of the state (note, vol...) into YM2610 registers
;;; Meant to run once per tick
run_ssg_pipeline::
        push    de
        ;; TODO should we consider IX and IY scratch registers?
        push    iy
        push    ix

        ;; we loop though every channel during the execution,
        ;; so save the current channel context
        ld      a, (state_ssg_channel)
        push    af

        ;; update mirrored state of all SSG channels, starting from SSGA
        xor     a

_update_loop:
        call    ssg_ctx_set_current

        ;; bail out if the current channel is not in use
        ld      a, PIPELINE(ix)
        or      a, FX(ix)
        or      a, NOTE_FX(ix)
        cp      #0
        jp      z, _end_ssg_channel_pipeline

        ;; Pipeline action: evaluate one macro step to update current state
        bit     BIT_EVAL_MACRO, PIPELINE(ix)
        jr      z, _ssg_pipeline_post_macro
        res     BIT_EVAL_MACRO, PIPELINE(ix)

        ;; the macro evaluation decides whether or not to load
        ;; registers later in the pipeline, and if we must continue
        ;; to evaluation the macro during the next pipeline run
        call    eval_macro_step
_ssg_pipeline_post_macro::


        ;; Pipeline action: evaluate one FX step for each enabled FX

        ;; misc FX
        bit     BIT_FX_TRIGGER, FX(ix)
        jr      z, _ssg_post_fx_trigger
        ld      hl, #state_ssg_action_funcs
        call    eval_trigger_step
_ssg_post_fx_trigger:

        ;; iy: FX state for channel
        push    ix
        pop     iy
        ld      bc, #VOL_CTX
        add     iy, bc

        bit     BIT_FX_SLIDE, FX(ix)
        jr      z, _ssg_post_fx_vol_slide
        call    eval_slide_step
        set     #BIT_LOAD_VOL, PIPELINE(ix)
_ssg_post_fx_vol_slide:

        ;; iy: note FX state for channel
        push    ix
        pop     iy
        ld      bc, #NOTE_CTX
        add     iy, bc

        bit     BIT_FX_SLIDE, NOTE_FX(ix)
        jr      z, _ssg_post_fx_slide
        call    eval_slide_step
        set     BIT_LOAD_NOTE, PIPELINE(ix)
_ssg_post_fx_slide:
        bit     BIT_FX_VIBRATO, NOTE_FX(ix)
        jr      z, _ssg_post_fx_vibrato
        call    eval_vibrato_step
        set     BIT_LOAD_NOTE, PIPELINE(ix)
_ssg_post_fx_vibrato:
        bit     BIT_FX_ARPEGGIO, NOTE_FX(ix)
        jr      z, _ssg_post_fx_arpeggio
        call    eval_arpeggio_step
        set     BIT_LOAD_NOTE, PIPELINE(ix)
_ssg_post_fx_arpeggio:
        bit     BIT_FX_QUICK_LEGATO, NOTE_FX(ix)
        jr      z, _ssg_post_fx_legato
        call    eval_legato_step
        set     BIT_LOAD_NOTE, PIPELINE(ix)
_ssg_post_fx_legato:

        ;; Pipeline action: make sure no load note takes place when not playing
        bit     BIT_PLAYING, PIPELINE(ix)
        jr      nz, _ssg_post_check_playing
        res     BIT_LOAD_NOTE, PIPELINE(ix)
_ssg_post_check_playing:

        ;; Pipeline action: load note register when the note state is modified
        bit     BIT_LOAD_NOTE, PIPELINE(ix)
        jr      z, _post_load_ssg_note
        res     BIT_LOAD_NOTE, PIPELINE(ix)

        call    compute_ssg_fixed_point_note
        call    compute_ym2610_ssg_note

        ;; YM2610: load note
        ld      a, (state_ssg_channel)
        sla     a
        add     #REG_SSG_A_FINE_TUNE
        ld      b, a
        ld      c, NOTE_FINE_COARSE(ix)
        call    ym2610_write_port_a
        inc     b
        ld      c, NOTE_FINE_COARSE+1(ix)
        call    ym2610_write_port_a
_post_load_ssg_note:

        ;; Pipeline action: load registers modified by macros
        ;; (do not load if macro is finished)
        bit     BIT_LOAD_REGS, PIPELINE(ix)
        jr      z, _post_ssg_macro_load
        res     BIT_LOAD_REGS, PIPELINE(ix)
_prepare_ld_call:

        ;; de: return address
        ld      de, #_post_ssg_macro_load
        push    de

        ;; bc: load_func for this SSG channel
        ld      c, MACRO_LOAD(ix)
        ld      b, MACRO_LOAD+1(ix)
        push    bc

        ;; call args: hl: state_mirrored_ssg_props (8bit aligned add)
        push    ix
        pop     hl
        ld      a, l
        add     #PROPS_OFFSET
        ld      l, a

        ;; indirect call
        ret

_post_ssg_macro_load:

        ;; Pipeline action: load volume registers when the volume state is modified
        ;; Note: this is after macro load as currently, this step sets the VOL LOAD
        ;; bit if the macro updated the volume register
        bit     BIT_LOAD_VOL, PIPELINE(ix)
        jr      z, _post_load_ssg_vol
        res     BIT_LOAD_VOL, PIPELINE(ix)

        call    compute_ym2610_ssg_vol

        ;; load into ym2610
        ld      c, OUT_VOL(ix)
        ld      a, (state_ssg_channel)
        add     #REG_SSG_A_VOLUME
        ld      b, a
        call    ym2610_write_port_a
_post_load_ssg_vol:


        ;; Pipeline action: configure waveform and start note playback
        ld      c, #0xff
        bit     BIT_LOAD_WAVEFORM, PIPELINE(ix)
        jr      z, _post_load_waveform
        res     BIT_LOAD_WAVEFORM, PIPELINE(ix)
        res     BIT_NOTE_STARTED, PIPELINE(ix)
        ;; c: waveform (shifted for channel)
        ;; b: waveform mask (shifted for channel)
        ld      c, WAVEFORM_OFFSET(ix)
        call    waveform_for_channel

        ;; start note
        bit     BIT_NOTE_STARTED, PIPELINE(ix)
        jr      nz, _post_load_waveform
        ld      a, (state_mirrored_enabled)
        and     b
        or      c
        ld      (state_mirrored_enabled), a
        ld      b, #REG_SSG_ENABLE
        ld      c, a
        call    ym2610_write_port_a
        set     BIT_NOTE_STARTED, PIPELINE(ix)
_post_load_waveform:

_end_ssg_channel_pipeline:
        ;; next ssg context
        ld      a, (state_ssg_channel)
        inc     a
        cp      #3
        jr      nc, _ssg_end_macro
        call    ssg_ctx_set_current
        jp      _update_loop

_ssg_end_macro:
        ;; restore the real ssg channel context
        pop     af
        call    ssg_ctx_set_current

        pop     ix
        pop     iy
        pop     de
        ret


;;; Update the current fixed-point position
;;; ------
;;; current note (integer) + all the note effects (fixed point)
compute_ssg_fixed_point_note::
        ;; hl: current decimal note
        ld      l, NOTE16(ix)
        ld      h, NOTE16+1(ix)

        ;; + detuned semitone
        ld      c, DETUNE(ix)
        ld      b, DETUNE+1(ix)
        add     hl, bc

        ;; + arpeggio FX offset
        ld      c, #0
        ld      b, ARPEGGIO_POS8(ix)
        add     hl, bc

        ;; + macro arpeggio shift
        ld      a, ARPEGGIO(ix)
        add     h
        ld      h, a

        ;; + vibrato offset if the vibrato FX is enabled
        bit     BIT_FX_VIBRATO, NOTE_FX(ix)
        jr      z, _ssg_post_add_vibrato
        ld      c, NOTE_CTX+VIBRATO_POS16(ix)
        ld      b, NOTE_CTX+VIBRATO_POS16+1(ix)
        add     hl, bc
_ssg_post_add_vibrato::

        ;; update computed fixed-point note position
        ld      NOTE_POS16(ix), l
        ld      NOTE_POS16+1(ix), h
        ret

compute_ym2610_ssg_note::
        ;; l: current note (integer part)
        ld      l, NOTE_POS16+1(ix)

        ;; c: octave and semitone from note
        ld      h, #>note_to_octave_semitone
        ld      c, (hl)

        ;; push base floating point tune for note (24bits)
        ;; b: ym2610 base tune for note (LSB)
        ld      a, c
        ld      hl, #ssg_tunes_lsb
        add     l
        ld      l, a
        ld      b, (hl)
        push    bc              ; +base tune __:8_

        ;; de: ym2610 base tune for note (MSB)
        ld      h, #>ssg_tunes_msb
        ld      l, c
        sla     l
        ld      e, (hl)
        inc     l
        ld      d, (hl)
        push    de              ; +base tune 16:__

        ;; prepare arguments for scaling distance to next tune
        ;; c: ym2610 distance for note (_8:__)
        ld      a, c
        ld      bc, #ssg_dists_msb
        add     c
        ld      c, a
        ld      a, (bc)
        ld      c, a

        ;; de: ym2610 distance for note (__:16)
        ld      h, #>ssg_dists_lsb
        ld      d, (hl)
        dec     l
        ld      e, (hl)

        ;; l: current note (fractional part) to offset in delta table
        ;; l/2 to get index in delta table
        ;; (l/2)*2 to get offset in bytes in the delta table
        ld      l, NOTE_POS16(ix)
        res     0, l

        ;; hl: delta factor for current fractional part
        ld      h, #>ssg_tune_deltas
        ld      b, (hl)
        inc     l
        ld      h, (hl)
        ld      l, b

        ;; de:b : scaled 24bit distance
        call    scale_int24_by_factor16

        ;; SSG has decreasing value for higher semitone, so we must
        ;; negate the result to get the new final ym2610 tune
        ;; hl:a_ : base tune
        pop     hl              ; -base tune 16:__
        pop     af              ; -base tune __:8_

        ;; final tune = base tune - result = hl:a_ - de:b_
        sub     b
        sbc     hl, de

        ;; hl: SSG final tune = hl >> 4
        ld      a, l
        srl     h
        rra
        srl     h
        rra
        srl     h
        rra
        srl     h
        rra
        ld      l, a

        ;; save ym2610 fine and coarse tune
        ld      NOTE_FINE_COARSE(ix), l
        ld      NOTE_FINE_COARSE+1(ix), h
        ret


;;; Blend all volumes together to yield the volume for the ym2610 register
;;; ------
;;; [b modified]
compute_ym2610_ssg_vol::
        ;; a: note volume for channel
        ld      a, VOL16+1(ix)

        ;; a: volume converted to attenuation
        sub     #SSG_MAX_VOL

        ;; additional global volume attenuation
        ;; NOTE: YM2610's SSG output level ramp follows an exponential curve,
        ;; so we implement this output level attenuation via a basic substraction
        ld      b, a
        ld      a, (state_ssg_volume_attenuation)
        neg
        add     b

        ;; apply attenuation to current volume (from macro), and
        ;; clamp if result is negative
        add     REG_VOL(ix)
        jp      p, _post_ssg_vol_clamp
        ld      a, #0
_post_ssg_vol_clamp:

        ld      OUT_VOL(ix), a
        ret


;;; Set the right waveform value for the current SSG channel
;;; ------
;;; IN:
;;;   c: waveform
;;; OUT
;;;   c: shifted waveform for the current channel
;;; [b, c modified]
waveform_for_channel:
        ld      b, #0xf6   ; 11110110
        ld      a, (state_ssg_channel)
        cp      #0
        jp      z, _post_waveform_shift
        rlc     b
        rlc     c
        dec     a
        jp      z, _post_waveform_shift
        rlc     b
        rlc     c
_post_waveform_shift:
        ret


;;;  Reset SSG playback state.
;;;  Called before waiting for the next tick
;;; ------
;;; [a modified - other registers saved]
ssg_ctx_reset::
        ld      a, #0
        call    ssg_ctx_set_current
        ret




;;; SSG NSS opcodes
;;; ------

;;; SSG_CTX_1
;;; Set the current SSG track to be SSG1 for the next SSG opcode processing
;;; ------
ssg_ctx_1::
        ;; set new current SSG channel
        ld      a, #0
        call    ssg_ctx_set_current
        ld      a, #1
        ret


;;; SSG_CTX_2
;;; Set the current SSG track to be SSG3 for the next SSG opcode processing
;;; ------
ssg_ctx_2::
        ;; set new current SSG channel
        ld      a, #1
        call    ssg_ctx_set_current
        ld      a, #1
        ret


;;; SSG_CTX_3
;;; Set the current SSG track to be SSG3 for the next SSG opcode processing
;;; ------
ssg_ctx_3::
        ;; set new current SSG channel
        ld      a, #2
        call    ssg_ctx_set_current
        ld      a, #1
        ret


;;; SSG_MACRO
;;; Configure the SSG channel based on a macro's data
;;; ------
;;; [ hl ]: macro number
ssg_macro::
        push    de

        ;; init current state prior to loading new macro
        ;; to clean up any unused macro state
        ld      a, #0
        ld      ARPEGGIO(ix), a

        ;; a: macro
        ld      a, (hl)
        inc     hl

        push    hl

        ;; hl: macro address from instruments
        ld      hl, (state_stream_instruments)
        sla     a
        ;; hl + a (8bit add)
        add     a, l
        ld      l, a
        adc     a, h
        sub     l
        ld      h, a

        ;; hl: macro definition in (hl)
        ld      e, (hl)
        inc     hl
        ld      d, (hl)
        ld      h, d
        ld      l, e

        ;; initialize the state of the new macro
        ld      a, (hl)
        ld      MACRO_LOAD(ix), a
        inc     hl
        ld      a, (hl)
        ld      MACRO_LOAD+1(ix), a
        inc     hl
        ld      MACRO_DATA(ix), l
        ld      MACRO_DATA+1(ix), h
        ld      MACRO_POS(ix), l
        ld      MACRO_POS+1(ix), h

        ;; reconfigure pipeline to start evaluating macro
        ld      a, PIPELINE(ix)
        or      #STATE_EVAL_MACRO
        ld      PIPELINE(ix), a

        ;; setting a new instrument/macro always trigger a note start,
        ;; register it for the next pipeline run
        res     BIT_NOTE_STARTED, PIPELINE(ix)
        set     BIT_LOAD_NOTE, PIPELINE(ix)

        pop     hl
        pop     de

        ld      a, #1
        ret


;;; Release the note on a SSG channel and update the pipeline state
;;; ------
ssg_stop_playback:
        push    bc

        ;; c: disable mask (shifted for channel)
        ld      c, #9           ; ..001001
        call    waveform_for_channel

        ;; stop channel
        ld      a, (state_mirrored_enabled)
        or      c
        ld      (state_mirrored_enabled), a
        ld      b, #REG_SSG_ENABLE
        ld      c, a
        call    ym2610_write_port_a

        ;; mute channel volume
        ld      a, (state_ssg_channel)
        add     #REG_SSG_A_VOLUME
        ld      b, a
        ld      c, #0
        call    ym2610_write_port_a

        pop     bc

        ;; disable playback in the pipeline, any note lod_note bit
        ;; will get cleaned during the next pipeline run
        res     BIT_PLAYING, PIPELINE(ix)

        ;; record that playback is stopped
        xor     a
        res     BIT_NOTE_STARTED, PIPELINE(ix)

        ret


;;; SSG_NOTE_OFF
;;; Release (stop) the note on the current SSG channel.
;;; ------
ssg_note_off::
        call    ssg_stop_playback

        ld      a, #1
        ret


;;; SSG_NOTE_OFF_AND_NEXT_CTX
;;; Release (stop) the note on the current SSG channel.
;;; Immediately switch to the next SSG context.
;;; ------
ssg_note_off_and_next_ctx::
        call    ssg_note_off

        ;; SSG context will now target the next channel
        ld      a, (state_ssg_channel)
        inc     a
        call    ssg_ctx_set_current

        ld      a, #1
        ret


;;; SSG_VOL
;;; Set the volume of the current SSG channel
;;; ------
;;; [ hl ]: volume level
ssg_vol::
        ;; a: volume
        ld      a, (hl)
        inc     hl

        ;; delay load via the trigger FX?
        bit     BIT_TRIGGER_ACTION_DELAY, TRIGGER_ACTION(ix)
        jr      z, _ssg_vol_immediate
        ld      TRIGGER_VOL(ix), a
        set     BIT_TRIGGER_LOAD_VOL, TRIGGER_ACTION(ix)
        jr      _ssg_vol_end

_ssg_vol_immediate:
        ;; else load vol immediately
        call    ssg_configure_vol

_ssg_vol_end:

        ld      a, #1
        ret


;;; Configure state for new note and trigger a load in the pipeline
;;; ------
ssg_configure_note_on:
        push    bc
        ;; if a slide is ongoing, this is treated as a slide FX update
        bit     BIT_FX_SLIDE, NOTE_FX(ix)
        jr      z, _ssg_cfg_note_update
        ld      bc, #NOTE_CTX
        call    slide_update
        ;; if a note is currently playing, do nothing else, the
        ;; portamento will be updated at the next pipeline run...
        bit     BIT_NOTE_STARTED, PIPELINE(ix)
        jr      nz, _ssg_cfg_note_end
        ;; ... else prepare the note for reload as well
        jr      _ssg_cfg_note_prepare_ym2610
_ssg_cfg_note_update:
        ;; update the current note and prepare the ym2610
        ld      NOTE(ix), a
        ld      NOTE16+1(ix), a
        ld      NOTE16(ix), #0
        ;; do not stop the current note if a legato is in progress
        bit     BIT_FX_LEGATO, NOTE_FX(ix)
        jr      z, _ssg_post_cfg_note_update
        set     BIT_LOAD_NOTE, PIPELINE(ix)
        jr      _ssg_cfg_note_end
_ssg_post_cfg_note_update:
        res     BIT_NOTE_STARTED, PIPELINE(ix)
_ssg_cfg_note_prepare_ym2610:
        ;; init macro position
        ld      a, MACRO_DATA(ix)
        ld      MACRO_POS(ix), a
        ld      a, MACRO_DATA+1(ix)
        ld      MACRO_POS+1(ix), a
        ;; reload all registers at the next pipeline run
        ld      a, PIPELINE(ix)
        or      #(STATE_PLAYING|STATE_EVAL_MACRO|STATE_LOAD_NOTE)
        ld      PIPELINE(ix), a
_ssg_cfg_note_end:
        pop     bc

        ret


;;; Configure state for new volume and trigger a load in the pipeline
;;; ------
ssg_configure_vol:
        ;; if a volume slide is ongoing, treat it as a volume slide FX update
        bit     BIT_FX_SLIDE, FX(ix)
        jr      z, _ssg_cfg_vol_update
        push    bc
        ld      bc, #VOL_CTX
        call    slide_update
        pop     bc
        jr      _ssg_cfg_vol_end
_ssg_cfg_vol_update:
        ld      VOL(ix), a
        ld      VOL16+1(ix), a
        ld      VOL16(ix), #0
        ;; reload configured vol at the next pipeline run
        set     BIT_LOAD_VOL, PIPELINE(ix)
_ssg_cfg_vol_end:
        ret


;;; SSG_NOTE_ON
;;; Emit a specific note (frequency) on a SSG channel
;;; ------
;;; [ hl ]: note (0xAB: A=octave B=semitone)
ssg_note_on::
        ;; a: note (0xAB: A=octave B=semitone)
        ld      a, (hl)
        inc     hl

        ;; delay load via the trigger FX?
        bit     BIT_TRIGGER_ACTION_DELAY, TRIGGER_ACTION(ix)
        jr      z, _ssg_note_on_immediate
        ld      TRIGGER_NOTE(ix), a
        set     BIT_TRIGGER_LOAD_NOTE, TRIGGER_ACTION(ix)
        jr      _ssg_note_on_end

_ssg_note_on_immediate:
        ;; else load note immediately
        call    ssg_configure_note_on

_ssg_note_on_end:
        ld      a, #1
        ret


;;; SSG_NOTE_ON_AND_NEXT_CTX
;;; Emit a specific note (frequency) on a SSG channel and
;;; immediately switch to the next SSG context
;;; ------
;;; [ hl ]: note (0xAB: A=octave B=semitone)
ssg_note_on_and_next_ctx::
        ;; process a regular note opcode
        call    ssg_note_on

        ;; SSG context will now target the next channel
        ld      a, (state_ssg_channel)
        inc     a
        call    ssg_ctx_set_current

        ld      a, #1
        ret


;;; SSG_NOTE_ON_AND_WAIT
;;; Emit a specific note (frequency) on a SSG channel and
;;; immediately wait as many rows as the last wait
;;; ------
;;; [ hl ]: note (0xAB: A=octave B=semitone)
ssg_note_on_and_wait::
        ;; process a regular note opcode
        call    ssg_note_on

        ;; wait rows
        call    wait_last_rows
        ret


;;; SSG_ENV_PERIOD
;;; Set the period of the SSG envelope generator
;;; ------
;;; [ hl ]: fine envelope period
;;; [hl+1]: coarse envelope period
ssg_env_period::
        push    bc

        ld      b, #REG_SSG_ENV_FINE_TUNE
        ld      a, (hl)
        inc     hl
        ld      c, a
        call    ym2610_write_port_a

        inc     b
        ld      a, (hl)
        inc     hl
        ld      c, a
        call    ym2610_write_port_a

        pop     bc

        ld      a, #1
        ret


;;; SSG_DELAY
;;; Enable delayed trigger for the next note and volume
;;; (note and volume and played after a number of ticks)
;;; ------
;;; [ hl ]: delay
ssg_delay::
        call    trigger_delay_init

        ld      a, #1
        ret


;;; SSG_PITCH
;;; Detune up to -+1 semitone for the current channel
;;; ------
;;; [ hl ]: detune
ssg_pitch::
        push    bc
        call    common_pitch
        ld      DETUNE(ix), c
        ld      DETUNE+1(ix), b
        pop     bc
        ld      a, #1
        ret


;;; SSG_CUT
;;; Record that the note being played must be stopped after some steps
;;; ------
;;; [ hl ]: delay
ssg_cut::
        call    trigger_cut_init

        ld      a, #1
        ret
