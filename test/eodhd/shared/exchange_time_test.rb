# frozen_string_literal: true

require_relative "../../test_helper"

require "date"
require "open3"
require "rbconfig"

describe Eodhd::Shared::ExchangeTime do
  test_equals(
    ".day_start_timestamp",
    [
      {
        description: "us daylight saving time date starts at 04:00 UTC",
        input: ["us", Date.new(2024, 6, 26)],
        expected: Time.utc(2024, 6, 26, 4).to_i
      },
      {
        description: "us standard time date starts at 05:00 UTC",
        input: ["us", Date.new(2024, 1, 10)],
        expected: Time.utc(2024, 1, 10, 5).to_i
      },
      {
        description: "us date on which daylight saving time starts (change is at 02:00)",
        input: ["us", Date.new(2024, 3, 10)],
        expected: Time.utc(2024, 3, 10, 5).to_i
      },
      {
        description: "us date on which daylight saving time ends (change is at 02:00)",
        input: ["us", Date.new(2024, 11, 3)],
        expected: Time.utc(2024, 11, 3, 4).to_i
      },
      {
        description: "upper-case exchange code",
        input: ["US", Date.new(2024, 6, 26)],
        expected: Time.utc(2024, 6, 26, 4).to_i
      }
    ],
    call: ->(input) { Eodhd::Shared::ExchangeTime.day_start_timestamp(*input) }
  )

  it "raises for an unsupported exchange" do
    err = _ { Eodhd::Shared::ExchangeTime.day_start_timestamp("xetra", Date.new(2024, 6, 26)) }
      .must_raise(Eodhd::Shared::ExchangeTime::Error)
    _(err.message).must_match(/Unsupported exchange/)
  end

  it "gives the same timestamps regardless of the machine's time zone" do
    lib_dir = File.expand_path("../../../lib", __dir__)
    script = <<~RUBY
      require "bundler/setup"
      require "date"
      $LOAD_PATH.unshift(#{lib_dir.inspect})
      require "setup"

      puts Eodhd::Shared::ExchangeTime.day_start_timestamp("us", Date.new(2024, 6, 26))
      puts Eodhd::Shared::ExchangeTime.day_start_timestamp("us", Date.new(2024, 1, 10))
    RUBY

    expected = "#{Time.utc(2024, 6, 26, 4).to_i}\n#{Time.utc(2024, 1, 10, 5).to_i}\n"

    ["UTC", "Europe/Zagreb", "Asia/Tokyo", "America/Los_Angeles"].each do |tz|
      stdout, stderr, status = Open3.capture3({ "TZ" => tz }, RbConfig.ruby, "-e", script)
      assert status.success?, "TZ=#{tz} subprocess failed: #{stderr}"
      assert_equal expected, stdout, "TZ=#{tz}"
    end
  end
end
