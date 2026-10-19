# frozen_string_literal: true

require_relative "../../../../../test_helper"

require "json"
require "tmpdir"

describe Eodhd::Commands::Process::Subcommands::Meta::Runner do
  class CaptureLog
    attr_reader :infos, :warnings, :errors

    def initialize
      @infos = []
      @warnings = []
      @errors = []
    end

    def info(message)
      @infos << message
    end

    def warn(message)
      @warnings << message
    end

    def error(message)
      @errors << message
    end
  end

  def write_intraday_month(io, symbol, month, datetimes)
    io.write_csv(
      intraday_month_path(symbol, month),
      "Timestamp,Datetime,Open,High,Low,Close,Volume\n" +
        datetimes.map { |datetime| "0,#{datetime},1,1,1,1,1\n" }.join
    )
  end

  def intraday_month_path(symbol, month)
    Eodhd::Shared::Path.data_intraday_month_file("US", symbol, 2024, month)
  end

  def intraday_ranges_with_summary(runner)
    summary = Eodhd::Shared::RunSummary.new(name: "process meta")
    result = runner.send(:get_intraday_ranges, parallel: false, workers: 1, summary: summary)
    [result, summary]
  end

  it "returns daily ranges as array of exchange/symbol/daily_range using first and last rows" do
    Dir.mktmpdir do |output_dir|
      io = Eodhd::Shared::Io.new(output_dir: output_dir)
      runner = Eodhd::Commands::Process::Subcommands::Meta::Runner.new(log: Logging::NullLogger.new, io: io)

      io.write_csv(
        Eodhd::Shared::Path.data_eod_symbol_file("US", "AAPL"),
        <<~CSV
          Date,Open,High,Low,Close,Volume
          2024-01-05,1,1,1,1,1
          2024-01-02,1,1,1,1,1
          2024-01-08,1,1,1,1,1
        CSV
      )

      io.write_csv(
        Eodhd::Shared::Path.data_eod_symbol_file("US", "MSFT"),
        <<~CSV
          Date,Open,High,Low,Close,Volume
          2024-02-10,1,1,1,1,1
          2024-02-11,1,1,1,1,1
        CSV
      )

      result = runner.send(:get_daily_ranges, parallel: false, workers: 1)

      assert_equal 2, result.size

      aapl = result.find { |row| row[:exchange] == "us" && row[:symbol] == "aapl" }
      refute_nil aapl
      assert_equal({ from: "2024-01-05", to: "2024-01-08" }, aapl[:daily_range])

      msft = result.find { |row| row[:exchange] == "us" && row[:symbol] == "msft" }
      refute_nil msft
      assert_equal({ from: "2024-02-10", to: "2024-02-11" }, msft[:daily_range])
    end
  end

  it "raises when a daily csv has no data rows" do
    Dir.mktmpdir do |output_dir|
      io = Eodhd::Shared::Io.new(output_dir: output_dir)
      runner = Eodhd::Commands::Process::Subcommands::Meta::Runner.new(log: Logging::NullLogger.new, io: io)

      io.write_csv(
        Eodhd::Shared::Path.data_eod_symbol_file("US", "AAPL"),
        <<~CSV
          Date,Open,High,Low,Close,Volume
        CSV
      )

      err = _ { runner.send(:get_daily_ranges, parallel: false, workers: 1) }
        .must_raise(Eodhd::Commands::Process::Subcommands::Meta::Runner::Error)
      _(err.message).must_match(/no data rows/i)
    end
  end

  it "logs EOD symbol processing progress every configured interval and on completion" do
    Dir.mktmpdir do |output_dir|
      io = Eodhd::Shared::Io.new(output_dir: output_dir)
      log = CaptureLog.new
      runner = Eodhd::Commands::Process::Subcommands::Meta::Runner.new(log: log, io: io)

      101.times do |index|
        symbol = format("SYM%03d", index)
        io.write_csv(
          Eodhd::Shared::Path.data_eod_symbol_file("US", symbol),
          <<~CSV
            Date,Open,High,Low,Close,Volume
            2024-01-01,1,1,1,1,1
            2024-01-02,1,1,1,1,1
          CSV
        )
      end

      runner.send(:get_daily_ranges, parallel: false, workers: 1)

      assert_includes(log.infos, "[us] Processed 100/101 EOD symbol file(s) (current: sym099)")
      assert_includes(log.infos, "[us] Processed 101/101 EOD symbol file(s) (current: sym100)")
    end
  end

  it "returns intraday ranges as array of exchange/symbol/intraday_range using sorted files and boundary rows" do
    Dir.mktmpdir do |output_dir|
      io = Eodhd::Shared::Io.new(output_dir: output_dir)
      runner = Eodhd::Commands::Process::Subcommands::Meta::Runner.new(log: Logging::NullLogger.new, io: io)

      io.write_csv(
        Eodhd::Shared::Path.data_intraday_month_file("US", "AAPL", 2024, 2),
        <<~CSV
          Timestamp,Datetime,Open,High,Low,Close,Volume
          1706776200,2024-02-01 09:30:00,1,1,1,1,1
          1706781600,2024-02-01 11:00:00,1,1,1,1,1
        CSV
      )

      io.write_csv(
        Eodhd::Shared::Path.data_intraday_month_file("US", "AAPL", 2024, 1),
        <<~CSV
          Timestamp,Datetime,Open,High,Low,Close,Volume
          1704187800,2024-01-02 09:30:00,1,1,1,1,1
          1704193200,2024-01-02 11:00:00,1,1,1,1,1
        CSV
      )

      io.write_csv(
        Eodhd::Shared::Path.data_intraday_month_file("US", "MSFT", 2024, 1),
        <<~CSV
          Timestamp,Datetime,Open,High,Low,Close,Volume
          1704187800,2024-01-02 09:30:00,1,1,1,1,1
          1704193200,2024-01-02 11:00:00,1,1,1,1,1
        CSV
      )

      result, summary = intraday_ranges_with_summary(runner)

      refute summary.failed?
      assert_equal 2, summary.total(:intraday)
      assert_equal 2, result.size

      aapl = result.find { |row| row[:exchange] == "us" && row[:symbol] == "aapl" }
      refute_nil aapl
      assert_equal(
        {
          from: "2024-01-02T09:30:00+00:00",
          to: "2024-02-01T11:00:00+00:00"
        },
        aapl[:intraday_range]
      )

      msft = result.find { |row| row[:exchange] == "us" && row[:symbol] == "msft" }
      refute_nil msft
      assert_equal(
        {
          from: "2024-01-02T09:30:00+00:00",
          to: "2024-01-02T11:00:00+00:00"
        },
        msft[:intraday_range]
      )
    end
  end

  it "starts the intraday range at the next file with data rows when the first file is empty" do
    Dir.mktmpdir do |output_dir|
      io = Eodhd::Shared::Io.new(output_dir: output_dir)
      log = CaptureLog.new
      runner = Eodhd::Commands::Process::Subcommands::Meta::Runner.new(log: log, io: io)

      write_intraday_month(io, "AAPL", 1, [])
      write_intraday_month(io, "AAPL", 2, ["2024-02-01 09:30:00", "2024-02-01 11:00:00"])
      write_intraday_month(io, "AAPL", 3, ["2024-03-01 09:30:00", "2024-03-01 11:00:00"])

      result, summary = intraday_ranges_with_summary(runner)

      assert_equal(
        [{
          exchange: "us",
          symbol: "aapl",
          intraday_range: { from: "2024-02-01T09:30:00+00:00", to: "2024-03-01T11:00:00+00:00" }
        }],
        result
      )
      assert summary.failed?
      assert_equal 1, summary.failures(:intraday)
      assert_equal 1, summary.total(:intraday)
      assert_equal(
        ["[us/aapl] Intraday month file(s) with no data rows: #{intraday_month_path('AAPL', 1)}"],
        summary.sample_errors
      )
      assert_includes(log.warnings, "Intraday month file has no data rows, skipping: #{intraday_month_path('AAPL', 1)}")
    end
  end

  it "ends the intraday range at the previous file with data rows when the last files are empty" do
    Dir.mktmpdir do |output_dir|
      io = Eodhd::Shared::Io.new(output_dir: output_dir)
      log = CaptureLog.new
      runner = Eodhd::Commands::Process::Subcommands::Meta::Runner.new(log: log, io: io)

      write_intraday_month(io, "AAPL", 1, ["2024-01-02 09:30:00", "2024-01-02 11:00:00"])
      write_intraday_month(io, "AAPL", 2, ["2024-02-01 09:30:00", "2024-02-01 11:00:00"])
      write_intraday_month(io, "AAPL", 3, [])
      write_intraday_month(io, "AAPL", 4, [])

      result, summary = intraday_ranges_with_summary(runner)

      assert_equal(
        { from: "2024-01-02T09:30:00+00:00", to: "2024-02-01T11:00:00+00:00" },
        result.first[:intraday_range]
      )
      assert summary.failed?
      assert_equal 1, summary.failures(:intraday)
      assert_equal(
        [
          "[us/aapl] Intraday month file(s) with no data rows: " \
          "#{intraday_month_path('AAPL', 3)}, #{intraday_month_path('AAPL', 4)}"
        ],
        summary.sample_errors
      )
      assert_includes(log.warnings, "Intraday month file has no data rows, skipping: #{intraday_month_path('AAPL', 3)}")
      assert_includes(log.warnings, "Intraday month file has no data rows, skipping: #{intraday_month_path('AAPL', 4)}")
    end
  end

  it "uses the only file with data rows for both ends of the intraday range" do
    Dir.mktmpdir do |output_dir|
      io = Eodhd::Shared::Io.new(output_dir: output_dir)
      runner = Eodhd::Commands::Process::Subcommands::Meta::Runner.new(log: Logging::NullLogger.new, io: io)

      write_intraday_month(io, "AAPL", 1, [])
      write_intraday_month(io, "AAPL", 2, ["2024-02-01 09:30:00", "2024-02-01 11:00:00"])
      write_intraday_month(io, "AAPL", 3, [])

      result, summary = intraday_ranges_with_summary(runner)

      assert_equal(
        { from: "2024-02-01T09:30:00+00:00", to: "2024-02-01T11:00:00+00:00" },
        result.first[:intraday_range]
      )
      assert_equal 1, summary.failures(:intraday)
    end
  end

  it "omits a symbol whose intraday month files all have no data rows and reports failure" do
    Dir.mktmpdir do |output_dir|
      io = Eodhd::Shared::Io.new(output_dir: output_dir)
      log = CaptureLog.new
      runner = Eodhd::Commands::Process::Subcommands::Meta::Runner.new(log: log, io: io)

      write_intraday_month(io, "AAPL", 1, [])
      write_intraday_month(io, "AAPL", 2, [])
      write_intraday_month(io, "MSFT", 1, ["2024-01-02 09:30:00", "2024-01-02 11:00:00"])

      summary = runner.process(parallel: false, workers: 1)

      result = JSON.parse(io.read_text(Eodhd::Shared::Path.meta_file))
      assert_equal %w[msft], result.map { |row| row["symbol"] }

      assert summary.failed?
      assert_equal 1, summary.failures(:intraday)
      assert_equal 2, summary.total(:intraday)
      assert_includes(
        log.warnings,
        "Intraday month files all have no data rows: #{Eodhd::Shared::Path.data_intraday_symbol_dir('US', 'AAPL')}"
      )
      assert_equal(
        [
          "Summary (process meta): intraday 1 of 2 failed",
          "First 1 of 1 error(s):",
          "  [us/aapl] Intraday month file(s) with no data rows: " \
          "#{intraday_month_path('AAPL', 1)}, #{intraday_month_path('AAPL', 2)}"
        ],
        log.errors
      )
    end
  end

  it "reports empty intraday month files in parallel mode" do
    Dir.mktmpdir do |output_dir|
      io = Eodhd::Shared::Io.new(output_dir: output_dir)
      log = CaptureLog.new
      runner = Eodhd::Commands::Process::Subcommands::Meta::Runner.new(log: log, io: io)

      write_intraday_month(io, "AAPL", 1, [])
      write_intraday_month(io, "AAPL", 2, ["2024-02-01 09:30:00", "2024-02-01 11:00:00"])
      write_intraday_month(io, "MSFT", 1, ["2024-01-02 09:30:00", "2024-01-02 11:00:00"])

      summary = runner.process(parallel: true, workers: 2)

      result = JSON.parse(io.read_text(Eodhd::Shared::Path.meta_file))
      assert_equal %w[aapl msft], result.map { |row| row["symbol"] }
      aapl = result.find { |row| row["symbol"] == "aapl" }
      assert_equal "2024-02-01T09:30:00+00:00", aapl["intraday"]["from"]

      assert summary.failed?
      assert_equal 1, summary.failures(:intraday)
      assert_equal 2, summary.total(:intraday)
      assert_equal "Summary (process meta): intraday 1 of 2 failed", log.errors.first
    end
  end

  it "combines daily and intraday by exchange/symbol and sorts results" do
    runner = Eodhd::Commands::Process::Subcommands::Meta::Runner.new(log: Logging::NullLogger.new, io: nil)

    daily_ranges = [
      {
        exchange: "us",
        symbol: "msft",
        daily_range: { from: "2024-01-01", to: "2024-01-31" }
      },
      {
        exchange: "us",
        symbol: "tsla",
        daily_range: { from: "2024-02-01", to: "2024-02-28" }
      }
    ]

    intraday_ranges = [
      {
        exchange: "us",
        symbol: "aapl",
        intraday_range: { from: "2024-01-02T09:30:00+00:00", to: "2024-01-02T16:00:00+00:00" }
      },
      {
        exchange: "us",
        symbol: "tsla",
        intraday_range: { from: "2024-02-01T09:30:00+00:00", to: "2024-02-01T16:00:00+00:00" }
      }
    ]

    result = runner.send(:combine_ranges, daily_ranges, intraday_ranges)

    assert_equal 3, result.size
    assert_equal %w[aapl msft tsla], result.map { |row| row[:symbol] }

    aapl = result.find { |row| row[:symbol] == "aapl" }
    assert_nil aapl[:daily]
    refute_nil aapl[:intraday]

    msft = result.find { |row| row[:symbol] == "msft" }
    refute_nil msft[:daily]
    assert_nil msft[:intraday]

    tsla = result.find { |row| row[:symbol] == "tsla" }
    refute_nil tsla[:daily]
    refute_nil tsla[:intraday]
  end

  it "writes merged meta.json with nil for missing ranges" do
    Dir.mktmpdir do |output_dir|
      io = Eodhd::Shared::Io.new(output_dir: output_dir)
      runner = Eodhd::Commands::Process::Subcommands::Meta::Runner.new(log: Logging::NullLogger.new, io: io)

      io.write_csv(
        Eodhd::Shared::Path.data_eod_symbol_file("US", "MSFT"),
        <<~CSV
          Date,Open,High,Low,Close,Volume
          2024-02-10,1,1,1,1,1
          2024-02-11,1,1,1,1,1
        CSV
      )

      io.write_csv(
        Eodhd::Shared::Path.data_intraday_month_file("US", "AAPL", 2024, 1),
        <<~CSV
          Timestamp,Datetime,Open,High,Low,Close,Volume
          1704187800,2024-01-02 09:30:00,1,1,1,1,1
          1704193200,2024-01-02 11:00:00,1,1,1,1,1
        CSV
      )

      summary = runner.process(parallel: false, workers: 1)

      refute summary.failed?
      assert_equal 1, summary.total(:intraday)

      result = JSON.parse(io.read_text(Eodhd::Shared::Path.meta_file))
      assert_equal 2, result.size
      assert_equal %w[aapl msft], result.map { |row| row["symbol"] }

      aapl = result.find { |row| row["symbol"] == "aapl" }
      assert_nil aapl["daily"]
      refute_nil aapl["intraday"]

      msft = result.find { |row| row["symbol"] == "msft" }
      refute_nil msft["daily"]
      assert_nil msft["intraday"]
    end
  end

  it "writes merged meta.json in parallel mode" do
    Dir.mktmpdir do |output_dir|
      io = Eodhd::Shared::Io.new(output_dir: output_dir)
      runner = Eodhd::Commands::Process::Subcommands::Meta::Runner.new(log: Logging::NullLogger.new, io: io)

      io.write_csv(
        Eodhd::Shared::Path.data_eod_symbol_file("US", "MSFT"),
        <<~CSV
          Date,Open,High,Low,Close,Volume
          2024-02-10,1,1,1,1,1
          2024-02-11,1,1,1,1,1
        CSV
      )

      io.write_csv(
        Eodhd::Shared::Path.data_intraday_month_file("US", "AAPL", 2024, 1),
        <<~CSV
          Timestamp,Datetime,Open,High,Low,Close,Volume
          1704187800,2024-01-02 09:30:00,1,1,1,1,1
          1704193200,2024-01-02 11:00:00,1,1,1,1,1
        CSV
      )

      summary = runner.process(parallel: true, workers: 2)

      refute summary.failed?
      assert_equal 1, summary.total(:intraday)

      result = JSON.parse(io.read_text(Eodhd::Shared::Path.meta_file))
      assert_equal 2, result.size
      assert_equal %w[aapl msft], result.map { |row| row["symbol"] }
    end
  end
end
