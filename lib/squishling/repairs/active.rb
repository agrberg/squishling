# frozen_string_literal: true

module Squishling
  module Repairs
    class Active
      def self.lookup(config, frame)
        return if config.store.empty?

        key = config.key(frame)
        rules = config.store.active(key)
        new(config:, key:, rules:) if rules
      end

      def initialize(config:, key:, rules:)
        @config = config
        @key = key
        @rules = rules
      end

      # Runs the Ruby implementation on the repaired inputs. When that fails (see Repairs.run_repaired), the rule is
      # forgotten and the implementation runs on the call's own inputs, which fails the way it did before.
      def run(impl, frame)
        call = repaired_call(frame)
        return impl.call unless call

        result = Repairs.run_repaired(impl, call, frame.definition)
        if result.equal?(Repairs::FAILED)
          @config.store.drop(@key)
          return impl.call
        end

        @config.store.used(@key)
        result
      end

      private

      def repaired_call(frame)
        changes = Repairs.changes(@rules, @config.select(frame.inputs))
        frame.definition.replace_inputs(frame.args, frame.kwargs, changes) unless changes.empty?
      end
    end
  end
end
