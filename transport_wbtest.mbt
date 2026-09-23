///|
/// Whitebox tests for the in-memory [`MockTransport`].

///|
/// Written bytes are buffered and returned by `outgoing`.
test {
  let mock = MockTransport::new()
  mock.write(b"ab")
  mock.write(b"cd")
  assert_eq(mock.outgoing(), b"abcd")
}

///|
/// `read_exact` returns exactly `n` bytes, advancing the cursor.
test {
  let mock = MockTransport::new()
  mock.feed(b"0123456789")
  assert_eq(mock.read_exact(4), Some(b"0123"))
  assert_eq(mock.read_exact(4), Some(b"4567"))
  assert_eq(mock.read_exact(2), Some(b"89"))
  // No bytes left: reading past the end returns None.
  assert_eq(mock.read_exact(1), None)
}

///|
/// A read that spans the end of the buffer returns None (and does not partially
/// consume).
test {
  let mock = MockTransport::new()
  mock.feed(b"abc")
  assert_eq(mock.read_exact(4), None)
  // The three bytes are still available.
  assert_eq(mock.read_exact(3), Some(b"abc"))
}

///|
/// `close` flips the flag; `feed` appends across calls.
test {
  let mock = MockTransport::new()
  assert_eq(mock.is_closed(), false)
  mock.feed(b"a")
  mock.feed(b"b")
  assert_eq(mock.read_exact(2), Some(b"ab"))
  mock.close()
  assert_eq(mock.is_closed(), true)
}
