///|
/// Whitebox tests for the Bolt handshake.

///|
/// The magic preamble is the fixed 4 bytes.
test {
  assert_eq(MAGIC, b"\x60\x60\xb0\x17")
}

///|
/// Version encoding: `[reserved][range][minor][major]`.
test {
  assert_eq(bolt_version(5, 0, 0), 0x00000005)
  assert_eq(bolt_version(5, 1, 0), 0x00000105)
  assert_eq(bolt_version(5, 4, 0), 0x00000405)
  assert_eq(bolt_version(4, 4, 0), 0x00000404)
  assert_eq(bolt_version(3, 0, 0), 0x00000003)
  // Range form: 5.4 accepting down to 5.0.
  assert_eq(bolt_version(5, 4, 4), 0x00040405)
}

///|
/// A handshake message is 20 bytes: magic + four version slots.
test {
  let msg = handshake_message([bolt_version(5, 0, 0)])
  assert_eq(msg.length(), 20)
  assert_eq(
    msg, b"\x60\x60\xb0\x17\x00\x00\x00\x05\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",
  )
}

///|
/// Four proposals are written in order.
test {
  let msg = handshake_message([
    bolt_version(5, 4, 0),
    bolt_version(5, 0, 0),
    bolt_version(4, 4, 0),
    bolt_version(3, 0, 0),
  ])
  assert_eq(
    msg, b"\x60\x60\xb0\x17\x00\x00\x04\x05\x00\x00\x00\x05\x00\x00\x04\x04\x00\x00\x00\x03",
  )
}

///|
/// Proposals beyond four are ignored; fewer than four are zero-padded.
test {
  assert_eq(
    handshake_message([
      bolt_version(5, 4, 0),
      bolt_version(5, 0, 0),
      bolt_version(4, 4, 0),
      bolt_version(3, 0, 0),
      bolt_version(2, 0, 0),
    ]),
    b"\x60\x60\xb0\x17\x00\x00\x04\x05\x00\x00\x00\x05\x00\x00\x04\x04\x00\x00\x00\x03",
  )
}

///|
/// The server response is parsed back to an agreed version.
test {
  assert_eq(
    parse_handshake_response(b"\x00\x00\x01\x05"),
    Some(bolt_version(5, 1, 0)),
  )
  assert_eq(
    parse_handshake_response(b"\x00\x00\x04\x04"),
    Some(bolt_version(4, 4, 0)),
  )
  // Zero means "no supported version".
  assert_eq(parse_handshake_response(b"\x00\x00\x00\x00"), None)
  // Wrong length.
  assert_eq(parse_handshake_response(b"\x00\x00"), None)
}
