#!/usr/bin/env python3
"""Convert a static-PIE ELF64 image into a PE32+ EFI application.

LLVM cannot emit PE/COFF for every architecture croi targets (RISC-V has no
COFF backend), so the loader is linked as an ELF static PIE and converted.

Requirements on the input, all enforced here:
  * ET_DYN, little-endian ELF64 for x86-64, AArch64 or RISC-V.
  * Linked at address 0 with page-aligned PT_LOAD segments starting at or
    above 0x1000, leaving room for the PE headers (VA == RVA).
  * The only dynamic relocations are R_*_RELATIVE. Each one becomes an
    IMAGE_REL_BASED_DIR64 base relocation that firmware applies at load time.

Usage: elf2efi.py input.elf output.efi
"""

import struct
import sys

# e_machine -> (PE machine, R_*_RELATIVE)
MACHINES = {
    62: (0x8664, 8),      # x86-64
    183: (0xAA64, 1027),  # AArch64
    243: (0x5064, 3),     # RISC-V (RV64)
}

PAGE = 0x1000
FILE_ALIGN = 0x200

PT_LOAD, PT_DYNAMIC = 1, 2
PF_X, PF_W = 1, 2
DT_NULL, DT_RELA, DT_RELASZ, DT_RELAENT = 0, 7, 8, 9

IMAGE_REL_BASED_ABSOLUTE = 0
IMAGE_REL_BASED_DIR64 = 10
IMAGE_SUBSYSTEM_EFI_APPLICATION = 10
IMAGE_DIRECTORY_ENTRY_BASERELOC = 5

FILE_EXECUTABLE_IMAGE = 0x0002
FILE_LARGE_ADDRESS_AWARE = 0x0020
DLL_HIGH_ENTROPY_VA = 0x0020
DLL_DYNAMIC_BASE = 0x0040
DLL_NX_COMPAT = 0x0100

SCN_CNT_CODE = 0x00000020
SCN_CNT_INITIALIZED_DATA = 0x00000040
SCN_MEM_DISCARDABLE = 0x02000000
SCN_MEM_EXECUTE = 0x20000000
SCN_MEM_READ = 0x40000000
SCN_MEM_WRITE = 0x80000000

PE_OFFSET = 0x40
COFF_HEADER = struct.Struct("<HHIIIHH")
OPTIONAL_HEADER = struct.Struct("<HBBIIIIIQIIHHHHHHIIIIHHQQQQII")
DATA_DIRECTORIES = 16
SECTION_HEADER = struct.Struct("<8sIIIIIIHHI")


def fail(msg):
    sys.exit(f"elf2efi: {msg}")


def align(value, alignment):
    return (value + alignment - 1) & ~(alignment - 1)


class Section:
    def __init__(self, name, rva, virtual_size, data, characteristics):
        self.name = name
        self.rva = rva
        self.virtual_size = virtual_size
        self.data = data
        self.characteristics = characteristics


def read_elf(elf):
    if elf[:4] != b"\x7fELF" or elf[4] != 2 or elf[5] != 1:
        fail("not a little-endian ELF64 file")
    (e_type, e_machine, _, e_entry, e_phoff, _, _, _, e_phentsize, e_phnum) = \
        struct.unpack_from("<HHIQQQIHHH", elf, 16)
    if e_type != 3:
        fail("expected ET_DYN (link with -static -pie)")
    if e_machine not in MACHINES:
        fail(f"unsupported e_machine {e_machine}")
    phdrs = [struct.unpack_from("<IIQQQQQQ", elf, e_phoff + i * e_phentsize)
             for i in range(e_phnum)]
    return e_machine, e_entry, phdrs


def build_image(elf, loads):
    """Lay the PT_LOAD segments out in memory order, exactly as firmware will."""
    end = 0
    for (_, _, _, vaddr, _, _, memsz, _) in loads:
        if vaddr % PAGE or vaddr < PAGE:
            fail(f"PT_LOAD at {vaddr:#x} is not page aligned above the headers")
        if vaddr < end:
            fail(f"PT_LOAD at {vaddr:#x} overlaps the previous segment")
        end = vaddr + memsz
    image = bytearray(align(end, PAGE))
    for (_, _, offset, vaddr, _, filesz, _, _) in loads:
        image[vaddr:vaddr + filesz] = elf[offset:offset + filesz]
    return image


def apply_relocations(image, phdrs, r_relative):
    """Resolve RELATIVE relocations for link base 0 and return their offsets."""
    dynamic = [p for p in phdrs if p[0] == PT_DYNAMIC]
    if not dynamic:
        return []
    tags = {}
    pos = dynamic[0][3]
    while True:
        tag, val = struct.unpack_from("<qQ", image, pos)
        if tag == DT_NULL:
            break
        tags[tag] = val
        pos += 16
    if DT_RELA not in tags:
        return []
    rela, size, entsize = tags[DT_RELA], tags[DT_RELASZ], tags.get(DT_RELAENT, 24)
    offsets = []
    for pos in range(rela, rela + size, entsize):
        r_offset, r_info, r_addend = struct.unpack_from("<QQq", image, pos)
        r_type = r_info & 0xFFFFFFFF
        if r_type == 0:
            continue
        if r_type != r_relative:
            fail(f"unsupported dynamic relocation type {r_type} at {r_offset:#x}")
        struct.pack_into("<Q", image, r_offset, r_addend & 0xFFFFFFFFFFFFFFFF)
        offsets.append(r_offset)
    return sorted(offsets)


def base_relocations(offsets):
    """Encode offsets as PE base relocation blocks, one per 4 KiB page."""
    out = bytearray()
    i = 0
    while i < len(offsets):
        page = offsets[i] & ~(PAGE - 1)
        entries = []
        while i < len(offsets) and offsets[i] & ~(PAGE - 1) == page:
            entries.append((IMAGE_REL_BASED_DIR64 << 12) | (offsets[i] - page))
            i += 1
        if len(entries) % 2:
            entries.append(IMAGE_REL_BASED_ABSOLUTE << 12)  # keep blocks 32-bit aligned
        out += struct.pack("<II", page, 8 + 2 * len(entries))
        out += struct.pack(f"<{len(entries)}H", *entries)
    return bytes(out)


def segment_sections(image, loads):
    sections = []
    for (_, flags, _, vaddr, _, filesz, memsz, _) in loads:
        if flags & PF_X:
            if flags & PF_W:
                fail(f"PT_LOAD at {vaddr:#x} is both writable and executable")
            name, chars = b".text", SCN_CNT_CODE | SCN_MEM_EXECUTE | SCN_MEM_READ
        elif flags & PF_W:
            name, chars = b".data", SCN_CNT_INITIALIZED_DATA | SCN_MEM_READ | SCN_MEM_WRITE
        else:
            name, chars = b".rdata", SCN_CNT_INITIALIZED_DATA | SCN_MEM_READ
        raw = bytes(image[vaddr:vaddr + align(filesz, FILE_ALIGN)]) if filesz else b""
        sections.append(Section(name, vaddr, memsz, raw, chars))
    return sections


def write_pe(machine, entry, image_size, sections, reloc_section):
    if reloc_section:
        sections = sections + [reloc_section]
    headers_size = align(PE_OFFSET + 4 + COFF_HEADER.size + OPTIONAL_HEADER.size
                         + 8 * DATA_DIRECTORIES + SECTION_HEADER.size * len(sections), FILE_ALIGN)
    if headers_size > sections[0].rva:
        fail("PE headers do not fit below the first segment")

    raw_offset = headers_size
    for s in sections:
        s.raw_offset = raw_offset if s.data else 0
        raw_offset += len(s.data)

    def total(pred):
        return sum(align(s.virtual_size, FILE_ALIGN) for s in sections if pred(s))

    code = [s for s in sections if s.characteristics & SCN_CNT_CODE]
    directories = [(0, 0)] * DATA_DIRECTORIES
    if reloc_section:
        directories[IMAGE_DIRECTORY_ENTRY_BASERELOC] = (reloc_section.rva, reloc_section.virtual_size)

    out = bytearray(headers_size)
    out[0:2] = b"MZ"
    struct.pack_into("<I", out, 0x3C, PE_OFFSET)
    out[PE_OFFSET:PE_OFFSET + 4] = b"PE\0\0"
    pos = PE_OFFSET + 4
    COFF_HEADER.pack_into(out, pos, machine, len(sections), 0, 0, 0,
                          OPTIONAL_HEADER.size + 8 * DATA_DIRECTORIES,
                          FILE_EXECUTABLE_IMAGE | FILE_LARGE_ADDRESS_AWARE)
    pos += COFF_HEADER.size
    OPTIONAL_HEADER.pack_into(
        out, pos,
        0x20B, 0, 0,                                        # PE32+, linker version
        total(lambda s: s.characteristics & SCN_CNT_CODE),  # SizeOfCode
        total(lambda s: s.characteristics & SCN_CNT_INITIALIZED_DATA),
        0,                                                  # SizeOfUninitializedData
        entry, code[0].rva if code else 0,                  # entry, BaseOfCode
        0, PAGE, FILE_ALIGN,                                # ImageBase, alignments
        0, 0, 0, 0, 0, 0, 0,                                # versions, Win32VersionValue
        image_size, headers_size, 0,                        # SizeOfImage, SizeOfHeaders, CheckSum
        IMAGE_SUBSYSTEM_EFI_APPLICATION,
        DLL_HIGH_ENTROPY_VA | DLL_DYNAMIC_BASE | DLL_NX_COMPAT,
        0x10000, 0x10000, 0, 0,                             # stack/heap reserve & commit
        0, DATA_DIRECTORIES)
    pos += OPTIONAL_HEADER.size
    for rva, size in directories:
        struct.pack_into("<II", out, pos, rva, size)
        pos += 8
    for s in sections:
        SECTION_HEADER.pack_into(out, pos, s.name, s.virtual_size, s.rva, len(s.data),
                                 s.raw_offset, 0, 0, 0, 0, s.characteristics)
        pos += SECTION_HEADER.size
    for s in sections:
        out += s.data
    return bytes(out)


def main(argv):
    if len(argv) != 3:
        sys.exit(__doc__.strip().splitlines()[-1])
    with open(argv[1], "rb") as f:
        elf = f.read()

    e_machine, entry, phdrs = read_elf(elf)
    machine, r_relative = MACHINES[e_machine]
    loads = sorted((p for p in phdrs if p[0] == PT_LOAD), key=lambda p: p[3])
    if not loads:
        fail("no PT_LOAD segments")

    image = build_image(elf, loads)
    relocs = base_relocations(apply_relocations(image, phdrs, r_relative))
    sections = segment_sections(image, loads)

    image_size = len(image)
    reloc_section = None
    if relocs:
        reloc_section = Section(b".reloc", image_size, len(relocs),
                                relocs + bytes(align(len(relocs), FILE_ALIGN) - len(relocs)),
                                SCN_CNT_INITIALIZED_DATA | SCN_MEM_DISCARDABLE | SCN_MEM_READ)
        image_size += align(len(relocs), PAGE)

    with open(argv[2], "wb") as f:
        f.write(write_pe(machine, entry, image_size, sections, reloc_section))


if __name__ == "__main__":
    main(sys.argv)
