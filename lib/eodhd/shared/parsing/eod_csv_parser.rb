# frozen_string_literal: true

require "csv"
require "date"

module Eodhd
  module Shared
    module Parsing
      class EodCsvParser
        class Error < StandardError; end

        class << self
          def parse(raw_csv, exchange:)
            csv = CSV.parse(raw_csv, headers: true)
            validate_headers(csv.headers)

            rows = []
            csv.each do |row|
              date_str = row["Date"].to_s.strip
              next if date_str.empty?

              begin
                date = Date.iso8601(date_str)
                open = Float(row["Open"])
                high = Float(row["High"])
                low = Float(row["Low"])
                close = Float(row["Close"])
                volume = Integer(row["Volume"])
              rescue StandardError => e
                raise Error, "Invalid data in row '#{date_str}': #{e.message}"
              end

              timestamp = Eodhd::Shared::ExchangeTime.day_start_timestamp(exchange, date)

              rows << {
                timestamp: timestamp,
                date: date,
                open: open,
                high: high,
                low: low,
                close: close,
                volume: volume
              }
            end

            rows
          rescue ArgumentError => e
            raise Error, e.message
          end

          private

          def validate_headers(headers)
            headers = headers.compact.map(&:to_s)
            required = ["Date", "Open", "High", "Low", "Close", "Adjusted_close", "Volume"]

            missing = required.reject { |h| headers.include?(h) }
            return if missing.empty?

            raise Error, "Missing required columns: #{missing.join(", ")}" 
          end
        end
      end
    end
  end
end
