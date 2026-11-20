# frozen_string_literal: true

module Squishling
  module Repairs
    # The rules learned for one squish_rescue declaration, by key. A rule becomes active once `confirm` different
    # failing inputs have proposed it; the entries are capped at `limit` (the one used least recently goes first), and
    # a rule not used for `expire_after` seconds is forgotten. Mutex-guarded, like Rotation, because calls run on any
    # thread.
    class Store
      Entry = Struct.new(:rules, :state, :confirmations, :uses, :touched_at)
      private_constant :Entry

      MONOTONIC = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }

      def initialize(confirm:, limit:, expire_after:, clock: MONOTONIC)
        check!(confirm:, limit:, expire_after:)
        @confirm = confirm
        @limit = limit
        @expire_after = expire_after
        @clock = clock
        @entries = {}
        @lock = Mutex.new
      end

      # One failing input (fingerprint) proposed these rules for the key. Returns :active once enough different
      # inputs agree, else :candidate. A different rule for a candidate starts the count again; an active rule is
      # never replaced by a proposal, only forgotten by #drop when it fails.
      def record(key, rules, fingerprint)
        @lock.synchronize do
          entry = current(key)
          next :active if entry&.state == :active

          entry = proposal(key, entry, rules)
          entry.confirmations << fingerprint
          entry.touched_at = @clock.call
          entry.state = :active if entry.confirmations.size >= @confirm
          evict
          entry.state
        end
      end

      # The key's active rules, or nil. Looking is not using: see #used.
      def active(key)
        @lock.synchronize do
          entry = current(key)
          entry.rules if entry&.state == :active
        end
      end

      # The key's rules changed a call's inputs.
      def used(key)
        @lock.synchronize do
          entry = current(key)
          next unless entry

          entry.uses += 1
          entry.touched_at = @clock.call
        end
        nil
      end

      def empty?
        @lock.synchronize { @entries.empty? }
      end

      def drop(key)
        @lock.synchronize { @entries.delete(key) }
        nil
      end

      def clear
        @lock.synchronize { @entries.clear }
      end

      def snapshot
        @lock.synchronize do
          @entries.map do |key, entry|
            { key:, state: entry.state, rules: entry.rules, confirmations: entry.confirmations.size,
              uses: entry.uses }.freeze
          end
        end
      end

      private

      def check!(confirm:, limit:, expire_after:)
        positive = ->(value) { value.is_a?(Integer) && value.positive? }
        raise ConfigurationError, "squish_rescue learn: confirm: must be a positive Integer" unless positive[confirm]
        raise ConfigurationError, "squish_rescue learn: limit: must be a positive Integer" unless positive[limit]
        return if expire_after.nil? || (expire_after.is_a?(Numeric) && expire_after.positive?)

        raise ConfigurationError, "squish_rescue learn: expire_after: must be nil or a positive number of seconds"
      end

      def proposal(key, entry, rules)
        return entry if entry && entry.rules == rules

        @entries[key] = Entry.new(rules, :candidate, Set.new, 0, @clock.call)
      end

      # The entry, unless it has gone unused for too long (it is forgotten then).
      def current(key)
        entry = @entries[key]
        return entry unless entry && @expire_after && @clock.call - entry.touched_at > @expire_after

        @entries.delete(key)
        nil
      end

      def evict
        @entries.delete(@entries.min_by { |_key, entry| entry.touched_at }.first) while @entries.size > @limit
      end
    end
  end
end
