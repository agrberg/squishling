# frozen_string_literal: true

module Squishling
  module Repairs
    # The request that asks the model for renames after it recovered a failed call. What it sends, besides what
    # the call already sent: the failing method's own source (unless source: false) and the correct result.
    class Request
      MAX_RULES = 5

      INSTRUCTIONS = <<~TEXT
        You repair the input of a Ruby method. The method failed on the input below, and the correct result for it
        is already known. Find renames of keys in the input that make the method's own code work, and return them.
        Each rename moves the key "from" to the key "to" inside the input named "input", in the object found by
        following "parent": a list of keys, where "*" stands for every element of an array (an empty list means the
        top of the input). Return no renames if no rename of keys would fix it.

        The request is a JSON object. "method" is the method's name, "source" its Ruby code, "error" what it raised,
        "inputs" the inputs that may be repaired, and "result" the correct result. Respond only with JSON matching
        the required schema.
      TEXT

      def initialize(definition:, config:, error:, inputs:)
        @definition = definition
        @config = config
        @error = error
        @inputs = inputs
      end

      # The rules the model proposes: every one valid, or none.
      def rules(run, result)
        prompt = Invoker::Prompt.new(instructions: INSTRUCTIONS, schema: Schema.for(schema), role: :repair,
          input: JSON.generate(payload(result)))
        renames = Schema.jsonify(run.ask_repair(prompt).to_h)["renames"].first(MAX_RULES)
        rules = renames.map { |rename| Rule.parse(rename, allowed: @inputs.keys.map(&:to_s)) }
        rules.all? ? rules : []
      end

      private

      def payload(result)
        { method: @definition.label, source:, error: { class: error_class, message: @error.message },
          inputs: Schema.jsonify(@inputs), result: Repairs.plain(result) }.compact
      end

      def source
        return unless @config.source

        Source.render(@definition.klass.instance_method(@definition.name))
      rescue ConfigurationError
        nil
      end

      def error_class
        klass = @error.class
        klass = klass.superclass until klass.name
        klass.name
      end

      def schema
        text = { "type" => "string" }
        input = { "type" => "string", "enum" => @inputs.keys.map(&:to_s) }
        parent = { "type" => "array", "items" => text }
        properties = { "input" => input, "parent" => parent, "from" => text, "to" => text }
        rename = { "type" => "object", "additionalProperties" => false, "required" => properties.keys,
                   "properties" => properties }
        { "title" => "squishling_repair", "type" => "object", "additionalProperties" => false,
          "required" => ["renames"], "properties" => { "renames" => { "type" => "array", "items" => rename } } }
      end
    end
  end
end
