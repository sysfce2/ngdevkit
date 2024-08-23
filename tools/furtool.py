#!/usr/bin/env python3
# Copyright (c) 2024 Damien Ciabrini
# This file is part of ngdevkit
#
# ngdevkit is free software: you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# ngdevkit is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with ngdevkit.  If not, see <http://www.gnu.org/licenses/>.

"""furtool.py - extract instruments and samples from a Furnace module."""

import argparse
import base64
import re
import sys
import zlib
from dataclasses import dataclass, field
from struct import pack, unpack, unpack_from
from adpcmtool import ym2610_adpcma, ym2610_adpcmb

VERBOSE = False


def error(s):
    sys.exit("error: " + s)


def warning(s):
    dbg("warning: " + s)


def dbg(s):
    if VERBOSE:
        print(s, file=sys.stderr)


class binstream(object):
    def __init__(self, data=b""):
        self.data = bytearray(data)
        self.pos = 0

    def bytes(self):
        return bytes(self.data)

    def eof(self):
        return self.pos == len(self.data)

    def read(self, n):
        res = self.data[self.pos:self.pos + n]
        self.pos += n
        return res

    def seek(self, pos):
        self.pos = pos

    def u1(self):
        res = unpack_from("B", self.data, self.pos)[0]
        self.pos += 1
        return res

    def u2(self):
        res = unpack_from("<H", self.data, self.pos)[0]
        self.pos += 2
        return res

    def u4(self):
        res = unpack_from("<I", self.data, self.pos)[0]
        self.pos += 4
        return res

    def uf4(self):
        res = unpack_from("<f", self.data, self.pos)[0]
        self.pos += 4
        return res

    def s4(self):
        res = unpack_from("<i", self.data, self.pos)[0]
        self.pos += 4
        return res

    def ustr(self):
        res = []
        b = self.u1()
        while b != 0:
            res.append(b)
            b = self.u1()
        return bytearray(res).decode("utf-8")

    def write(self, data):
        self.data.extend(data)
        self.pos += len(data)

    def e1(self, data):
        self.data.extend(pack("B", data))
        self.pos += 1

    def e2(self, data):
        self.data.extend(pack("<H", data))
        self.pos += 2

    def e4(self, data):
        self.data.extend(pack("<I", data))
        self.pos += 4


def ubit(data, msb, lsb):
    mask = (2 ** (msb - lsb + 1)) - 1
    return (data >> lsb) & mask


def ubits(data, *args):
    res = []
    for a in args:
        res.append(ubit(data, a[0], a[1]))
    return res


def ebit(data, msb, lsb):
    return (data << lsb)


@dataclass
class fur_module:
    name: str = ""
    author: str = ""
    speed: int = 0
    arpeggio: int = 0
    frequency: float = 0.0
    instruments: list[int] = field(default_factory=list)
    samples: list[int] = field(default_factory=list)


def read_module(bs):
    mod = fur_module()
    assert bs.read(16) == b"-Furnace module-"  # magic
    bs.u2()  # version
    bs.u2()
    infodesc = bs.u4()
    bs.seek(infodesc)
    assert bs.read(4) == b"INFO"
    bs.read(4) # skip size
    bs.u1() # skip timebase
    mod.speed = bs.u1()
    bs.u1() # skip speed2
    mod.arpeggio = bs.u1()
    mod.frequency = bs.uf4()
    pattern_len = bs.u2()
    nb_orders = bs.u2()
    bs.read(2)  # skip highlights
    nb_instruments = bs.u2()
    nb_wavetables = bs.u2()
    nb_samples = bs.u2()
    nb_patterns = bs.u4()  # skip global pattern count
    chips = [x for x in bs.read(32)]
    assert chips[:chips.index(0)] == [165]  # single ym2610 chip
    bs.read(32 + 32 + 128)  # skip chips vol, pan, flags
    mod.name = bs.ustr()
    mod.author = bs.ustr()
    mod.pattern_len = pattern_len
    bs.uf4()  # skip tuning
    bs.read(20)  # skip furnace configs
    mod.instruments = [bs.u4() for i in range(nb_instruments)]
    _ = [bs.u4() for i in range(nb_wavetables)]
    mod.samples = [bs.u4() for i in range(nb_samples)]
    mod.patterns = [bs.u4() for i in range(nb_patterns)]
    # 14 tracks in ym2610 (4 FM, 3 SSG, 6 ADPCM-A, 1 ADPCM-B)
    mod.orders = [[-1 for x in range(14)] for y in range(nb_orders)]
    for i in range(14):
        for o in range(nb_orders):
            mod.orders[o][i] = bs.u1()
    mod.fxcolumns = [bs.u1() for x in range(14)]
    return mod



@dataclass
class fm_operator:
    detune: int = 0
    multiply: int = 0
    total_level: int = 0
    key_scale: int = 0
    attack_rate: int = 0
    am_on: int = 0
    decay_rate: int = 0
    kvs: int = 0
    sustain_rate: int = 0
    sustain_level: int = 0
    release_rate: int = 0
    ssg_eg: int = 0


@dataclass
class adpcm_a_sample:
    name: str = ""
    data: bytearray = field(default=b"", repr=False)


@dataclass
class adpcm_b_sample:
    name: str = ""
    data: bytearray = field(default=b"", repr=False)


@dataclass
class pcm_sample:
    name: str = ""
    data: bytearray = field(default=b"", repr=False)
    loop: bool = False


@dataclass
class fm_instrument:
    name: str = ""
    algorithm: int = 0
    feedback: int = 0
    am_sense: int = 0
    fm_sense: int = 0
    ops: list[fm_operator] = field(default_factory=list)


@dataclass
class ssg_macro:
    name: str = ""
    prog: list[int] = field(default_factory=list)
    keys: list[int] = field(default_factory=list)
    offset: list[int] = field(default_factory=list)
    autoenv: bool = False


@dataclass
class adpcm_a_instrument:
    name: str = ""
    sample: adpcm_a_sample = None


@dataclass
class adpcm_b_instrument:
    name: str = ""
    sample: adpcm_b_sample = None
    loop: bool = False


def read_fm_instrument(bs):
    ifm = fm_instrument()
    assert bs.u1() == 0xf4  # data for all operators
    ifm.algorithm, ifm.feedback = ubits(bs.u1(), [6, 4], [2, 0])
    ifm.am_sense, ifm.fm_sense = ubits(bs.u1(), [4, 3], [2, 0])
    bs.u1()  # unused
    for _ in range(4):
        op = fm_operator()
        tmpdetune, op.multiply = ubits(bs.u1(), [6, 4], [3, 0])
        # convert furnace detune format into ym2610 format
        tmpdetune-=3
        if tmpdetune<0:
            tmpdetune=abs(tmpdetune)+0b100
        op.detune=tmpdetune
        (op.total_level,) = ubits(bs.u1(), [6, 0])
        # RS is env_scale in furnace UI. key_scale in wiki?
        op.key_scale, op.attack_rate = ubits(bs.u1(), [7, 6], [4, 0])
        # KSL todo
        op.am_on, op.decay_rate = ubits(bs.u1(), [7, 7], [4, 0])
        op.kvs, op.sustain_rate = ubits(bs.u1(), [6, 5], [4, 0])
        op.sustain_level, op.release_rate = ubits(bs.u1(), [7, 4], [3, 0])
        (op.ssg_eg,) = ubits(bs.u1(), [3, 0])
        bs.u1()  # unused

        ifm.ops.append(op)
    return ifm


@dataclass
class ssg_prop:
    name: str = ""
    offset: int = 0

    
def read_ssg_macro(length, bs):
    # TODO -1 are unsupported in nullsound
    code_map = {0: ssg_prop("volume", 3),      # volume
                3: ssg_prop("waveform", 4),    # noise_tune
                6: ssg_prop("env", 0),         # envelope shape
                7: ssg_prop("env_vol_num", 1), # volume envelope numerator
                8: ssg_prop("env_vol_den", 2)  # volume envelope denominator
                }

    blocks={}
    autoenv=False
    init=bs.pos
    max_pos = bs.pos + length
    header_len = bs.u2()
    # pass: read all macro blocks
    while bs.pos < max_pos:
        header_start = bs.pos
        code = bs.u1()
        if code == 255:
            break
        length = bs.u1()
        # TODO unsupported. no loop
        loop = bs.u1()
        # TODO unsupported. last macro stays
        release = bs.u1()
        # TODO meaning?
        mode = bs.u1()
        msize, mtype = ubits(bs.u1(), [7, 6], [2, 1])
        assert msize == 0, "macro value should be of type '8-bit unsigned'"
        assert mtype == 0, "macro should be of type 'sequence'"
        # TODO unsupported. no delay
        delay = bs.u1()
        # TODO unsupported. same speed as the module tick
        speed = bs.u1()
        header_end = bs.pos
        assert header_end - header_start == header_len
        data = [bs.u1() for i in range(length)]
        blocks[code_map[code].offset]=data
    assert bs.pos == max_pos
    # pass: create a "empty" waveform property if it's not there
    # we need it to tell nullsound to not update the envelope SSG register
    if 0 not in blocks:
        blocks[0] = [128] # do not update envelope (bit7 set)
    # pass: convert waveform for noise_tone register
    if 4 in blocks:
        # NOTE: only read a single waveform as we don't allow
        # sequence on this register right now
        wav=blocks[4][0]
        env, noise, tone = ubits(wav,[2,2],[1,1],[0,0]) # latest furnace version
        # pass: store envelope bit as mode for volume register
        if 3 in blocks:
            new_vols=[env<<4|v for v in blocks[3]]
            blocks[3]=new_vols
        new_wav=(noise<<3|tone)^0xff
        blocks[4]=[new_wav]
    # pass: put auto-env information aside, it requires muls and divs
    # and we don't want to do that at runtime on the Z80. Instead
    # we will simulate that feature via a specific NSS opcode
    if 1 in blocks or 2 in blocks:
        # NOTE: only read a single element as we don't allow
        # macros on these registers right now
        num = blocks.get(1,[1])[0]
        den = blocks.get(2,[1])[0]
        autoenv=(num,den)
        blocks.pop(1, None)
        blocks.pop(2, None)
    # pass: build macro program
    # a macro program consists of two separate parts:
    prog = []
    # the first parts is a sequence that initializes SSG registers
    # that should not be updated at every tick (done in ssg_macro)
    keys = sorted(filter(lambda x: x in [4,0],blocks.keys()))
    iseq, _ = compile_macro_sequence(keys, blocks)
    prog.extend(iseq)
    # the second parts is a series of sequences that update SSG registers
    # at every tick. Right now it only includes volume.
    keys = sorted(filter(lambda x: x not in [4,0],blocks.keys()))
    nseq, offset = compile_macro_sequence(keys, blocks)
    prog.extend(nseq)
    # add end of macro marker
    prog.append(255)
    issg = ssg_macro(prog=prog, keys=keys, offset=offset, autoenv=autoenv)
    return issg


def compile_macro_sequence(keys, blocks):
    seq = []
    offset = [v if i==0 else keys[i]-keys[i-1]-1 for i,v in enumerate(keys)]
    step = [-1]
    while step:
        step = []
        for k,o in zip(keys, offset):
            if not blocks[k]:
                continue
            v = blocks[k].pop(0)
            o2 = k if not step else o
            p = [o2, v]
            step.extend(p)
        if step:
            seq.extend(step+[255])
    return seq, offset


def read_instrument(nth, bs, smp):
    def asm_ident(x):
        return re.sub(r"\W|^(?=\d)", "_", x).lower()
    
    assert bs.read(4) == b"INS2"
    endblock = bs.pos + bs.u4()
    assert bs.u2() >= 127  # format version
    itype = bs.u2()
    assert itype in [1, 6, 37, 38]  # FM, SSG, ADPCM-A, ADPCM-B
    # for when the instrument has no SM feature
    sample = 0
    name = ""
    ins = None
    mac = None
    while bs.pos < endblock:
        feat = bs.read(2)
        length = bs.u2()
        if feat == b"NA":
            name = bs.ustr()
        elif feat == b"FM":
            ins = read_fm_instrument(bs)
        elif feat == b"LD":
            # unused OPL drum data
            bs.read(length)
        elif feat == b"SM":
            sample = bs.u2()
            bs.u2()  # unused flags and waveform
        elif feat == b"MA" and itype == 6:
            mac = read_ssg_macro(length, bs)
        elif feat == b"NE":            
            # NES DPCM tag is present when the instrument
            # uses a PCM sample instead of ADPCM. Skip it
            assert bs.u1()==0, "sample map unsupported"
        else:
            warning("unexpected feature in sample %02x%s: %s" % \
                    (nth, (" (%s)"%name if name else ""), feat.decode()))
            bs.read(length)
    # for ADPCM sample, populate sample data
    if itype in [37, 38]:
        ins = {37: adpcm_a_instrument,
               38: adpcm_b_instrument}[itype]()
        # ADPCM-B loop information
        if itype == 38:
            ins.loop = smp[sample].loop
        if isinstance(smp[sample],pcm_sample):
            # the sample is encoded in PCM, so it has to be converted
            # to be played back on the hardware.
            warning("sample '%s' is encoded in PCM, converting to ADPCM-%s"%\
                (smp[sample].name, "A" if itype==37 else "B"))
            converted = convert_sample(smp[sample], itype)
            smp[sample] = converted
        ins.sample = smp[sample]
    # generate a ASM name for the instrument or macro
    if itype == 6:
        mac.name = asm_ident("macro_%02x_%s"%(nth, name))
        mac.load_name = asm_ident("macro_%02x_load_func"%nth)
        return mac
    else:
        ins.name = asm_ident("instr_%02x_%s"%(nth, name))
        return ins


def read_instruments(ptrs, smp, bs):
    ins = []
    n = 0
    for p in ptrs:
        bs.seek(p)
        ins.append(read_instrument(n, bs, smp))
        # print(ins[-1].name)
        n += 1
    return ins


def read_sample(bs):
    assert bs.read(4) == b"SMP2"
    _ = bs.u4()  # endblock
    name = bs.ustr()
    adpcm_samples = bs.u4()
    _ = bs.u4()  # unused compat frequency
    c4_freq = bs.u4()
    stype = bs.u1()
    if stype in [5,6]: # ADPCM-A, ADPCM-B
        assert adpcm_samples % 2 == 0
        data_bytes = adpcm_samples // 2
        data_padding = 0
        if data_bytes % 256 != 0:
            dbg("length of sample '%s' (%d bytes) is not a multiple of 256bytes, padding added"%\
                (str(name), data_bytes))
            data_padding = (((data_bytes+255)//256)*256) - data_bytes
    elif stype == 16: # PCM16 (requires conversion to ADPCM)
        data_bytes = adpcm_samples * 2
        data_padding = 0  # adpcmtool codecs automatically adds padding
    else:
        error("sample '%s' is of unsupported type: %d"%(str(name), stype))
    # assert c4_freq == {5: 18500, 6: 44100}[stype]
    bs.u1()  # unused loop direction
    bs.u2()  # unused flags
    loop_start, loop_end = bs.s4(), bs.s4()
    bs.read(16)  # unused rom allocation
    data = bs.read(data_bytes) + bytearray(data_padding)
    # generate a ASM name for the instrument
    insname = re.sub(r"\W|^(?=\d)", "_", name).lower()
    ins = {5: adpcm_a_sample,
           6: adpcm_b_sample,
           16: pcm_sample}[stype](insname, data)
    ins.loop = loop_start != -1 and loop_end != -1
    return ins


def convert_sample(pcm_sample, totype):
    codec = {37: ym2610_adpcma,
             38: ym2610_adpcmb}[totype]()
    pcm16s = unpack('<%dh' % (len(pcm_sample.data)>>1), pcm_sample.data)
    adpcms=codec.encode(pcm16s)
    adpcms_packed = [(adpcms[i] << 4 | adpcms[i+1]) for i in range(0, len(adpcms), 2)]
    # convert sample to the right class
    converted = {37: adpcm_a_sample,
                 38: adpcm_b_sample}[totype](pcm_sample.name, bytes(adpcms_packed))
    return converted


def read_samples(ptrs, bs):
    smp = []
    for p in ptrs:
        bs.seek(p)
        smp.append(read_sample(bs))
    return smp

def check_for_unused_samples(smp, bs):
    # module might have unused samples, leave them in the output
    # if these are pcm_samples, convert them to adpcm_a to avoid errors
    for i,s in enumerate(smp):
        if isinstance(s, pcm_sample):
            smp[i] = convert_sample(s, 37)

def asm_fm_instrument(ins, fd):
    dtmul = tuple(ebit(ins.ops[i].detune, 6, 4) | ebit(ins.ops[i].multiply, 3, 0) for i in range(4))
    tl = tuple(ebit(ins.ops[i].total_level, 6, 0) for i in range(4))
    ksar = tuple(ebit(ins.ops[i].key_scale, 7, 6) | ebit(ins.ops[i].attack_rate, 4, 0) for i in range(4))
    amdr = tuple(ebit(ins.ops[i].am_on, 7, 7) | ebit(ins.ops[i].decay_rate, 4, 0) for i in range(4))
    sr = tuple(ebit(ins.ops[i].kvs, 6, 5) | ebit(ins.ops[i].sustain_rate, 4, 0) for i in range(4))
    slrr = tuple(ebit(ins.ops[i].sustain_level, 7, 4) | ebit(ins.ops[i].release_rate, 3, 0) for i in range(4))
    ssgeg = tuple(ebit(ins.ops[i].ssg_eg, 3, 0) for i in range(4))
    fbalgo = (ebit(ins.feedback, 5, 3) | ebit(ins.algorithm, 2, 0),)
    amsfms = (ebit(0b11, 7, 6) | ebit(ins.am_sense, 5, 4) | ebit(ins.fm_sense, 2, 0),)
    print("%s:" % ins.name, file=fd)
    print("        ;;       OP1 - OP3 - OP2 - OP4", file=fd)
    print("        .db     0x%02x, 0x%02x, 0x%02x, 0x%02x   ; DT | MUL" % dtmul, file=fd)
    print("        .db     0xff, 0xff, 0xff, 0xff   ; empty", file=fd)
    print("        .db     0x%02x, 0x%02x, 0x%02x, 0x%02x   ; KS | AR" % ksar, file=fd)
    print("        .db     0x%02x, 0x%02x, 0x%02x, 0x%02x   ; AM | DR" % amdr, file=fd)
    print("        .db     0x%02x, 0x%02x, 0x%02x, 0x%02x   ; SR" % sr, file=fd)
    print("        .db     0x%02x, 0x%02x, 0x%02x, 0x%02x   ; SL | RR" % slrr, file=fd)
    print("        .db     0x%02x, 0x%02x, 0x%02x, 0x%02x   ; SSG" % ssgeg, file=fd)
    print("        .db     0x%02x                     ; FB | ALGO" % fbalgo, file=fd)
    print("        .db     0x%02x                     ; LR | AMS | FMS" % amsfms, file=fd)
    print("        .db     0x%02x, 0x%02x, 0x%02x, 0x%02x   ; TL" % tl, file=fd)
    print("", file=fd)


def asm_ssg_macro(mac, fd):
    prev = 0
    cur = mac.prog.index(255, 0)
    lines = []
    while cur != prev:
        line = mac.prog[prev:cur+1]
        lines.append(", ".join(["0x%02x"%x for x in line]))
        prev = cur+1
        cur = mac.prog.index(255,cur+1)
    # macro actions
    print("%s:" % mac.name, file=fd)
    longest = max([len(x) for x in lines])
    step = 0
    print("        ;; macro load function", file=fd)
    print("        .dw     %s" % mac.load_name, file=fd)
    print("        ;; macro actions", file=fd)
    for l in lines:
        print("        .db     %s   ; tick %d"%(l.ljust(longest), step), file=fd)
        step += 1
    print("        .db     %s   ; end"%"0xff".ljust(longest), file=fd)
    print("", file=fd)
    # load func
    asm_ssg_load_func(mac, fd)

    
def asm_ssg_load_func(mac, fd):
    def asm_ssg(reg):
        print("        ld      b, #0x%02x"%reg, file=fd)
        print("        ld      c, (hl)", file=fd)
        print("        call    ym2610_write_port_a", file=fd)
    def asm_cha(reg):
        print("        ld      a, (state_ssg_channel)", file=fd)
        print("        ld      b, a", file=fd)
        print("        ld      c, (hl)", file=fd)
        print("        call    ssg_mix_volume", file=fd)
    def offset(off):
        if off==1:
            print("        inc     hl", file=fd)
        else:
            print("        ld      bc, #%d"%off, file=fd)
            print("        add     hl, bc", file=fd)
        pass
    ssg_map = {
        0: 0x0d, # REG_SSG_ENV_SHAPE
        1: 0x0b, # REG_SSG_ENV_FINE_TUNE
        2: 0x0c, # REG_SSG_ENV_COARSE_TUNE
    }
    cha_map = {
        3: 0x08  # REG_SSG_A_VOLUME
    }
    print("%s:" % mac.load_name, file=fd)
    data = zip(range(len(mac.offset)), mac.offset, mac.keys)
    for i, o, k in data:
        if i != 0:
            o+=1
        offset(o)
        if k in ssg_map:
            asm_ssg(ssg_map[k])
        elif k in cha_map:
            asm_cha(cha_map[k])
        else:
            error("no ASM for SSG property: %d"%k)
    print("        ret", file=fd)
    print("", file=fd)


def asm_adpcm_instrument(ins, fd):
    name = ins.sample.name.upper()
    print("%s:" % ins.name, file=fd)
    print("        .db     %s_START_LSB, %s_START_MSB  ; start >> 8" % (name, name), file=fd)
    print("        .db     %s_STOP_LSB,  %s_STOP_MSB   ; stop  >> 8" % (name, name), file=fd)
    if isinstance(ins, adpcm_b_instrument):
        print("        .db     0x%02x  ; loop" % (ins.loop,), file=fd)
    print("", file=fd)


def generate_instruments(mod, sample_map_name, ins_name, ins, fd):
    print(";;; NSS instruments and macros", file=fd)
    print(";;; generated by furtool.py (ngdevkit)", file=fd)
    print(";;; ---", file=fd)
    print(";;; Song title: %s" % mod.name, file=fd)
    print(";;; Song author: %s" % mod.author, file=fd)
    print(";;;", file=fd)
    print("", file=fd)
    print("        .area   CODE", file=fd)
    print("", file=fd)
    print("        ;; offset of ADPCM samples in ROMs", file=fd)
    print('        .include "%s"' % sample_map_name, file=fd)
    print("", file=fd)
    inspp = {fm_instrument: asm_fm_instrument,
             ssg_macro: asm_ssg_macro,
             adpcm_a_instrument: asm_adpcm_instrument,
             adpcm_b_instrument: asm_adpcm_instrument}
    if ins:
        print("%s::" % ins_name, file=fd)
        for i in ins:
            print("        .dw     %s" % i.name, file=fd)
    else:
        print(";; no instruments defined in this song", file=fd)
    print("", file=fd)
    for i in ins:
        inspp[type(i)](i, fd)


def generate_sample_map(mod, smp, fd):
    print("# ADPCM sample map - generated by furtool.py (ngdevkit)", file=fd)
    print("# ---", file=fd)
    print("# Song title: %s" % mod.name, file=fd)
    print("# Song author: %s" % mod.author, file=fd)
    print("#", file=fd)
    stype = {adpcm_a_sample: "adpcm_a", adpcm_b_sample: "adpcm_b"}
    for s in smp:
        print("- %s:" % stype[type(s)], file=fd)
        print("    name: %s" % s.name, file=fd)
        print("    # length: %d" % len(s.data), file=fd)
        print("    uri: data:;base64,%s" % base64.b64encode(s.data).decode(), file=fd)


def load_module(modname):
    with open(modname, "rb") as f:
        furzbin = f.read()
        furbin = zlib.decompress(furzbin)
        return binstream(furbin)


def samples_from_module(modname):
    bs = load_module(modname)
    m = read_module(bs)
    smp = read_samples(m.samples, bs)
    ins = read_instruments(m.instruments, smp, bs)
    check_for_unused_samples(smp, bs)
    return smp


def main():
    global VERBOSE
    parser = argparse.ArgumentParser(
        description="Extract instruments and samples from a Furnace module")

    paction = parser.add_argument_group("action")
    pmode = paction.add_mutually_exclusive_group(required=True)
    pmode.add_argument("-i", "--instruments", action="store_const",
                       const="instruments", dest="action",
                       help="extract instrument information from a Furnace module")
    pmode.add_argument("-s", "--samples", action="store_const",
                       const="samples", dest="action", default="instruments",
                       help="extract samples data from a Furnace module")

    parser.add_argument("FILE", help="Furnace module")
    parser.add_argument("-o", "--output", help="Output file name")

    parser.add_argument("-n", "--name",
                        help="Name of the generated instrument table")

    parser.add_argument("-m", "--map",
                        help="Name of the ADPCM sample map file to include")

    parser.add_argument("-v", "--verbose", dest="verbose", action="store_true",
                        default=False, help="print details of processing")

    arguments = parser.parse_args()
    VERBOSE = arguments.verbose

    # load all samples data in memory from the map file
    bs = load_module(arguments.FILE)
    m = read_module(bs)
    smp = read_samples(m.samples, bs)
    ins = read_instruments(m.instruments, smp, bs)
    check_for_unused_samples(smp, bs)

    if arguments.output:
        outfd = open(arguments.output, "w")
    else:
        outfd = sys.__stdout__

    if arguments.name:
        name = arguments.name
    else:
        name = "nss_instruments"

    if arguments.map:
        sample_map = arguments.map
    else:
        sample_map = "samples.inc"

    if arguments.action == "instruments":
        generate_instruments(m, sample_map, name, ins, outfd)
    elif arguments.action == "samples":
        generate_sample_map(m, smp, outfd)
    else:
        error("Unknown action: %s" % arguments.action)


if __name__ == "__main__":
    main()
