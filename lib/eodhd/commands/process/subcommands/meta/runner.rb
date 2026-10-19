# frozen_string_literal: true

require "csv"
require "date"
require "json"

module Eodhd
  module Commands
    module Process
      module Subcommands
        module Meta
          class Runner
            class Error < StandardError; end
            SYMBOL_PROGRESS_LOG_EVERY = 100

            def initialize(log:, io:)
              @log = log
              @io = io
            end

            def process(parallel:, workers:)
              @log.info("Building meta summary from processed data...")
              summary = Eodhd::Shared::RunSummary.new(name: "process meta")

              daily_ranges = get_daily_ranges(parallel: parallel, workers: workers)
              intraday_ranges = get_intraday_ranges(parallel: parallel, workers: workers, summary: summary)

              rows = combine_ranges(daily_ranges, intraday_ranges)

              rows_with_daily = rows.count { |row| !row[:daily].nil? }
              rows_with_intraday = rows.count { |row| !row[:intraday].nil? }

              if rows.empty?
                @log.warn("No processed data found under #{Eodhd::Shared::Path.data_dir}; writing empty summary")
              else
                @log.info(
                  "Prepared #{rows.size} meta entr#{rows.size == 1 ? 'y' : 'ies'} " \
                  "(daily: #{rows_with_daily}, intraday: #{rows_with_intraday})"
                )
              end

              output_file = Eodhd::Shared::Path.meta_file
              @io.write_json(output_file, JSON.generate(rows), true)
              @log.info("Wrote #{output_file} (#{rows.size} entries)")

              summary.log(@log)
              summary
            end

            private

            def get_daily_ranges(parallel:, workers:)
              root_dir = Eodhd::Shared::Path.data_eod_dir
              unless @io.dir_exists?(root_dir)
                @log.info("No processed EOD directory found: #{root_dir}")
                return []
              end

              exchange_dirs = @io.list_relative_dirs(root_dir).sort
              if exchange_dirs.empty?
                @log.info("No EOD exchange directories found under: #{root_dir}")
                return []
              end

              @log.info("Scanning EOD data in #{exchange_dirs.size} exchange director#{exchange_dirs.size == 1 ? 'y' : 'ies'}")

              results = []

              exchange_dirs.each do |exchange_dir|
                exchange = File.basename(exchange_dir)
                symbol_files = @io.list_relative_files(exchange_dir)
                  .filter { |path| path.end_with?(".csv") }
                  .sort

                if symbol_files.empty?
                  @log.info("[#{exchange}] No EOD symbol files found")
                  next
                end

                @log.info("[#{exchange}] Processing #{symbol_files.size} EOD symbol file(s)")

                symbol_items = symbol_files.each_with_index.map do |symbol_file, index|
                  {
                    symbol_file: symbol_file,
                    symbol_number: index + 1,
                    total_symbols: symbol_files.size
                  }
                end

                exchange_results = Util::ParallelExecutor.map(symbol_items, parallel: parallel, workers: workers) do |item|
                  symbol = File.basename(item[:symbol_file], ".csv")
                  log_symbol_progress(exchange, item[:symbol_number], item[:total_symbols], symbol, "EOD symbol file(s)")

                  {
                    exchange: exchange,
                    symbol: symbol,
                    daily_range: daily_range(item[:symbol_file])
                  }
                end

                results.concat(exchange_results)
              end

              results
            end

            def daily_range(relative_csv_path)
              text = @io.read_text(relative_csv_path)
              parsed = CSV.parse(text, headers: true)

              rows = parsed.each.to_a
              if rows.empty?
                raise Error, "CSV contains no data rows: #{relative_csv_path}"
              end

              from = Date.iso8601(rows.first["Date"].to_s.strip)
              to = Date.iso8601(rows.last["Date"].to_s.strip)
              { from: from.iso8601, to: to.iso8601 }
            end

            def get_intraday_ranges(parallel:, workers:, summary:)
              root_dir = Eodhd::Shared::Path.data_intraday_dir
              unless @io.dir_exists?(root_dir)
                @log.info("No processed intraday directory found: #{root_dir}")
                return []
              end

              exchange_dirs = @io.list_relative_dirs(root_dir).sort
              if exchange_dirs.empty?
                @log.info("No intraday exchange directories found under: #{root_dir}")
                return []
              end

              @log.info("Scanning intraday data in #{exchange_dirs.size} exchange director#{exchange_dirs.size == 1 ? 'y' : 'ies'}")

              results = []

              exchange_dirs.each do |exchange_dir|
                exchange = File.basename(exchange_dir)
                symbol_dirs = @io.list_relative_dirs(exchange_dir)
                  .sort

                if symbol_dirs.empty?
                  @log.info("[#{exchange}] No intraday symbol directories found")
                  next
                end

                @log.info("[#{exchange}] Processing #{symbol_dirs.size} intraday symbol director#{symbol_dirs.size == 1 ? 'y' : 'ies'}")

                symbol_items = symbol_dirs.each_with_index.map do |symbol_dir, index|
                  {
                    symbol_dir: symbol_dir,
                    symbol_number: index + 1,
                    total_symbols: symbol_dirs.size
                  }
                end

                exchange_results = Util::ParallelExecutor.map(symbol_items, parallel: parallel, workers: workers) do |item|
                  symbol_dir = item[:symbol_dir]
                  symbol = File.basename(symbol_dir)
                  month_files = @io.list_relative_files(symbol_dir)
                    .filter { |path| path.end_with?(".csv") }
                    .sort

                  @log.info("[#{exchange}/#{symbol}] Found #{month_files.size} intraday month file(s)")
                  log_symbol_progress(exchange, item[:symbol_number], item[:total_symbols], symbol, "intraday symbol director#{item[:total_symbols] == 1 ? 'y' : 'ies'}")

                  range_result = intraday_range(month_files)

                  {
                    exchange: exchange,
                    symbol: symbol,
                    intraday_range: range_result[:range],
                    outcome: { intraday: empty_files_error(exchange, symbol, range_result[:empty_files]) }
                  }
                end

                summary.add_all(exchange_results.map { |result| result[:outcome] })
                results.concat(
                  exchange_results
                    .reject { |result| result[:intraday_range].nil? }
                    .map { |result| result.except(:outcome) }
                )
              end

              results
            end

            def log_symbol_progress(exchange, symbol_number, total_symbols, symbol, noun)
              return unless (symbol_number % SYMBOL_PROGRESS_LOG_EVERY).zero? || symbol_number == total_symbols

              @log.info("[#{exchange}] Processed #{symbol_number}/#{total_symbols} #{noun} (current: #{symbol})")
            end

            # Returns { range:, empty_files: }. Only the month files at either end are read:
            # empty files are skipped inward until one with data rows is found.
            # The range is nil when no file has data rows or a boundary datetime is empty.
            def intraday_range(relative_csv_paths)
              sorted_paths = relative_csv_paths.sort
              empty_files = []
              return { range: nil, empty_files: empty_files } if sorted_paths.empty?

              first_file, first_rows = first_file_with_rows(sorted_paths, empty_files)
              if first_file.nil?
                @log.warn("Intraday month files all have no data rows: #{File.dirname(sorted_paths.first)}")
                return { range: nil, empty_files: empty_files }
              end

              later_paths = sorted_paths.drop(sorted_paths.index(first_file) + 1)
              last_file, last_rows = first_file_with_rows(later_paths.reverse, empty_files)
              last_file, last_rows = first_file, first_rows if last_file.nil?

              { range: boundary_range(first_file, first_rows, last_file, last_rows), empty_files: empty_files }
            end

            # Returns [file, rows] for the first file in order with data rows, or nil.
            # Adds each empty file passed over to empty_files.
            def first_file_with_rows(relative_csv_paths, empty_files)
              relative_csv_paths.each do |file|
                rows = CSV.parse(@io.read_text(file), headers: true).each.to_a
                return [file, rows] unless rows.empty?

                @log.warn("Intraday month file has no data rows, skipping: #{file}")
                empty_files << file
              end
              nil
            end

            def boundary_range(first_file, first_rows, last_file, last_rows)
              from_string = first_rows.first["Datetime"].to_s.strip
              if from_string.empty?
                @log.warn("Intraday first file has empty datetime in first row: #{first_file}")
                return nil
              end
              from = DateTime.parse(from_string)

              to_string = last_rows.last["Datetime"].to_s.strip
              if to_string.empty?
                @log.warn("Intraday last file has empty datetime in last row: #{last_file}")
                return nil
              end
              to = DateTime.parse(to_string)

              { from: from.iso8601, to: to.iso8601 }
            end

            # Returns nil when no empty month files were found, or the failure message.
            def empty_files_error(exchange, symbol, empty_files)
              return nil if empty_files.empty?

              "[#{exchange}/#{symbol}] Intraday month file(s) with no data rows: #{empty_files.sort.join(', ')}"
            end

            def combine_ranges(daily_ranges, intraday_ranges)
              rows_by_key = {}

              daily_ranges.each do |entry|
                exchange = entry[:exchange]
                symbol = entry[:symbol]
                key = row_key(exchange, symbol)

                rows_by_key[key] ||= base_row(exchange, symbol)
                rows_by_key[key][:daily] = entry[:daily_range]
              end

              intraday_ranges.each do |entry|
                exchange = entry[:exchange]
                symbol = entry[:symbol]
                key = row_key(exchange, symbol)

                rows_by_key[key] ||= base_row(exchange, symbol)
                rows_by_key[key][:intraday] = entry[:intraday_range]
              end

              rows_by_key
                .values
                .sort_by { |row| [row[:exchange], row[:symbol]] }
            end

            def row_key(exchange, symbol)
              "#{exchange}/#{symbol}"
            end

            def base_row(exchange, symbol)
              {
                symbol: symbol,
                exchange: exchange,
                daily: nil,
                intraday: nil
              }
            end
          end
        end
      end
    end
  end
end
