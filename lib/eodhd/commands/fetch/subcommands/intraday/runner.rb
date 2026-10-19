# frozen_string_literal: true

require "set"

module Eodhd
  module Commands
    module Fetch
      module Subcommands
        module Intraday
          class Runner
            DAYS_TO_SECONDS = 24 * 60 * 60
            RANGE_SECONDS = 118 * DAYS_TO_SECONDS
            STRIDE_SECONDS = 110 * DAYS_TO_SECONDS

            def initialize(container:, shared:)
              @log = container.logger
              @api = container.api
              @io = container.io
              @data_reader = container.data_reader

              @shared = shared

              @intraday_shared = Shared.new(container: container)
              @processor = Processor.new(container: container)
            end

            def fetch(recheck_start_date:, unfetched_only:, parallel:, workers:)
              @log.info("Starting intraday fetch...")

              symbol_entries = @data_reader.symbols

              filtered_entries = symbol_entries.filter { |entry| @shared.should_fetch_symbol_intraday?(entry) }
              @log.info("Eligible symbols for intraday fetch: #{filtered_entries.size}")

              if unfetched_only
                total_candidates = filtered_entries.size
                @log.info("Unfetched-only scan: checking processed intraday files for #{total_candidates} symbols...")

                processed_pairs = existing_processed_intraday_pairs
                filtered_entries = filtered_entries.reject do |entry|
                  pair = normalized_exchange_symbol_pair(entry[:exchange], entry[:symbol])
                  processed_pairs.include?(pair)
                end

                skipped_count = total_candidates - filtered_entries.size
                @log.info("Unfetched-only: skipped #{skipped_count} symbols with processed intraday files")
              end

              @log.info("Intraday fetch queue size: #{filtered_entries.size} symbols")

              fetch_intraday_for_symbols(
                filtered_entries,
                recheck_start_date: recheck_start_date,
                parallel: parallel,
                workers: workers
              )
            end

            private

            def fetch_intraday_for_symbols(symbol_entries, recheck_start_date:, parallel:, workers:)
              outcomes = Util::ParallelExecutor.map(symbol_entries, parallel: parallel, workers: workers) do |entry|
                { intraday: fetch_single_symbol(entry, recheck_start_date: recheck_start_date) }
              end

              summary = Eodhd::Shared::RunSummary.new(name: "fetch intraday").add_all(outcomes)
              summary.log(@log)
              summary
            end

            # Returns nil on success, or the failure message.
            def fetch_single_symbol(symbol_entry, recheck_start_date:)
              exchange = symbol_entry[:exchange]
              symbol = symbol_entry[:symbol]

              exchange_symbol = "#{exchange}/#{symbol}"

              begin
                fetched_dir = Eodhd::Shared::Path.raw_intraday_fetched_symbol_dir(exchange, symbol)

                # Delete any old fetched data.
                # This does not delete processed by-year-month 'raw' data, which is in a separate dir.
                @log.info("[#{exchange_symbol}] Deleting old fetched intraday files in #{fetched_dir}...")
                @io.delete_dir(fetched_dir)

                if recheck_start_date
                  # Find earliest existing timestamp from processed files.
                  first_ts = first_existing_timestamp(exchange, symbol)

                  if should_refetch?(exchange, symbol, first_ts, exchange_symbol)
                    # Delete all processed data to force refecth for symbol.
                    @log.info("[#{exchange_symbol}] Deleting all processed intraday files to force refetch...")
                    delete_all_processed_files(exchange, symbol, exchange_symbol)
                  end
                end

                last_ts = last_existing_timestamp(exchange, symbol)

                # The farthest back we can fetch is around 1900, so use that as a hard cutoff.
                min_ts = Time.utc(1900, 1, 1).to_i

                to = Time.now.to_i
                while to > min_ts do
                  from = [min_ts, to - RANGE_SECONDS].max

                  if !last_ts.nil? && to <= last_ts
                    latest_to_formatted = Util::Date.seconds_to_datetime(last_ts)
                    @log.info("[#{exchange_symbol}] Stopping intraday fetch (already have fetched data) (from=#{Util::Date.seconds_to_datetime(from)} <= latest_to=#{latest_to_formatted})")
                    break
                  end

                  fetch_valid = fetch_intraday_interval(exchange, symbol, from, to)
                  break unless fetch_valid

                  to = to - STRIDE_SECONDS
                end

                # Process fetched data into monthly files
                @processor.process(exchange, symbol)

                # Delete fetched directory after processing
                @io.delete_dir(fetched_dir)
                @log.info("[#{exchange_symbol}] Deleted fetched intraday files after processing")
                nil
              rescue StandardError => e
                raise if e.is_a?(Eodhd::Shared::Api::PaymentRequiredError)

                message = "[#{exchange_symbol}] Failed intraday: #{e.class}: #{e.message}"
                @log.warn(message)
                message
              end
            end

            def fetch_intraday_interval(exchange, symbol, from, to)
              exchange_symbol = "#{exchange}/#{symbol}"
              csv = @intraday_shared.fetch_intraday_interval_csv(exchange, symbol, from, to)
              return false if csv.nil?

              rows = Eodhd::Shared::Parsing::IntradayCsvParser.parse(csv)
              if rows.empty?
                @log.info("[#{exchange_symbol}] Stopping intraday history fetch (empty CSV) (from=#{Util::Date.seconds_to_datetime(from)} to=#{Util::Date.seconds_to_datetime(to)})")
                return nil
              end

              parsed_from = rows.first[:timestamp]
              parsed_to = rows.last[:timestamp]

              relative_path = Eodhd::Shared::Path.raw_intraday_fetched_symbol_file(exchange, symbol, parsed_from, parsed_to)
              @io.write_csv(relative_path, csv)
              @log.info("[#{exchange_symbol}] Wrote #{relative_path}")

              true
            end

            def first_existing_timestamp(exchange, symbol)
              files = sorted_processed_files(exchange, symbol)
              return nil if files.empty?

              first_file = files.first
              csv_content = @io.read_text(first_file)
              rows = Eodhd::Shared::Parsing::IntradayCsvParser.parse(csv_content)

              return nil if rows.empty?

              rows.first[:timestamp]
            end

            def last_existing_timestamp(exchange, symbol)
              files = sorted_processed_files(exchange, symbol)
              return nil if files.empty?

              last_file = files.last
              csv_content = @io.read_text(last_file)
              rows = Eodhd::Shared::Parsing::IntradayCsvParser.parse(csv_content)

              return nil if rows.empty?

              rows.last[:timestamp]
            end

            def sorted_processed_files(exchange, symbol)
              processed_dir = Eodhd::Shared::Path.raw_intraday_processed_symbol_dir(exchange, symbol)
              @io.list_relative_files(processed_dir)
                .filter { |path| path.end_with?(".csv") }
                .sort
            end

            def existing_processed_intraday_pairs
              root_dir = Eodhd::Shared::Path.raw_intraday_processed_dir
              exchange_dirs = @io.list_relative_dirs(root_dir)

              exchange_dirs.flat_map do |exchange_dir|
                exchange = File.basename(exchange_dir)
                symbol_dirs = @io.list_relative_dirs(exchange_dir)
                symbol_dirs.map { |symbol_dir| "#{exchange}/#{File.basename(symbol_dir)}" }
              end.to_set
            end

            def normalized_exchange_symbol_pair(exchange, symbol)
              "#{Util::String.kebab_case(exchange)}/#{Util::String.kebab_case(symbol)}"
            end

            def should_refetch?(exchange, symbol, first_ts, exchange_symbol)
              if first_ts.nil?
                @log.info("[#{exchange_symbol}] No existing processed intraday data, refetching all intraday data")
                return true
              end

              # Fetch a range around the processed start date to check if the start date has changed
              check_from = [0, first_ts - RANGE_SECONDS / 2].max
              check_to = first_ts + RANGE_SECONDS

              @log.info("[#{exchange_symbol}] Rechecking start date around #{Util::Date.seconds_to_datetime(first_ts)}")

              csv = @intraday_shared.fetch_intraday_interval_csv(exchange, symbol, check_from, check_to)
              return true if csv.nil?

              rows = Eodhd::Shared::Parsing::IntradayCsvParser.parse(csv)
              return true if rows.empty?

              new_start_ts = rows.first[:timestamp]

              if new_start_ts != first_ts
                @log.warn("[#{exchange_symbol}] Start date changed: old=#{Util::Date.seconds_to_datetime(first_ts)}, new=#{Util::Date.seconds_to_datetime(new_start_ts)}")
                return true
              end

              @log.info("[#{exchange_symbol}] Start date unchanged")
              false
            end

            def delete_all_processed_files(exchange, symbol, exchange_symbol)
              processed_dir = Eodhd::Shared::Path.raw_intraday_processed_symbol_dir(exchange, symbol)
                    @io.delete_dir(processed_dir)
                    @log.info("[#{exchange_symbol}] Deleted all processed files due to start date change")
            end

          end
        end
      end
    end
  end
end
