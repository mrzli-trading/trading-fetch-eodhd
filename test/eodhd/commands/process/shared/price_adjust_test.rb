
# frozen_string_literal: true

require_relative "../../../../test_helper"

require "date"

describe Eodhd::Commands::Process::Shared::PriceAdjust do
  it "returns rows unchanged when no splits and no dividends" do
    rows = [
      { timestamp: Time.utc(2024, 1, 10).to_i, date: Date.new(2024, 1, 10), open: 10.0, high: 11.0, low: 9.0, close: 10.5, volume: 100 }
    ]

    adjusted = Eodhd::Commands::Process::Shared::PriceAdjust.apply(rows, [], [])

    _(adjusted).must_equal rows
  end

  it "applies cumulative split factors to prior rows" do
    rows = [
      drow("1999-11-18", "56", "56", "56", "56", 10),
      drow("1999-11-19", "112", "112", "112", "112", 20),
      drow("2000-06-21", "28", "28", "28", "28", 30),
      drow("2000-06-22", "56", "56", "56", "56", 40),
      drow("2014-06-09", "40", "40", "40", "40", 50),
      drow("2014-06-10", "20", "20", "20", "20", 60),
      drow("2024-01-10", "7", "7", "7", "7", 1),
      drow("2024-01-11", "8", "8", "8", "8", 2)
    ]

    splits_json = <<~JSON
      [
        {"date":"2000-06-21","split":"2.000000/1.000000"},
        {"date":"2014-06-09","split":"7.000000/1.000000"},
        {"date":"2024-01-10","split":"4.000000/1.000000"}
      ]
    JSON

    raw_splits = Eodhd::Shared::Parsing::SplitsParser.parse(splits_json)
    segments = Eodhd::Commands::Process::Shared::SplitsProcessor.process(raw_splits, exchange: "us")

    adjusted = Eodhd::Commands::Process::Shared::PriceAdjust.apply(rows, segments, [])

    expected = [
      drow("1999-11-18", "1.0", "1.0", "1.0", "1.0", 560),
      drow("1999-11-19", "2.0", "2.0", "2.0", "2.0", 1120),
      drow("2000-06-21", "1.0", "1.0", "1.0", "1.0", 840),
      drow("2000-06-22", "2.0", "2.0", "2.0", "2.0", 1120),
      drow("2014-06-09", "10.0", "10.0", "10.0", "10.0", 200),
      drow("2014-06-10", "5.0", "5.0", "5.0", "5.0", 240),
      drow("2024-01-10", "7.0", "7.0", "7.0", "7.0", 1),
      drow("2024-01-11", "8.0", "8.0", "8.0", "8.0", 2)
    ]

    _(adjusted).must_equal expected
  end

  it "applies dividend multipliers to prior rows (prices only)" do
    rows = [
      drow("2024-01-09", "100", "100", "100", "100", 10),
      drow("2024-01-10", "110", "110", "110", "110", 20),
      drow("2024-01-11", "120", "120", "120", "120", 30)
    ]

    # dividend on 2024-01-11 uses previous close (2024-01-10 close=110)
    multiplier = (110.0 - 2.0) / 110.0
    dividends = [ { timestamp: day_start("2024-01-11"), multiplier: multiplier } ]

    adjusted = Eodhd::Commands::Process::Shared::PriceAdjust.apply(rows, [], dividends)

    expected = [
      drow("2024-01-09", (100.0 * multiplier).to_s, (100.0 * multiplier).to_s, (100.0 * multiplier).to_s, (100.0 * multiplier).to_s, 10),
      drow("2024-01-10", (110.0 * multiplier).to_s, (110.0 * multiplier).to_s, (110.0 * multiplier).to_s, (110.0 * multiplier).to_s, 20),
      drow("2024-01-11", "120.0", "120.0", "120.0", "120.0", 30)
    ]

    _(adjusted).must_equal expected
  end

  it "combines splits and dividends adjustments" do
    rows = [
      drow("2024-01-08", "100", "100", "100", "100", 10),
      drow("2024-01-09", "110", "110", "110", "110", 20),
      drow("2024-01-10", "120", "120", "120", "120", 30),
      drow("2024-01-11", "130", "130", "130", "130", 40)
    ]

    # One split on 2024-01-10: factor=2 (affects rows before 2024-01-10)
    splits = [ { timestamp: day_start("2024-01-10"), factor: 2.0 } ]

    # One dividend on 2024-01-11 with prev close 120 and value 10 -> multiplier = (120-10)/120 = 0.9166...
    dividends = [ { timestamp: day_start("2024-01-11"), multiplier: (120.0 - 10.0) / 120.0 } ]

    adjusted = Eodhd::Commands::Process::Shared::PriceAdjust.apply(rows, splits, dividends)

    expected = [
      drow("2024-01-08", "45.83333333333333", "45.83333333333333", "45.83333333333333", "45.83333333333333", 20),
      drow("2024-01-09", "50.416666666666664", "50.416666666666664", "50.416666666666664", "50.416666666666664", 40),
      drow("2024-01-10", "110.0", "110.0", "110.0", "110.0", 30),
      drow("2024-01-11", "130.0", "130.0", "130.0", "130.0", 40)
    ]

    _(adjusted).must_equal expected
  end

  def day_start(date_str)
    Eodhd::Shared::ExchangeTime.day_start_timestamp("us", Date.parse(date_str))
  end

  def drow(date_str, open, high, low, close, volume)
    date = Date.parse(date_str)
    {
      timestamp: day_start(date_str),
      date: date,
      open: Float(open),
      high: Float(high),
      low: Float(low),
      close: Float(close),
      volume: volume
    }
  end
end
