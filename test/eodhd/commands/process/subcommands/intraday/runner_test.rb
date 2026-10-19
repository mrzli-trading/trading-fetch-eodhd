# frozen_string_literal: true

require_relative "../../../../../test_helper"

require "csv"
require "tmpdir"

describe Eodhd::Commands::Process::Subcommands::Intraday::Runner do
  class ProcessIntradayCaptureLog
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

  # Official daily closes: 11 on 2024-01-02, 12 on 2024-01-03.
  PROCESS_INTRADAY_RAW_EOD_CSV = <<~CSV
    Date,Open,High,Low,Close,Adjusted_close,Volume
    2024-01-02,10,12,9,11,11,1000
    2024-01-03,11,13,10,12,12,1100
  CSV

  # Ex-date 2024-01-04; previous official close 12, so the multiplier is
  # (12 - 1.2) / 12 = 0.9.
  PROCESS_INTRADAY_DIVIDENDS_JSON = <<~JSON
    [
      {
        "date": "2024-01-04",
        "declarationDate": null,
        "recordDate": null,
        "paymentDate": null,
        "period": "Quarterly",
        "value": 1.2,
        "unadjustedValue": 1.2,
        "currency": "USD"
      }
    ]
  JSON

  def intraday_row(time, close)
    [time.to_i, 0, time.strftime("%Y-%m-%d %H:%M:%S"), close, close, close, close, 100]
  end

  # The last bar before New York midnight is an evening bar (18:00 New York)
  # whose close of 15 differs from the official daily close of 12.
  def raw_intraday_csv
    CSV.generate do |csv|
      csv << ["Timestamp", "Gmtoffset", "Datetime", "Open", "High", "Low", "Close", "Volume"]
      csv << intraday_row(Time.utc(2024, 1, 3, 14, 30), 12.0)
      csv << intraday_row(Time.utc(2024, 1, 3, 23, 0), 15.0)
      csv << intraday_row(Time.utc(2024, 1, 4, 14, 30), 13.0)
    end
  end

  def write_raw_intraday(io, symbol)
    path = Eodhd::Shared::Path.raw_intraday_processed_month_file("US", symbol, 2024, 1)
    io.write_csv(path, raw_intraday_csv)
  end

  def write_raw_eod(io, symbol)
    io.write_csv(Eodhd::Shared::Path.raw_eod_file("US", symbol), PROCESS_INTRADAY_RAW_EOD_CSV)
  end

  def write_dividends(io, symbol)
    io.write_json(Eodhd::Shared::Path.dividends_file("US", symbol), PROCESS_INTRADAY_DIVIDENDS_JSON, false)
  end

  def run_process_intraday(io)
    log = ProcessIntradayCaptureLog.new
    runner = Eodhd::Commands::Process::Subcommands::Intraday::Runner.new(log: log, io: io)
    summary = runner.process(force: true, parallel: false, workers: 1)
    [summary, log]
  end

  def run_process_eod(io)
    log = ProcessIntradayCaptureLog.new
    runner = Eodhd::Commands::Process::Subcommands::Eod::Runner.new(log: log, io: io)
    summary = runner.process(force: true, parallel: false, workers: 1)
    [summary, log]
  end

  def processed_intraday_closes(io, symbol)
    path = Eodhd::Shared::Path.data_intraday_month_file("US", symbol, 2024, 1)
    CSV.parse(io.read_text(path), headers: true).map { |row| Float(row["Close"]) }
  end

  def processed_eod_closes(io, symbol)
    path = Eodhd::Shared::Path.data_eod_symbol_file("US", symbol)
    CSV.parse(io.read_text(path), headers: true).to_h { |row| [row["Date"], Float(row["Close"])] }
  end

  it "uses the official daily close for dividend multipliers, matching process eod" do
    Dir.mktmpdir do |output_dir|
      io = Eodhd::Shared::Io.new(output_dir: output_dir)
      write_raw_intraday(io, "AAA")
      write_raw_eod(io, "AAA")
      write_dividends(io, "AAA")

      intraday_summary, = run_process_intraday(io)
      eod_summary, = run_process_eod(io)

      refute intraday_summary.failed?
      refute eod_summary.failed?

      eod_multiplier = processed_eod_closes(io, "AAA").fetch("2024-01-03") / 12.0
      intraday_closes = processed_intraday_closes(io, "AAA")
      intraday_multiplier = intraday_closes[0] / 12.0

      assert_in_delta 0.9, eod_multiplier, 1e-9
      assert_in_delta eod_multiplier, intraday_multiplier, 1e-9
      assert_in_delta 15.0 * 0.9, intraday_closes[1], 1e-9
      assert_in_delta 13.0, intraday_closes[2], 1e-9
    end
  end

  it "fails a symbol with dividends but no raw daily file" do
    Dir.mktmpdir do |output_dir|
      io = Eodhd::Shared::Io.new(output_dir: output_dir)
      write_raw_intraday(io, "AAA")
      write_raw_eod(io, "AAA")
      write_dividends(io, "AAA")
      write_raw_intraday(io, "BBB")
      write_dividends(io, "BBB")

      summary, log = run_process_intraday(io)

      assert summary.failed?
      assert_equal 1, summary.failures(:intraday)
      assert_equal 2, summary.total(:intraday)
      assert_equal "Summary (process intraday): intraday 1 of 2 failed", log.errors[0]
      expected_message = "  [us/bbb] Failed processing intraday: " \
        "Eodhd::Commands::Process::Subcommands::Intraday::Runner::Error: " \
        "Missing raw daily file #{Eodhd::Shared::Path.raw_eod_file("US", "BBB")}, needed for dividend adjustment"
      assert_equal expected_message, log.errors[2]
      refute io.file_exists?(Eodhd::Shared::Path.data_intraday_month_file("US", "BBB", 2024, 1))
    end
  end

  it "processes a symbol with no dividends and no raw daily file" do
    Dir.mktmpdir do |output_dir|
      io = Eodhd::Shared::Io.new(output_dir: output_dir)
      write_raw_intraday(io, "AAA")

      summary, = run_process_intraday(io)

      refute summary.failed?
      assert_equal 1, summary.total(:intraday)
      assert_equal [12.0, 15.0, 13.0], processed_intraday_closes(io, "AAA")
    end
  end
end
