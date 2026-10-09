# Allocation-free text formatting shared by the loader and the kernel.
add_library(croi-fmt STATIC Fmt/TextOutput.swift)
set_target_properties(croi-fmt PROPERTIES Swift_MODULE_NAME Fmt)
