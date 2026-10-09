# croi_image(<target> ENTRY <symbol> BASE <address>)
#
# Links an executable target as a croi static-PIE image using ld/image.ld.
function(croi_image target)
  cmake_parse_arguments(PARSE_ARGV 1 arg "" "ENTRY;BASE" "")
  set(script ${PROJECT_SOURCE_DIR}/ld/image.ld)
  target_link_options(${target} PRIVATE
    ${CROI_LINK_FLAGS} -e ${arg_ENTRY} --defsym=IMAGE_BASE=${arg_BASE} -T ${script})
  set_target_properties(${target} PROPERTIES LINKER_LANGUAGE C LINK_DEPENDS ${script})
endfunction()
