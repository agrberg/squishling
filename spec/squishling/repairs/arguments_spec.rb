# frozen_string_literal: true

RSpec.describe Squishling::Repairs::Arguments do
  def replace(parameters, args, kwargs, changes)
    described_class.replace(parameters, args, kwargs, changes)
  end

  let(:parameters) { ->(first, second = 2, *rest, third:, fourth: 4, **options) {}.parameters }

  it "replaces a required positional argument" do
    expect(replace(parameters, [1, 2], { third: 3 }, { first: :new })).to eq([[:new, 2], { third: 3 }])
  end

  it "replaces an optional positional argument" do
    expect(replace(parameters, [1, 2], { third: 3 }, { second: :new })).to eq([[1, :new], { third: 3 }])
  end

  it "replaces a required and an optional keyword argument" do
    expect(replace(parameters, [1], { third: 3, fourth: 4 }, { third: :a, fourth: :b }))
      .to eq([[1], { third: :a, fourth: :b }])
  end

  it "replaces several arguments at once" do
    expect(replace(parameters, [1, 2], { third: 3 }, { first: :a, third: :c })).to eq([[:a, 2], { third: :c }])
  end

  it "counts a parameter with no name when it finds a position" do
    destructuring = ->((first, second), third) {}.parameters

    expect(replace(destructuring, [[1, 2], 3], {}, { third: :new })).to eq([[[1, 2], :new], {}])
  end

  it "does not change the arguments it is given" do
    args = [1, 2].freeze
    kwargs = { third: 3 }.freeze

    expect { replace(parameters, args, kwargs, { first: :new, third: :new }) }.not_to raise_error
  end

  it "returns nil for an input that is a splat, a keyword splat, or not a parameter" do
    expect(replace(parameters, [1, 2, 3], { third: 3 }, { rest: [:new] })).to be_nil
    expect(replace(parameters, [1], { third: 3, extra: 1 }, { extra: :new })).to be_nil
    expect(replace(parameters, [1], { third: 3 }, { options: {} })).to be_nil
  end

  it "returns nil when any one of the inputs cannot be replaced" do
    expect(replace(parameters, [1], { third: 3 }, { first: :new, extra: :new })).to be_nil
  end

  it "returns the arguments unchanged for no changes" do
    expect(replace(parameters, [1], { third: 3 }, {})).to eq([[1], { third: 3 }])
  end
end
