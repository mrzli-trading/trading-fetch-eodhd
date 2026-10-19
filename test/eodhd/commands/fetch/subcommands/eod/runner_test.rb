# frozen_string_literal: true

require_relative "../../../../../test_helper"

require "tmpdir"

describe Eodhd::Commands::Fetch::Subcommands::Eod::Runner do
  class FetchEodCaptureLog
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

  class FetchEodFakeApi
    def initialize(failing_symbols: [])
      @failing_symbols = failing_symbols
    end

    def get_eod_data_csv(_exchange, symbol)
      raise ArgumentError, "no data for #{symbol}" if @failing_symbols.include?(symbol)

      "Date,Open,High,Low,Close,Adjusted_close,Volume\n2024-01-02,1,2,0.5,1.5,1.5,100\n"
    end
  end

  class FetchEodFakeDataReader
    def initialize(symbols)
      @symbols = symbols
    end

    def symbols
      @symbols.map { |symbol| { exchange: "US", symbol: symbol, type: "Common Stock" } }
    end
  end

  class FetchEodFakeShared
    def should_fetch_symbol?(_symbol_entry)
      true
    end

    def file_stale?(_relative_path)
      true
    end
  end

  FetchEodContainer = Struct.new(:logger, :api, :io, :data_reader, keyword_init: true)

  def run_fetch(output_dir, api:, parallel:)
    log = FetchEodCaptureLog.new
    container = FetchEodContainer.new(
      logger: log,
      api: api,
      io: Eodhd::Shared::Io.new(output_dir: output_dir),
      data_reader: FetchEodFakeDataReader.new(["AAA", "BBB", "CCC", "DDD"])
    )
    runner = Eodhd::Commands::Fetch::Subcommands::Eod::Runner.new(container: container, shared: FetchEodFakeShared.new)
    summary = runner.fetch(force: false, parallel: parallel, workers: 2)
    [summary, log]
  end

  [false, true].each do |parallel|
    it "reports no failures when every symbol succeeds (parallel: #{parallel})" do
      Dir.mktmpdir do |output_dir|
        summary, log = run_fetch(output_dir, api: FetchEodFakeApi.new, parallel: parallel)

        refute summary.failed?
        assert_equal 4, summary.total(:eod)
        assert_empty log.errors
        assert_includes log.infos, "Summary (fetch eod): eod 0 of 4 failed"
      end
    end

    it "counts and reports failed symbols (parallel: #{parallel})" do
      Dir.mktmpdir do |output_dir|
        api = FetchEodFakeApi.new(failing_symbols: ["BBB", "DDD"])
        summary, log = run_fetch(output_dir, api: api, parallel: parallel)

        assert summary.failed?
        assert_equal 2, summary.failures(:eod)
        assert_equal 4, summary.total(:eod)
        assert_equal [
          "Summary (fetch eod): eod 2 of 4 failed",
          "First 2 of 2 error(s):",
          "  [US/BBB] Failed EOD: ArgumentError: no data for BBB",
          "  [US/DDD] Failed EOD: ArgumentError: no data for DDD"
        ], log.errors
      end
    end
  end
end
