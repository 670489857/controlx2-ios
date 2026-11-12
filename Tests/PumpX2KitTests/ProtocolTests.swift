import XCTest
@testable import PumpX2Kit

final class ProtocolTests: XCTestCase {

    // 向量来自 pumpX2 messages/src/test/java/.../BTResponseParserTest.java
    func testPacketizeCentralChallenge() throws {
        let msg = AuthMessages.centralChallengeRequest(appInstanceId: 0, challenge: [0, 1, 2, 3, 4, 5, 6, 7])
        let packets = try Packetize.encode(msg, txId: 0)
        XCTAssertEqual(packets.count, 1)
        XCTAssertEqual(Hex.encode(packets[0]), "000010000a00000001020304050607361a")
    }

    func testPacketizeWithCapturedChallenge() throws {
        let msg = AuthMessages.centralChallengeRequest(appInstanceId: 0, challenge: try Hex.decode("670b42de65985e97"))
        let packets = try Packetize.encode(msg, txId: 0)
        XCTAssertEqual(Hex.encode(packets[0]), "000010000a0000670b42de65985e97f1ce")
    }

    func testAssembleCapturedResponse() throws {
        let raw = try Hex.decode("000011001e01008c212d7a8fbda85f83a3440254488dfb561264ec840c4e16873046bc2c1a")
        let asm = PacketAssembler()
        let frame = try XCTUnwrap(try asm.ingest(raw))
        XCTAssertEqual(frame.opCode, 0x11)
        XCTAssertEqual(frame.cargo.count, 30)

        let parsed = try AuthMessages.parseCentralChallengeResponse(frame.cargo)
        XCTAssertEqual(parsed.appInstanceId, 1)
        XCTAssertEqual(Hex.encode(parsed.hash), "8c212d7a8fbda85f83a3440254488dfb561264ec")
        XCTAssertEqual(Hex.encode(parsed.hmacKey), "840c4e16873046bc")
    }

    func testCRCChangesWithContent() throws {
        let a = CRC16.checksum([0x10, 0x00, 0x0A])
        let b = CRC16.checksum([0x10, 0x00, 0x0B])
        XCTAssertNotEqual(a, b)
    }

    func testChunkingSplitsLongMessage() throws {
        // 167 字节 cargo 的 JPAKE 报文会切成多片，首片 remaining 最大、末片为 0
        let msg = PumpMessage.request(characteristic: .authorization, opCode: 0x20,
                                      cargo: [UInt8](repeating: 0xAB, count: 165))
        let packets = try Packetize.encode(msg, txId: 7)
        XCTAssertGreaterThan(packets.count, 1)
        XCTAssertEqual(Int(packets[0][0]), packets.count - 1)
        XCTAssertEqual(Int(packets.last![0]), 0)
        XCTAssertTrue(packets.allSatisfy { $0[1] == 7 })
    }

    func testReassemblyRoundTrip() throws {
        let msg = PumpMessage.request(characteristic: .authorization, opCode: 0x20,
                                      cargo: (0..<165).map { UInt8($0 & 0xFF) })
        let packets = try Packetize.encode(msg, txId: 3)
        let asm = PacketAssembler()
        var result: AssembledFrame?
        for p in packets { result = try asm.ingest(p) }
        let frame = try XCTUnwrap(result)
        XCTAssertEqual(frame.opCode, 0x20)
        XCTAssertEqual(frame.cargo, msg.cargo)
        XCTAssertEqual(frame.txId, 3)
    }

    func testCorruptedCRCRejected() throws {
        var bad = try Hex.decode("000010000a0000670b42de65985e97f1ce")
        bad[bad.count - 1] ^= 0xFF
        XCTAssertThrowsError(try PacketAssembler.validate(frame: Array(bad.dropFirst(2))))
    }

    func testSignedMessageHasHmacAndVerifies() throws {
        let key = try Hex.decode("00112233445566778899aabbccddeeff")
        let msg = PumpMessage.request(characteristic: .control, opCode: 0xA2, cargo: [1, 2, 3], signed: true)
        let packets = try Packetize.encode(msg, txId: 9, authKey: key, pumpTimeSinceReset: 0x01020304)
        let asm = PacketAssembler()
        asm.authKey = key
        var frame: AssembledFrame?
        for p in packets { frame = try asm.ingest(p) }
        let f = try XCTUnwrap(frame)
        XCTAssertTrue(f.hmacVerified)
        XCTAssertEqual(f.cargo, [1, 2, 3])
    }

    func testRegistryCoverage() {
        XCTAssertGreaterThan(MessageRegistry.count, 250)
        let e = MessageRegistry.entry(0x10, .authorization)
        XCTAssertEqual(e?.name, "CentralChallengeRequest")
        XCTAssertEqual(MessageRegistry.entry(0x21, .authorization)?.size, 167)
    }
}
