# frozen_string_literal: true

module Squishling
  module Repairs
    # One failed Ruby call that the LLM recovered, and what can be learned from it. It runs in two steps: the model
    # proposes rules while the call is on the LLM path (#request_rules), then the Router checks them in the Ruby
    # phase, once the call has its result (#finish).
    class Attempt
      def initialize(config:, frame:, error:, impl:)
        @config = config
        @frame = frame
        @error = error
        @impl = impl
        @definition = frame.definition
        @inputs = repairable(config.select(frame.inputs))
        @key = config.key(frame)
        @rules = []
      end

      # Asks the model for rules. A failed or rejected request teaches nothing and never fails the call, which has
      # its result; any other setup mistake (ConfigurationError) still does.
      def request_rules(run, result)
        return if @inputs.empty? || !Repairs.plain_json?(@inputs)
        # An active rule is never replaced, so a proposal for a key that has one would be thrown away.
        return if @config.store.active(@key)

        request = Request.new(definition: @definition, config: @config, error: @error, inputs: @inputs)
        @rules = request.rules(run, result)
      rescue InvalidOutputError, LLMError, RequestRejectedError, JSON::JSONError => e
        run.log("repair request failed (#{e.class}), so nothing was learned")
      end

      def finish(result)
        return unless proven?(@rules, result)

        @config.store.record(@key, needed(result), Schema.jsonify(@inputs).hash)
      end

      private

      def proven?(rules, result)
        changes = Repairs.changes(rules, @inputs)
        return false if changes.empty?

        call = @definition.replace_inputs(@frame.args, @frame.kwargs, changes)
        !call.nil? && Repairs.same?(rerun(call), result)
      end

      # The rules without any that the result doesn't need, so a model's extra rename isn't kept with the real one.
      def needed(result)
        @rules.each_with_object(@rules.dup) { |rule, kept| kept.delete(rule) if proven?(kept - [rule], result) }
      end

      # The inputs that can be put back into the call's arguments.
      def repairable(inputs)
        inputs.select { |name, value| @definition.replace_inputs(@frame.args, @frame.kwargs, { name => value }) }
      end

      # nil when it proved nothing. The call has its result, so a failed request inside the method doesn't end it.
      def rerun(call)
        result = Repairs.run_repaired(@impl, call, @frame)
        result unless result.equal?(Repairs::FAILED)
      rescue LLMError, InvalidOutputError, RequestRejectedError
        nil
      end
    end
  end
end
