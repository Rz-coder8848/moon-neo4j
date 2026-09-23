///|
/// Blackbox integration tests: the public API, exercised the way an external
/// consumer would — through the `@moon-neo4j` surface only. No internal
/// helpers; every value is built and decoded with the exported functions.

///|
/// A framed server SUCCESS carrying `metadata`.
fn success(metadata : Array[(String, @moon-neo4j.PackStreamValue)]) -> Bytes {
  @moon-neo4j.frame(
    @moon-neo4j.PackStreamValue::struct_(@moon-neo4j.SIG_SUCCESS, [
      @moon-neo4j.PackStreamValue::map(metadata),
    ]),
  )
}

///|
/// A framed server RECORD carrying `fields`.
fn record(fields : Array[@moon-neo4j.PackStreamValue]) -> Bytes {
  @moon-neo4j.frame(
    @moon-neo4j.PackStreamValue::struct_(@moon-neo4j.SIG_RECORD, [
      @moon-neo4j.PackStreamValue::list(fields),
    ]),
  )
}

///|
/// A framed server FAILURE carrying `metadata`.
fn failure(metadata : Array[(String, @moon-neo4j.PackStreamValue)]) -> Bytes {
  @moon-neo4j.frame(
    @moon-neo4j.PackStreamValue::struct_(@moon-neo4j.SIG_FAILURE, [
      @moon-neo4j.PackStreamValue::map(metadata),
    ]),
  )
}

///|
/// A value survives a PackStream encode/decode round-trip unchanged.
test "PackStream encode/decode round-trips" {
  let value = @moon-neo4j.PackStreamValue::list([
    @moon-neo4j.PackStreamValue::str("hello"),
    @moon-neo4j.PackStreamValue::int(42L),
    @moon-neo4j.PackStreamValue::bool(true),
    @moon-neo4j.PackStreamValue::null(),
    @moon-neo4j.PackStreamValue::map([
      ("k", @moon-neo4j.PackStreamValue::float(3.5)),
    ]),
  ])
  match @moon-neo4j.packstream_decode(@moon-neo4j.packstream_encode(value)) {
    Some(decoded) => assert_eq(decoded, value)
    None => panic()
  }
}

///|
/// The full Bolt session — handshake, HELLO, a typed query, and its rows — works
/// end to end through the public surface.
test "Bolt session runs a typed query" {
  let mock = @moon-neo4j.MockTransport::new()
  mock.feed(b"\x00\x00\x01\x05") // handshake
  mock.feed(success([])) // HELLO
  mock.feed(
    success([
      (
        "fields",
        @moon-neo4j.PackStreamValue::list([
          @moon-neo4j.PackStreamValue::str("n.name"),
        ]),
      ),
    ]),
  ) // RUN
  mock.feed(record([@moon-neo4j.PackStreamValue::str("Alice")]))
  mock.feed(record([@moon-neo4j.PackStreamValue::str("Bob")]))
  mock.feed(success([])) // PULL done

  let conn = @moon-neo4j.BoltConnection::new(mock)
  let _ = conn.handshake([@moon-neo4j.bolt_version(5, 1, 0)])
  let _ = conn.authenticate([
    ("scheme", @moon-neo4j.PackStreamValue::str("none")),
  ])

  let q = @moon-neo4j.Query::new()
  let name = q.param(@moon-neo4j.PackStreamValue::str("A"))
  q.match_("(n:Person)")
  q.where_("n.name >= " + name)
  q.return_("n.name")
  let (cypher, params) = q.build()

  assert_eq(cypher, "MATCH (n:Person) WHERE n.name >= $p0 RETURN n.name")
  assert_eq(params, [("p0", @moon-neo4j.PackStreamValue::str("A"))])

  match conn.run_query(cypher, params) {
    Some(rows) =>
      assert_eq(rows, [
        [@moon-neo4j.PackStreamValue::str("Alice")],
        [@moon-neo4j.PackStreamValue::str("Bob")],
      ])
    None => panic()
  }
}

///|
/// An explicit transaction — BEGIN, a write, COMMIT — works end to end.
test "explicit transaction commits" {
  let mock = @moon-neo4j.MockTransport::new()
  mock.feed(b"\x00\x00\x01\x05")
  mock.feed(success([])) // HELLO
  mock.feed(success([])) // BEGIN
  mock.feed(
    success([
      (
        "fields",
        @moon-neo4j.PackStreamValue::list([
          @moon-neo4j.PackStreamValue::str("p.name"),
        ]),
      ),
    ]),
  ) // RUN
  mock.feed(record([@moon-neo4j.PackStreamValue::str("Lana")])) // PULL record
  mock.feed(success([])) // PULL done
  mock.feed(success([])) // COMMIT

  let conn = @moon-neo4j.BoltConnection::new(mock)
  let _ = conn.handshake([@moon-neo4j.bolt_version(5, 1, 0)])
  let _ = conn.authenticate([
    ("scheme", @moon-neo4j.PackStreamValue::str("none")),
  ])

  let tx = @moon-neo4j.Transaction::new(conn)
  assert_eq(tx.begin(), true)
  match
    tx.run("CREATE (p:Person {name: $p0}) RETURN p.name", [
      ("p0", @moon-neo4j.PackStreamValue::str("Lana")),
    ]) {
    Some(rows) => assert_eq(rows, [[@moon-neo4j.PackStreamValue::str("Lana")]])
    None => panic()
  }
  assert_eq(tx.commit(), true)
  assert_eq(tx.is_open(), false)
}

///|
/// The HTTP transactional endpoint builds a request and parses a response.
test "HTTP tx endpoint round-trips" {
  let request = @moon-neo4j.build_tx_request([
    @moon-neo4j.Statement::new("CREATE (n {name: $name})", [
      ("name", @moon-neo4j.PackStreamValue::str("Alice")),
    ]),
  ])
  assert_eq(
    request.stringify(),
    "{\"statements\":[{\"statement\":\"CREATE (n {name: $name})\",\"parameters\":{\"name\":\"Alice\"}}]}",
  )

  let response = @json.parse(
    "{\"results\":[{\"columns\":[\"n\"],\"data\":[{\"row\":[1],\"meta\":[null]}]}],\"errors\":[]}",
  ) catch {
    _ => panic()
  }
  match @moon-neo4j.parse_tx_response(response) {
    Some(tx) => {
      assert_eq(tx.results[0].columns, ["n"])
      assert_eq(tx.results[0].rows, [[@moon-neo4j.PackStreamValue::int(1L)]])
      assert_eq(tx.errors, [])
    }
    None => panic()
  }
}

///|
/// A transport failure on the HTTP endpoint surfaces as `None`.
test "HTTP tx commit reports a transport failure" {
  let client = @moon-neo4j.MockHttpClient::new(None)
  assert_eq(
    @moon-neo4j.tx_commit(client, "http://localhost:7474/db/neo4j/tx/commit", [
      @moon-neo4j.Statement::new("RETURN 1", []),
    ]),
    None,
  )
}

///|
/// A statement the server rejects fails the session and returns `None`.
test "server failure fails the query" {
  let mock = @moon-neo4j.MockTransport::new()
  mock.feed(b"\x00\x00\x01\x05")
  mock.feed(success([])) // HELLO
  mock.feed(
    failure([
      (
        "code",
        @moon-neo4j.PackStreamValue::str(
          "Neo.ClientError.Statement.SyntaxError",
        ),
      ),
    ]),
  ) // RUN fails

  let conn = @moon-neo4j.BoltConnection::new(mock)
  let _ = conn.handshake([@moon-neo4j.bolt_version(5, 1, 0)])
  let _ = conn.authenticate([
    ("scheme", @moon-neo4j.PackStreamValue::str("none")),
  ])
  assert_eq(conn.run_query("NOT VALID CYPHER", []), None)
  match conn.conn_state() {
    @moon-neo4j.ConnState::Failed => ()
    _ => panic()
  }
}

///|
/// The movie demo's scripted server returns the expected actors.
test "movie demo returns the actors" {
  let (cypher, params) = @moon-neo4j.actors_query("The Matrix")
  let mock = @moon-neo4j.scripted_actors_server()
  let conn = @moon-neo4j.BoltConnection::new(mock)
  let _ = conn.handshake([@moon-neo4j.bolt_version(5, 1, 0)])
  let _ = conn.authenticate([
    ("scheme", @moon-neo4j.PackStreamValue::str("none")),
  ])
  match conn.run_query(cypher, params) {
    Some(rows) => assert_eq(rows.length(), 3)
    None => panic()
  }
}
