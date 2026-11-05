# frozen_string_literal: true

module BeakerKubevirt
  # A monotonic clock for deadline and grace-window arithmetic, shared by the
  # hypervisor and the port forwarder. Time.now is wall-clock and can jump on an
  # NTP adjustment, shortening or extending a wait.
  module MonotonicClock
    private

    # @return [Float] seconds from an arbitrary fixed point
    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
