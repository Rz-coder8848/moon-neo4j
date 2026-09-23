# moon-neo4j

[![CI](https://github.com/Rz-coder8848/moon-neo4j/actions/workflows/ci.yml/badge.svg)](https://github.com/Rz-coder8848/moon-neo4j/actions)
[![mooncakes.io](https://img.shields.io/badge/mooncakes.io-Rz--coder8848%2Fmoon--neo4j-8A2BE2)](https://mooncakes.io/packages/Rz-coder8848/moon-neo4j)

A pure-MoonBit [Neo4j](https://neo4j.com) client: a
[Bolt](https://neo4j.com/docs/bolt/current/) protocol implementation, the
[PackStream](https://neo4j.com/docs/bolt/current/packstream/) serialization
codec, an HTTP transactional-endpoint client, and a typed Cypher query builder —
written from scratch in MoonBit with zero runtime dependencies.

## Install

```sh
moon add Rz-coder8848/moon-neo4j
```

Then import the package (the alias is the last path segment):

```moonbit
import { "Rz-coder8848/moon-neo4j" @lib }
```

## What's inside

| Layer | What it does | Entry points |
| --- | --- | --- |
| PackStream codec | value model + binary encoder/decoder | `PackStreamValue`, `packstream_encode`, `packstream_decode` |
| Bolt transport | byte pipe abstraction + in-memory mock | `Transport`, `MockTransport` |
| Bolt handshake | magic `0x6060B017` + version negotiation | `bolt_version`, `handshake_message`, `parse_handshake_response` |
| Bolt messages | message signatures, builders, parser, chunked framing | `hello`, `run`, `begin`, `commit`, `rollback`, `pull`, `frame`, `unframe`, `parse_message` |
| Session | connection state machine | `BoltConnection`, `ConnState` |
| Transactions | explicit BEGIN / COMMIT / ROLLBACK | `Transaction` |
| Cypher builder | typed, injection-safe query construction | `Query` |
| HTTP endpoint | `/db/{database}/tx` request/response codec | `build_tx_request`, `parse_tx_response`, `tx_commit`, `value_to_json`, `value_from_json` |
| Demo | runnable *Matrix* movie-graph demo | `demo_actors`, `demo_add_person` |

## Quick start

### Typed Cypher builder (pure — no connection)

```moonbit
let q = @lib.Query::new()
let title = q.param(PackStreamValue::str("The Matrix"))
q.match_("(p:Person)-[:ACTED_IN]->(m:Movie)")
q.where_("m.title = " + title)
q.return_("p.name")
q.order_by("p.name")
let (cypher, params) = q.build()
// cypher == "MATCH (p:Person)-[:ACTED_IN]->(m:Movie) WHERE m.title = $p0 RETURN p.name ORDER BY p.name"
// params == [("p0", PackStreamValue::str("The Matrix"))]
```

Runtime values enter only through `Query::param`, which stores them out-of-band
under a generated `$pN` name — Cypher injection is impossible by construction.

### Bolt session

```moonbit
let conn = BoltConnection::new(transport)   // transport : Transport
let _ = conn.handshake([bolt_version(5, 1, 0)])
let _ = conn.authenticate([("user_agent", PackStreamValue::str("my-app/1.0"))])
let (cypher, params) = q.build()
match conn.run_query(cypher, params) {
  Some(rows) => println("rows: \{rows.length()}")
  None => println("query failed")
}
```

### Explicit transaction

```moonbit
let tx = Transaction::new(conn)
if tx.begin() {
  let _ = tx.run("CREATE (n:Person {name: \$p0})", [("p0", PackStreamValue::str("Lana"))])
  let _ = tx.commit()
}
```

### HTTP transactional endpoint

```moonbit
let resp = tx_commit(
  client,                                    // client : HttpClient
  "http://localhost:7474/db/neo4j/tx/commit",
  [Statement::new("RETURN 1", [])],
)
```

### Demo CLI

The package ships a runnable *Matrix* demo:

```sh
moon run cmd/main            # query actors of "The Matrix", then add a person in a transaction
moon run cmd/main add Lana   # run only the "add a person" demo
```

## Status: the transport boundary

The entire protocol layer — PackStream codec, Bolt message state machine, typed
Cypher builder, transactions, and the HTTP endpoint codec — is implemented and
fully tested **without any network access**. Every Bolt byte is exercised
against an in-memory [`MockTransport`], and the HTTP endpoint against an
in-memory [`HttpClient`].

MoonBit's core library does not yet ship a socket or HTTP client, so the concrete
networking backend lives behind the [`Transport`] and [`HttpClient`] traits and is
target-platform-specific (需查官方文档). Drop in a TCP-backed `Transport` (or a
`fetch`-backed `HttpClient` on wasm) and the rest of the stack works unchanged.

## Testing

83 tests pass with zero warnings:

```sh
moon check   # type-checks clean
moon test    # 83 whitebox + blackbox tests
moon fmt     # formats the code
```

The whitebox tests (`*_wbtest.mbt`) cover every PackStream marker and every
state-machine transition; the blackbox tests (`*_test.mbt`) drive the public API
the way an external consumer would.

## Project layout

```
.
├── packstream.mbt      # PackStream value model + codec
├── stream.mbt          # streaming reader/writer
├── message.mbt         # Bolt message codec + chunked framing
├── handshake.mbt       # Bolt handshake (magic + version negotiation)
├── transport.mbt       # Transport trait + MockTransport
├── session.mbt         # BoltConnection state machine
├── transaction.mbt     # explicit transactions
├── cypher.mbt          # typed Cypher query builder
├── http.mbt            # HTTP transactional endpoint codec
├── demo.mbt            # Matrix movie-graph demo
├── cmd/main/           # demo CLI (executable package)
└── moon.mod / moon.pkg
```

## Attribution

This project is an independent reimplementation of the Neo4j Bolt and PackStream
wire protocols; it is not a copy of any existing driver. Its design is informed
by the public Neo4j protocol specifications and these reference drivers:

- [neo4j-go-driver](https://github.com/neo4j/neo4j-go-driver) — Apache-2.0
- [neo4j-javascript-driver](https://github.com/neo4j/neo4j-javascript-driver) — Apache-2.0

## License

[Apache-2.0](LICENSE)
