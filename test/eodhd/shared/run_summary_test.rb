# frozen_string_literal: true

require_relative "../../test_helper"

describe Eodhd::Shared::RunSummary do
  class RunSummaryCaptureLog
    attr_reader :infos, :errors

    def initialize
      @infos = []
      @errors = []
    end

    def info(message)
      @infos << message
    end

    def error(message)
      @errors << message
    end
  end

  it "reports no failures when every outcome succeeded" do
    summary = Eodhd::Shared::RunSummary.new(name: "fetch info")
    summary.add_all([{ splits: nil, dividends: nil }, { splits: nil, dividends: nil }])

    refute summary.failed?
    assert_equal 0, summary.failure_count
    assert_equal 2, summary.total(:splits)

    log = RunSummaryCaptureLog.new
    summary.log(log)

    assert_empty log.errors
    assert_equal ["Summary (fetch info): splits 0 of 2 failed, dividends 0 of 2 failed"], log.infos
  end

  it "counts failures per kind and logs them as errors" do
    summary = Eodhd::Shared::RunSummary.new(name: "fetch info")
    summary.add({ splits: nil, dividends: "[US/A] Failed dividends: RuntimeError: boom" })
    summary.add({ splits: "[US/B] Failed splits: RuntimeError: bang", dividends: nil })
    summary.add({ splits: nil, dividends: nil })

    assert summary.failed?
    assert_equal 2, summary.failure_count
    assert_equal 1, summary.failures(:splits)
    assert_equal 1, summary.failures(:dividends)
    assert_equal 3, summary.total(:dividends)

    log = RunSummaryCaptureLog.new
    summary.log(log)

    assert_empty log.infos
    assert_equal [
      "Summary (fetch info): splits 1 of 3 failed, dividends 1 of 3 failed",
      "First 2 of 2 error(s):",
      "  [US/A] Failed dividends: RuntimeError: boom",
      "  [US/B] Failed splits: RuntimeError: bang"
    ], log.errors
  end

  it "limits the logged errors to a fixed sample" do
    summary = Eodhd::Shared::RunSummary.new(name: "fetch eod")
    8.times { |i| summary.add({ eod: "error #{i}" }) }

    log = RunSummaryCaptureLog.new
    summary.log(log)

    assert_equal "First 5 of 8 error(s):", log.errors[1]
    assert_equal ["  error 0", "  error 1", "  error 2", "  error 3", "  error 4"], log.errors[2..]
  end

  it "reports nothing to do for an empty run" do
    summary = Eodhd::Shared::RunSummary.new(name: "process eod")

    log = RunSummaryCaptureLog.new
    summary.log(log)

    refute summary.failed?
    assert_equal ["Summary (process eod): nothing to do"], log.infos
  end
end
