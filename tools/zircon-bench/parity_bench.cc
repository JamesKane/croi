// croi's M2 budgets (user/m2/Bench.swift) measured on Zircon: the same four
// workloads, CPU masks, iteration counts and statistics, against zx_*
// syscalls. Built in the Fuchsia tree as a standalone ZBI test (userboot
// runs it, no component framework), see BUILD.gn and README.md.
//
// Times come from zx_ticks_get in user space (croi reads its trace marks).
// Port wake is timed from just before zx_object_signal to just after
// zx_port_wait returns, so it includes one syscall entry and one exit that
// croi's syscall-enter/exit records leave out (tens of ns).

#include <lib/standalone-test/standalone.h>
#include <lib/zx/resource.h>
#include <stdio.h>
#include <threads.h>
#include <zircon/assert.h>
#include <zircon/process.h>
#include <zircon/syscalls.h>
#include <zircon/syscalls/port.h>
#include <zircon/syscalls/profile.h>
#include <zircon/testonly-syscalls.h>
#include <zircon/threads.h>

#include <algorithm>
#include <vector>

#include <zxtest/zxtest.h>

namespace {

// CPUs as in Bench.swift: the client/signaler, the port waiter, the sleeper.
constexpr uint32_t kClientCpu = 1;
constexpr uint32_t kWaiterCpu = 2;
constexpr uint32_t kSleeperCpu = 3;

uint64_t TicksToNs(zx_ticks_t ticks) {
  static const uint64_t per_second = zx_ticks_per_second();
  return static_cast<uint64_t>(
      (static_cast<__uint128_t>(ticks) * 1'000'000'000) / per_second);
}

zx::resource& ProfileResource() {
  static zx::resource resource = [] {
    zx::resource r;
    zx_status_t status = zx::resource::create(*standalone::GetSystemResource(), ZX_RSRC_KIND_SYSTEM,
                                              ZX_RSRC_SYSTEM_PROFILE_BASE, 1, nullptr, 0, &r);
    ZX_ASSERT_MSG(status == ZX_OK, "profile resource: %d", status);
    return r;
  }();
  return resource;
}

void SetCpu(zx_profile_info_t& info, uint32_t cpu) {
  info.flags |= ZX_PROFILE_INFO_FLAG_CPU_MASK;
  info.cpu_affinity_mask.mask[cpu / 64] = uint64_t{1} << (cpu % 64);
}

// Sys.profile(priority:mask:) and Sys.apply.
void ApplyFair(zx_handle_t thread, uint32_t cpu) {
  zx_profile_info_t info = {};
  info.flags = ZX_PROFILE_INFO_FLAG_PRIORITY;
  info.priority = ZX_PRIORITY_DEFAULT;
  SetCpu(info, cpu);
  zx_handle_t profile;
  ASSERT_OK(zx_profile_create(ProfileResource().get(), 0, &info, &profile));
  ASSERT_OK(zx_object_set_profile(thread, profile, 0));
  zx_handle_close(profile);
}

// Sys.profile(deadline: (capacity, period)): deadline = period, as croi's.
void ApplyDeadline(zx_handle_t thread, zx_duration_t capacity, zx_duration_t period,
                   uint32_t cpu) {
  zx_profile_info_t info = {};
  info.flags = ZX_PROFILE_INFO_FLAG_DEADLINE;
  info.deadline_params = {.capacity = capacity, .relative_deadline = period, .period = period};
  SetCpu(info, cpu);
  zx_handle_t profile;
  ASSERT_OK(zx_profile_create(ProfileResource().get(), 0, &info, &profile));
  ASSERT_OK(zx_object_set_profile(thread, profile, 0));
  zx_handle_close(profile);
}

zx_handle_t Self() { return zx_thread_self(); }
zx_handle_t ThreadHandle(thrd_t t) { return thrd_get_zx_handle(t); }

// Sys.take: wait for SIGNALED and clear it.
void Take(zx_handle_t event) {
  zx_object_wait_one(event, ZX_EVENT_SIGNALED, ZX_TIME_INFINITE, nullptr);
  zx_object_signal(event, ZX_EVENT_SIGNALED, 0);
}

// One line per result, easy to grep from the serial log.
void Report(const char* name, int64_t ns) { printf("croi-parity: %s %ld ns\n", name, ns); }

// A budget line as m2 prints it (user/m2/Main.swift), under m2's names, so
// tools/zircon-bench/compare.py reads both kernels' boots the same way.
void Budget(const char* name, int64_t ns) {
  printf("croi-parity: budget name=%s value=%ld unit=ns\n", name, ns);
}

// p10, median, p90, p99 and max of a sorted distribution.
template <typename T>
void ReportDistribution(const char* name, const std::vector<T>& sorted) {
  char line[64];
  for (auto [suffix, i] : {std::pair{"p10", sorted.size() / 10}, {"median", sorted.size() / 2},
                           {"p90", sorted.size() * 9 / 10}, {"p99", sorted.size() * 99 / 100},
                           {"max", sorted.size() - 1}}) {
    snprintf(line, sizeof line, "%s_%s", name, suffix);
    Report(line, static_cast<int64_t>(sorted[i]));
  }
}

// MARK: Null syscall

void NullSyscall() {
  constexpr uint64_t n = 10'000;
  zx_ticks_t start = zx_ticks_get();
  for (uint64_t i = 0; i < n; i++) {
    zx_syscall_test_0();
  }
  zx_ticks_t end = zx_ticks_get();
  Report("null_syscall_mean", TicksToNs(end - start) / n);
  Budget("syscall.null", TicksToNs(end - start) / n);
}

// MARK: vDSO clock (usertest.c's comparison)

void ClockMonotonic() {
  constexpr uint64_t n = 1000;
  zx_ticks_t start = zx_ticks_get();
  for (uint64_t i = 0; i < n; i++) {
    zx_clock_get_monotonic();
  }
  zx_ticks_t end = zx_ticks_get();
  Report("vdso_clock_mean", TicksToNs(end - start) / n);
  Budget("vdso.clock_monotonic", TicksToNs(end - start) / n);
}

// MARK: channel_call with a deadline caller, one core

zx_handle_t server_channel;

int Server(void*) {
  uint64_t message;
  uint32_t actual;
  for (;;) {
    zx_object_wait_one(server_channel, ZX_CHANNEL_READABLE | ZX_CHANNEL_PEER_CLOSED,
                       ZX_TIME_INFINITE, nullptr);
    zx_status_t read =
        zx_channel_read(server_channel, 0, &message, nullptr, sizeof message, 0, &actual, nullptr);
    if (read == ZX_ERR_SHOULD_WAIT) {
      continue;
    }
    if (read != ZX_OK) {
      break;  // PEER_CLOSED: the client is done
    }
    // The reply carries the call's txid (its first four bytes).
    zx_channel_write(server_channel, 0, &message, sizeof message, nullptr, 0);
  }
  zx_handle_close(server_channel);
  return 0;
}

void ChannelCall() {
  zx_handle_t client;
  ASSERT_OK(zx_channel_create(0, &client, &server_channel));
  thrd_t worker;
  ASSERT_EQ(thrd_create(&worker, Server, nullptr), thrd_success);
  ASSERT_NO_FATAL_FAILURE(ApplyFair(ThreadHandle(worker), kClientCpu));
  ASSERT_NO_FATAL_FAILURE(ApplyDeadline(Self(), ZX_MSEC(4), ZX_MSEC(10), kClientCpu));

  uint64_t request = 0, reply = 0;
  zx_channel_call_args_t args = {
      .wr_bytes = &request,
      .wr_handles = nullptr,
      .rd_bytes = &reply,
      .rd_handles = nullptr,
      .wr_num_bytes = sizeof request,
      .wr_num_handles = 0,
      .rd_num_bytes = sizeof reply,
      .rd_num_handles = 0,
  };
  uint32_t bytes, handles;
  auto call = [&] {
    return zx_channel_call(client, 0, ZX_TIME_INFINITE, &args, &bytes, &handles);
  };
  for (int i = 0; i < 100; i++) {
    ASSERT_OK(call(), "a warm-up call");
  }
  constexpr uint64_t kBatches = 10, kPerBatch = 200;
  std::vector<uint64_t> means;
  for (uint64_t batch = 0; batch < kBatches; batch++) {
    zx_ticks_t start = zx_ticks_get();
    for (uint64_t i = 0; i < kPerBatch; i++) {
      ASSERT_OK(call(), "a channel call");
    }
    means.push_back(TicksToNs(zx_ticks_get() - start) / kPerBatch);
  }
  zx_handle_close(client);  // the server sees PEER_CLOSED and exits
  thrd_join(worker, nullptr);
  std::sort(means.begin(), means.end());
  Report("channel_call_median_of_batch_means", means[means.size() / 2]);
  Budget("ipc.channel_call", means[means.size() / 2]);
  Report("channel_call_min_batch_mean", means.front());
  Report("channel_call_max_batch_mean", means.back());
}

// MARK: Port wake from another core

constexpr uint64_t kWakes = 200;
zx_handle_t wake_event, ready_event, go_event, wake_port;
zx_ticks_t woke_at[kWakes];

int Waiter(void*) {
  zx_port_packet_t packet;
  Take(go_event);  // pinned to its CPU first
  for (uint64_t i = 0; i < kWakes; i++) {
    zx_object_wait_async(wake_event, wake_port, i, ZX_EVENT_SIGNALED, 0);
    zx_object_signal(ready_event, 0, ZX_EVENT_SIGNALED);
    zx_port_wait(wake_port, ZX_TIME_INFINITE, &packet);
    woke_at[i] = zx_ticks_get();
    zx_object_signal(wake_event, ZX_EVENT_SIGNALED, 0);
  }
  return 0;
}

void PortWake() {
  ASSERT_OK(zx_event_create(0, &wake_event));
  ASSERT_OK(zx_event_create(0, &ready_event));
  ASSERT_OK(zx_event_create(0, &go_event));
  ASSERT_OK(zx_port_create(0, &wake_port));
  // Back to fair, from the call test's deadline.
  ASSERT_NO_FATAL_FAILURE(ApplyFair(Self(), kClientCpu));
  thrd_t worker;
  ASSERT_EQ(thrd_create(&worker, Waiter, nullptr), thrd_success);
  ASSERT_NO_FATAL_FAILURE(ApplyFair(ThreadHandle(worker), kWaiterCpu));
  zx_object_signal(go_event, 0, ZX_EVENT_SIGNALED);
  std::vector<zx_ticks_t> signaled_at(kWakes);
  for (uint64_t i = 0; i < kWakes; i++) {
    Take(ready_event);
    zx_nanosleep(zx_deadline_after(ZX_USEC(100)));  // the waiter is blocked by now
    signaled_at[i] = zx_ticks_get();
    zx_object_signal(wake_event, 0, ZX_EVENT_SIGNALED);
  }
  thrd_join(worker, nullptr);
  for (zx_handle_t h : {wake_event, ready_event, go_event, wake_port}) {
    zx_handle_close(h);
  }
  std::vector<uint64_t> latencies;
  for (uint64_t i = 0; i < kWakes; i++) {
    if (woke_at[i] >= signaled_at[i]) {
      latencies.push_back(TicksToNs(woke_at[i] - signaled_at[i]));
    }
  }
  ASSERT_FALSE(latencies.empty(), "measuring port wakes");
  std::sort(latencies.begin(), latencies.end());
  ReportDistribution("port_wake", latencies);
  Budget("port.wake_median", latencies[latencies.size() / 2]);
  Budget("port.wake_p99", latencies[latencies.size() * 99 / 100]);
}

// MARK: Wake error, real-time intent

// A deadline thread sleeping to absolute deadlines: how late it runs, by
// the clock the deadlines come from. p99.
//
// croi-parity.sleeper=fair runs the sleeper on a fair profile instead, to
// tell the timer's lateness from the deadline scheduler's.
void WakeError() {
  standalone::Option sleeper{"croi-parity.sleeper="};
  standalone::GetOptions({sleeper});
  if (sleeper.option == "croi-parity.sleeper=fair") {
    printf("croi-parity: sleeper on a fair profile\n");
    ASSERT_NO_FATAL_FAILURE(ApplyFair(Self(), kSleeperCpu));
  } else {
    ASSERT_NO_FATAL_FAILURE(ApplyDeadline(Self(), ZX_MSEC(1), ZX_MSEC(10), kSleeperCpu));
  }
  constexpr uint64_t n = 200;
  std::vector<int64_t> errors;
  for (uint64_t i = 0; i < n; i++) {
    zx_instant_mono_t deadline = zx_clock_get_monotonic() + ZX_USEC(500);
    zx_nanosleep(deadline);
    errors.push_back(zx_clock_get_monotonic() - deadline);
  }
  std::sort(errors.begin(), errors.end());
  ReportDistribution("wake_error", errors);
  Budget("timer.wake_error_p99", errors[errors.size() * 99 / 100]);
}

// In Bench.run's order: each step leaves the main thread's profile as the
// next expects (the call test's deadline, then fair, then the sleeper's).
TEST(CroiParity, Bench) {
  ASSERT_NO_FATAL_FAILURE(NullSyscall());
  ASSERT_NO_FATAL_FAILURE(ChannelCall());
  ASSERT_NO_FATAL_FAILURE(PortWake());
  ASSERT_NO_FATAL_FAILURE(WakeError());
  ASSERT_NO_FATAL_FAILURE(ClockMonotonic());
}

}  // namespace
