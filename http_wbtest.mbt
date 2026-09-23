///|
/// Whitebox tests for the HTTP transactional endpoint codec.

///|
/// Parse a JSON string, panicking on a malformed literal (test-only helper).
fn json_of(text : String) -> Json {
  @json.parse(text) catch {
    _ => panic()
  }
}

///|
/// `build_tx_request` produces the expected request body.
test {
  let req = build_tx_request([Statement::new("RETURN 1", [])])
  assert_eq(
    req,
    json_of("{\"statements\":[{\"statement\":\"RETURN 1\",\"parameters\":{}}]}"),
  )
}

///|
/// Parameters of every scalar/collection kind are serialized.
test {
  let req = build_tx_request([
    Statement::new("CREATE (n {name: $name, age: $age})", [
      ("name", PackStreamValue::str("Alice")),
      ("age", PackStreamValue::int(42L)),
      ("active", PackStreamValue::bool(true)),
      (
        "tags",
        PackStreamValue::list([
          PackStreamValue::str("a"),
          PackStreamValue::str("b"),
        ]),
      ),
    ]),
  ])
  assert_eq(
    req,
    json_of(
      "{\"statements\":[{\"statement\":\"CREATE (n {name: $name, age: $age})\",\"parameters\":{\"name\":\"Alice\",\"age\":42,\"active\":true,\"tags\":[\"a\",\"b\"]}}]}",
    ),
  )
}

///|
/// PackStream -> JSON: integers keep their integer form, collections nest.
test {
  assert_eq(value_to_json(PackStreamValue::int(42L)).stringify(), "42")
  assert_eq(value_to_json(PackStreamValue::bool(true)).stringify(), "true")
  assert_eq(value_to_json(PackStreamValue::null()).stringify(), "null")
  assert_eq(value_to_json(PackStreamValue::str("hi")).stringify(), "\"hi\"")
  assert_eq(
    value_to_json(
      PackStreamValue::list([PackStreamValue::int(1L), PackStreamValue::int(2L)]),
    ).stringify(),
    "[1,2]",
  )
  assert_eq(
    value_to_json(PackStreamValue::map([("a", PackStreamValue::int(1L))])).stringify(),
    "{\"a\":1}",
  )
}

///|
/// JSON -> PackStream: whole numbers become integers, objects become maps.
test {
  assert_eq(value_from_json(json_of("42")), PackStreamValue::int(42L))
  assert_eq(value_from_json(json_of("2.5")), PackStreamValue::float(2.5))
  assert_eq(value_from_json(json_of("true")), PackStreamValue::bool(true))
  assert_eq(value_from_json(json_of("null")), PackStreamValue::null())
  assert_eq(value_from_json(json_of("\"hi\"")), PackStreamValue::str("hi"))
  assert_eq(
    value_from_json(json_of("[1,\"a\"]")),
    PackStreamValue::list([PackStreamValue::int(1L), PackStreamValue::str("a")]),
  )
  assert_eq(
    value_from_json(json_of("{\"x\":1}")),
    PackStreamValue::map([("x", PackStreamValue::int(1L))]),
  )
}

///|
/// `parse_tx_response` decodes columns and rows into typed results.
test {
  let resp = json_of(
    "{\"results\":[{\"columns\":[\"name\",\"age\"],\"data\":[{\"row\":[\"Alice\",42],\"meta\":[null,null]},{\"row\":[\"Bob\",30],\"meta\":[null,null]}]}],\"errors\":[]}",
  )
  match parse_tx_response(resp) {
    Some(tx) => {
      assert_eq(tx.results.length(), 1)
      assert_eq(tx.results[0].columns, ["name", "age"])
      assert_eq(tx.results[0].rows.length(), 2)
      assert_eq(tx.results[0].rows[0], [
        PackStreamValue::str("Alice"),
        PackStreamValue::int(42L),
      ])
      assert_eq(tx.results[0].rows[1], [
        PackStreamValue::str("Bob"),
        PackStreamValue::int(30L),
      ])
      assert_eq(tx.errors, [])
    }
    None => panic()
  }
}

///|
/// Errors are decoded alongside empty results.
test {
  let resp = json_of(
    "{\"results\":[],\"errors\":[{\"code\":\"Neo.ClientError.Statement.SyntaxError\",\"message\":\"Invalid input\"}]}",
  )
  match parse_tx_response(resp) {
    Some(tx) => {
      assert_eq(tx.results, [])
      assert_eq(tx.errors.length(), 1)
      assert_eq(tx.errors[0].code, "Neo.ClientError.Statement.SyntaxError")
      assert_eq(tx.errors[0].message, "Invalid input")
    }
    None => panic()
  }
}

///|
/// Malformed responses are rejected.
test {
  assert_eq(parse_tx_response(Json::null()), None)
  assert_eq(parse_tx_response(json_of("{}")), None) // missing "results"
  assert_eq(parse_tx_response(json_of("{\"results\":\"nope\"}")), None) // wrong type
}

///|
/// `tx_commit` builds the request, posts it, and parses the response.
test {
  let response = json_of(
    "{\"results\":[{\"columns\":[\"n\"],\"data\":[{\"row\":[1],\"meta\":[null]}]}],\"errors\":[]}",
  )
  let client = MockHttpClient::new(Some(response))
  match
    tx_commit(client, "http://localhost:7474/db/neo4j/tx/commit", [
      Statement::new("RETURN 1", []),
    ]) {
    Some(tx) => {
      assert_eq(tx.results[0].rows[0], [PackStreamValue::int(1L)])
      match client.last_body() {
        Some(body) =>
          assert_eq(
            body,
            json_of(
              "{\"statements\":[{\"statement\":\"RETURN 1\",\"parameters\":{}}]}",
            ),
          )
        None => panic()
      }
    }
    None => panic()
  }
}

///|
/// A transport failure surfaces as `None`.
test {
  let client = MockHttpClient::new(None)
  assert_eq(
    tx_commit(client, "http://localhost:7474/db/neo4j/tx/commit", [
      Statement::new("RETURN 1", []),
    ]),
    None,
  )
}
