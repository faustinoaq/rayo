# JSON and JWT

Require either part independently with `require "rayo/json"` or
`require "rayo/jwt"`. JWT links to OpenSSL libcrypto.

```crystal
buffer = Rayo::Buf.new(8192) # Allocate once, then clear between responses.
writer = Rayo::JSON::Writer.new(buffer)
writer.object do
  writer.field "id", 42_i64
  writer.field("items") do
    writer.array { writer.value "hello"; writer.value nil }
  end
end

reader = Rayo::JSON::Reader.new(Bytes.new(buffer.ptr, buffer.len))
reader["id"].i64 # => 42
reader.object do |key, value|
  # Keys and values are Reader views.
  key.string_equals?("items")
end
```

Writer supports object/array blocks, field(name, value), field(name) blocks,
value(all Int/UInt widths, Float32/Float64, Bool/Nil/String/Bytes), and raw(String/Bytes).
NamedTuple values become objects with compile-time escaped constant keys; tuples and
numeric StaticArray/Slice values become arrays (Bytes remain quoted strings).
Custom values implement `to_json(Rayo::JSON::Writer)`; unsupported types fail compilation.
`writer.array(enumerable) { |item| {id: item} }` emits an array of NamedTuples.
The framework adds `ctx.json(**fields)`, `ctx.json { |j| ... }`,
`ctx.json_array(enumerable) { |item| named_tuple }`, and `ctx.json_body` through
`rayo/context/json`; `rayo/json` itself stays independent of the server.
Raw fragments are validated. There is one root value and at most 64 nested
containers. Bytes used as strings must be valid UTF-8. Floats use the stdlib's
Dragonbox algorithm with stack digits; non-finite values raise JSON::Error.
Create a fresh Writer struct after clearing the buffer.

Reader.new validates the entire document before exposing views; malformed
syntax, invalid UTF-8, unpaired surrogate escapes and excessive depth raise
JSON::Error. Reader.valid? returns Bool; Reader.parse? returns Reader or nil.
The reader borrows the input, which must remain alive and unchanged.
Object iteration yields key/value views; array iteration yields element views.
reader[name] finds an object field and rejects missing or duplicate matches.

Typed getters are i32, i64, f64, bool, null?, and string. i64? and f64? return
nil on type/range errors. JSON number syntax is validated independently of
machine ranges; getters enforce their range. Object/array/string predicates
are object?, array?, and string?. raw includes the complete value without
surrounding whitespace. string returns a Bytes slice between the quotes,
**still JSON escaped**. string(scratch : Bytes) decodes escapes and surrogate
pairs into caller storage, which must have at least string.size bytes.
string_equals?(String) compares the decoded contents without scratch allocation.
Navigation scans the requested container rather than building an index.

```crystal
key = Rayo::JWT::Key.new("application secret") # Once per worker/key.
output = Bytes.new(4096)                     # Once, then reuse.
scratch = Bytes.new(4096)
token = key.sign(%q({"sub":"123","exp":200}), output)
if claims = key.verify(token, scratch, now: 150_i64)
  claims["sub"].string # => raw bytes for 123
end
```

Key accepts String or Bytes. sign(payload, output) requires a JSON object and
returns a slice into output. It writes the fixed HS256/JWT header. Reserve
at least 81 + JWT.encoded_size(payload.size) bytes. Invalid payloads and short
signing/encoding buffers raise. Output must not overlap payload.

verify(token, scratch, now, leeway = 0) accepts String or Bytes and returns a
claims Reader or nil. Pass Unix seconds explicitly. Scratch must accommodate
the larger decoded header or payload and must not overlap token. Returned
claims borrow scratch until reuse. Signature comparison examines all 32 bytes.
The signature is checked before parsing. Only HS256 is accepted; crit and b64
extensions are rejected. Malformed tokens and insufficient scratch return nil.

Optional exp, nbf and iat must be finite NumericDates. exp must be later than
now minus leeway; nbf and iat must be no later than now plus leeway. Future iat
is rejected as a library policy. Negative leeway and duplicate alg or timestamp
claims are rejected. Int64 dates compare exactly with overflow-safe leeway;
fractional or larger dates use Float64 precision. Applications enforce required
claims, issuer, audience and their own authorization policy.

JWT.encode(input, output) and JWT.decode(input, output) write unpadded base64url
into distinct caller buffers and return the written length; decode returns -1
for malformed/noncanonical input or short output. encoded_size(n) sizes encoding
storage; decoding needs floor(encoded_length * 3 / 4) bytes.

Successful writer, reader, signing and verification paths allocate no managed
memory when buffers have enough capacity. Buf can grow through realloc.
Invalid JSON through the throwing API allocates exceptions; verify uses optional
parsing to reject malformed input without exceptions. GC.stats specs measure
managed allocations with the GC enabled; gc_none reports zero statistics and
is tested separately for compatibility. These counters do not measure libc.
