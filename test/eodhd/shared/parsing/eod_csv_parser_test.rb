# frozen_string_literal: true

require_relative "../../../test_helper"

require "date"

describe Eodhd::Shared::Parsing::EodCsvParser do
  it "parses EOD rows" do
    raw = <<~CSV
      Date,Open,High,Low,Close,Adjusted_close,Volume
      2024-01-10,10,11,9,10.5,10.3,1000
      2024-01-11,20.1,21.2,19.9,20.5,20.5,2000
      ,1,1,1,1,1,1
    CSV

    result = Eodhd::Shared::Parsing::EodCsvParser.parse(raw, exchange: "us")

    expected = [
      {
        timestamp: Time.utc(2024, 1, 10, 5).to_i,
        date: Date.new(2024, 1, 10),
        open: 10.0,
        high: 11.0,
        low: 9.0,
        close: 10.5,
        volume: 1000
      },
      {
        timestamp: Time.utc(2024, 1, 11, 5).to_i,
        date: Date.new(2024, 1, 11),
        open: 20.1,
        high: 21.2,
        low: 19.9,
        close: 20.5,
        volume: 2000
      }
    ]

    assert_equal expected, result
  end

  it "timestamps rows at New York midnight regardless of the machine's time zone" do
    raw = <<~CSV
      Date,Open,High,Low,Close,Adjusted_close,Volume
      2024-01-10,10,11,9,10.5,10.3,1000
      2024-06-26,20.1,21.2,19.9,20.5,20.5,2000
    CSV

    # Standard time: New York midnight is 05:00 UTC; daylight saving time: 04:00 UTC.
    expected = [Time.utc(2024, 1, 10, 5).to_i, Time.utc(2024, 6, 26, 4).to_i]

    MACHINE_TIME_ZONES.each do |tz|
      result = with_time_zone(tz) { Eodhd::Shared::Parsing::EodCsvParser.parse(raw, exchange: "us") }
      assert_equal expected, result.map { |row| row[:timestamp] }, "TZ=#{tz}"
    end
  end

  it "raises on unsupported exchange" do
    raw = <<~CSV
      Date,Open,High,Low,Close,Adjusted_close,Volume
      2024-01-10,10,11,9,10.5,10.3,1000
    CSV

    _ { Eodhd::Shared::Parsing::EodCsvParser.parse(raw, exchange: "xetra") }.must_raise(Eodhd::Shared::ExchangeTime::Error)
  end

  it "raises on missing columns" do
    raw = <<~CSV
      Date,Open,High,Low,Close,Volume
      2024-01-10,10,11,9,10.5,1000
    CSV

    err = _ { Eodhd::Shared::Parsing::EodCsvParser.parse(raw, exchange: "us") }.must_raise(Eodhd::Shared::Parsing::EodCsvParser::Error)
    _(err.message).must_match(/Missing required columns/i)
  end

  it "raises on invalid data" do
    raw = <<~CSV
      Date,Open,High,Low,Close,Adjusted_close,Volume
      not-a-date,10,11,9,10.5,10.3,1000
    CSV

    err = _ { Eodhd::Shared::Parsing::EodCsvParser.parse(raw, exchange: "us") }.must_raise(Eodhd::Shared::Parsing::EodCsvParser::Error)
    _(err.message).must_match(/Invalid data/i)
  end
end
