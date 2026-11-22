# frozen_string_literal: true

module Squishling
  class Rescue
    attr_reader :errors

    class << self
      def build(owner, errors, as:, learn:, overrides:)
        where = "#{owner}#squish_rescue"
        check_errors!(where, errors)
        check_as!(where, as)
        raise ConfigurationError, "#{where} does not take repair:, which is Squishling's own" if overrides.key?(:repair)

        config = Repairs::Config.build(learn, where)
        # for_call checks the overrides exactly as `squish!` would, so a bad value fails here, not on a call.
        Definition.new(klass: owner, name: :squish_rescue).for_call(**overrides)
        check_context!(where, as, overrides[:context])
        new(errors:, as:, config:, overrides:)
      end

      private

      def check_errors!(where, errors)
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

      def check_as!(where, as)
        return if (as.is_a?(Symbol) || as.is_a?(String)) && !as.empty?

        raise ConfigurationError, "#{where} as: must be a non-empty Symbol or String, got #{as.inspect}"
      end

      def check_context!(where, as, context)
        return unless context&.keys&.any? { |key| key.to_sym == as.to_sym }

        raise ConfigurationError, "#{where} context: has the key #{as.to_sym.inspect}, which as: uses for the error; " \
                                  "rename one of them"
      end
    end

    def initialize(errors:, as:, config:, overrides:)
      @errors = errors
      @as = as.to_sym
      @config = config
      @overrides = overrides
    end

    def match?(error)
      errors.any? { |klass| klass === error } # rubocop:disable Style/CaseEquality
    end

    def overrides_for(error, attempt = nil)
      overrides = @overrides.merge(context: (@overrides[:context] || {}).merge(@as => error))
      attempt ? overrides.merge(repair: attempt) : overrides
    end

    def learn?
      !@config.nil?
    end

    def learn_key
      @config&.by
    end

    def attempt(frame, error, impl)
      Repairs::Attempt.new(config: @config, frame:, error:, impl:) if learn?
    end

    def active(frame)
      Repairs::Active.lookup(@config, frame) if learn?
    end

    def repairs
      return [] unless learn?

      @config.store.snapshot.map { |entry| entry.merge(method: entry[:key].first, key: entry[:key].last) }
    end

    def forget_repairs
      @config&.store&.clear
    end
  end
end
