import Foundation

// Wire-format shared helpers for Action and Event JSON encoding.
//
// Every Action / Event encodes to a discriminated union:
//
//   {"kind": "<caseName>", "payload": {<label>: <value>, ...}}
//
// `kind` is the Swift case name verbatim. `payload` is an object whose
// keys are either the case's argument labels (where labeled) or the
// lowercased first letter of the argument's type name (where unlabeled).
// Unlabeled-arg rule example: `case repoCreated(Repo)` → payload key is
// `repo`.
//
// This is the only wire format. ManiCore types are encoded the same way
// when persisted (events.jsonl) and when transmitted (mani-server
// WebSocket protocol per docs/decisions.md and the v0.2 plan), so client
// code in any language sees one schema.

enum WireTop: String, CodingKey {
    case kind
    case payload
}

// Union of every field label that appears in Action / Event payloads.
// Per-case CodingKey enums would be type-safer but produce ~70 tiny
// enums; this single enum keeps the code readable. Typos are caught by
// the round-trip golden tests rather than the type checker.
enum WireKeys: String, CodingKey {
    // Argument labels
    case at
    case autoSelect
    case by
    case cleanup
    case code
    case color
    case command
    case completedAt
    case enabled
    case from
    case id
    case into
    case invocation
    case kind
    case mode
    case name
    case namespace
    case path
    case repoId
    case rootDir
    case sessionId
    case spec
    case to
    case when
    case workspace

    // Type-name-lowercased labels (for unlabeled associated values)
    case availableWorktree
    case cwd
    case externalConvo
    case project
    case repo
    case settings
    case task
    case taskPath
}

// Type-erased Encodable for building heterogeneous payload dicts.
struct AnyEncodable: Encodable {
    private let _encode: (Encoder) throws -> Void
    init<T: Encodable>(_ value: T) {
        self._encode = { encoder in
            var c = encoder.singleValueContainer()
            try c.encode(value)
        }
    }
    func encode(to encoder: Encoder) throws {
        try _encode(encoder)
    }
}

// Encode the {kind, payload} envelope. Callers pass the case's name and
// a [label: AnyEncodable] payload built inline.
func encodeWireEnvelope(
    kind: String,
    payload: [String: AnyEncodable],
    to encoder: Encoder
) throws {
    var c = encoder.container(keyedBy: WireTop.self)
    try c.encode(kind, forKey: .kind)
    try c.encode(payload, forKey: .payload)
}

// Read the discriminator + return a nested payload container keyed by
// WireKeys. Decode call sites read fields out of the returned
// container.
func decodeWireEnvelope(
    from decoder: Decoder
) throws -> (kind: String, payload: KeyedDecodingContainer<WireKeys>) {
    let c = try decoder.container(keyedBy: WireTop.self)
    let kind = try c.decode(String.self, forKey: .kind)
    let payload = try c.nestedContainer(keyedBy: WireKeys.self, forKey: .payload)
    return (kind, payload)
}

// Standard "unknown kind" decode error for use in the default branch
// of Action / Event decode switches. We can't use Swift's exhaustive
// enum-switch checking on a String discriminator, so the default
// branch throws.
func wireUnknownKind(
    _ kind: String,
    type: String
) -> DecodingError {
    DecodingError.dataCorrupted(
        DecodingError.Context(
            codingPath: [],
            debugDescription: "Unknown \(type) wire kind: \(kind)"
        )
    )
}
