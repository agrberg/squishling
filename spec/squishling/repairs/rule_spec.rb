# frozen_string_literal: true

RSpec.describe Squishling::Repairs::Rule do
  def rule(from: "items", to: "line_items", parent: [], input: "document")
    described_class.new(input:, parent:, from:, to:)
  end

  def deep_freeze(value)
    case value
    when Hash then value.each { |key, item| deep_freeze(key) && deep_freeze(item) }
    when Array then value.each { |item| deep_freeze(item) }
    end
    value.freeze
  end

  describe "#apply" do
    it "renames a key of the named input" do
      inputs = { vendor: "acme", document: { "items" => [1, 2] } }

      repaired = rule.apply(inputs)

      expect(repaired).to eq(vendor: "acme", document: { "line_items" => [1, 2] })
    end

    it "keeps the order of the keys" do
      repaired = rule.apply({ document: { "a" => 1, "items" => 2, "z" => 3 } })

      expect(repaired[:document].keys).to eq(%w[a line_items z])
    end

    it "renames a Symbol key to a Symbol key" do
      repaired = rule.apply({ document: { items: [1] } })

      expect(repaired[:document]).to eq(line_items: [1])
    end

    it "does not change its argument" do
      inputs = deep_freeze({ vendor: "acme", document: { "items" => [{ "cost" => 1 }] } })

      expect { rule.apply(inputs) }.not_to raise_error
    end

    it "renames inside a nested parent" do
      repaired = rule(parent: ["invoice"]).apply({ document: { "invoice" => { "items" => [1] }, "items" => [2] } })

      expect(repaired[:document]).to eq("invoice" => { "line_items" => [1] }, "items" => [2])
    end

    it "renames in every element of an Array for a * parent" do
      document = { "invoices" => [{ "items" => [1] }, { "items" => [2] }, { "other" => 3 }] }

      repaired = rule(parent: %w[invoices *]).apply({ document: })

      expect(repaired[:document]["invoices"])
        .to eq([{ "line_items" => [1] }, { "line_items" => [2] }, { "other" => 3 }])
    end

    it "renames at the top of an input that is an Array of Hashes" do
      repaired = rule(parent: ["*"]).apply({ document: [{ "items" => 1 }, { "items" => 2 }] })

      expect(repaired[:document]).to eq([{ "line_items" => 1 }, { "line_items" => 2 }])
    end

    it "returns the same inputs when nothing matches" do
      inputs = { document: { "other" => 1 } }

      expect(rule.apply(inputs)).to equal(inputs)
    end

    it "does not overwrite a key that already has the new name" do
      inputs = { document: { "items" => 1, "line_items" => 2 } }

      expect(rule.apply(inputs)).to equal(inputs)
    end

    it "leaves another input alone" do
      inputs = { vendor: { "items" => 1 }, document: { "items" => 2 } }

      expect(rule.apply(inputs)[:vendor]).to eq("items" => 1)
    end

    it "returns the same inputs when the named input is missing or is not a Hash or Array" do
      expect(rule.apply({ vendor: "acme" })).to eq(vendor: "acme")
      expect(rule.apply({ document: "text" })).to eq(document: "text")
    end

    it "does not follow a parent through a value that is not a container" do
      inputs = { document: { "invoice" => "text" } }

      expect(rule(parent: ["invoice"]).apply(inputs)).to equal(inputs)
    end
  end

  describe ".parse" do
    def parse(hash, allowed: %w[document])
      described_class.parse(hash, allowed:)
    end

    it "builds a rule from the model's hash" do
      parsed = parse({ "input" => "document", "parent" => ["a"], "from" => "x", "to" => "y" })

      expect(parsed).to eq(rule(parent: ["a"], from: "x", to: "y"))
    end

    it "rejects an input that is not allowed" do
      expect(parse({ "input" => "vendor", "parent" => [], "from" => "x", "to" => "y" })).to be_nil
    end

    it "rejects empty names, a rename to the same name, and a * as a key" do
      base = { "input" => "document", "parent" => [] }

      [{ "from" => "", "to" => "y" }, { "from" => "x", "to" => "x" }, { "from" => "*", "to" => "y" },
       { "from" => "x", "to" => "*" }].each do |keys|
        expect(parse(base.merge(keys))).to be_nil
      end
    end

    it "rejects a parent that is too deep or has an empty part" do
      expect(parse({ "input" => "document", "parent" => Array.new(7, "a"), "from" => "x", "to" => "y" })).to be_nil
      expect(parse({ "input" => "document", "parent" => [""], "from" => "x", "to" => "y" })).to be_nil
    end

    it "rejects anything that is not the expected shape" do
      [nil, "x", [], { "input" => "document" }, { "input" => 1, "parent" => [], "from" => "x", "to" => "y" },
       { "input" => "document", "parent" => "a", "from" => "x", "to" => "y" }].each do |bad|
        expect(parse(bad)).to be_nil
      end
    end
  end

  describe "#to_h" do
    it "is the model's own shape" do
      expect(rule(parent: ["a"]).to_h)
        .to eq("input" => "document", "parent" => ["a"], "from" => "items", "to" => "line_items")
    end
  end
end
