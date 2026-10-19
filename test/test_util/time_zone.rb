# frozen_string_literal: true

module TestSupport
  module TimeZone
    # Machine time zones that put local midnight on either side of New York
    # midnight, and on either side of UTC midnight.
    MACHINE_TIME_ZONES = ["UTC", "Europe/Zagreb", "Asia/Tokyo", "America/Los_Angeles"].freeze

    module_function

    # Runs the block with the process time zone set to `tz`. Ruby resets its
    # local time zone cache when ENV["TZ"] is assigned.
    def with_time_zone(tz)
      previous = ENV["TZ"]
      ENV["TZ"] = tz
      yield
    ensure
      ENV["TZ"] = previous
    end
  end
end
