///|
/// Whitebox tests for the streaming [`Reader`] / [`Writer`].

///|
/// A writer accumulates multiple values in order.
test {
  let w = Writer::new()
  w.write(PackStreamValue::int(1L))
  w.write(PackStreamValue::str("hi"))
  w.write(PackStreamValue::null())
  assert_eq(w.to_bytes(), b"\x01\x82hi\xc0")
}

///|
/// A reader walks values one at a time and reports eof.
test {
  let r = Reader::new(b"\x01\x82hi\xc0")
  assert_eq(r.eof(), false)
  assert_eq(r.read(), Some(PackStreamValue::int(1L)))
  assert_eq(r.read(), Some(PackStreamValue::str("hi")))
  assert_eq(r.read(), Some(PackStreamValue::null()))
  assert_eq(r.eof(), true)
  assert_eq(r.read(), None)
}

///|
/// A reader leaves its cursor unchanged on malformed input.
test {
  let r = Reader::new(b"\x85he")
  assert_eq(r.read(), None)
  // Still not eof: the truncated string was not consumed.
  assert_eq(r.eof(), false)
}

///|
/// `remaining` counts unconsumed bytes.
test {
  let r = Reader::new(b"\x01\x01\x01")
  assert_eq(r.remaining(), 3)
  let _ = r.read()
  assert_eq(r.remaining(), 2)
}

///|
/// Writer/reader round-trip via the streaming interface.
test {
  let w = Writer::new()
  w.write(
    PackStreamValue::list([PackStreamValue::int(1L), PackStreamValue::int(2L)]),
  )
  let bytes = w.to_bytes()
  let r = Reader::new(bytes)
  assert_eq(
    r.read(),
    Some(
      PackStreamValue::list([PackStreamValue::int(1L), PackStreamValue::int(2L)]),
    ),
  )
  assert_eq(r.eof(), true)
}
