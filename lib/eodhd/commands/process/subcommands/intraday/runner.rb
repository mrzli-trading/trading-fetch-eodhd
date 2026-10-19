# frozen_string_literal: true

module Eodhd
  module Commands
    module Process
      module Subcommands
        module Intraday
          class Runner
            OUTPUT_HEADERS = ["Timestamp", "Datetime", "Open", "High", "Low", "Close", "Volume"].freeze
            FILE_PROGRESS_LOG_EVERY = 50

            def initialize(log:, io:)
              @log = log
              @io = io
            end

            def process(force:, parallel:, workers:)
              raw_dir = Eodhd::Shared::Path.raw_intraday_processed_dir
              unless @io.dir_exists?(raw_dir)
                @log.info("No raw intraday directory found: #{raw_dir}")
                return
              end

              exchange_dirs = @io.list_relative_dirs(raw_dir).sort
              if exchange_dirs.empty?
                @log.info("No exchange directories found under: #{raw_dir}")
                return
              end

              exchange_dirs.each do |exchange_dir|
                process_exchange(exchange_dir, force: force, parallel: parallel, workers: workers)
              end
            end

            private

            def process_exchange(exchange_dir, force:, parallel:, workers:)
              symbol_dirs = @io.list_relative_dirs(exchange_dir).sort
              return if symbol_dirs.empty?

              exchange = File.basename(exchange_dir)
              @log.info("[#{exchange}] Processing intraday (#{symbol_dirs.size} symbols)")

              symbol_data_list = symbol_dirs.map do |symbol_dir|
                {
                  exchange: exchange,
                  symbol: File.basename(symbol_dir),
                  symbol_dir: symbol_dir
                }
              end

              Util::ParallelExecutor.execute(symbol_data_list, parallel: parallel, workers: workers) do |symbol_data|
                process_symbol(symbol_data, force: force)
              end
            end

            def process_symbol(symbol_data, force:)
              exchange = symbol_data[:exchange]
              symbol = symbol_data[:symbol]
              symbol_dir = symbol_data[:symbol_dir]
              exchange_symbol = "#{exchange}/#{symbol}"

              month_files = @io.list_relative_files(symbol_dir)
                .filter { |path| path.end_with?(".csv") }
                .sort
              return if month_files.empty?

              processed_dir = Eodhd::Shared::Path.data_intraday_symbol_dir(exchange, symbol)
              processed_files = @io.list_relative_files(processed_dir)
                .filter { |path| path.end_with?(".csv") }
                .sort

              splits_file = Eodhd::Shared::Path.splits_file(exchange, symbol)
              dividends_file = Eodhd::Shared::Path.dividends_file(exchange, symbol)

              unless should_process?(
                force: force,
                processed_files: processed_files,
                raw_files: month_files,
                splits_file: splits_file,
                dividends_file: dividends_file
              )
                @log.info("[#{exchange_symbol}] Skipping processed intraday (fresh)")
                return
              end

              @log.info("[#{exchange_symbol}] Processing intraday, found #{month_files.size} raw month file(s)")

              @log.info("[#{exchange_symbol}] Parsing raw data (#{month_files.size} files)...")
              data_raw = parse_raw_data(month_files, exchange, symbol)
              @log.info("[#{exchange_symbol}] Parsed #{data_raw.size} total rows")

              @log.info("[#{exchange_symbol}] Processing splits and dividends...")
              splits_json = @io.file_exists?(splits_file) ? @io.read_text(splits_file) : "[]"
              splits_raw = Eodhd::Shared::Parsing::SplitsParser.parse(splits_json)
              splits = Shared::SplitsProcessor.process(splits_raw, exchange: exchange)

              dividends_json = @io.file_exists?(dividends_file) ? @io.read_text(dividends_file) : "[]"
              dividends_raw = Eodhd::Shared::Parsing::DividendsParser.parse(dividends_json)
              dividends = Shared::DividendsProcessor.process(dividends_raw, data_raw, exchange: exchange)

              @log.info("[#{exchange_symbol}] Applying price adjustments (#{splits.size} splits, #{dividends.size} dividends)...")
              data = Shared::PriceAdjust.apply(data_raw, splits, dividends)

              @log.info("[#{exchange_symbol}] Grouping data by month...")
              data_by_month = Eodhd::Shared::Processing::IntradayGrouper.group_by_month(data)
              @log.info("[#{exchange_symbol}] Grouped into #{data_by_month.size} month(s)")

              data_by_month.each_with_index do |(year_month, data_for_month), index|
                year, month = year_month
                processed_file = Eodhd::Shared::Path.data_intraday_month_file(exchange, symbol, year, month)

                data = to_output(data_for_month)
                processed_csv = to_csv(data)

                @io.write_csv(processed_file, processed_csv)
                current = index + 1
                total = data_by_month.size
                if should_log_file_progress?(current, total)
                  @log.info("[#{exchange_symbol}] Writing file #{current}/#{total}: #{File.basename(processed_file)}")
                end
              end

              @log.info("[#{exchange_symbol}] Completed processing intraday")
            rescue StandardError => e
              @log.warn("[#{exchange_symbol}] Failed processing intraday: #{e.class}: #{e.message}")
            end

            def should_process?(
              force:,
              processed_files:,
              raw_files:,
              splits_file:,
              dividends_file:
            )
              return true if force
              return true if processed_files.empty?

              # Find latest processed file
              latest_processed_mtime = processed_files
                .map { |file| @io.file_last_updated_at(file) }
                .compact
                .max
              return true if latest_processed_mtime.nil?

              # Find latest raw file
              latest_raw_mtime = raw_files
                .map { |file| @io.file_last_updated_at(file) }
                .compact
                .max
              return true if latest_raw_mtime && latest_raw_mtime > latest_processed_mtime

              # Check splits file
              splits_mtime = @io.file_last_updated_at(splits_file)
              return true if splits_mtime && splits_mtime > latest_processed_mtime

              # Check dividends file
              dividends_mtime = @io.file_last_updated_at(dividends_file)
              return true if dividends_mtime && dividends_mtime > latest_processed_mtime

              false
            end

            def parse_raw_data(month_files, exchange, symbol)
              all_data = []
              exchange_symbol = "#{exchange}/#{symbol}"
              
              month_files.each_with_index do |raw_file, index|
                current = index + 1
                total = month_files.size
                if should_log_file_progress?(current, total)
                  @log.info("[#{exchange_symbol}] Parsing file #{current}/#{total}: #{File.basename(raw_file)}")
                end

                raw_csv = @io.read_text(raw_file)
                parsed_data = Eodhd::Shared::Parsing::IntradayCsvParser.parse(raw_csv)
                all_data.concat(parsed_data)
              end

              all_data
            end

            def should_log_file_progress?(current, total)
              current == total || (current % FILE_PROGRESS_LOG_EVERY).zero?
            end

            def to_output(data)
              data.map do |row|
                {
                  timestamp: row[:timestamp].to_s,
                  datetime: row[:datetime],
                  open: format_price(row[:open]),
                  high: format_price(row[:high]),
                  low: format_price(row[:low]),
                  close: format_price(row[:close]),
                  volume: row[:volume].to_s
                }
              end
            end

            def format_price(price)
              price.round(Eodhd::Commands::Process::Shared::Constants::OUTPUT_DECIMALS).to_s
            end

            def to_csv(rows)
              CSV.generate do |out_csv|
                out_csv << OUTPUT_HEADERS

                rows.each do |row|
                  out_csv << [
                    row[:timestamp],
                    row[:datetime],
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
