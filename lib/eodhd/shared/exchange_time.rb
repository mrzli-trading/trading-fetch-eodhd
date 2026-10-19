# frozen_string_literal: true

require "tzinfo"

module Eodhd
  module Shared
    class ExchangeTime
      class Error < StandardError; end

      # Exchange code (kebab-cased, as used in paths) to IANA time zone.
      TIME_ZONES = {
        "us" => "America/New_York"
      }.freeze

      class << self
        # Returns unix epoch seconds of midnight at the start of the trading date
        # in the exchange's time zone. Independent of the machine's time zone.
        def day_start_timestamp(exchange, date)
          time_zone(exchange).local_time(date.year, date.month, date.day).to_i
        end

        private

        def time_zone(exchange)
          code = Util::String.kebab_case(exchange)
          identifier = TIME_ZONES[code]
          raise Error, "Unsupported exchange for time zone: '#{exchange}'" if identifier.nil?

          TZInfo::Timezone.get(identifier)
        end
      end
    end
  end
end
