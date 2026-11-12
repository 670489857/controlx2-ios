import XCTest
@testable import PumpX2Kit

final class ArithmeticFuzzTests: XCTestCase {

    func testMontgomeryMulAgainstShiftAdd() {
        var rng = SystemRandomNumberGenerator()
        var failures = 0
        for _ in 0..<200 {
            var ab = [UInt8](); for _ in 0..<32 { ab.append(UInt8.random(in: 0...255, using: &rng)) }
            var bb = [UInt8](); for _ in 0..<32 { bb.append(UInt8.random(in: 0...255, using: &rng)) }
            let a = Modulus.reduce(U256(bytesBE: ab), P256.p)
            let b = Modulus.reduce(U256(bytesBE: bb), P256.p)

            let fast = P256.fmul(a, b)
            var slow = U256.zero
            var acc = a
            for i in 0..<256 {
                if b.bit(i) { slow = Modulus.addMod(slow, acc, P256.p) }
                acc = Modulus.addMod(acc, acc, P256.p)
            }
            if fast != slow {
                failures += 1
                if failures < 3 {
                    print("MISMATCH a=\(a) b=\(b)\n fast=\(fast)\n slow=\(slow)")
                }
            }
        }
        XCTAssertEqual(failures, 0, "Montgomery 乘法与移位加法结果不一致")
    }

    func testScalarMulAgainstShiftAdd() {
        var rng = SystemRandomNumberGenerator()
        var failures = 0
        for _ in 0..<100 {
            var ab = [UInt8](); for _ in 0..<32 { ab.append(UInt8.random(in: 0...255, using: &rng)) }
            var bb = [UInt8](); for _ in 0..<32 { bb.append(UInt8.random(in: 0...255, using: &rng)) }
            let a = P256.scalarReduce(U256(bytesBE: ab))
            let b = P256.scalarReduce(U256(bytesBE: bb))
            let fast = P256.scalarMul(a, b)
            var slow = U256.zero
            var acc = a
            for i in 0..<256 {
                if b.bit(i) { slow = Modulus.addMod(slow, acc, P256.n) }
                acc = Modulus.addMod(acc, acc, P256.n)
            }
            if fast != slow { failures += 1; if failures < 3 { print("SCALAR MISMATCH \(a) * \(b)") } }
        }
        XCTAssertEqual(failures, 0)
    }

    func testPointMultiplicationMapsToCurve() throws {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<20 {
            var kb = [UInt8](); for _ in 0..<32 { kb.append(UInt8.random(in: 0...255, using: &rng)) }
            let k = P256.scalarReduce(U256(bytesBE: kb))
            guard let p = P256.multiply(k, P256.generator) else {
                XCTFail("标量乘返回无穷远点"); return
            }
            XCTAssertTrue(P256.isOnCurve(p))
            // (k)*G 与 (k-1)*G + G 必须相等
            let km1 = P256.scalarSub(k, U256(1))
            if let q = P256.multiply(km1, P256.generator) {
                let sum = P256.toAffine(P256.add(P256.toJacobian(q), P256.generator))
                XCTAssertEqual(sum, p, "k*G 与 (k-1)*G + G 不一致，k=\(k)")
            }
        }
    }
}
