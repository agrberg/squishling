# frozen_string_literal: true

RSpec.describe Squishling::Repairs::Store do
  let(:now) { [0.0] }
  let(:rules) { [Squishling::Repairs::Rule.new(input: "document", parent: [], from: "items", to: "line_items")] }
  let(:other_rules) { [Squishling::Repairs::Rule.new(input: "document", parent: [], from: "lines", to: "line_items")] }

  def store(confirm: 2, limit: 100, expire_after: nil)
    described_class.new(confirm:, limit:, expire_after:, clock: -> { now.first })
  end

  describe "#record" do
    it "keeps a rule a candidate until enough different inputs agree" do
      repairs = store(confirm: 2)

      expect(repairs.record(:acme, rules, "input-1")).to eq(:candidate)
      expect(repairs.active(:acme)).to be_nil
      expect(repairs.record(:acme, rules, "input-2")).to eq(:active)
      expect(repairs.active(:acme)).to eq(rules)
    end

    it "counts the same input once" do
      repairs = store(confirm: 2)

      repairs.record(:acme, rules, "input-1")

      expect(repairs.record(:acme, rules, "input-1")).to eq(:candidate)
      expect(repairs.active(:acme)).to be_nil
    end

    it "starts again when a later input proposes a different rule" do
      repairs = store(confirm: 2)
      repairs.record(:acme, rules, "input-1")

      expect(repairs.record(:acme, other_rules, "input-2")).to eq(:candidate)
      expect(repairs.record(:acme, rules, "input-3")).to eq(:candidate)
      expect(repairs.active(:acme)).to be_nil
    end

    it "activates at once when confirm is 1" do
      expect(store(confirm: 1).record(:acme, rules, "input-1")).to eq(:active)
    end

    it "keeps each key apart" do
      repairs = store(confirm: 1)
      repairs.record(:acme, rules, "input-1")

      expect(repairs.active(:globex)).to be_nil
    end
  end

  describe "#drop" do
    it "forgets a key, active or not" do
      repairs = store(confirm: 1)
      repairs.record(:acme, rules, "input-1")

      repairs.drop(:acme)

      expect(repairs.active(:acme)).to be_nil
      expect(repairs.snapshot).to be_empty
    end

    it "does nothing for an unknown key" do
      expect { store.drop(:nobody) }.not_to raise_error
    end
  end

  describe "limit:" do
    it "forgets the key used least recently when it is full" do
      repairs = store(confirm: 1, limit: 2)
      repairs.record(:a, rules, "i")
      now[0] = 1.0
      repairs.record(:b, rules, "i")
      now[0] = 2.0
      repairs.used(:a)
      now[0] = 3.0
      repairs.record(:c, rules, "i")

      expect(repairs.snapshot.map { |entry| entry[:key] }).to contain_exactly(:a, :c)
    end
  end

  describe "expire_after:" do
    it "forgets a rule that has not been used for that long" do
      repairs = store(confirm: 1, expire_after: 60)
      repairs.record(:acme, rules, "i")

      now[0] = 59.0
      expect(repairs.active(:acme)).to eq(rules)
      repairs.used(:acme)
      now[0] = 100.0
      expect(repairs.active(:acme)).to eq(rules)
      repairs.used(:acme)
      now[0] = 161.0
      expect(repairs.active(:acme)).to be_nil
      expect(repairs.snapshot).to be_empty
    end

    it "does not count a lookup as a use" do
      repairs = store(confirm: 1, expire_after: 60)
      repairs.record(:acme, rules, "i")

      now[0] = 50.0
      repairs.active(:acme)
      now[0] = 100.0

      expect(repairs.active(:acme)).to be_nil
    end

    it "never forgets a rule when it is nil" do
      repairs = store(confirm: 1, expire_after: nil)
      repairs.record(:acme, rules, "i")

      now[0] = 10_000_000.0

      expect(repairs.active(:acme)).to eq(rules)
    end
  end

  describe "#snapshot" do
    it "describes each entry without exposing the store's own objects" do
      repairs = store(confirm: 2)
      repairs.record(:acme, rules, "input-1")
      repairs.record(:acme, rules, "input-2")
      repairs.active(:acme)
      repairs.used(:acme)

      entry = repairs.snapshot.first

      expect(entry).to include(key: :acme, state: :active, rules:, confirmations: 2, uses: 1)
      expect(entry).to be_frozen
    end
  end

  describe "#clear" do
    it "forgets everything" do
      repairs = store(confirm: 1)
      repairs.record(:acme, rules, "i")

      repairs.clear

      expect(repairs.snapshot).to be_empty
    end
  end

  it "activates once and stops counting under many threads" do
    repairs = store(confirm: 5, limit: 100)

    Array.new(20) { |index| Thread.new { repairs.record(:acme, rules, "input-#{index}") } }.each(&:join)

    expect(repairs.active(:acme)).to eq(rules)
    expect(repairs.snapshot.first[:confirmations]).to eq(5)
  end

  describe "an active rule" do
    it "stops counting inputs, so a stream of failing inputs does not grow the entry" do
      repairs = store(confirm: 2)

      1_000.times { |index| repairs.record(:acme, rules, "input-#{index}") }

      expect(repairs.snapshot.first[:confirmations]).to eq(2)
    end

    it "is kept when another input proposes a different rule" do
      repairs = store(confirm: 1)
      repairs.record(:acme, rules, "input-1")

      expect(repairs.record(:acme, other_rules, "input-2")).to eq(:active)
      expect(repairs.active(:acme)).to eq(rules)
    end
  end

  it "rejects a bad configuration" do
    expect { store(confirm: 0) }.to raise_error(Squishling::ConfigurationError, /confirm/)
    expect { store(limit: 0) }.to raise_error(Squishling::ConfigurationError, /limit/)
    expect { store(expire_after: -1) }.to raise_error(Squishling::ConfigurationError, /expire_after/)
  end
end
