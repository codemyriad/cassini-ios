"""Signing-stable identity of arm64 Mach-O code/data; never modifies the input.

Apple validates the whole signed image at load. This extra pin covers file-backed
sections and dependency/platform commands, excluding mutable signing/link-edit data.
"""
import hashlib
import struct

def identity(data):
    def u32(at):
        if at < 0 or at + 4 > len(data): raise ValueError("Truncated Mach-O")
        return struct.unpack_from("<I", data, at)[0]
    if len(data) < 32 or u32(0) != 0xfeedfacf or u32(4) != 0x100000c or u32(12) != 6:
        raise ValueError("Expected arm64 MH_DYLIB")
    count, size = u32(16), u32(20)
    if count > 1024 or size > len(data)-32: raise ValueError("Invalid load commands")
    out = bytearray(b"cassini-whistle-sections-v1\0") + data[4:16]
    at = 32; sections = 0
    for _ in range(count):
        cmd, length = u32(at), u32(at+4)
        if length < 8 or length % 8 or at+length > 32+size: raise ValueError("Invalid command")
        if cmd == 0x19:
            if length < 72: raise ValueError("Truncated segment")
            n = u32(at+64)
            if length != 72+n*80: raise ValueError("Invalid sections")
            for i in range(n):
                s = at+72+i*80; flags = u32(s+64)
                if flags & 0xff in (1, 0xc, 0x12): continue
                amount = struct.unpack_from("<Q",data,s+40)[0]; offset = u32(s+48)
                if offset < 32+size or amount > len(data)-offset: raise ValueError("Invalid section range")
                out += data[s:s+32] + struct.pack("<QI", amount, flags) + data[offset:offset+amount]
                sections += 1
        elif cmd in (0xc,0xd,0x80000018,0x8000001c,0x8000001f,0x20,0x80000023,0x32,0x1b,0x2a):
            out += struct.pack("<I",length) + data[at:at+length]
        elif cmd == 0x2c:
            if length < 24 or u32(at+16) != 0: raise ValueError("Encrypted runtime needs separate acceptance")
            out += struct.pack("<I",length) + data[at:at+length]
        elif cmd not in (2,0xb,0x1d,0x26,0x29,0x80000022,0x80000033,0x80000034):
            raise ValueError("Unreviewed Mach-O command")
        at += length
    if at != 32+size or sections == 0: raise ValueError("Incomplete Mach-O")
    return hashlib.sha256(out).hexdigest()
