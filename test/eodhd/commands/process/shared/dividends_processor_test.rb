# frozen_string_literal: true

require_relative "../../../../test_helper"

require "date"

describe Eodhd::Commands::Process::Shared::DividendsProcessor do
  it "returns empty array for nil dividends" do
    result = Eodhd::Commands::Process::Shared::DividendsProcessor.process(nil, [], exchange: "us")
    _(result).must_equal []
  end

  it "returns empty array for empty dividends" do
    result = Eodhd::Commands::Process::Shared::DividendsProcessor.process([], [], exchange: "us")
    _(result).must_equal []
  end

  it "computes multiplier using previous close" do
    dividends = [dividend("2024-01-11", 1.0)]
    data = [row("2024-01-12", 104), row("2024-01-10", 100), row("2024-01-11", 102)]

    result = Eodhd::Commands::Process::Shared::DividendsProcessor.process(dividends, data, exchange: "us")

    expected = [
      { timestamp: date_to_ts("2024-01-11"), multiplier: 0.99 }
    ]

    _(result).must_equal expected
  end

  it "calculates cumulative multipliers for multiple dividends" do
    dividends = [
      dividend("2024-01-10", 2.0),
      dividend("2024-01-12", 3.0)
    ]

    data = [
      row("2024-01-08", 90),
      row("2024-01-09", 100),
      row("2024-01-10", 110),
      row("2024-01-11", 120),
      row("2024-01-12", 130)
    ]

    result = Eodhd::Commands::Process::Shared::DividendsProcessor.process(dividends, data, exchange: "us")

    m1 = (100.0 - 2.0) / 100.0
    m2 = (120.0 - 3.0) / 120.0

    expected = [
      { timestamp: date_to_ts("2024-01-10"), multiplier: m1 * m2 },
      { timestamp: date_to_ts("2024-01-12"), multiplier: m2 }
    ]

    _(result).must_equal expected
  end

  it "skips dividend when no previous price is available" do
    dividends = [dividend("2024-01-10", 1.0)]
    data = [row("2024-01-10", 100)]

    result = Eodhd::Commands::Process::Shared::DividendsProcessor.process(dividends, data, exchange: "us")
    _(result).must_equal []
  end

  it "raises when previous close is non-positive" do
    dividends = [dividend("2024-01-11", 1.0)]
    data = [row("2024-01-10", 0)]

    err = _(-> { Eodhd::Commands::Process::Shared::DividendsProcessor.process(dividends, data, exchange: "us") }).must_raise(Eodhd::Commands::Process::Shared::DividendsProcessor::Error)
    _(err.message).must_match(/must be positive/)
  end

  it "raises when dividend wipes out or exceeds previous close" do
    dividends = [dividend("2024-01-11", 5.0)]
    data = [row("2024-01-10", 5.0)]

    err = _(-> { Eodhd::Commands::Process::Shared::DividendsProcessor.process(dividends, data, exchange: "us") }).must_raise(Eodhd::Commands::Process::Shared::DividendsProcessor::Error)
    _(err.message).must_match(/too large/)
  end

  it "places ex-dates at New York midnight regardless of the machine's time zone" do
    dividends = [
      dividend("2024-01-10", 1.0),
      dividend("2024-06-26", 2.0)
    ]

    data = [
      { timestamp: Time.utc(2024, 1, 9, 21).to_i, close: 100.0 },
      { timestamp: Time.utc(2024, 6, 25, 21).to_i, close: 200.0 }
    ]

    # Standard time: New York midnight is 05:00 UTC; daylight saving time: 04:00 UTC.
    expected = [
      { timestamp: Time.utc(2024, 1, 10, 5).to_i, multiplier: 0.99 * 0.99 },
      { timestamp: Time.utc(2024, 6, 26, 4).to_i, multiplier: 0.99 }
    ]

    MACHINE_TIME_ZONES.each do |tz|
      result = with_time_zone(tz) { Eodhd::Commands::Process::Shared::DividendsProcessor.process(dividends, data, exchange: "us") }
      _(result).must_equal expected, "TZ=#{tz}"
    end
  end

  def row(date_str, close)
    ts = date_to_ts(date_str)
    { timestamp: ts, close: Float(close) }
  end

  def dividend(date_str, unadjusted_value)
    Eodhd::Shared::Parsing::DividendsParser::Dividend.new(
      date: Date.iso8601(date_str),
      declaration_date: nil,
      record_date: nil,
      payment_date: nil,
      period: nil,
      value: unadjusted_value,
      unadjusted_value: unadjusted_value,
      currency: "USD"
    )
  end

  def date_to_ts(date_str)
    Eodhd::Shared::ExchangeTime.day_start_timestamp("us", Date.iso8601(date_str))
  end
end
