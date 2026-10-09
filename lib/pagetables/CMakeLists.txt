# Page-table formats and a builder, shared by the loader (boot page tables)
# and the kernel (its own address space).
add_library(croi-pagetables STATIC
  PageTables/PageTableBuilder.swift
  PageTables/PageTableFormat.swift)
set_target_properties(croi-pagetables PROPERTIES Swift_MODULE_NAME PageTables)
