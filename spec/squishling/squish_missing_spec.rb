# frozen_string_literal: true

RSpec.describe Squishling, ".squish_missing" do
  let(:converter) do
    squishling_class do
      squish_missing(/\A(?<from>[a-z]+)_to_(?<to>[a-z]+)\z/,
        purpose: ->(from:, to:) { "Convert a value from #{from} to #{to}." }) do
        number :value
      end
    end
  end

  describe "creating a method on first call" do
    it "sends the first matching call to the LLM with a purpose built from the captures" do
      chats = stub_llm({ "value" => 212.0 })

      result = converter.new.celsius_to_fahrenheit(value: 100)

      expect(result.value).to eq(212.0)
      expect(result.squished?).to be(true)
      expect(chats.first.instructions).to start_with("Convert a value from celsius to fahrenheit.")
      expect(JSON.parse(chats.first.messages.first)).to eq("arguments" => { "value" => 100 })
    end

    it "defines a real method, so a second call does not go through method_missing" do
      stub_llm({ "value" => 212.0 }, { "value" => 32.0 })
      instance = converter.new

      instance.celsius_to_fahrenheit(value: 100)

      expect(converter.public_method_defined?(:celsius_to_fahrenheit)).to be(true)
      expect(converter.squished_methods).to include(:celsius_to_fahrenheit)
      allow(instance).to receive(:method_missing).and_call_original
      instance.celsius_to_fahrenheit(value: 0)
      expect(instance).not_to have_received(:method_missing)
    end

    it "gives each name its own purpose" do
      chats = stub_llm({ "value" => 1.0 }, { "value" => 2.0 })
      instance = converter.new

      instance.miles_to_km(value: 1)
      instance.km_to_miles(value: 1)

      expect(chats.map { |chat| chat.instructions.lines.first.strip })
        .to eq(["Convert a value from miles to km.", "Convert a value from km to miles."])
    end

    it "answers respond_to? for a matching name and not for another" do
      instance = converter.new

      expect(instance.respond_to?(:celsius_to_fahrenheit)).to be(true)
      expect(instance.respond_to?(:celsius_from_fahrenheit)).to be(false)
    end

    it "lets a subclass use the parent's patterns" do
      stub_llm({ "value" => 1.0 })
      child = Class.new(converter)

      expect(child.new.miles_to_km(value: 1).value).to eq(1.0)
    end

    it "takes the same per-method options as squish" do
      klass = squishling_class do
        squish_missing(/\A(?<a>[a-z]+)_to_(?<b>[a-z]+)\z/, purpose: "Convert.", model: "fake-model",
          validate: ->(result, **) { "value must be positive" if result.value.negative? }) do
          number :value
        end
      end
      stub_llm({ "value" => -1.0 }, { "value" => -1.0 })

      expect { klass.new.x_to_y(value: 1) }.to raise_error(Squishling::InvalidOutputError)
    end
  end

  describe "a name that does not match" do
    it "raises NoMethodError and makes no LLM request" do
      chats = stub_llm

      expect { converter.new.unrelated(value: 1) }.to raise_error(NoMethodError, /unrelated/)
      expect(chats).to be_empty
      expect(converter.squished_methods.keys).not_to include(:unrelated)
    end

    it "does not hide an inherited method_missing" do
      parent = Class.new do
        def method_missing(name, *)
          name == :from_parent ? :parent_answer : super
        end

        def respond_to_missing?(name, include_private = false)
          name == :from_parent || super
        end
      end
      klass = squishling_class(parent) do
        squish_missing(/\A(?<a>[a-z]+)_to_(?<b>[a-z]+)\z/, purpose: "Convert.") { number :value }
      end

      expect(klass.new.from_parent).to eq(:parent_answer)
    end
  end

  describe "limit:" do
    it "raises ConfigurationError for a name past the limit and defines nothing for it" do
      stub_llm({ "value" => 1.0 }, { "value" => 2.0 }, { "value" => 3.0 })
      klass = squishling_class do
        squish_missing(/\A(?<a>[a-z]+)_to_(?<b>[a-z]+)\z/, purpose: "Convert.", limit: 2) { number :value }
      end
      instance = klass.new
      instance.a_to_b(value: 1)
      instance.a_to_c(value: 1)

      expect { instance.a_to_d(value: 1) }.to raise_error(Squishling::ConfigurationError, /limit/)
      expect(klass.squished_methods.keys).not_to include(:a_to_d)
    end

    it "raises the limit error without calling the purpose Proc for a name past the limit" do
      stub_llm({ "value" => 1.0 })
      calls = []
      klass = squishling_class do
        squish_missing(/\A(?<a>[a-z]+)_to_(?<b>[a-z]+)\z/, limit: 1,
          purpose: lambda { |a:, **|
            calls << a
            raise "boom" if a == "over"

            "Convert."
          }) { number :value }
      end
      instance = klass.new
      instance.first_to_x(value: 1)

      expect { instance.over_to_x(value: 1) }.to raise_error(Squishling::ConfigurationError, /limit/)
      expect(calls).to eq(["first"])
    end

    it "does not raise the limit error for a name that another thread made after the first read" do
      klass = squishling_class do
        squish_missing(/\A(?<a>[a-z]+)_to_(?<b>[a-z]+)\z/, purpose: "Convert.", limit: 1) { number :value }
      end
      racing = true
      allow(klass).to receive(:method_defined?).and_wrap_original do |original, name, *rest|
        stale = original.call(name, *rest)
        if racing && name == :a_to_b
          racing = false
          Squishling::Missing.create(klass, name)
        end
        stale
      end

      expect(Squishling::Missing.create(klass, :a_to_b)).to be(true)
      expect(klass.squished_methods.keys).to include(:a_to_b)
    end

    it "does not count a name again once it exists" do
      stub_llm({ "value" => 1.0 }, { "value" => 2.0 })
      klass = squishling_class do
        squish_missing(/\A(?<a>[a-z]+)_to_(?<b>[a-z]+)\z/, purpose: "Convert.", limit: 1) { number :value }
      end
      instance = klass.new

      expect { 2.times { instance.a_to_b(value: 1) } }.not_to raise_error
    end
  end

  describe "hardening a name with a def" do
    it "runs the hand-written method in Ruby, typed like an LLM result" do
      chats = stub_llm
      klass = squishling_class do
        squish_missing(/\A(?<a>[a-z]+)_to_(?<b>[a-z]+)\z/, purpose: "Convert.") { number :value }

        def celsius_to_fahrenheit(value:)
          result(value: (value * 9.0 / 5) + 32)
        end
      end

      result = klass.new.celsius_to_fahrenheit(value: 100)

      expect(result.value).to eq(212.0)
      expect(result.squished?).to be(false)
      expect(chats).to be_empty
    end

    it "sends a def that raises NotImplementedError to the LLM" do
      stub_llm({ "value" => 7.0 })
      klass = squishling_class do
        squish_missing(/\A(?<a>[a-z]+)_to_(?<b>[a-z]+)\z/, purpose: "Convert.") { number :value }

        def miles_to_km(value:) = raise(NotImplementedError)
      end

      expect(klass.new.miles_to_km(value: 1).squished?).to be(true)
    end

    it "leaves a def whose name does not match alone" do
      klass = squishling_class do
        squish_missing(/\A(?<a>[a-z]+)_to_(?<b>[a-z]+)\z/, purpose: "Convert.") { number :value }

        def helper = :plain
      end

      expect(klass.new.helper).to eq(:plain)
      expect(klass.squished_methods.keys).not_to include(:helper)
    end

    it "does not squish a def written before the squish_missing line" do
      klass = squishling_class do
        def a_to_b = :plain

        squish_missing(/\A(?<a>[a-z]+)_to_(?<b>[a-z]+)\z/, purpose: "Convert.") { number :value }
      end

      expect(klass.new.a_to_b).to eq(:plain)
      expect(klass.squished_methods.keys).not_to include(:a_to_b)
    end

    it "leaves a def in a private section alone" do
      chats = stub_llm
      klass = squishling_class do
        squish_missing(/\A(?<a>[a-z]+)_to_(?<b>[a-z]+)\z/, purpose: "Convert.") { number :value }

        private

        def a_to_b = :plain
      end

      expect(klass.squished_methods.keys).not_to include(:a_to_b)
      expect { klass.new.a_to_b }.to raise_error(NoMethodError, /private method/)
      expect(chats).to be_empty
    end

    it "leaves a def in a protected section alone" do
      chats = stub_llm
      klass = squishling_class do
        squish_missing(/\A(?<a>[a-z]+)_to_(?<b>[a-z]+)\z/, purpose: "Convert.") { number :value }

        protected

        def a_to_b = :plain
      end

      expect(klass.squished_methods.keys).not_to include(:a_to_b)
      expect { klass.new.a_to_b }.to raise_error(NoMethodError, /protected method/)
      expect(chats).to be_empty
    end
  end

  describe "matching a whole name" do
    it "matches the whole name even when the pattern has no anchors" do
      klass = squishling_class do
        squish_missing(/a_to_b|c_to_d/, purpose: "Convert.") { number :value }
      end
      instance = klass.new

      expect(instance.respond_to?(:a_to_b)).to be(true)
      expect(instance.respond_to?(:zz_a_to_b)).to be(false)
      expect(instance.respond_to?(:a_to_b_zz)).to be(false)
    end

    it "keeps the end of the name anchored when the x flag's pattern ends in a # comment" do
      klass = squishling_class do
        squish_missing(/\Aa_to_b # the whole name/x, purpose: "Convert.") { number :value }
      end
      instance = klass.new

      expect(instance.respond_to?(:a_to_b)).to be(true)
      expect(instance.respond_to?(:a_to_b_zz)).to be(false)
    end

    it "keeps the pattern's flags" do
      klass = squishling_class do
        squish_missing(/\Ab_to_(?<unit>[a-z]+)\z/i, purpose: "Convert.") { number :value }
      end

      expect(klass.new.respond_to?(:B_TO_km)).to be(true)
    end

    it "keeps a backreference to a named group" do
      klass = squishling_class do
        squish_missing(/\A(?<w>[a-z]+)_to_\k<w>\z/, purpose: "Convert.") { number :value }
      end
      instance = klass.new

      expect(instance.respond_to?(:a_to_a)).to be(true)
      expect(instance.respond_to?(:a_to_b)).to be(false)
    end

    it "matches the whole name when the pattern's anchors cover only one alternative" do
      klass = squishling_class do
        squish_missing(/\Aa_to_b|c_to_d\z/, purpose: "Convert.") { number :value }
      end
      instance = klass.new

      expect(instance.respond_to?(:c_to_d)).to be(true)
      expect(instance.respond_to?(:zzzc_to_d)).to be(false)
      expect { instance.zzzc_to_d(value: 1) }.to raise_error(NoMethodError)
    end
  end

  describe "respond_to?" do
    it "is false for a private method that matches" do
      klass = squishling_class do
        squish_missing(/\A(?<a>[a-z]+)_to_(?<b>[a-z]+)\z/, purpose: "Convert.") { number :value }

        private

        def helper_to_x = :plain
      end

      expect(klass.new.respond_to?(:helper_to_x)).to be(false)
    end

    it "is false for a new name once the limit is reached" do
      stub_llm({ "value" => 1.0 })
      klass = squishling_class do
        squish_missing(/\A(?<a>[a-z]+)_to_(?<b>[a-z]+)\z/, purpose: "Convert.", limit: 1) { number :value }
      end
      instance = klass.new
      instance.a_to_b(value: 1)

      expect(instance.respond_to?(:a_to_c)).to be(false)
      expect(instance.respond_to?(:a_to_b)).to be(true)
    end
  end

  describe "subclasses" do
    it "shares a created method and the limit with its parent and sibling subclasses" do
      stub_llm({ "value" => 1.0 })
      klass = squishling_class do
        squish_missing(/\A(?<a>[a-z]+)_to_(?<b>[a-z]+)\z/, purpose: "Convert.", limit: 1) { number :value }
      end
      first = Class.new(klass)
      second = Class.new(klass)

      first.new.a_to_b(value: 1)

      expect(klass.method_defined?(:a_to_b)).to be(true)
      expect(second.method_defined?(:a_to_b)).to be(true)
      expect { second.new.a_to_c(value: 1) }.to raise_error(Squishling::ConfigurationError, /limit/)
    end
  end

  describe "a purpose Proc that calls another new name" do
    it "makes both methods instead of locking itself" do
      stub_llm({ "value" => 1.0 }, { "value" => 2.0 })
      instance = nil
      klass = squishling_class do
        squish_missing(/\A(?<a>[a-z]+)_to_(?<b>[a-z]+)\z/, purpose: lambda { |a:, **|
          instance.inner_to_x(value: 1) if a == "outer"
          "Convert."
        }) { number :value }
      end
      instance = klass.new

      expect(instance.outer_to_x(value: 1).value).to eq(2.0)
      expect(klass.squished_methods.keys).to include(:outer_to_x, :inner_to_x)
    end
  end

  describe "squish" do
    it "still raises ArgumentError for an unknown keyword" do
      expect { squishling_class { squish :a, bogus: 1 } }.to raise_error(ArgumentError, /bogus/)
    end
  end

  describe "a purpose Proc that raises" do
    it "propagates the error and leaves no method and no count behind" do
      stub_llm({ "value" => 1.0 })
      klass = squishling_class do
        squish_missing(/\A(?<a>[a-z]+)_to_(?<b>[a-z]+)\z/, limit: 1,
          purpose: ->(a:, **) { a == "bad" ? raise("boom") : "Convert." }) { number :value }
      end
      instance = klass.new

      expect { instance.bad_to_x(value: 1) }.to raise_error(RuntimeError, "boom")
      expect(klass.method_defined?(:bad_to_x)).to be(false)
      expect(instance.good_to_x(value: 1).value).to eq(1.0)
    end
  end

  describe "thread safety" do
    it "declares the method once when many threads call the same new name" do
      stub_llm(*Array.new(10) { { "value" => 1.0 } })
      instance = converter.new
      allow(converter).to receive(:squish).and_call_original
      start = Queue.new

      threads = Array.new(10) { Thread.new { start.pop && instance.miles_to_km(value: 1) } }
      10.times { start << true }
      threads.each(&:join)

      expect(converter).to have_received(:squish).once
    end

    it "makes exactly `limit` methods when many threads call distinct names" do
      stub_llm(*Array.new(20) { { "value" => 1.0 } })
      klass = squishling_class do
        squish_missing(/\A(?<a>[a-z]+)_to_(?<b>[a-z]+)\z/, purpose: "Convert.", limit: 5) { number :value }
      end
      instance = klass.new
      start = Queue.new

      threads = Array.new(20) do |index|
        Thread.new do
          start.pop
          instance.public_send(:"a_to_n#{('a'.ord + index).chr}", value: 1)
        rescue Squishling::ConfigurationError
          :over_limit
        end
      end
      20.times { start << true }
      outcomes = threads.map(&:value)

      expect(outcomes.count(:over_limit)).to eq(15)
      expect(klass.squished_methods.keys - [:call]).to have_attributes(size: 5)
    end
  end

  describe "declaration errors" do
    it "rejects a pattern that is not a Regexp" do
      expect { squishling_class { squish_missing("a_to_b", purpose: "x") { number :v } } }
        .to raise_error(Squishling::ConfigurationError, /Regexp/)
    end

    it "rejects an unknown option at declaration, not on the first call" do
      expect { squishling_class { squish_missing(/\Aa\z/, purpose: "x", bogus: 1) { number :v } } }
        .to raise_error(Squishling::ConfigurationError, /bogus/)
    end

    it "rejects a bad option value at declaration, not on the first call" do
      expect { squishling_class { squish_missing(/\Aa\z/, purpose: "x", model: 123) { number :v } } }
        .to raise_error(Squishling::ConfigurationError, /squish_missing.*model/)
      expect { squishling_class { squish_missing(/\Aa\z/, purpose: "x", harness: :nonexistent) { number :v } } }
        .to raise_error(Squishling::ConfigurationError, /squish_missing.*harness/)
    end

    it "rejects a provider: without a model:" do
      expect { squishling_class { squish_missing(/\Aa\z/, purpose: "x", provider: :openai) { number :v } } }
        .to raise_error(Squishling::ConfigurationError, /provider/)
    end

    it "rejects a limit that is not a positive Integer" do
      expect { squishling_class { squish_missing(/\Aa\z/, purpose: "x", limit: 0) { number :v } } }
        .to raise_error(Squishling::ConfigurationError, /limit/)
    end
  end

  describe "Squishling.verify" do
    it "reports a purpose lambda that does not take the pattern's captures" do
      klass = squishling_class do
        squish_missing(/\A(?<from>[a-z]+)_to_(?<to>[a-z]+)\z/, purpose: ->(from:) { "From #{from}" }) do
          number :value
        end
      end

      report = Squishling.verify(klass)

      expect(report.problems.map(&:message)).to include(a_string_matching(/to:/))
    end

    it "reports a pattern with no output_schema and no purpose" do
      klass = squishling_class { squish_missing(/\Aa_to_b\z/) }

      messages = Squishling.verify(klass).problems.map(&:message)

      expect(messages).to include("has no output_schema", "has no purpose")
    end

    it "does not report an inherited pattern again for a subclass" do
      child = Class.new(converter)

      expect(Squishling.verify(child).problems).to be_empty
      expect(Squishling.verify(converter, child).problems).to be_empty
    end

    it "is clean for a valid pattern" do
      expect(Squishling.verify(converter).problems).to be_empty
    end
  end
end
