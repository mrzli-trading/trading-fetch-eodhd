# frozen_string_literal: true

module Eodhd
  module Commands
    module Process
      module Subcommands
        module Eod
          class Runner
            OUTPUT_HEADERS = ["Date", "Open", "High", "Low", "Close", "Volume"].freeze

            def initialize(log:, io:)
              @log = log
              @io = io
            end

            def process(force:, parallel:, workers:)
              summary = Eodhd::Shared::RunSummary.new(name: "process eod")

              raw_dir = Eodhd::Shared::Path.raw_eod_dir
              unless @io.dir_exists?(raw_dir)
                @log.info("No raw EOD directory found: #{raw_dir}")
                return summary
              end

              exchange_dirs = @io.list_relative_dirs(raw_dir).sort
              if exchange_dirs.empty?
                @log.info("No exchange directories found under: #{raw_dir}")
                return summary
              end

              exchange_dirs.each do |exchange_dir|
                outcomes = process_exchange(exchange_dir, force: force, parallel: parallel, workers: workers)
                summary.add_all(outcomes)
              end

              summary.log(@log)
              summary
            end

            private

            def process_exchange(exchange_dir, force:, parallel:, workers:)
              symbol_files = @io.list_relative_files(exchange_dir)
                .filter { |path| path.end_with?(".csv") }
                .sort
              return [] if symbol_files.empty?

              exchange = File.basename(exchange_dir)
              @log.info("[#{exchange}] Processing EOD (#{symbol_files.size} symbols)")

              symbol_data_list = symbol_files.map do |symbol_file|
                {
                  exchange: exchange,
                  symbol: File.basename(symbol_file, ".csv"),
                  path: symbol_file
                }
              end

              Util::ParallelExecutor.map(symbol_data_list, parallel: parallel, workers: workers) do |symbol_data|
                { eod: process_symbol(symbol_data, force: force) }
              end
            end

            # Returns nil on success or skip, or the failure message.
            def process_symbol(symbol_data, force:)
              exchange = symbol_data[:exchange]
              symbol = symbol_data[:symbol]
              symbol_file = symbol_data[:path]

              exchange_symbol = "#{exchange}/#{symbol}"

              processed_file = Eodhd::Shared::Path.data_eod_symbol_file(exchange, symbol)
              splits_file = Eodhd::Shared::Path.splits_file(exchange, symbol)
              dividends_file = Eodhd::Shared::Path.dividends_file(exchange, symbol)

              unless should_process?(
                force: force,
                processed_file: processed_file,
                symbol_file: symbol_file,
                splits_file: splits_file,
                dividends_file: dividends_file,
              )
                @log.info("[#{exchange_symbol}] Skipping processed EOD (fresh): #{processed_file}")
                return nil
              end

              raw_csv = @io.read_text(symbol_file)
              data_raw = Eodhd::Shared::Parsing::EodCsvParser.parse(raw_csv, exchange: exchange)

              splits_json = @io.file_exists?(splits_file) ? @io.read_text(splits_file) : "[]"
              splits_raw = Eodhd::Shared::Parsing::SplitsParser.parse(splits_json)
              splits = Shared::SplitsProcessor.process(splits_raw, exchange: exchange)

              dividends_json = @io.file_exists?(dividends_file) ? @io.read_text(dividends_file) : "[]"
              dividends_raw = Eodhd::Shared::Parsing::DividendsParser.parse(dividends_json)
              dividends = Shared::DividendsProcessor.process(dividends_raw, data_raw, exchange: exchange)

              data = Shared::PriceAdjust.apply(data_raw, splits, dividends)
              data = to_output(data)
              processed_csv = to_csv(data)

              @io.write_csv(processed_file, processed_csv)
              @log.info("[#{exchange_symbol}] Wrote #{processed_file}")
              nil
            rescue StandardError => e
              message = "[#{exchange_symbol}] Failed processing EOD: #{e.class}: #{e.message}"
              @log.warn(message)
              message
            end

            def should_process?(
              force:,
              processed_file:,
              symbol_file:,
              splits_file:,
              dividends_file:
            )
              return true if force

              processed_mtime = @io.file_last_updated_at(processed_file)
              return true if processed_mtime.nil?

              symbol_mtime = @io.file_last_updated_at(symbol_file)
              return true if symbol_mtime && symbol_mtime > processed_mtime

              splits_mtime = @io.file_last_updated_at(splits_file)
              return true if splits_mtime && splits_mtime > processed_mtime

              dividends_mtime = @io.file_last_updated_at(dividends_file)
              return true if dividends_mtime && dividends_mtime > processed_mtime

              false
            end

            def to_output(data)
              data.map do |row|
                {
                  date: row[:date].iso8601,
                  open: format_price(row[:open]),
                  high: format_price(row[:high]),
                  low: format_price(row[:low]),
                  close: format_price(row[:close]),
                  volume: row[:volume].to_s
                }
              end
            end

            def format_price(price)
              price.round(Shared::Constants::OUTPUT_DECIMALS).to_s
            end

            def to_csv(rows)
              CSV.generate do |out_csv|
                out_csv << OUTPUT_HEADERS

                rows.each do |row|
                  out_csv << [
                    row[:date],
                    row[:open],
                    row[:high],
                    row[:low],
                    row[:close],
                    row[:volume]
                  ]
                end
              end
            end
          end
        end
      end
    end
  end
end
