///|
/// Whitebox tests for the Bolt message codec: signature tags, client-message
/// builders, server-message parsing, and chunked framing.

///|
/// The signature (struct tag) of `value`.
fn tag_of(value : PackStreamValue) -> Int {
  match value {
    Struct(tag, _) => tag
    _ => -1
  }
}

///|
/// Client builders produce structs with the correct signature.
test {
  assert_eq(tag_of(hello([])), SIG_HELLO)
  assert_eq(tag_of(goodbye()), SIG_GOODBYE)
  assert_eq(tag_of(reset()), SIG_RESET)
  assert_eq(tag_of(run("RETURN 1", [], [])), SIG_RUN)
  assert_eq(tag_of(begin([])), SIG_BEGIN)
  assert_eq(tag_of(commit()), SIG_COMMIT)
  assert_eq(tag_of(rollback()), SIG_ROLLBACK)
  assert_eq(tag_of(discard([])), SIG_DISCARD)
  assert_eq(tag_of(pull([])), SIG_PULL)
}

///|
/// RUN carries `(query, parameters, extra)` in that order.
test {
  let r = run("RETURN 1", [("n", PackStreamValue::int(1L))], [
    ("mode", PackStreamValue::str("r")),
  ])
  match r {
    Struct(tag, [Str(q), Map(params), Map(extra)]) => {
      assert_eq(tag, SIG_RUN)
      assert_eq(q, "RETURN 1")
      assert_eq(params, [("n", PackStreamValue::int(1L))])
      assert_eq(extra, [("mode", PackStreamValue::str("r"))])
    }
    _ => panic()
  }
}

///|
/// BEGIN/DISCARD/PULL carry a single extra-metadata map.
test {
  match begin([("db", PackStreamValue::str("neo4j"))]) {
    Struct(tag, [Map(extra)]) => {
      assert_eq(tag, SIG_BEGIN)
      assert_eq(extra, [("db", PackStreamValue::str("neo4j"))])
    }
    _ => panic()
  }
  match pull([("n", PackStreamValue::int(10L))]) {
    Struct(tag, [Map(extra)]) => {
      assert_eq(tag, SIG_PULL)
      assert_eq(extra, [("n", PackStreamValue::int(10L))])
    }
    _ => panic()
  }
}

///|
/// Server messages parse from their PackStream structs.
test {
  // SUCCESS.
  assert_eq(
    parse_message(
      PackStreamValue::struct_(SIG_SUCCESS, [
        PackStreamValue::map([("x", PackStreamValue::int(1L))]),
      ]),
    ),
    Some(ServerMessage::Success([("x", PackStreamValue::int(1L))])),
  )
  // RECORD.
  assert_eq(
    parse_message(
      PackStreamValue::struct_(SIG_RECORD, [
        PackStreamValue::list([PackStreamValue::int(1L)]),
      ]),
    ),
    Some(ServerMessage::Record([PackStreamValue::int(1L)])),
  )
  // FAILURE.
  assert_eq(
    parse_message(
      PackStreamValue::struct_(SIG_FAILURE, [
        PackStreamValue::map([("code", PackStreamValue::str("Neo.ClientError"))]),
      ]),
    ),
    Some(
      ServerMessage::Failure([("code", PackStreamValue::str("Neo.ClientError"))]),
    ),
  )
  // IGNORED (no fields).
  assert_eq(
    parse_message(PackStreamValue::struct_(SIG_IGNORED, [])),
    Some(ServerMessage::Ignored),
  )
  // Unknown signature.
  assert_eq(parse_message(PackStreamValue::struct_(0x99, [])), None)
  // Wrong field shape.
  assert_eq(parse_message(PackStreamValue::struct_(SIG_SUCCESS, [])), None)
  assert_eq(
    parse_message(
      PackStreamValue::struct_(SIG_RECORD, [PackStreamValue::map([])]),
    ),
    None,
  )
  // Not a struct at all.
  assert_eq(parse_message(PackStreamValue::null()), None)
}

///|
/// A single-chunk message frames as `length`, payload, `0x0000`.
test {
  // null encodes to the single byte 0xC0.
  assert_eq(frame(PackStreamValue::null()), b"\x00\x01\xc0\x00\x00")
}

///|
/// Frame/unframe round-trips for a small message.
test {
  let msg = PackStreamValue::struct_(SIG_SUCCESS, [
    PackStreamValue::map([("k", PackStreamValue::str("v"))]),
  ])
  assert_eq(unframe(frame(msg)), Some(packstream_encode(msg)))
}

///|
/// A payload longer than 65535 bytes is split into multiple chunks and
/// reassembled losslessly.
test {
  let msg = PackStreamValue::str(String::make(70000, 'a'))
  let framed = frame(msg)
  match unframe(framed) {
    Some(payload) => {
      assert_eq(payload, packstream_encode(msg))
      assert_eq(packstream_decode(payload), Some(msg))
    }
    None => panic()
  }
}

///|
/// `unframe` rejects truncated chunks and missing terminators.
test {
  assert_eq(unframe(b""), None)
  // Missing terminator (one chunk, no 0x0000).
  assert_eq(unframe(b"\x00\x01a"), None)
  // Chunk claims 3 bytes, only 2 present.
  assert_eq(unframe(b"\x00\x03ab"), None)
  // A single stray length byte (no terminator).
  assert_eq(unframe(b"\x00"), None)
}
