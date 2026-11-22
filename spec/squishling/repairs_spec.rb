# frozen_string_literal: true

RSpec.describe Squishling::Repairs do
  # Totals the cost of the document's "line_items", which acme now sends as "items".
  def invoice_class(**learn)
    Class.new do
      include Squishling

      purpose "Total the invoice."
      output_schema { number :total }
      squish_rescue KeyError, NoMethodError, append_to_purpose: "The parser failed; the error is in the context.",
        learn: { by: ->(vendor:, **) { vendor }, **learn }

      def call(vendor:, document:) # rubocop:disable Lint/UnusedMethodArgument -- vendor only keys the repair
        result(total: document.fetch("line_items").sum { |item| item["cost"] })
      end
    end
  end

  def acme(cost) = { "items" => [{ "cost" => cost }, { "cost" => 7 }] }

  def rename_items
    { "renames" => [{ "input" => "document", "parent" => [], "from" => "items", "to" => "line_items" }] }
  end

  def total(value) = { "total" => value }

  def messages(chats, index) = JSON.parse(chats[index].messages.first)

  describe "learning a repair" do
    it "makes Ruby handle a changed input after enough different inputs agree" do
      chats = stub_llm(total(12), rename_items, total(14), rename_items)
      klass = invoice_class

      first = klass.call(vendor: "acme", document: acme(5))
      second = klass.call(vendor: "acme", document: acme(7))
      third = klass.call(vendor: "acme", document: acme(9))

      expect([first, second].map(&:squished?)).to eq([true, true])
      expect(third.squished?).to be(false)
      expect(third.total).to eq(16)
      expect(third.class).to eq(first.class)
      expect(chats.size).to eq(4)
    end

    it "keeps the caller's input as it was" do
      stub_llm(total(12), rename_items, total(14), rename_items)
      klass = invoice_class
      document = acme(9)

      klass.call(vendor: "acme", document: acme(5))
      klass.call(vendor: "acme", document: acme(7))
      klass.call(vendor: "acme", document: document)

      expect(document.keys).to eq(["items"])
    end

    it "activates after one input when confirm is 1" do
      chats = stub_llm(total(12), rename_items)
      klass = invoice_class(confirm: 1)

      klass.call(vendor: "acme", document: acme(5))

      expect(klass.call(vendor: "acme", document: acme(9)).squished?).to be(false)
      expect(chats.size).to eq(2)
    end

    it "does not count the same input twice" do
      chats = stub_llm(total(12), rename_items, total(12), rename_items, total(16), rename_items)
      klass = invoice_class

      2.times { klass.call(vendor: "acme", document: acme(5)) }
      expect(klass.squishling_repairs.first).to include(state: :candidate, confirmations: 1)

      expect(klass.call(vendor: "acme", document: acme(9)).squished?).to be(true)
      expect(klass.squishling_repairs.first).to include(state: :active, confirmations: 2)
      expect(chats.size).to eq(6)
    end

    it "keeps a rule for one key from another" do
      stub_llm(total(12), rename_items, total(14), rename_items, total(20))
      klass = invoice_class
      klass.call(vendor: "acme", document: acme(5))
      klass.call(vendor: "acme", document: acme(7))

      expect(klass.call(vendor: "globex", document: acme(13)).squished?).to be(true)
    end

    it "sends the LLM the call's own input when an active rule's call fails" do
      chats = stub_llm(total(12), rename_items, total(14), rename_items, total(1), rename_items)
      klass = invoice_class(confirm: 2)
      [5, 7].each { |cost| klass.call(vendor: "acme", document: acme(cost)) }
      broken = { "items" => 5 }

      result = klass.call(vendor: "acme", document: broken)

      expect(result.squished?).to be(true)
      expect(messages(chats, 4)["arguments"]).to eq("vendor" => "acme", "document" => { "items" => 5 })
    end

    it "forgets an active rule whose call fails" do
      stub_llm(total(12), rename_items, total(14), rename_items, total(1), rename_items)
      klass = invoice_class
      [5, 7].each { |cost| klass.call(vendor: "acme", document: acme(cost)) }
      expect(klass.squishling_repairs.first).to include(state: :active)

      klass.call(vendor: "acme", document: { "items" => 5 })

      expect(klass.squishling_repairs.map { |entry| entry[:state] }).not_to include(:active)
    end
  end

  describe "what a repair must prove" do
    it "is not kept when Ruby still fails on the repaired input" do
      stub_llm(total(12), { "renames" => [{ "input" => "document", "parent" => [], "from" => "items", "to" => "x" }] })
      klass = invoice_class(confirm: 1)

      result = klass.call(vendor: "acme", document: acme(5))

      expect(result.squished?).to be(true)
      expect(klass.squishling_repairs).to be_empty
    end

    it "is not kept when Ruby's result on the repaired input differs from the LLM's" do
      stub_llm(total(99), rename_items)
      klass = invoice_class(confirm: 1)

      klass.call(vendor: "acme", document: acme(5))

      expect(klass.squishling_repairs).to be_empty
    end

    it "is not kept when it changes nothing" do
      stub_llm(total(12), { "renames" => [{ "input" => "document", "parent" => [], "from" => "nope", "to" => "x" }] })
      klass = invoice_class(confirm: 1)

      klass.call(vendor: "acme", document: acme(5))

      expect(klass.squishling_repairs).to be_empty
    end

    it "is not kept when the model names an input that learn: does not allow" do
      stub_llm(total(12), { "renames" => [{ "input" => "vendor", "parent" => [], "from" => "a", "to" => "b" }] })
      klass = invoice_class(confirm: 1)

      klass.call(vendor: "acme", document: acme(5))

      expect(klass.squishling_repairs).to be_empty
    end

    it "is not kept when the model proposes no rename" do
      stub_llm(total(12), { "renames" => [] })
      klass = invoice_class(confirm: 1)

      klass.call(vendor: "acme", document: acme(5))

      expect(klass.squishling_repairs).to be_empty
    end
  end

  describe "what the model may propose" do
    def reply(*renames) = { "renames" => renames }

    def rename(from, to, input: "document") = { "input" => input, "parent" => [], "from" => from, "to" => to }

    it "keeps at most five renames" do
      decoys = (1..5).map { |index| rename("a#{index}", "b#{index}") }
      stub_llm(total(12), reply(*decoys, rename("items", "line_items")))
      klass = invoice_class(confirm: 1)

      klass.call(vendor: "acme", document: acme(5))

      expect(klass.squishling_repairs).to be_empty
    end

    it "learns nothing when one of the renames is invalid" do
      stub_llm(total(12), reply(rename("items", "line_items"), rename("meta", "meta")))
      klass = invoice_class(confirm: 1)

      klass.call(vendor: "acme", document: acme(5))

      expect(klass.squishling_repairs).to be_empty
    end
  end

  describe "when the repair request fails" do
    it "still returns the LLM's result when the reply is invalid" do
      stub_llm(total(12), "not json", "not json", "not json")
      klass = invoice_class(confirm: 1)

      result = klass.call(vendor: "acme", document: acme(5))

      expect(result.total).to eq(12)
      expect(klass.squishling_repairs).to be_empty
    end

    it "still returns the LLM's result when the provider fails" do
      stub_llm(total(12), Squishling::LLMError.new("down"))
      klass = invoice_class(confirm: 1)

      expect(klass.call(vendor: "acme", document: acme(5)).total).to eq(12)
    end

    it "does not hide a setup mistake" do
      stub_llm(total(12), Squishling::ConfigurationError.new("bad key"))
      klass = invoice_class(confirm: 1)

      expect { klass.call(vendor: "acme", document: acme(5)) }.to raise_error(Squishling::ConfigurationError)
    end

    it "still returns the LLM's result when the provider rejects the repair request" do
      stub_llm(total(12), Squishling::RequestRejectedError.new("HTTP 400"))
      klass = invoice_class(confirm: 1)

      result = klass.call(vendor: "acme", document: acme(5))

      expect(result.total).to eq(12)
      expect(klass.squishling_repairs).to be_empty
    end

    it "does not ask when no input can be repaired, such as one that arrives in a splat" do
      chats = stub_llm(total(12))
      klass = Class.new do
        include Squishling

        purpose "Total."
        output_schema { number :total }
        squish_rescue KeyError, learn: { by: ->(**) { :all } }

        def call(*documents) = result(total: documents.first.fetch("line_items").size)
      end

      expect(klass.call(acme(5)).total).to eq(12)
      expect(chats.size).to eq(1)
    end

    it "does not ask, or learn, when an input is not plain JSON" do
      chats = stub_llm(total(12))
      klass = invoice_class(confirm: 1)

      klass.call(vendor: "acme", document: { "items" => [{ "cost" => 5 }], "tag" => Object.new })

      expect(chats.size).to eq(1)
      expect(klass.squishling_repairs).to be_empty
    end

    it "makes no repair request when the LLM path fails" do
      chats = stub_llm("not json", "not json", "not json")
      klass = invoice_class(confirm: 1)

      expect { klass.call(vendor: "acme", document: acme(5)) }.to raise_error(Squishling::InvalidOutputError)
      expect(chats.size).to eq(1)
    end
  end

  describe "the repair request" do
    it "sends the error, the input, and the correct result, and no other input or source" do
      chats = stub_llm(total(12), rename_items)
      invoice_class(confirm: 1).call(vendor: "acme", document: acme(5))

      sent = messages(chats, 1)

      expect(sent["error"]).to include("class" => "KeyError")
      expect(sent["inputs"]).to eq("document" => acme(5))
      expect(sent["result"]).to eq("total" => 12)
      expect(sent).not_to have_key("source")
    end

    it "sends the method's own source with source: true" do
      chats = stub_llm(total(12), rename_items)
      invoice_class(confirm: 1, source: true).call(vendor: "acme", document: acme(5))

      expect(messages(chats, 1)["source"]).to include("def call(vendor:, document:)")
    end

    it "leaves the source out when the method has none on disk" do
      stub_llm(total(12), rename_items)
      klass = Class.new do
        include Squishling

        purpose "Total the invoice."
        output_schema { number :total }
        squish_rescue KeyError, learn: { by: ->(vendor:, **) { vendor }, confirm: 1, source: true }
      end
      klass.class_eval(<<~RUBY, "(no source on disk)", 1) # rubocop:disable Style/EvalWithLocation -- no file to read
        def call(vendor:, document:)
          result(total: document.fetch("line_items").sum { |item| item["cost"] })
        end
      RUBY

      expect(klass.call(vendor: "acme", document: acme(5)).total).to eq(12)
      expect(klass.squishling_repairs).not_to be_empty
    end

    it "sends only the inputs that inputs: names" do
      chats = stub_llm(total(12), rename_items)
      invoice_class(confirm: 1, inputs: [:document]).call(vendor: "acme", document: acme(5))

      expect(messages(chats, 1)["inputs"].keys).to eq(["document"])
    end

    it "is reported to squawk as a repair" do
      reports = []
      stub_llm(total(12), rename_items)
      klass = invoice_class(confirm: 1)
      klass.squishling(squawk: ->(metadata:, **) { reports << metadata[:role] })

      klass.call(vendor: "acme", document: acme(5))

      expect(reports).to eq([nil, :repair])
    end

    it "counts against the call's token budget" do
      stub_llm(FakeChat::Response.new(total(12), nil, { input_tokens: 10, output_tokens: 100 }), rename_items)
      klass = invoice_class(confirm: 1)
      klass.squishling(max_total_output_tokens: 50)

      result = klass.call(vendor: "acme", document: acme(5))

      expect(result.total).to eq(12)
      expect(klass.squishling_repairs).to be_empty
    end
  end

  describe "an active repair" do
    # Raises `error` from the method's own code for the document the rename would produce from {"items" => "boom"}.
    def strict_class(error)
      boom_class { raise error, "from the method" }
    end

    # A learning class whose method runs the block for the document that the rename makes from {"items" => "boom"}.
    def boom_class(&on_boom)
      Class.new do
        include Squishling

        purpose "Total."
        output_schema { number :total }
        squish_rescue KeyError, learn: { by: ->(vendor:, **) { vendor }, confirm: 1 }

        define_method(:call) do |document:, **|
          next instance_exec(&on_boom) if document["line_items"] == "boom"

          result(total: document.fetch("line_items").sum { |item| item["cost"] })
        end
      end
    end

    it "counts a use only when it changes the call's inputs" do
      stub_llm(total(12), rename_items)
      klass = invoice_class(confirm: 1)
      klass.call(vendor: "acme", document: acme(5))

      klass.call(vendor: "acme", document: { "line_items" => [{ "cost" => 1 }] })
      expect(klass.squishling_repairs.first[:uses]).to eq(0)

      klass.call(vendor: "acme", document: acme(9))
      expect(klass.squishling_repairs.first[:uses]).to eq(1)
    end

    it "does not call by: for a healthy call while nothing is learned" do
      calls = []
      klass = Class.new do
        include Squishling

        purpose "Total."
        output_schema { number :total }
        squish_rescue KeyError, learn: { by: ->(**) { calls << :by } }

        def call(**) = result(total: 1)
      end

      klass.call(vendor: "acme")

      expect(calls).to be_empty
    end

    it "does not hide an error of Squishling's from the method, and keeps the rule" do
      stub_llm(total(12), rename_items)
      klass = strict_class(Squishling::ConfigurationError)
      klass.call(vendor: "acme", document: acme(5))

      expect { klass.call(vendor: "acme", document: { "items" => "boom" }) }
        .to raise_error(Squishling::ConfigurationError, "from the method")
      expect(klass.squishling_repairs.first).to include(state: :active)
    end

    it "does not hide an error of the test helpers from the method, and keeps the rule" do
      require "squishling/testing"
      stub_llm(total(12), rename_items)
      klass = strict_class(Squishling::Testing::UnscriptedRequestError)
      klass.call(vendor: "acme", document: acme(5))

      expect { klass.call(vendor: "acme", document: { "items" => "boom" }) }
        .to raise_error(Squishling::Testing::UnscriptedRequestError)
      expect(klass.squishling_repairs.first).to include(state: :active)
    end

    it "does not fail a call that has its LLM result when the repaired input reaches a missing implementation" do
      stub_llm(total(12), rename_items)
      klass = strict_class(NotImplementedError)

      result = klass.call(vendor: "acme", document: { "items" => "boom" })

      expect(result.total).to eq(12)
      expect(klass.squishling_repairs).to be_empty
    end

    it "forgets a rule whose repaired call reaches a missing implementation, and lets the LLM handle the call" do
      stub_llm(total(12), rename_items, total(3), rename_items)
      klass = strict_class(NotImplementedError)
      klass.call(vendor: "acme", document: acme(5))

      result = klass.call(vendor: "acme", document: { "items" => "boom" })

      expect(result.squished?).to be(true)
      expect(klass.squishling_repairs).to be_empty
    end

    def invalid_result_class
      boom_class { { total: "bad" } }
    end

    it "forgets a rule whose repaired call returns a result that fails the schema, and lets the LLM handle the call" do
      stub_llm(total(12), rename_items, total(3), rename_items)
      klass = invalid_result_class
      klass.call(vendor: "acme", document: acme(5))

      result = klass.call(vendor: "acme", document: { "items" => "boom" })

      expect(result.squished?).to be(true)
      expect(result.total).to eq(3)
      expect(klass.squishling_repairs).to be_empty
    end

    it "does not fail a call that has its LLM result when the repaired input returns a result that fails the schema" do
      stub_llm(total(12), rename_items)
      klass = invalid_result_class

      result = klass.call(vendor: "acme", document: { "items" => "boom" })

      expect(result.total).to eq(12)
      expect(klass.squishling_repairs).to be_empty
    end

    it "does not fail a call that has its LLM result when a squished call inside the method fails while proving" do
      [Squishling::LLMError, Squishling::InvalidOutputError, Squishling::RequestRejectedError].each do |failure|
        stub_llm(total(12), rename_items)
        klass = boom_class { raise failure, "from a nested squished call" }

        result = klass.call(vendor: "acme", document: { "items" => "boom" })

        expect(result.total).to eq(12)
        expect(klass.squishling_repairs).to be_empty
      end
    end

    it "does not hide an error of Squishling's raised while a rule is being proven" do
      stub_llm(total(12), rename_items)
      klass = strict_class(Squishling::ConfigurationError)

      expect { klass.call(vendor: "acme", document: { "items" => "boom" }) }
        .to raise_error(Squishling::ConfigurationError, "from the method")
    end

    it "does not hide an error of the test helpers raised while a rule is being proven" do
      require "squishling/testing"
      stub_llm(total(12), rename_items)
      klass = strict_class(Squishling::Testing::UnscriptedRequestError)

      expect { klass.call(vendor: "acme", document: { "items" => "boom" }) }
        .to raise_error(Squishling::Testing::UnscriptedRequestError)
    end

    it "does not let a squish! in the method prove a rename" do
      stub_llm(total(12), rename_items, total(12))
      klass = boom_class { squish! }

      klass.call(vendor: "acme", document: { "items" => "boom" })

      expect(klass.squishling_repairs).to be_empty
    end

    it "forgets a rule whose repaired call hands itself to the LLM with squish!" do
      stub_llm(total(12), rename_items, total(3), rename_items)
      klass = boom_class { squish! }
      klass.call(vendor: "acme", document: acme(5))

      result = klass.call(vendor: "acme", document: { "items" => "boom" })

      expect(result.total).to eq(3)
      expect(klass.squishling_repairs).to be_empty
    end

    it "logs the error that made it forget a rule" do
      log = StringIO.new
      Squishling.configure { |config| config.logger = Logger.new(log) }
      stub_llm(total(12), rename_items, total(3), rename_items)
      klass = strict_class(IOError)
      klass.call(vendor: "acme", document: acme(5))

      klass.call(vendor: "acme", document: { "items" => "boom" })

      expect(log.string).to match(/forgot the learned repair.*IOError/)
    end

    it "makes no repair request for a key whose rule is active but does not apply to the input" do
      chats = stub_llm(total(12), rename_items, total(5))
      klass = invoice_class(confirm: 1)
      klass.call(vendor: "acme", document: acme(5))

      result = klass.call(vendor: "acme", document: { "entries" => [{ "cost" => 5 }] })

      expect(result.total).to eq(5)
      expect(chats.size).to eq(3)
    end

    it "keeps only the renames that the result needs" do
      extra = { "input" => "document", "parent" => [], "from" => "meta", "to" => "metadata" }
      stub_llm(total(12), { "renames" => rename_items["renames"] + [extra] })
      klass = invoice_class(confirm: 1)

      klass.call(vendor: "acme", document: acme(5).merge("meta" => { "page" => 1 }))

      expect(klass.squishling_repairs.first[:rules].map(&:from)).to eq(["items"])
    end

    it "repairs an input that the method takes positionally" do
      stub_llm(total(12), rename_items)
      klass = Class.new do
        include Squishling

        purpose "Total."
        output_schema { number :total }
        squish_rescue KeyError, learn: { by: ->(vendor:, **) { vendor }, confirm: 1 }

        def call(document, vendor:) # rubocop:disable Lint/UnusedMethodArgument -- vendor only keys the repair
          result(total: document.fetch("line_items").sum { |item| item["cost"] })
        end
      end
      klass.call(acme(5), vendor: "acme")

      repaired = klass.call(acme(9), vendor: "acme")

      expect(repaired.squished?).to be(false)
      expect(repaired.total).to eq(16)
    end

    it "works through a subclass that calls super" do
      stub_llm(total(12), rename_items)
      child = Class.new(invoice_class(confirm: 1)) do
        def call(vendor:, document:) = super(vendor:, document: document.dup)
      end
      child.call(vendor: "acme", document: acme(5))

      expect(child.call(vendor: "acme", document: acme(9)).squished?).to be(false)
    end
  end

  describe "squish_validate" do
    it "does not check the repair, which is not the method's output" do
      stub_llm(total(12), rename_items)
      klass = invoice_class(confirm: 1)
      klass.squish_validate { |result, **| "never" if result.respond_to?(:renames) }

      klass.call(vendor: "acme", document: acme(5))

      expect(klass.squishling_repairs).not_to be_empty
    end
  end

  describe "by:" do
    it "is the developer's code: an error from it ends a failing call" do
      klass = Class.new do
        include Squishling

        purpose "Total."
        output_schema { number :total }
        squish_rescue KeyError, learn: { by: ->(**) { raise "by: failed" } }

        def call(**) = raise(KeyError, "x")
      end

      expect { klass.call(vendor: "acme") }.to raise_error(RuntimeError, "by: failed")
    end
  end

  describe "by: on a healthy call" do
    it "ends the call when it raises an error that another squish_rescue declares" do
      chats = stub_llm(total(12), rename_items)
      klass = Class.new do
        include Squishling

        purpose "Total."
        output_schema { number :total }
        squish_rescue KeyError, append_to_purpose: "The parser failed; the error is in the context."
        squish_rescue NoMethodError, learn: { by: ->(vendor:, **) { { "acme" => 1 }.fetch(vendor) }, confirm: 1 }

        def call(vendor:, document:) # rubocop:disable Lint/UnusedMethodArgument -- vendor only keys the repair
          result(total: document["line_items"].sum { |item| item["cost"] })
        end
      end
      klass.call(vendor: "acme", document: acme(5))

      expect { klass.call(vendor: "globex", document: { "line_items" => [{ "cost" => 1 }] }) }
        .to raise_error(KeyError)
      expect(chats.size).to eq(2)
    end
  end

  describe "#squishling_repairs and #squishling_forget_repairs!" do
    it "lists what is learned, by method and key, and forgets it" do
      stub_llm(total(12), rename_items)
      klass = invoice_class(confirm: 1)
      klass.call(vendor: "acme", document: acme(5))

      entry = klass.squishling_repairs.first

      expect(entry).to include(method: :call, key: "acme", state: :active, confirmations: 1, uses: 0)
      expect(entry[:rules].map(&:to_h)).to eq(rename_items["renames"])

      klass.squishling_forget_repairs!

      expect(klass.squishling_repairs).to be_empty
    end

    it "lists rules that cannot change what the class uses" do
      stub_llm(total(12), rename_items)
      klass = invoice_class(confirm: 1)
      klass.call(vendor: "acme", document: acme(5))

      expect { klass.squishling_repairs.first[:rules].clear }.to raise_error(FrozenError)
    end

    it "lists and forgets what a subclass learned from its parent's declaration" do
      stub_llm(total(12), rename_items)
      child = Class.new(invoice_class(confirm: 1))
      child.call(vendor: "acme", document: acme(5))

      expect(child.squishling_repairs).not_to be_empty

      child.squishling_forget_repairs!

      expect(child.squishling_repairs).to be_empty
    end

    it "uses a rule learned through the second of two learn: declarations" do
      stub_llm(total(12), rename_items)
      klass = Class.new do
        include Squishling

        purpose "Total."
        output_schema { number :total }
        squish_rescue NoMethodError, learn: { by: ->(vendor:, **) { vendor }, confirm: 1 }
        squish_rescue KeyError, learn: { by: ->(vendor:, **) { vendor }, confirm: 1 }

        def call(vendor:, document:) # rubocop:disable Lint/UnusedMethodArgument -- vendor only keys the repair
          result(total: document.fetch("line_items").sum { |item| item["cost"] })
        end
      end
      klass.call(vendor: "acme", document: acme(5))

      expect(klass.call(vendor: "acme", document: acme(9)).squished?).to be(false)
    end
  end

  describe "declaring learn:" do
    def declare(learn)
      Class.new do
        include Squishling

        squish_rescue ArgumentError, learn:
      end
    end

    it "does not take repair:, which is Squishling's own" do
      expect do
        Class.new do
          include Squishling

          squish_rescue ArgumentError, repair: Object.new
        end
      end.to raise_error(Squishling::ConfigurationError, /repair:/)
    end

    it "needs by:, a Proc" do
      expect { declare({}) }.to raise_error(Squishling::ConfigurationError, /by:/)
      expect { declare({ by: "vendor" }) }.to raise_error(Squishling::ConfigurationError, /by:/)
    end

    it "must be a Hash" do
      expect { declare(true) }.to raise_error(Squishling::ConfigurationError, /learn:/)
    end

    it "rejects an unknown key" do
      expect { declare({ by: ->(**) { 1 }, bogus: 1 }) }.to raise_error(Squishling::ConfigurationError, /bogus/)
    end

    it "rejects bad numbers" do
      expect { declare({ by: ->(**) { 1 }, confirm: 0 }) }.to raise_error(Squishling::ConfigurationError, /confirm/)
      expect { declare({ by: ->(**) { 1 }, limit: "x" }) }.to raise_error(Squishling::ConfigurationError, /limit/)
      expect { declare({ by: ->(**) { 1 }, expire_after: -5 }) }
        .to raise_error(Squishling::ConfigurationError, /expire_after/)
    end

    it "rejects inputs: that is not a list of names" do
      expect { declare({ by: ->(**) { 1 }, inputs: "document" }) }
        .to raise_error(Squishling::ConfigurationError, /inputs:/)
      expect { declare({ by: ->(**) { 1 }, inputs: [1] }) }.to raise_error(Squishling::ConfigurationError, /inputs:/)
    end

    it "rejects source: that is not true or false" do
      expect { declare({ by: ->(**) { 1 }, source: "yes" }) }.to raise_error(Squishling::ConfigurationError, /source:/)
    end
  end

  describe "Squishling.verify" do
    it "reports a by: Proc that does not take the method's inputs" do
      klass = Class.new do
        include Squishling

        purpose "x"
        output_schema { number :total }
        squish_rescue KeyError, learn: { by: ->(missing:) { missing } }

        def call(vendor:, document:) = result(total: [vendor, document].size)
      end

      messages = Squishling.verify(klass).problems.map(&:message)

      expect(messages).to include(a_string_matching(/learn by:/))
    end

    it "is clean for a valid declaration" do
      expect(Squishling.verify(invoice_class).problems).to be_empty
    end
  end
end
