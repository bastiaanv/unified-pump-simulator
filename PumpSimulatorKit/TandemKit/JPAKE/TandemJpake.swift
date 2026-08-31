import Foundation

#if canImport(SwiftECC) && canImport(BigInt)
    /// Splits and reassembles the two 165-byte JPAKE frames the pump exchanges.
    /// Port of TandemKit's `JpakeRound1Framing`.
    enum TandemJpakeRound1Framing {
        static let frameSize = 165

        static func groupLength(in data: Data, at offset: Int) -> Int? {
            var cursor = offset
            for _ in 0 ..< 3 {
                guard cursor < data.count else { return nil }
                let fieldLength = Int(data[data.startIndex + cursor])
                cursor += 1 + fieldLength
                guard cursor <= data.count else { return nil }
            }
            return cursor - offset
        }

        static func padToFrame(_ data: Data) -> Data {
            TandemBytes.pad(data, to: frameSize)
        }

        static func splitRound1(_ round1: Data) -> (first: Data, second: Data)? {
            guard let firstLength = groupLength(in: round1, at: 0),
                  let secondLength = groupLength(in: round1, at: firstLength),
                  firstLength <= frameSize,
                  secondLength <= frameSize
            else {
                return nil
            }
            let start = round1.startIndex
            let first = round1.subdata(in: start ..< start + firstLength)
            let second = round1.subdata(in: start + firstLength ..< start + firstLength + secondLength)
            return (padToFrame(first), padToFrame(second))
        }

        static func joinRound1(first: Data, second: Data) -> Data {
            guard let firstLength = groupLength(in: first, at: 0) else {
                return TandemBytes.combine(first, second)
            }
            let start = first.startIndex
            return TandemBytes.combine(first.subdata(in: start ..< start + firstLength), second)
        }
    }

    /// Pump-side JPAKE responder state machine. Mirrors what a real Mobi's
    /// firmware does when a central runs `JpakeAuthBuilder` against it.
    final class TandemJpake {
        enum Phase {
            case idle
            case round1Pending // awaiting Jpake1bRequest
            case round1Complete // awaiting Jpake2Request
            case round2Complete // awaiting Jpake3SessionKeyRequest
            case round3Complete // awaiting Jpake4KeyConfirmationRequest
            case complete
        }

        private var ecJpake: TandemEcJpake
        private var password: Data
        private var phase: Phase = .idle
        private var round1First: Data?
        private var round1Second: Data?
        private var peerRound1First: Data?
        private var peerRound1Second: Data?

        private(set) var derivedSecret: Data?
        private(set) var serverNonce3: Data?

        /// 8-byte server nonce for round 4, exposed for key-confirmation hashing.
        private var serverNonce4: Data?

        init(pairingCode: String, existingDerivedSecret: Data? = nil) {
            password = TandemJpake.pairingCodeToBytes(pairingCode)
            ecJpake = TandemEcJpake(
                role: .server,
                password: password,
                random: TandemRandom.bytes
            )
            // Reconnecting central that already paired: skip rounds 1-2 and only
            // do the short key-confirmation path (rounds 3+4).
            if let secret = existingDerivedSecret, !secret.isEmpty {
                derivedSecret = secret
                phase = .round2Complete
            }
        }

        var isComplete: Bool {
            if case .complete = phase {
                return true
            }
            return false
        }

        /// Called when the central sends a request on AUTHORIZATION. Returns the
        /// matching response (opcode + cargo) or nil for unexpected/unknown ops.
        func handleRequest(opCode: UInt8, cargo: Data) -> (opCode: UInt8, cargo: Data)? {
            let appInstanceId = cargo.count >= 2 ? TandemBytes.readU16(cargo, 0) : 0

            switch opCode {
            case 32: // Jpake1aRequest — first client round-1 frame
                let round1 = ecJpake.getRound1()
                guard let frames = TandemJpakeRound1Framing.splitRound1(round1)
                else { return nil }
                round1First = frames.first
                round1Second = frames.second
                peerRound1First = frame(cargo)
                phase = .round1Pending
                return (33, TandemBytes.combine(TandemBytes.u16(appInstanceId), round1First!))

            case 34: // Jpake1bRequest — second client round-1 frame
                peerRound1Second = frame(cargo)
                if let first = peerRound1First, let second = peerRound1Second {
                    let full = TandemJpakeRound1Framing.joinRound1(first: first, second: second)
                    ecJpake.readRound1(full)
                }
                phase = .round1Complete
                return (35, TandemBytes.combine(TandemBytes.u16(appInstanceId), round1Second!))

            case 36: // Jpake2Request — client round 2
                guard phase == .round1Complete else { return nil }
                let clientRound2 = frame(cargo)
                ecJpake.readRound2(clientRound2)
                let serverRound2 = ecJpake.getRound2()
                phase = .round2Complete
                return (37, TandemBytes.combine(TandemBytes.u16(appInstanceId), serverRound2))

            case 38: // Jpake3SessionKeyRequest
                guard phase == .round2Complete else { return nil }
                if derivedSecret == nil {
                    derivedSecret = ecJpake.deriveSecret()
                }
                serverNonce3 = TandemJpake.randomBytes(8)
                let reserved = Data(repeating: 0, count: 8)
                let cargo = TandemBytes.combine(
                    TandemBytes.u16(appInstanceId),
                    serverNonce3!,
                    reserved
                )
                phase = .round3Complete
                return (39, cargo)

            case 40: // Jpake4KeyConfirmationRequest
                guard phase == .round3Complete,
                      let derivedSecret = derivedSecret,
                      let serverNonce3 = serverNonce3,
                      cargo.count >= 18
                else { return nil }

                // Verify the client's hashDigest.
                let clientNonce = cargo.subdata(in: 2 ..< 10)
                let clientDigest = cargo.subdata(in: 18 ..< cargo.count)
                let key = TandemHkdf.build(nonce: serverNonce3, keyMaterial: derivedSecret)
                let expected = TandemHmac.hmacSha256(data: clientNonce, key: key)

                // Even on failure we reply (the central reports the mismatch), but
                // only a verified digest advances us to `complete`.
                serverNonce4 = TandemJpake.randomBytes(8)
                let reserved = Data(repeating: 0, count: 8)
                let serverDigest = TandemHmac.hmacSha256(data: serverNonce4!, key: key)
                let response = TandemBytes.combine(
                    TandemBytes.u16(appInstanceId),
                    serverNonce4!,
                    reserved,
                    serverDigest
                )
                if clientDigest == expected {
                    phase = .complete
                }
                return (41, response)

            default:
                return nil
            }
        }

        func reset() {
            phase = .idle
            round1First = nil
            round1Second = nil
            peerRound1First = nil
            peerRound1Second = nil
            derivedSecret = nil
            serverNonce3 = nil
            serverNonce4 = nil
            ecJpake = TandemEcJpake(
                role: .server,
                password: password,
                random: TandemRandom.bytes
            )
            if let secret = derivedSecret, !secret.isEmpty {
                phase = .round2Complete
            }
        }

        private func frame(_ cargo: Data) -> Data {
            if cargo.count >= 2 + TandemJpakeRound1Framing.frameSize {
                return cargo.subdata(in: 2 ..< 2 + TandemJpakeRound1Framing.frameSize)
            }
            return Data()
        }

        /// Legacy 16-char pairing code byte encoding (`0`-`9` → 0x30..0x39).
        static func pairingCodeToBytes(_ code: String) -> Data {
            var bytes = Data()
            for char in code {
                if let ascii = char.asciiValue, (0x30 ... 0x39).contains(ascii) {
                    bytes.append(ascii)
                }
            }
            return bytes
        }

        static func randomBytes(_ count: Int) -> Data {
            var data = Data(count: count)
            let result = data.withUnsafeMutableBytes { ptr -> Int32 in
                SecRandomCopyBytes(kSecRandomDefault, count, ptr.baseAddress!)
            }
            guard result == errSecSuccess else {
                return Data((0 ..< count).map { _ in UInt8.random(in: .min ... .max) })
            }
            return data
        }
    }

#else
    /// SwiftECC unavailable — pairing over JPAKE cannot be performed. The manager
    /// degrades (logs an error) rather than crashing the whole simulator.
    final class TandemJpake {
        enum Phase { case idle, complete }
        private(set) var derivedSecret: Data?
        private(set) var serverNonce3: Data?
        var isComplete: Bool {
            false
        }

        init(pairingCode _: String, existingDerivedSecret _: Data? = nil) {}
        func handleRequest(opCode _: UInt8, cargo _: Data) -> (opCode: UInt8, cargo: Data)? {
            nil
        }

        func reset() {}
    }
#endif
