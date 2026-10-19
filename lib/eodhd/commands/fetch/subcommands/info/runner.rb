# frozen_string_literal: true

module Eodhd
  module Commands
    module Fetch
      module Subcommands
        module Info
          class Runner

            def initialize(container:, shared:)
              @log = container.logger
              @api = container.api
              @io = container.io
              @data_reader = container.data_reader

              @shared = shared
            end

            def fetch(force:, parallel:, workers:)
              symbol_entries = @data_reader.symbols
              filtered_entries = symbol_entries.filter { |entry| @shared.should_fetch_symbol?(entry) }

              fetch_info_for_symbols(filtered_entries, force: force, parallel: parallel, workers: workers)
            end

            private

            def fetch_info_for_symbols(symbol_entries, force:, parallel:, workers:)
              Util::ParallelExecutor.execute(symbol_entries, parallel: parallel, workers: workers) do |entry|
                fetch_single(entry, force: force)
              end
            end

            def fetch_single(symbol_entry, force:)
              threads = [
                Thread.new do
                  fetch_info(
                    symbol_entry,
                    :splits,
                    ->(e, s) { Eodhd::Shared::Path.splits_file(e, s) },
                    ->(e, s) { @api.get_splits_json(e, s) },
                    force: force
                  )
                end,
                Thread.new do
                  fetch_info(
                    symbol_entry,
                    :dividends,
                    ->(e, s) { Eodhd::Shared::Path.dividends_file(e, s) },
                    ->(e, s) { @api.get_dividends_json(e, s) },
                    force: force
                  )
                end
              ]
              threads.each(&:value)
            end

            def fetch_info(symbol_entry, type, path_method, api_method, force:)
              exchange = symbol_entry[:exchange]
              symbol = symbol_entry[:symbol]
              exchange_symbol = "#{exchange}/#{symbol}"

              path = path_method.call(exchange, symbol)
              unless force || @shared.file_stale?(path)
                @log.info("[#{exchange_symbol}] Skipping #{type} (fresh): #{path}")
                return
              end

              @log.info("[#{exchange_symbol}] Fetching #{type} JSON#{force ? ' (forced)' : ''}...")
              data = api_method.call(exchange, symbol)
              @io.write_json(path, data, true)
              @log.info("[#{exchange_symbol}] Wrote #{path}")
            rescue StandardError => e
              raise if e.is_a?(Eodhd::Shared::Api::PaymentRequiredError)

              @log.warn("[#{exchange_symbol}] Failed #{type}: #{e.class}: #{e.message}")
            end

          end
        end
      end
    end
  end
end
