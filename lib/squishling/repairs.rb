# frozen_string_literal: true

require_relative "repairs/rule"
require_relative "repairs/arguments"
require_relative "repairs/store"
require_relative "repairs/config"
require_relative "repairs/request"
require_relative "repairs/attempt"
require_relative "repairs/active"

module Squishling
  # What squish_rescue's learn: remembers: renames of keys in an input, which let the Ruby implementation handle a
  # changed input without the LLM. A rule is data (a Rule), never code, so a model's reply can't run in the process.
  module Repairs
    MAX_JSON_DEPTH = 100

    FAILED = Object.new.freeze

    class << self
      # The typed result of the Ruby implementation on a repaired call, or FAILED when it raised or returned what the
      # schema rejects. An error of Squishling's or of the test helpers goes on to the caller, and the schema check
      # is apart from the call, so an InvalidOutputError from a nested squished call is not taken for this result's.
      def run_repaired(impl, call, definition)
        value = impl.call(*call)
        begin
          definition.coerce(value)
        rescue InvalidOutputError
          FAILED
        end
      rescue StandardError, NotImplementedError => e
        raise if Router.unrescuable?(e)

        FAILED
      end

      def call(frame, impl)
        active = frame.definition.active_repair(frame)
        active ? active.run(impl, frame) : impl.call
      end

      def plain(value)
        Schema.jsonify(value.is_a?(Result::Instance) ? value.to_h : value)
      end

      def same?(first, second)
        !first.nil? && plain(first) == plain(second)
      end

      # The inputs the rules change, by name, with their new values.
      def changes(rules, inputs)
        repaired = rules.inject(inputs) { |current, rule| rule.apply(current) }
        repaired.reject { |name, value| value.equal?(inputs[name]) }
      end

      # Whether a value is only Hashes, Arrays, Strings, Symbols, numbers, true, false, and nil: what a JSON round
      # trip keeps. Anything else (an object, which would put its id in the fingerprint) can't be learned from.
      def plain_json?(value, depth = 0)
        return false if depth > MAX_JSON_DEPTH

        case value
        when Hash then value.all? { |key, item| plain_key?(key) && plain_json?(item, depth + 1) }
        when Array then value.all? { |item| plain_json?(item, depth + 1) }
        when String, Symbol, Numeric, true, false, nil then true
        else false
        end
      end

      private

      def plain_key?(key)
        key.is_a?(String) || key.is_a?(Symbol)
      end
    end
  end
end
