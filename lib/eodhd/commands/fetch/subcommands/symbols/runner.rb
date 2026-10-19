# frozen_string_literal: true

require "json"

module Eodhd
  module Commands
    module Fetch
      module Subcommands
        module Symbols
          class Runner
            def initialize(container:, shared:)
              @log = container.logger
              @api = container.api
              @io = container.io
              @data_reader = container.data_reader

              @shared = shared
            end

            def fetch(force:, parallel:, workers:)
              exchanges = @data_reader.exchanges
              exchange_items = build_exchange_items(exchanges)

              fetch_symbols_for_exchanges(exchange_items, force: force, parallel: parallel, workers: workers)
            end

            private

            def fetch_symbols_for_exchanges(exchange_items, force:, parallel:, workers:)
              outcomes = Util::ParallelExecutor.map(exchange_items, parallel: parallel, workers: workers) do |item|
                { symbols: fetch_symbols_for_exchange(item[:exchange], force: force, existing_paths: item[:existing_paths]) }
              end

              summary = Eodhd::Shared::RunSummary.new(name: "fetch symbols").add_all(outcomes)
              summary.log(@log)
              summary
            end

            def build_exchange_items(exchanges)
              exchanges.map do |exchange|
                { exchange: exchange, existing_paths: symbols_paths_for_exchange(exchange) }
              end
            end

            # Returns nil on success or skip, or the failure message.
            def fetch_symbols_for_exchange(exchange, force:, existing_paths:)
              if !force && existing_paths.any? && existing_paths.none? { |path| @shared.file_stale?(path) }
                @log.info("[#{exchange}] Skipping symbols (fresh): #{File.join(Eodhd::Shared::Path.symbols_dir, Util::String.kebab_case(exchange), '*.json')}")
                return nil
              end

              @log.info("[#{exchange}] Fetching symbols#{force ? ' (forced)' : ''}...")

              begin
                symbols_text = @api.get_exchange_symbol_list_json(exchange)
                symbols = JSON.parse(symbols_text)

                symbols_by_type = symbols.group_by do |symbol|
                  raw_type = symbol["Type"]
                  type = Util::String.kebab_case(raw_type)
                  type = "unknown" if type.empty?
                  type
                end

                symbols_by_type.each do |type, items|
                  relative_path = Eodhd::Shared::Path.exchange_symbols_file(exchange, type)
                  @io.write_json(relative_path, JSON.generate(items), true)
                  @log.info("[#{exchange}] Wrote #{relative_path}")
                end
                nil
              rescue StandardError => e
                raise if e.is_a?(Eodhd::Shared::Api::PaymentRequiredError)

                message = "[#{exchange}] Failed symbols: #{e.class}: #{e.message}"
                @log.warn(message)
                message
              end
            end

            def symbols_paths_for_exchange(exchange)
              relative_dir = File.join(Eodhd::Shared::Path.symbols_dir, Util::String.kebab_case(exchange))

              @io
                .list_relative_files(relative_dir)
                .select { |path| path.end_with?(".json") }
            end

          end
        end
      end
    end
  end
end
