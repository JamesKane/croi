# ELF images as croi loads them: the loader (the kernel), the kernel
# (userboot) and userboot (programs from bootfs, compiled into it).
add_library(croi-elf STATIC Elf/ElfImage.swift)
set_target_properties(croi-elf PROPERTIES Swift_MODULE_NAME Elf)
