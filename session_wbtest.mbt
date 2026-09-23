///|
/// Whitebox tests for the Bolt session state machine.

///|
/// A framed server SUCCESS carrying `metadata`.
fn server_success(metadata : Array[(String, PackStreamValue)]) -> Bytes {
  frame(PackStreamValue::struct_(SIG_SUCCESS, [PackStreamValue::map(metadata)]))
}

///|
/// A framed server RECORD carrying `fields`.
fn server_record(fields : Array[PackStreamValue]) -> Bytes {
  frame(PackStreamValue::struct_(SIG_RECORD, [PackStreamValue::list(fields)]))
}

///|
/// A framed server FAILURE carrying `metadata`.
fn server_failure(metadata : Array[(String, PackStreamValue)]) -> Bytes {
  frame(PackStreamValue::struct_(SIG_FAILURE, [PackStreamValue::map(metadata)]))
}

///|
/// The handshake succeeds and moves the session to Connected, writing the
/// 20-byte handshake message.
test {
  let mock = MockTransport::new()
  mock.feed(b"\x00\x00\x01\x05") // server agrees on Bolt 5.1
  let conn = BoltConnection::new(mock)
  assert_eq(
    conn.handshake([bolt_version(5, 1, 0)]),
    Some(bolt_version(5, 1, 0)),
  )
  assert_eq(conn.conn_state(), Connected)
  assert_eq(mock.outgoing(), handshake_message([bolt_version(5, 1, 0)]))
}

///|
/// A handshake the server rejects (0x00000000) fails the session.
test {
  let mock = MockTransport::new()
  mock.feed(b"\x00\x00\x00\x00")
  let conn = BoltConnection::new(mock)
  assert_eq(conn.handshake([bolt_version(5, 1, 0)]), None)
  assert_eq(conn.conn_state(), Failed)
}

///|
/// A handshake with a dropped connection (no response) fails the session.
test {
  let conn = BoltConnection::new(MockTransport::new())
  assert_eq(conn.handshake([bolt_version(5, 1, 0)]), None)
  assert_eq(conn.conn_state(), Failed)
}

///|
/// HELLO moves Connected -> Ready on success, and writes the framed HELLO.
test {
  let mock = MockTransport::new()
  mock.feed(b"\x00\x00\x01\x05")
  mock.feed(server_success([]))
  let conn = BoltConnection::new(mock)
  let _ = conn.handshake([bolt_version(5, 1, 0)])
  let metadata = [("user_agent", PackStreamValue::str("moon-neo4j/0.1"))]
  match conn.authenticate(metadata) {
    Some(ServerMessage::Success(_)) => ()
    _ => panic()
  }
  assert_eq(conn.conn_state(), Ready)
  // Outgoing = handshake message + framed HELLO.
  let handshake = handshake_message([bolt_version(5, 1, 0)])
  let hello = frame(hello(metadata))
  let expected = {
    let b = Buffer::Buffer()
    b.write_bytes(handshake.exact_view())
    b.write_bytes(hello.exact_view())
    b.to_bytes()
  }
  assert_eq(mock.outgoing(), expected)
}

///|
/// HELLO failure moves the session to Failed.
test {
  let mock = MockTransport::new()
  mock.feed(b"\x00\x00\x01\x05")
  mock.feed(
    server_failure([
      ("code", PackStreamValue::str("Neo.ClientError.Security.Unauthorized")),
    ]),
  )
  let conn = BoltConnection::new(mock)
  let _ = conn.handshake([bolt_version(5, 1, 0)])
  match conn.authenticate([("scheme", PackStreamValue::str("basic"))]) {
    Some(ServerMessage::Failure(meta)) =>
      assert_eq(meta, [
        ("code", PackStreamValue::str("Neo.ClientError.Security.Unauthorized")),
      ])
    _ => panic()
  }
  assert_eq(conn.conn_state(), Failed)
}

///|
/// A full query round-trip: RUN -> PULL -> RECORDs -> final SUCCESS.
test {
  let mock = MockTransport::new()
  mock.feed(b"\x00\x00\x01\x05")
  mock.feed(server_success([])) // HELLO
  mock.feed(
    server_success([
      ("fields", PackStreamValue::list([PackStreamValue::str("name")])),
    ]),
  ) // RUN
  mock.feed(
    server_record([PackStreamValue::str("Alice"), PackStreamValue::int(42L)]),
  )
  mock.feed(
    server_record([PackStreamValue::str("Bob"), PackStreamValue::int(30L)]),
  )
  mock.feed(server_success([])) // final PULL success

  let conn = BoltConnection::new(mock)
  let _ = conn.handshake([bolt_version(5, 1, 0)])
  let _ = conn.authenticate([("scheme", PackStreamValue::str("none"))])

  let rows = conn.run_query("MATCH (n) RETURN n.name, n.age", [])
  match rows {
    Some(records) => {
      assert_eq(records.length(), 2)
      assert_eq(records[0], [
        PackStreamValue::str("Alice"),
        PackStreamValue::int(42L),
      ])
      assert_eq(records[1], [
        PackStreamValue::str("Bob"),
        PackStreamValue::int(30L),
      ])
    }
    None => panic()
  }
  assert_eq(conn.conn_state(), Ready)
}

///|
/// A RUN that the server rejects moves the session to Failed.
test {
  let mock = MockTransport::new()
  mock.feed(b"\x00\x00\x01\x05")
  mock.feed(server_success([]))
  mock.feed(
    server_failure([
      ("code", PackStreamValue::str("Neo.ClientError.Statement.SyntaxError")),
    ]),
  )

  let conn = BoltConnection::new(mock)
  let _ = conn.handshake([bolt_version(5, 1, 0)])
  let _ = conn.authenticate([("scheme", PackStreamValue::str("none"))])
  assert_eq(conn.run_query("NOT VALID CYPHER", []), None)
  assert_eq(conn.conn_state(), Failed)
}

///|
/// RESET recovers a failed session back to Ready.
test {
  let mock = MockTransport::new()
  mock.feed(b"\x00\x00\x01\x05")
  mock.feed(server_success([]))
  mock.feed(
    server_failure([
      ("code", PackStreamValue::str("Neo.ClientError.Statement.SyntaxError")),
    ]),
  )
  mock.feed(server_success([])) // RESET success

  let conn = BoltConnection::new(mock)
  let _ = conn.handshake([bolt_version(5, 1, 0)])
  let _ = conn.authenticate([("scheme", PackStreamValue::str("none"))])
  assert_eq(conn.run_query("NOT VALID", []), None)
  assert_eq(conn.conn_state(), Failed)
  match conn.reset_conn() {
    Some(ServerMessage::Success(_)) => ()
    _ => panic()
  }
  assert_eq(conn.conn_state(), Ready)
}

///|
/// Methods enforce the lifecycle: the wrong call at the wrong state returns None.
test {
  let conn = BoltConnection::new(MockTransport::new())
  // Cannot HELLO before handshake.
  assert_eq(conn.authenticate([]), None)
  // Cannot RUN before HELLO.
  assert_eq(conn.start_run("RETURN 1", [], []), None)
  // Cannot PULL before RUN.
  assert_eq(conn.pull_next([]), None)
  assert_eq(conn.conn_state(), Disconnected)
}

///|
/// `close` sends GOODBYE and closes the transport.
test {
  let mock = MockTransport::new()
  mock.feed(b"\x00\x00\x01\x05")
  let conn = BoltConnection::new(mock)
  let _ = conn.handshake([bolt_version(5, 1, 0)])
  conn.close()
  assert_eq(conn.conn_state(), Closed)
  assert_eq(mock.is_closed(), true)
  // Outgoing ends with the framed GOODBYE.
  let handshake = handshake_message([bolt_version(5, 1, 0)])
  let goodbye = frame(goodbye())
  let expected = {
    let b = Buffer::Buffer()
    b.write_bytes(handshake.exact_view())
    b.write_bytes(goodbye.exact_view())
    b.to_bytes()
  }
  assert_eq(mock.outgoing(), expected)
}
