///|
/// Whitebox tests for the Bolt explicit transaction layer.

///|
/// A framed server SUCCESS carrying `metadata`.
fn tx_server_success(metadata : Array[(String, PackStreamValue)]) -> Bytes {
  frame(PackStreamValue::struct_(SIG_SUCCESS, [PackStreamValue::map(metadata)]))
}

///|
/// A framed server RECORD carrying `fields`.
fn tx_server_record(fields : Array[PackStreamValue]) -> Bytes {
  frame(PackStreamValue::struct_(SIG_RECORD, [PackStreamValue::list(fields)]))
}

///|
/// A framed server FAILURE carrying `metadata`.
fn tx_server_failure(metadata : Array[(String, PackStreamValue)]) -> Bytes {
  frame(PackStreamValue::struct_(SIG_FAILURE, [PackStreamValue::map(metadata)]))
}

///|
/// Concatenate several byte strings in order.
fn tx_concat(parts : Array[Bytes]) -> Bytes {
  let buf = Buffer::Buffer()
  for p in parts {
    buf.write_bytes(p.exact_view())
  }
  buf.to_bytes()
}

///|
/// `begin` opens the transaction and writes the framed BEGIN message.
test {
  let mock = MockTransport::new()
  mock.feed(b"\x00\x00\x01\x05") // handshake
  mock.feed(tx_server_success([])) // HELLO
  mock.feed(tx_server_success([])) // BEGIN

  let conn = BoltConnection::new(mock)
  let _ = conn.handshake([bolt_version(5, 1, 0)])
  let _ = conn.authenticate([("scheme", PackStreamValue::str("none"))])

  let tx = Transaction::new(conn)
  assert_eq(tx.begin(), true)
  assert_eq(tx.is_open(), true)
  assert_eq(conn.conn_state(), Ready)

  assert_eq(
    mock.outgoing(),
    tx_concat([
      handshake_message([bolt_version(5, 1, 0)]),
      frame(hello([("scheme", PackStreamValue::str("none"))])),
      frame(begin([])),
    ]),
  )
}

///|
/// A full transaction round-trips BEGIN -> RUN -> PULL -> COMMIT.
test {
  let mock = MockTransport::new()
  mock.feed(b"\x00\x00\x01\x05")
  mock.feed(tx_server_success([])) // HELLO
  mock.feed(tx_server_success([])) // BEGIN
  mock.feed(
    tx_server_success([
      ("fields", PackStreamValue::list([PackStreamValue::str("id(n)")])),
    ]),
  ) // RUN
  mock.feed(tx_server_record([PackStreamValue::int(1L)])) // PULL record
  mock.feed(tx_server_success([])) // PULL done
  mock.feed(tx_server_success([])) // COMMIT

  let conn = BoltConnection::new(mock)
  let _ = conn.handshake([bolt_version(5, 1, 0)])
  let _ = conn.authenticate([("scheme", PackStreamValue::str("none"))])

  let tx = Transaction::new(conn)
  assert_eq(tx.begin(), true)
  match tx.run("CREATE (n) RETURN id(n)", []) {
    Some(rows) => assert_eq(rows, [[PackStreamValue::int(1L)]])
    None => panic()
  }
  assert_eq(tx.commit(), true)
  assert_eq(tx.is_open(), false)

  assert_eq(
    mock.outgoing(),
    tx_concat([
      handshake_message([bolt_version(5, 1, 0)]),
      frame(hello([("scheme", PackStreamValue::str("none"))])),
      frame(begin([])),
      frame(run("CREATE (n) RETURN id(n)", [], [])),
      frame(pull([("n", PackStreamValue::int(-1L))])),
      frame(commit()),
    ]),
  )
}

///|
/// `rollback` closes the transaction and writes the framed ROLLBACK message.
test {
  let mock = MockTransport::new()
  mock.feed(b"\x00\x00\x01\x05")
  mock.feed(tx_server_success([])) // HELLO
  mock.feed(tx_server_success([])) // BEGIN
  mock.feed(tx_server_success([])) // ROLLBACK

  let conn = BoltConnection::new(mock)
  let _ = conn.handshake([bolt_version(5, 1, 0)])
  let _ = conn.authenticate([("scheme", PackStreamValue::str("none"))])

  let tx = Transaction::new(conn)
  assert_eq(tx.begin(), true)
  assert_eq(tx.rollback(), true)
  assert_eq(tx.is_open(), false)

  assert_eq(
    mock.outgoing(),
    tx_concat([
      handshake_message([bolt_version(5, 1, 0)]),
      frame(hello([("scheme", PackStreamValue::str("none"))])),
      frame(begin([])),
      frame(rollback()),
    ]),
  )
}

///|
/// Out-of-order calls are refused: `run`/`commit`/`rollback` before `begin`,
/// and a second `begin` after the first.
test {
  let mock = MockTransport::new()
  mock.feed(b"\x00\x00\x01\x05")
  mock.feed(tx_server_success([])) // HELLO
  mock.feed(tx_server_success([])) // BEGIN

  let conn = BoltConnection::new(mock)
  let _ = conn.handshake([bolt_version(5, 1, 0)])
  let _ = conn.authenticate([("scheme", PackStreamValue::str("none"))])

  let fresh = Transaction::new(BoltConnection::new(MockTransport::new()))
  assert_eq(fresh.run("RETURN 1", []), None)
  assert_eq(fresh.commit(), false)
  assert_eq(fresh.rollback(), false)

  let tx = Transaction::new(conn)
  assert_eq(tx.begin(), true)
  assert_eq(tx.begin(), false) // already open
}

///|
/// A statement the server rejects fails the connection; `commit` then reports
/// `false` (the transaction is closed and must be reset).
test {
  let mock = MockTransport::new()
  mock.feed(b"\x00\x00\x01\x05")
  mock.feed(tx_server_success([])) // HELLO
  mock.feed(tx_server_success([])) // BEGIN
  mock.feed(
    tx_server_failure([
      ("code", PackStreamValue::str("Neo.ClientError.Statement.SyntaxError")),
    ]),
  ) // RUN fails

  let conn = BoltConnection::new(mock)
  let _ = conn.handshake([bolt_version(5, 1, 0)])
  let _ = conn.authenticate([("scheme", PackStreamValue::str("none"))])

  let tx = Transaction::new(conn)
  assert_eq(tx.begin(), true)
  assert_eq(tx.run("NOT VALID CYPHER", []), None)
  assert_eq(conn.conn_state(), Failed)
  assert_eq(tx.commit(), false)
  assert_eq(tx.is_open(), false)
}
