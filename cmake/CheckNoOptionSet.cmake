# Fails if a kernel Swift source declares an OptionSet (run as cmake -P
# with -DSOURCES=<;-list> -DSTAMP=<file>). Kernel flag types are BitFlags
# (kernel/Kernel/Object/Status.swift), combined with |: an OptionSet array
# literal builds an Array, so whether the kernel linked free of Swift
# refcounting depended on the optimizer folding it, and unrelated edits
# broke the link three times (K10e, K11a, K11b).
foreach(_source ${SOURCES})
  if(_source MATCHES "\\.swift$")
    file(READ ${_source} _text)
    if(_text MATCHES ":[ \t]*OptionSet")
      message(FATAL_ERROR "${_source}: use BitFlags (combined with |), not OptionSet, in the kernel")
    endif()
  endif()
endforeach()
file(TOUCH ${STAMP})
