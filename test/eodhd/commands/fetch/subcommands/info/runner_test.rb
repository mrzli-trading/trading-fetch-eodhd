# frozen_string_literal: true

require_relative "../../../../../test_helper"

require "json"
require "tmpdir"

describe Eodhd::Commands::Fetch::Subcommands::Info::Runner do
  class InfoCaptureLog
    attr_reader :warnings, :errors

    def initialize
      @warnings = []
      @errors = []
    end

    def info(_message); end

    def warn(message)
      @warnings << message
    end

    def error(message)
      @errors << message
    end
  end

  class InfoFakeApi
    def get_splits_json(_exchange, symbol)
      JSON.generate([{ "date" => "2024-06-26", "split" => "50.000000/1.000000", "symbol" => symbol }])
    end

    def get_dividends_json(_exchange, symbol)
      JSON.generate([{ "date" => "2024-05-10", "value" => 0.25, "symbol" => symbol }])
    end
  end

  class InfoFailingDividendsApi < InfoFakeApi
    def get_dividends_json(_exchange, symbol)
      raise "dividends unavailable for #{symbol}" if symbol == "BAD"

      super
    end
  end

  # Both kinds raise, so no thread writes files while the temp dir is being removed.
  class InfoPaymentRequiredApi
    def get_splits_json(_exchange, _symbol)
      raise Eodhd::Shared::Api::PaymentRequiredError, "402"
    end

    def get_dividends_json(_exchange, _symbol)
      raise Eodhd::Shared::Api::PaymentRequiredError, "402"
    end
  end

  class InfoFakeDataReader
    def initialize(symbols = ["CMG"])
      @symbols = symbols
    end

    def symbols
      @symbols.map { |symbol| { exchange: "US", symbol: symbol, real_exchange: "NYSE", type: "Common Stock" } }
    end
  end

  class InfoFakeShared
    def should_fetch_symbol?(_symbol_entry)
      true
    end

    def file_stale?(_relative_path)
      true
    end
  end

  InfoContainer = Struct.new(:logger, :api, :io, :data_reader, keyword_init: true)

  it "writes splits and dividends files for each symbol" do
    Dir.mktmpdir do |output_dir|
      io = Eodhd::Shared::Io.new(output_dir: output_dir)
      log = InfoCaptureLog.new
      container = InfoContainer.new(logger: log, api: InfoFakeApi.new, io: io, data_reader: InfoFakeDataReader.new)
      runner = Eodhd::Commands::Fetch::Subcommands::Info::Runner.new(container: container, shared: InfoFakeShared.new)

      summary = runner.fetch(force: false, parallel: false, workers: 1)

      assert_empty log.warnings
      assert_empty log.errors
      refute summary.failed?
      assert_equal 1, summary.total(:splits)
      assert_equal 1, summary.total(:dividends)

      splits = JSON.parse(io.read_text(Eodhd::Shared::Path.splits_file("US", "CMG")))
      assert_equal "50.000000/1.000000", splits.first["split"]

      dividends = JSON.parse(io.read_text(Eodhd::Shared::Path.dividends_file("US", "CMG")))
      assert_equal 0.25, dividends.first["value"]
    end
  end

  [false, true].each do |parallel|
    it "counts and reports failed items per kind (parallel: #{parallel})" do
      Dir.mktmpdir do |output_dir|
        io = Eodhd::Shared::Io.new(output_dir: output_dir)
        log = InfoCaptureLog.new
        container = InfoContainer.new(
          logger: log,
          api: InfoFailingDividendsApi.new,
          io: io,
          data_reader: InfoFakeDataReader.new(["CMG", "BAD", "KO"])
        )
        runner = Eodhd::Commands::Fetch::Subcommands::Info::Runner.new(container: container, shared: InfoFakeShared.new)

        summary = runner.fetch(force: false, parallel: parallel, workers: 2)

        assert summary.failed?
        assert_equal 0, summary.failures(:splits)
        assert_equal 1, summary.failures(:dividends)
        assert_equal 3, summary.total(:dividends)
        assert_equal [
          "Summary (fetch info): splits 0 of 3 failed, dividends 1 of 3 failed",
          "First 1 of 1 error(s):",
          "  [US/BAD] Failed dividends: RuntimeError: dividends unavailable for BAD"
        ], log.errors
      end
    end
  end

  it "still stops immediately on payment required" do
    Dir.mktmpdir do |output_dir|
      io = Eodhd::Shared::Io.new(output_dir: output_dir)
      container = InfoContainer.new(
        logger: InfoCaptureLog.new,
        api: InfoPaymentRequiredApi.new,
        io: io,
        data_reader: InfoFakeDataReader.new
      )
      runner = Eodhd::Commands::Fetch::Subcommands::Info::Runner.new(container: container, shared: InfoFakeShared.new)

      report_on_exception = Thread.report_on_exception
      Thread.report_on_exception = false
      begin
        assert_raises(Eodhd::Shared::Api::PaymentRequiredError) do
          runner.fetch(force: false, parallel: false, workers: 1)
        end
      ensure
        Thread.report_on_exception = report_on_exception
      end
    end
  end
end
