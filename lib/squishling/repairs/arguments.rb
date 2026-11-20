# frozen_string_literal: true

module Squishling
  module Repairs
    module Arguments
      POSITIONAL = %i[req opt].freeze
      KEYWORD = %i[key keyreq].freeze

      module_function

      # args and kwargs with the changes made, or nil when one of the inputs isn't a plain positional or keyword
      # parameter of the method (a splat, or one with no name). parameters is Method#parameters.
      def replace(parameters, args, kwargs, changes)
        positional = positional_names(parameters)
        return unless (changes.keys - positional - keyword_names(parameters)).empty?

        args = args.dup
        kwargs = kwargs.dup
        changes.each do |name, value|
          position = positional.index(name)
          position ? args[position] = value : kwargs[name] = value
        end
        [args, kwargs]
      end

      # Every positional parameter, so that one with no name (nil) still takes its place.
      def positional_names(parameters)
        parameters.each_with_object([]) { |(type, name), names| names << name if POSITIONAL.include?(type) }
      end

      def keyword_names(parameters)
        parameters.filter_map { |type, name| name if KEYWORD.include?(type) }
      end
    end
  end
end
