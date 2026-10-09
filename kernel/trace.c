// The trace category mask (see include/trace.h for why it is C).

#include "trace.h"

uint32_t croi_trace_mask = 0;

// Whether user-access protection is on (amd64 SMAP, arm64 PAN): the user
// accessors in usercopy.S open it (stac/clac, PAN toggles) only then.
// Read from assembly, so a C global like the trace mask.
uint8_t croi_user_protection = 0;

// ExtendedState's configuration for the save/restore assembly (xstate.h).
uint64_t croi_xstate_config = 0;
