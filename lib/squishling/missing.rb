# frozen_string_literal: true

module Squishling
  # Squished methods made on first call from a name pattern (see ClassMethods#squish_missing).
  module Missing
    DEFAULT_LIMIT = 100

    # Definitions are rare and brief, so one lock serves every class.
    LOCK = Mutex.new

    SQUISH_OPTIONS = ClassMethods.instance_method(:squishling_method_options).parameters
      .filter_map { |type, name| name if type == :key }.freeze
    private_constant :SQUISH_OPTIONS

    class Pattern
      attr_reader :owner, :regexp, :purpose, :limit, :names

      def self.build(owner, regexp, purpose:, limit:, options:, schema_block:)
        where = "#{owner} squish_missing"
        check_regexp!(where, regexp)
        check_purpose!(where, purpose)
        check_limit!(where, limit)
        check_options!(where, options, schema_block)
        options = options.merge(output_schema: Schematist::Schema.create(&schema_block)) if schema_block
        owner.send(:squishling_method_options, where, **options)
        new(owner:, regexp:, purpose:, limit:, options:)
      end

      def self.check_regexp!(where, regexp)
        return if regexp.is_a?(Regexp)

        raise ConfigurationError, "#{where} needs a Regexp, got #{regexp.inspect}"
      end

      def self.check_purpose!(where, purpose)
        return if purpose.nil? || purpose.is_a?(String) || purpose.is_a?(Proc)

        raise ConfigurationError, "#{where} purpose: must be a String or a Proc of the captures"
      end

      def self.check_limit!(where, limit)
        return if limit.is_a?(Integer) && limit.positive?

        raise ConfigurationError, "#{where} limit: must be a positive Integer, got #{limit.inspect}"
      end

      def self.check_options!(where, options, schema_block)
        unknown = options.keys - SQUISH_OPTIONS
        raise ConfigurationError, "#{where}: unknown option(s) #{unknown.join(', ')}" if unknown.any?
        return unless schema_block && options[:output_schema]

        raise ConfigurationError, "#{where} takes an output_schema: or a block, not both"
      end
      private_class_method :check_regexp!, :check_purpose!, :check_limit!, :check_options!

      def initialize(owner:, regexp:, purpose:, limit:, options:)
        @owner = owner
        @regexp = regexp
        @whole_name = whole_name(regexp)
        @purpose = purpose
        @limit = limit
        @options = options
        @names = []
      end

      # The named captures of a matching name, as keywords, or nil when the name doesn't match.
      def captures(name)
        @whole_name.match(name.to_s)&.named_captures&.transform_keys(&:to_sym)
      end

      def full?
        names.size >= limit
      end

      def capture_names
        regexp.names.map(&:to_sym)
      end

      def output_schema
        @options[:output_schema]
      end

      def options_for(captures)
        value = purpose.is_a?(Proc) ? purpose.call(**captures) : purpose
        @options.merge(purpose: value).compact
      end

      private

      # Wrapped, so a top-level `|` can't leave one side unanchored; a newline ends a `#` comment in the x flag.
      def whole_name(regexp)
        tail = regexp.options.anybits?(Regexp::EXTENDED) ? "\n" : ""
        Regexp.new("\\A(?:#{regexp.source}#{tail})\\z", regexp.options)
      end
    end

    module Instance
      def method_missing(name, ...)
        return super unless Missing.create(self.class, name)

        public_send(name, ...)
      end

      def respond_to_missing?(name, include_private = false)
        Missing.creatable?(self.class, name) || super
      end
    end

    module Hook
      private

      def method_added(name)
        super
        Missing.harden(self, name)
      end
    end

    class << self
      def find(klass, name)
        klass.squishling_missing_patterns.each do |pattern|
          captures = pattern.captures(name)
          return [pattern, captures] if captures
        end
        nil
      end

      # Whether a method exists for the name afterwards; raises ConfigurationError past the pattern's limit.
      def create(klass, name)
        return false if hidden?(klass, name)

        pattern, captures = find(klass, name)
        return false unless pattern

        full = pattern.full?
        unless pattern.owner.method_defined?(name)
          raise_over_limit!(pattern, name) if full
          define(pattern, name, pattern.options_for(captures))
        end
        true
      end

      # `private def x` is squished and public: Ruby reports the `def` before the `private` that follows it.
      def harden(klass, name)
        return if klass.squished_methods.key?(name) || hidden?(klass, name)

        pattern, captures = find(klass, name)
        return unless pattern

        options = pattern.options_for(captures)
        LOCK.synchronize { klass.squish(name, **options) }
      end

      def creatable?(klass, name)
        return false if hidden?(klass, name)

        pattern, = find(klass, name)
        pattern ? !pattern.full? : false
      end

      private

      # Checked again under the lock: another thread may have made the name, or filled the pattern, meanwhile.
      def define(pattern, name, options)
        LOCK.synchronize do
          next if pattern.owner.method_defined?(name)

          raise_over_limit!(pattern, name) if pattern.full?
          pattern.owner.squish(name, **options)
          pattern.names << name
        end
      end

      def hidden?(klass, name)
        klass.private_method_defined?(name) || klass.protected_method_defined?(name)
      end

      def raise_over_limit!(pattern, name)
        raise ConfigurationError,
          "#{pattern.owner} squish_missing #{pattern.regexp.inspect} has reached its limit: of #{pattern.limit} " \
          "names, so #{name} is not created. Raise limit:, or check the code that passes the names"
      end
    end
  end
end
