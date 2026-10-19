# frozen_string_literal: true

require_relative "../../../../../test_helper"

require "tmpdir"

describe Eodhd::Commands::Process::Subcommands::Eod::Runner do
  class ProcessEodCaptureLog
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

  PROCESS_EOD_RAW_CSV = <<~CSV
    Date,Open,High,Low,Close,Adjusted_close,Volume
    2024-01-02,10,12,9,11,11,1000
    2024-01-03,11,13,10,12,12,1100
  CSV

  def write_raw_eod(io, symbols)
    symbols.each do |symbol|
      io.write_csv(Eodhd::Shared::Path.raw_eod_file("US", symbol), PROCESS_EOD_RAW_CSV)
    end
  end

  def run_process(io, parallel:)
    log = ProcessEodCaptureLog.new
    runner = Eodhd::Commands::Process::Subcommands::Eod::Runner.new(log: log, io: io)
    summary = runner.process(force: true, parallel: parallel, workers: 2)
    [summary, log]
  end

  [false, true].each do |parallel|
    it "reports no failures when every symbol succeeds (parallel: #{parallel})" do
      Dir.mktmpdir do |output_dir|
        io = Eodhd::Shared::Io.new(output_dir: output_dir)
        write_raw_eod(io, ["AAA", "BBB", "CCC"])

        summary, log = run_process(io, parallel: parallel)

        refute summary.failed?
        assert_equal 3, summary.total(:eod)
        assert_empty log.errors
        assert_includes log.infos, "Summary (process eod): eod 0 of 3 failed"
      end
    end

    it "counts and reports failed symbols (parallel: #{parallel})" do
      Dir.mktmpdir do |output_dir|
        io = Eodhd::Shared::Io.new(output_dir: output_dir)
        write_raw_eod(io, ["AAA", "BBB", "CCC"])
        io.write_json(Eodhd::Shared::Path.splits_file("US", "BBB"), "not json", false)

        summary, log = run_process(io, parallel: parallel)

        assert summary.failed?
        assert_equal 1, summary.failures(:eod)
        assert_equal 3, summary.total(:eod)
        assert_equal "Summary (process eod): eod 1 of 3 failed", log.errors[0]
        assert_equal "First 1 of 1 error(s):", log.errors[1]
        assert_match(%r{\A  \[us/bbb\] Failed processing EOD: Eodhd::Shared::Parsing::SplitsParser::Error: }, log.errors[2])
        assert_equal 3, log.errors.size
      end
    end
  end
end
