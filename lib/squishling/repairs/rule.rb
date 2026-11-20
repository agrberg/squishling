# frozen_string_literal: true

module Squishling
  module Repairs
    # Rename the key `from` to `to` inside the input named `input`, in the Hash found by following `parent`: a list of
    # keys, where "*" stands for every element of an Array. It never overwrites a key, and never changes what it
    # is given.
    class Rule < Data.define(:input, :parent, :from, :to)
      MAX_DEPTH = 6

      class << self
        def parse(hash, allowed:)
          return unless hash.is_a?(Hash)

          input, parent, from, to = hash.values_at("input", "parent", "from", "to")
          return unless allowed.include?(input) && key?(from) && key?(to) && from != to && parent?(parent)

          new(input:, parent: parent.dup.freeze, from:, to:)
        end

        private

        def key?(value)
          value.is_a?(String) && !value.empty? && value != "*"
        end

        def parent?(value)
          value.is_a?(Array) && value.size <= MAX_DEPTH && value.all? { |part| part.is_a?(String) && !part.empty? }
        end
      end

      def apply(inputs)
        name = inputs.keys.find { |key| key.to_s == input }
        return inputs unless name

        renamed = rename(inputs[name], parent)
        renamed.equal?(inputs[name]) ? inputs : inputs.merge(name => renamed)
      end

      def to_h
        { "input" => input, "parent" => parent, "from" => from, "to" => to }
      end

      private

      def rename(value, path)
        return rename_key(value) if path.empty?

        head, *rest = path
        case value
        when Array then head == "*" ? each_element(value, rest) : value
        when Hash then within_key(value, head, rest)
        else value
        end
      end

      def each_element(array, rest)
        renamed = array.map { |element| rename(element, rest) }
        renamed.zip(array).all? { |new, old| new.equal?(old) } ? array : renamed
      end

      def within_key(hash, head, rest)
        key = hash.keys.find { |candidate| candidate.to_s == head }
        return hash unless key

        renamed = rename(hash[key], rest)
        renamed.equal?(hash[key]) ? hash : hash.merge(key => renamed)
      end

      def rename_key(value)
        return value unless value.is_a?(Hash)

        key = value.keys.find { |candidate| candidate.to_s == from }
        return value if key.nil? || value.keys.any? { |candidate| candidate.to_s == to }

        new_key = key.is_a?(Symbol) ? to.to_sym : to
        value.to_h { |candidate, item| candidate == key ? [new_key, item] : [candidate, item] }
      end
    end
  end
end
