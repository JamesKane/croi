# Fails if a linked kernel image contains the Swift refcounting runtime.
#
#   cmake -DNM=<llvm-nm> -DIMAGE=<kernel.elf> -P CheckNoArc.cmake
#
# Embedded Swift treats objects at addresses with bit 63 set (all of the
# kernel's higher half) as immortal: retain/release are no-ops, so class
# instances, boxes and Array/String/Dictionary storage would never be
# freed. The kernel is ownership-only (see CLAUDE.md); after --gc-sections
# these symbols are only present if something uses them.

execute_process(COMMAND ${NM} --defined-only ${IMAGE}
                OUTPUT_VARIABLE symbols RESULT_VARIABLE rc)
if(NOT rc EQUAL 0)
  message(FATAL_ERROR "llvm-nm failed on ${IMAGE}")
endif()

string(REGEX MATCHALL
  "[ \t](swift_(allocObject|allocBox|allocEmptyBox|retain|retain_n|release|release_n|bridgeObjectRetain|bridgeObjectRelease|isUniquelyReferenced[A-Za-z_]*|deallocObject|deallocClassInstance))\n"
  found "${symbols}")
if(found)
  string(REGEX REPLACE "[ \t\n]+" " " found "${found}")
  message(FATAL_ERROR
    "${IMAGE} uses the Swift refcounting runtime:${found}\n"
    "Classes, closures that capture, existentials and copy-on-write collections\n"
    "(Array, String, Dictionary, Set) leak in the kernel. Use ~Copyable types,\n"
    "UniqueBox/UniqueArray and Ref<T>. Find the user with:\n"
    "  ld.lld --why-live=<symbol> ...")
endif()
