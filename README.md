# moon-neo4j

[![CI](https://github.com/Rz-coder8848/moon-neo4j/actions/workflows/ci.yml/badge.svg)](https://github.com/Rz-coder8848/moon-neo4j/actions)
[![mooncakes.io](https://img.shields.io/badge/mooncakes.io-Rz--coder8848%2Fmoon--neo4j-8A2BE2)](https://mooncakes.io/packages/Rz-coder8848/moon-neo4j)

A pure-MoonBit [Neo4j](https://neo4j.com) client: a
[Bolt](https://neo4j.com/docs/bolt/current/) protocol implementation, the
[PackStream](https://neo4j.com/docs/bolt/current/packstream/) serialization
codec, an HTTP transactional-endpoint client, and a typed Cypher query builder.

> **Status:** early development. The pure protocol layer (PackStream codec,
> Bolt message state machine, typed Cypher builder) is implemented and fully
> unit-tested without any network access; the socket transport is being added
> incrementally.

## Install

```sh
moon add Rz-coder8848/moon-neo4j
```

## Quick start

```moonbit
// Typed Cypher builder (pure — no connection needed).
let q = cypher::match_(Node::new("p", "Person"))
  .relationship_to(Node::new("m", "Movie"), "ACTED_IN")
  .where_(m.prop("title").eq("The Matrix"))
  .return_(m)
  .limit(5)
  .build()
```

See [`examples/`](examples) for runnable demos.

## Features

- PackStream value model + codec
  (`Null` / `Bool` / `Int` / `Float` / `String` / `List` / `Map` / `Struct` / `Bytes`)
- Bolt handshake (magic `0x6060B017` + version negotiation) and message state
  machine (`HELLO` / `RUN` / `PULL` / `RESET` / `SUCCESS` / `FAILURE` / `RECORD`)
- HTTP transactional endpoint client (`POST /db/neo4j/tx/commit`)
- Typed Cypher query builder (`Node` / `Relationship` / `WHERE` / `RETURN` / `LIMIT`)
- Transactions (begin / commit / rollback)

## Attribution

This project is an independent reimplementation of the Neo4j Bolt and PackStream
wire protocols; it is not a copy of any existing driver. Its design is informed
by the public Neo4j protocol specifications and these reference drivers:

- [neo4j-go-driver](https://github.com/neo4j/neo4j-go-driver) — Apache-2.0
- [neo4j-javascript-driver](https://github.com/neo4j/neo4j-javascript-driver) — Apache-2.0

## License

[Apache-2.0](LICENSE)
