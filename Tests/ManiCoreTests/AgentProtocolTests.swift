import XCTest
@testable import ManiCore

final class AgentProtocolTests: XCTestCase {

    func test_output_roundtrip() {
        let payload = Data("hello \u{1F600}".utf8)
        let frame = AgentProtocol.encode(.output, payload: payload)
        let dec = AgentFrameDecoder()
        dec.append(frame)
        let f = dec.next()
        XCTAssertEqual(f?.type, .output)
        XCTAssertEqual(f?.payload, payload)
        XCTAssertNil(dec.next())
    }

    func test_resize_encodeDecode() {
        let frame = AgentProtocol.resizeFrame(rows: 50, cols: 180)
        let dec = AgentFrameDecoder()
        dec.append(frame)
        let f = dec.next()
        XCTAssertEqual(f?.type, .resize)
        guard let p = f?.payload else { return XCTFail() }
        let r = AgentProtocol.decodeResize(p)
        XCTAssertEqual(r?.rows, 50)
        XCTAssertEqual(r?.cols, 180)
    }

    func test_exit_negativeCode_roundtrips() {
        let frame = AgentProtocol.exitFrame(code: -1)
        let dec = AgentFrameDecoder()
        dec.append(frame)
        let f = dec.next()
        XCTAssertEqual(f?.type, .exit)
        guard let p = f?.payload else { return XCTFail() }
        XCTAssertEqual(AgentProtocol.decodeExit(p), -1)
    }

    func test_streaming_splitAcrossAppends() {
        // Encode two frames, feed bytes one at a time, verify both
        // pop out cleanly.
        let f1 = AgentProtocol.encode(.input, payload: Data("ab".utf8))
        let f2 = AgentProtocol.encode(.terminate, payload: Data())
        let combined = f1 + f2
        let dec = AgentFrameDecoder()
        var popped: [AgentFrameDecoder.Frame] = []
        for byte in combined {
            dec.append(Data([byte]))
            while let f = dec.next() { popped.append(f) }
        }
        XCTAssertEqual(popped.count, 2)
        XCTAssertEqual(popped[0].type, .input)
        XCTAssertEqual(popped[0].payload, Data("ab".utf8))
        XCTAssertEqual(popped[1].type, .terminate)
        XCTAssertTrue(popped[1].payload.isEmpty)
    }
}
