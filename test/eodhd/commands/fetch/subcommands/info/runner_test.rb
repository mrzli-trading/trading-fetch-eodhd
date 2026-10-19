# frozen_string_literal: true

require_relative "../../../../../test_helper"

require "json"
require "tmpdir"

describe Eodhd::Commands::Fetch::Subcommands::Info::Runner do
  class InfoCaptureLog
    attr_reader :warnings

    def initialize
      @warnings = []
    end

    def info(_message); end

    def warn(message)
      @warnings << message
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

  class InfoFakeDataReader
    def symbols
      [{ exchange: "US", symbol: "CMG", real_exchange: "NYSE", type: "Common Stock" }]
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

      runner.fetch(force: false, parallel: false, workers: 1)

      assert_empty log.warnings

      splits = JSON.parse(io.read_text(Eodhd::Shared::Path.splits_file("US", "CMG")))
      assert_equal "50.000000/1.000000", splits.first["split"]

      dividends = JSON.parse(io.read_text(Eodhd::Shared::Path.dividends_file("US", "CMG")))
      assert_equal 0.25, dividends.first["value"]
    end
  end
end
