# frozen_string_literal: true

require_relative "../../../../test_helper"

describe Eodhd::Commands::Process::Shared::SplitsProcessor do
  it "returns empty array for nil splits" do
    result = Eodhd::Commands::Process::Shared::SplitsProcessor.process(nil, exchange: "us")
    assert_equal [], result
  end

  it "returns empty array for empty splits" do
    result = Eodhd::Commands::Process::Shared::SplitsProcessor.process([], exchange: "us")
    assert_equal [], result
  end

  it "processes single split" do
    splits_json = <<~JSON
      [
        {"date":"2014-11-03","split":"1398.000000/1000.000000"}
      ]
    JSON

    splits = Eodhd::Shared::Parsing::SplitsParser.parse(splits_json)
    result = Eodhd::Commands::Process::Shared::SplitsProcessor.process(splits, exchange: "us")

    expected = [
      {
        timestamp: Time.utc(2014, 11, 3, 5).to_i,
        factor: Rational(1398, 1000)
      }
    ]

    assert_equal expected, result
  end

  it "processes multiple splits with cumulative factors" do
    splits_json = <<~JSON
      [
        {"date":"2000-06-21","split":"2.000000/1.000000"},
        {"date":"2014-06-09","split":"7.000000/1.000000"},
        {"date":"2024-01-10","split":"4.000000/1.000000"}
      ]
    JSON

    splits = Eodhd::Shared::Parsing::SplitsParser.parse(splits_json)
    result = Eodhd::Commands::Process::Shared::SplitsProcessor.process(splits, exchange: "us")

    expected = [
      { timestamp: Time.utc(2000, 6, 21, 4).to_i, factor: Rational(56, 1) },
      { timestamp: Time.utc(2014, 6, 9, 4).to_i, factor: Rational(28, 1) },
      { timestamp: Time.utc(2024, 1, 10, 5).to_i, factor: Rational(4, 1) }
    ]

    assert_equal expected, result
  end

  it "handles fractional split ratios" do
    splits_json = <<~JSON
      [
        {"date":"2020-01-01","split":"3.000000/2.000000"},
        {"date":"2021-01-01","split":"5.000000/4.000000"}
      ]
    JSON

    splits = Eodhd::Shared::Parsing::SplitsParser.parse(splits_json)
    result = Eodhd::Commands::Process::Shared::SplitsProcessor.process(splits, exchange: "us")

    expected = [
      { timestamp: Time.utc(2020, 1, 1, 5).to_i, factor: Rational(15, 8) },
      { timestamp: Time.utc(2021, 1, 1, 5).to_i, factor: Rational(5, 4) }
    ]

    assert_equal expected, result
  end

  it "places splits at New York midnight regardless of the machine's time zone" do
    splits_json = <<~JSON
      [
        {"date":"2024-01-10","split":"4.000000/1.000000"},
        {"date":"2024-06-26","split":"50.000000/1.000000"}
      ]
    JSON

    splits = Eodhd::Shared::Parsing::SplitsParser.parse(splits_json)

    # Standard time: New York midnight is 05:00 UTC; daylight saving time: 04:00 UTC.
    expected = [
      { timestamp: Time.utc(2024, 1, 10, 5).to_i, factor: 200.0 },
      { timestamp: Time.utc(2024, 6, 26, 4).to_i, factor: 50.0 }
    ]

    MACHINE_TIME_ZONES.each do |tz|
      result = with_time_zone(tz) { Eodhd::Commands::Process::Shared::SplitsProcessor.process(splits, exchange: "us") }
      assert_equal expected, result, "TZ=#{tz}"
    end
  end

  # Regression: CMG 50:1 split on 2024-06-26. Evening-session bars on 2024-06-25
  # from 22:00 UTC (local midnight in Central Europe) were left unadjusted.
  it "adjusts intraday bars before New York midnight of a daylight-saving-time split date" do
    splits_json = <<~JSON
      [
        {"date":"2024-06-26","split":"50.000000/1.000000"}
      ]
    JSON

    splits = Eodhd::Shared::Parsing::SplitsParser.parse(splits_json)

    rows = [
      bar(Time.utc(2024, 6, 25, 21, 59), 3295.9),
      bar(Time.utc(2024, 6, 25, 22, 0), 3297.88),
      bar(Time.utc(2024, 6, 26, 0, 30), 3300.0),
      bar(Time.utc(2024, 6, 26, 3, 59), 3300.0),
      bar(Time.utc(2024, 6, 26, 4, 0), 66.0),
      bar(Time.utc(2024, 6, 26, 8, 0), 66.5)
    ]

    expected_closes = [65.918, 65.9576, 66.0, 66.0, 66.0, 66.5]

    MACHINE_TIME_ZONES.each do |tz|
      adjusted = with_time_zone(tz) do
        segments = Eodhd::Commands::Process::Shared::SplitsProcessor.process(splits, exchange: "us")
        Eodhd::Commands::Process::Shared::PriceAdjust.apply(rows, segments, [])
      end

      adjusted.zip(expected_closes).each do |row, expected_close|
        assert_in_delta expected_close, row[:close], 1e-9, "TZ=#{tz} at #{Time.at(row[:timestamp]).utc}"
      end
    end
  end

  it "adjusts intraday bars before New York midnight of a standard-time split date" do
    splits_json = <<~JSON
      [
        {"date":"2024-01-10","split":"2.000000/1.000000"}
      ]
    JSON

    splits = Eodhd::Shared::Parsing::SplitsParser.parse(splits_json)

    rows = [
      bar(Time.utc(2024, 1, 10, 0, 30), 100.0),
      bar(Time.utc(2024, 1, 10, 4, 59), 100.0),
      bar(Time.utc(2024, 1, 10, 5, 0), 50.0)
    ]

    MACHINE_TIME_ZONES.each do |tz|
      adjusted = with_time_zone(tz) do
        segments = Eodhd::Commands::Process::Shared::SplitsProcessor.process(splits, exchange: "us")
        Eodhd::Commands::Process::Shared::PriceAdjust.apply(rows, segments, [])
      end

      assert_equal [50.0, 50.0, 50.0], adjusted.map { |row| row[:close] }, "TZ=#{tz}"
    end
  end

  def bar(time, price)
    { timestamp: time.to_i, open: price, high: price, low: price, close: price, volume: 100 }
  end
end
