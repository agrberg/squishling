# frozen_string_literal: true

module Squishling
  module Repairs
    class Config
      KEYS = %i[by inputs confirm limit expire_after source].freeze

      attr_reader :by, :source, :store

      def self.build(learn, where)
        return if learn.nil?
        unless learn.is_a?(Hash)
          raise ConfigurationError, "#{where} learn: must be a Hash with by:, got #{learn.inspect}"
        end

        unknown = learn.keys - KEYS
        raise ConfigurationError, "#{where} learn: has unknown option(s) #{unknown.join(', ')}" if unknown.any?

        new(where:, **learn)
      end

      def initialize(where:, by: nil, inputs: nil, confirm: 2, limit: 100, expire_after: nil, source: false)
        raise ConfigurationError, "#{where} learn: by: must be a Proc of the method's inputs" unless by.is_a?(Proc)
        raise ConfigurationError, "#{where} learn: inputs: must be a list of input names" unless names?(inputs)
        raise ConfigurationError, "#{where} learn: source: must be true or false" unless [true, false].include?(source)

        @by = by
        @inputs = inputs&.map(&:to_s)
        @source = source
        @store = Store.new(confirm:, limit:, expire_after:)
      end

      # The store key of a call: its method and what by: makes of its inputs.
      def key(frame)
        [frame.definition.name, frame.receiver.instance_exec(**frame.inputs, &by)]
      end

      def select(inputs)
        inputs.select do |name, value|
          @inputs ? @inputs.include?(name.to_s) : value.is_a?(Hash) || value.is_a?(Array)
        end
      end

      private

      def names?(inputs)
        inputs.nil? || (inputs.is_a?(Array) && inputs.all? { |name| name.is_a?(Symbol) || name.is_a?(String) })
      end
    end
  end
end
