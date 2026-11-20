# Learned repairs

[`squish_rescue`](routing.md#rescuing-declared-errors-with-squish_rescue) sends a failed call to the LLM, and the
LLM gets the same failure again on the next call. A learned repair stops that. When the LLM recovers a call, it also
says which keys of the input changed names. After enough inputs agree, the Ruby implementation handles the changed
input itself, with no request and no waiting.

## An example

A vendor changes its invoice format. Your parser reads `line_items`, and the vendor now sends `items`:

```ruby
class InvoiceParser
  include Squishling

  purpose "Total the invoice."
  output_schema { number :total }
  squish_rescue KeyError, learn: { by: ->(vendor:, **) { vendor } }

  def call(vendor:, document:)
    result(total: document.fetch("line_items").sum { |item| item["cost"] })
  end
end
```

1. A call with the new format raises `KeyError`. The LLM recovers it, as for any `squish_rescue`.
2. Squishling sends one more request. It asks the model which keys to rename. The model answers
   `items` to `line_items` in `document`.
3. Squishling applies the rename to a copy of the input and runs your Ruby again. If the result is exactly the one
   the LLM gave, the rename is a candidate for the key `"acme"`. The caller always gets the LLM's result.
4. A second, different input from the same vendor proposes the same rename. The rename is now active.
5. The next call from this vendor renames the key and runs your Ruby. It makes no request. `squished?` is `false`.

## Declaring it

`learn:` takes a Hash:

| Option | Default | Meaning |
|---|---|---|
| `by:` | required | A Proc that gets the method's inputs as keywords and returns the key a repair belongs to, such as the vendor. A repair is used only for calls with the same key. Return a String, a Symbol, or a number. |
| `inputs:` | every Hash or Array input | The names of the inputs that a repair may change. |
| `confirm:` | `2` | How many different inputs must propose the same rename before it is used. |
| `limit:` | `100` | The most keys that are remembered. The key used least recently is forgotten first. |
| `expire_after:` | `nil` | Forget a repair that has not been used for this many seconds. |
| `source:` | `false` | Also send the method's own Ruby source in the repair request. |

`by:` is your code. An error from it is yours: it ends the call, as an error from your method does. It runs when a
call fails, and, once the class remembers anything (even a candidate), on every call of the class. A `learn:`
declaration covers every squished method of the class, so `by:` must accept the inputs of all of them.
`Squishling.verify` checks this.

A repair can change only an input that your method takes as a plain positional or keyword parameter, and only one
that is plain JSON (Hashes, Arrays, Strings, Symbols, numbers, `true`, `false`, and `nil`). An input that arrives in
a splat (`*args`, `**options`), or that holds another object, is never repaired, and the request is not made.

## What a repair is

A repair is a list of renames, and nothing else. Each rename moves one key to a new name inside an input. It
can reach into nested hashes, and into every element of an array with `*`. It never overwrites a key, and it never
changes the input that you pass in.

A repair is data. Squishling never runs code that a model wrote. The input often comes from outside your system,
and a document that contains instructions for the model could otherwise run code in your process.

## What it can promise, and what it cannot

A repair is kept only if your Ruby, on a repaired input, returns the result that the LLM gave. It is used only after
`confirm` different inputs agree. A repair that is in use is not replaced by a proposal for a different rename. It
is forgotten as soon as it fails: if the repaired call raises, or returns a result that fails the schema, Squishling
forgets the repair and runs your Ruby on the call's own input. That call fails as before, and the LLM handles it. An
error of Squishling's own, or of `squishling/testing`, is not a reason to forget a repair, and goes to the caller.
The one exception is the check that a new repair works: there, a failed request of a squished call inside your
method (`LLMError`, `InvalidOutputError`) proves nothing and does not fail the call, which already has its result.
A method whose correct result is `nil` can never be proven, so nothing is learned for it.

A repair cannot promise that every later result is right. After it is active, Squishling does not compare the Ruby
result with the LLM. Suppose a vendor sends `{"items" => "n/a"}`. The repaired call runs
`"n/a".sum { ... }`, and `String#sum` is a real method that returns a number. The result is valid, and it is wrong.
To lower this risk:

- Keep `confirm:` at 2 or more.
- Choose a narrow `by:`, so a repair learned from one vendor is not used for another.
- Check `squishling_repairs` (below), and put a rename that you trust into your code.

Two more warnings, for input that you do not control:

- `confirm:` is not a defense against a hostile document. "Different" means any difference in the data, such as
  `1` and `1.0`, and not a different sender. A person who can send two documents under one key can propose a
  rename for that key, and the rename is checked only against their own documents.
- `by:` must not come from the document. If the sender chooses the key, the sender can plant a rename under another
  customer's key, or fill the store with keys until it forgets the real ones. Take the key from your own data, such
  as the authenticated account.

## What it costs

- **One more request per learning call.** It uses the method's escalation steps and counts against the call's token
  budget. The caller waits for it. A call that fails on the LLM path makes no repair request. A request that fails
  teaches nothing and does not fail the call: an invalid answer, a provider error, a spent token budget, and a
  request that the provider rejects (a 400) are logged with the error class, and the call returns the LLM's result.
- **Your Ruby runs again** on a learning call: once to check the renames and, when the model proposed more than one,
  once for each of them (Squishling drops a rename that the result does not need, and at most 5 are kept). It also
  runs again when a repair fails. Do not write to a database or send a message before the line that raises. These
  runs share the nested objects of your input with the caller, so a method that changes its arguments changes them
  each time. A squished call inside your method can make a billed request on each run.
- **A repair lives in one process.** Each worker learns on its own, and a restart forgets everything. A class and its
  subclasses share what is learned, so forgetting in one forgets for all.

## What leaves the process

The repair request goes to the provider of the method's escalation. Besides what the call already sent, it carries
the inputs that a repair may change and the correct result. With `source: true` it also carries the Ruby source of
the failing method, and when the source can't be read, it is left out.

The model's answer reaches your code only through the `squawk` hook, with the role `:repair`, like any other model
output. Squishling does not write it to the log.

## Seeing and removing what was learned

```ruby
InvoiceParser.squishling_repairs
# => [{ method: :call, key: "acme", state: :active, confirmations: 2, uses: 41,
#       rules: [#<Squishling::Repairs::Rule input="document", parent=[], from="items", to="line_items">] }]

InvoiceParser.squishling_forget_repairs!
```

`uses` counts the calls that a repair changed and that your Ruby then handled. `squishling_forget_repairs!` on a
subclass also forgets what the subclass inherits from its parents. A learned repair is a stop-gap while the service
runs. To keep the change, put the rename in your parser and deploy. `state` is `:candidate` until `confirm` inputs
agree.

## Testing

A plain `step` rule in [`squishling/testing`](testing.md) answers a repair request, because it has no role of its
own. Script the call's answer first and the repair's answer second.
