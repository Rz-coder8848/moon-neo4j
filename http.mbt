///|
/// The Neo4j HTTP transactional endpoint (`/db/{database}/tx`), an alternative
/// to Bolt for running Cypher over plain HTTP.
///
/// A request `POST`s a JSON body of the shape
/// `{"statements": [{"statement": "...", "parameters": {...}}]}` and the server
/// replies with `{"results": [{"columns": [...], "data": [{"row": [...], ...}]}],
/// "errors": [...]}`. This module builds the request and parses the response,
/// reusing [`PackStreamValue`] as the shared value model across both transports.
///
/// The actual HTTP `POST` is delegated to an [`HttpClient`]; MoonBit's core
/// library does not ship a socket/HTTP client as of this release, so a concrete
/// HTTP client is left to the target platform (需查官方文档 for the backend's
/// networking API). Everything here is testable against an in-memory client.

///|
/// A single statement in a transactional request.
pub struct Statement {
  statement : String
  parameters : Array[(String, PackStreamValue)]
} derive(Eq, @debug.Debug)

///|
pub fn Statement::new(
  statement : String,
  parameters : Array[(String, PackStreamValue)],
) -> Statement {
  { statement, parameters, }
}

///|
/// One result set returned by the server.
pub struct ResultSet {
  columns : Array[String]
  rows : Array[Array[PackStreamValue]]
} derive(Eq, @debug.Debug)

///|
/// An error reported by the server.
pub struct TxError {
  code : String
  message : String
} derive(Eq, @debug.Debug)

///|
/// The parsed response of a transactional request.
pub struct TxResponse {
  results : Array[ResultSet]
  errors : Array[TxError]
} derive(Eq, @debug.Debug)

///|
/// A minimal HTTP client used by the transactional endpoint.
pub trait HttpClient {
  ///| POST a JSON body to `url` and return the parsed JSON response, or `None`
  ///| on a transport failure.
  fn post_json(Self, String, Json) -> Json?
}

///|
/// An in-memory [`HttpClient`] for tests. The response is fixed up front and
/// the request body is captured for inspection.
pub struct MockHttpClient {
  response : Json?
  mut last_body : Json?
}

///|
pub fn MockHttpClient::new(response : Json?) -> MockHttpClient {
  { response, last_body: None, }
}

///|
/// The body of the most recent `POST`.
pub fn MockHttpClient::last_body(self : MockHttpClient) -> Json? {
  self.last_body
}

///|
pub impl HttpClient for MockHttpClient with fn post_json(self, _url, body) {
  self.last_body = Some(body)
  self.response
}

///|
/// Commit a batch of statements and parse the response. Returns `None` on a
/// transport failure or a malformed response.
pub fn[T : HttpClient] tx_commit(
  client : T,
  url : String,
  statements : Array[Statement],
) -> TxResponse? {
  let request = build_tx_request(statements)
  match client.post_json(url, request) {
    None => None
    Some(response) => parse_tx_response(response)
  }
}

///|
/// Build the JSON request body for a list of statements.
pub fn build_tx_request(statements : Array[Statement]) -> Json {
  let stmts = []
  for s in statements {
    stmts.push(statement_to_json(s))
  }
  let root = @builtin.Map([])
  root["statements"] = Json::array(stmts)
  Json::object(root)
}

///|
/// Parse a transactional response body into a [`TxResponse`], or `None` when
/// the JSON does not have the expected shape.
pub fn parse_tx_response(json : Json) -> TxResponse? {
  match json {
    Object(obj) => {
      let results = match obj.get("results") {
        Some(Array(rs)) =>
          match parse_result_sets(rs) {
            Some(sets) => sets
            None => return None
          }
        _ => return None
      }
      let errors = match obj.get("errors") {
        Some(Array(errs)) => parse_errors(errs)
        None => []
        _ => return None
      }
      Some({ results, errors, })
    }
    _ => None
  }
}

///|
/// Convert a PackStream value to its JSON representation. Structs and bytes
/// have no JSON-native form and map to `null`; use Bolt for those.
pub fn value_to_json(value : PackStreamValue) -> Json {
  match value {
    Null => Json::null()
    Bool(b) => Json::boolean(b)
    Int(i) => Json::number(i.to_double(), repr=i.to_string())
    Float(f) => Json::number(f)
    Str(s) => Json::string(s)
    List(items) => {
      let arr = []
      for item in items {
        arr.push(value_to_json(item))
      }
      Json::array(arr)
    }
    Map(entries) => {
      let obj = @builtin.Map([])
      for (k, v) in entries {
        obj[k] = value_to_json(v)
      }
      Json::object(obj)
    }
    Struct(_, _) => Json::null()
    Bytes(_) => Json::null()
  }
}

///|
/// Convert a JSON value to its PackStream representation. JSON objects map to
/// PackStream maps (nodes/relationships are not distinguished here).
pub fn value_from_json(json : Json) -> PackStreamValue {
  match json {
    Null => PackStreamValue::null()
    True => PackStreamValue::bool(true)
    False => PackStreamValue::bool(false)
    Number(n, ..) => number_value(n)
    String(s) => PackStreamValue::str(s)
    Array(items) => {
      let out = []
      for item in items {
        out.push(value_from_json(item))
      }
      PackStreamValue::list(out)
    }
    Object(obj) => {
      let out = []
      for (k, v) in obj.to_array() {
        out.push((k, value_from_json(v)))
      }
      PackStreamValue::map(out)
    }
  }
}

///|
/// Map a JSON number to a PackStream integer when it is a whole number within
/// the 53-bit safe-integer range, else a float.
fn number_value(d : Double) -> PackStreamValue {
  if d == d.floor() && d >= -9007199254740992.0 && d <= 9007199254740992.0 {
    PackStreamValue::int(d.to_int64())
  } else {
    PackStreamValue::float(d)
  }
}

///|
fn statement_to_json(s : Statement) -> Json {
  let obj = @builtin.Map([])
  obj["statement"] = Json::string(s.statement)
  obj["parameters"] = parameters_to_json(s.parameters)
  Json::object(obj)
}

///|
fn parameters_to_json(params : Array[(String, PackStreamValue)]) -> Json {
  let obj = @builtin.Map([])
  for (k, v) in params {
    obj[k] = value_to_json(v)
  }
  Json::object(obj)
}

///|
fn parse_result_sets(rs : Array[Json]) -> Array[ResultSet]? {
  let out = []
  for r in rs {
    match parse_result_set(r) {
      Some(set) => out.push(set)
      None => return None
    }
  }
  Some(out)
}

///|
fn parse_result_set(json : Json) -> ResultSet? {
  match json {
    Object(obj) => {
      let columns = match obj.get("columns") {
        Some(Array(cols)) =>
          match parse_strings(cols) {
            Some(names) => names
            None => return None
          }
        _ => return None
      }
      let rows = match obj.get("data") {
        Some(Array(data)) =>
          match parse_rows(data) {
            Some(rows) => rows
            None => return None
          }
        _ => return None
      }
      Some({ columns, rows, })
    }
    _ => None
  }
}

///|
fn parse_strings(arr : Array[Json]) -> Array[String]? {
  let out = []
  for s in arr {
    match s {
      String(str) => out.push(str)
      _ => return None
    }
  }
  Some(out)
}

///|
fn parse_rows(data : Array[Json]) -> Array[Array[PackStreamValue]]? {
  let out = []
  for row_obj in data {
    match row_obj {
      Object(o) =>
        match o.get("row") {
          Some(Array(cells)) => {
            let row = []
            for cell in cells {
              row.push(value_from_json(cell))
            }
            out.push(row)
          }
          _ => return None
        }
      _ => return None
    }
  }
  Some(out)
}

///|
fn parse_errors(errs : Array[Json]) -> Array[TxError] {
  let out = []
  for e in errs {
    match e {
      Object(o) => {
        let code = match o.get("code") {
          Some(String(s)) => s
          _ => ""
        }
        let message = match o.get("message") {
          Some(String(s)) => s
          _ => ""
        }
        out.push({ code, message, })
      }
      _ => ()
    }
  }
  out
}
