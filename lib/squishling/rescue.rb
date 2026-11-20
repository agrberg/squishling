# frozen_string_literal: true

module Squishling
  class Rescue
    attr_reader :errors

    def self.build(owner, errors, as:, overrides:)
      where = "#{owner}#squish_rescue"
      check_errors!(where, errors)
      check_as!(where, as)
      # for_call checks the overrides exactly as `squish!` would, so a bad value fails here, not on a call.
      Definition.new(klass: owner, name: :squish_rescue).for_call(**overrides)
      check_context!(where, as, overrides[:context])
      new(errors:, as:, overrides:)
    end

    def self.check_errors!(where, errors)
      raise ConfigurationError, "#{where} needs at least one error class" if errors.empty?

      classes = errors.grep(Class)
      if classes.include?(NotImplementedError)
        raise ConfigurationError, "#{where}: NotImplementedError already sends a call to the LLM"
      end
      unless classes.size == errors.size && classes.all? { |error| error <= StandardError }
        raise ConfigurationError, "#{where} needs exception classes that inherit StandardError, got #{errors.inspect}"
      end
      return unless classes.any? { |error| error <= Error }

      raise ConfigurationError, "#{where}: Squishling's own errors are never sent to the LLM"
    end

    def self.check_as!(where, as)
      return if (as.is_a?(Symbol) || as.is_a?(String)) && !as.empty?

      raise ConfigurationError, "#{where} as: must be a non-empty Symbol or String, got #{as.inspect}"
    end

    def self.check_context!(where, as, context)
      return unless context&.keys&.any? { |key| key.to_sym == as.to_sym }

      raise ConfigurationError, "#{where} context: has the key #{as.to_sym.inspect}, which as: uses for the error; " \
                                "rename one of them"
    end
    private_class_method :check_errors!, :check_as!, :check_context!

    def initialize(errors:, as:, overrides:)
      @errors = errors
      @as = as.to_sym
      @overrides = overrides
    end

    def match?(error)
      errors.any? { |klass| klass === error } # rubocop:disable Style/CaseEquality
    end

    def overrides_for(error)
      @overrides.merge(context: (@overrides[:context] || {}).merge(@as => error))
    end
  end
end
