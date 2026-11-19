import Foundation
import CommonCrypto

enum BackupError: LocalizedError {
    case wrongPassword
    case invalid(String)
    case missingFile(String)

    var errorDescription: String? {
        switch self {
        case .wrongPassword: return "The password is incorrect."
        case .invalid(let reason): return "This backup can't be read: \(reason)"
        case .missingFile(let name): return "File not found in backup: \(name)"
        }
    }
}

enum Crypto {
    static func pbkdf2(_ password: Data, salt: Data, rounds: Int, sha256: Bool) -> Data {
        var out = [UInt8](repeating: 0, count: 32)
        password.withUnsafeBytes { p in
            salt.withUnsafeBytes { s in
                _ = CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    p.bindMemory(to: Int8.self).baseAddress, password.count,
                    s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(sha256 ? kCCPRFHmacAlgSHA256 : kCCPRFHmacAlgSHA1),
                    UInt32(rounds), &out, 32)
            }
        }
        return Data(out)
    }

    static func aesUnwrap(kek: Data, wrapped: Data) -> Data? {
        guard wrapped.count >= 24, wrapped.count % 8 == 0 else { return nil }
        let w = [UInt8](wrapped), k = [UInt8](kek)
        let n = w.count / 8 - 1
        var a = Array(w[0..<8])
        var r = (0..<n).map { Array(w[($0 + 1) * 8..<($0 + 2) * 8]) }
        for j in (0..<6).reversed() {
            for i in (0..<n).reversed() {
                var t = UInt64(n * j + i + 1)
                var block = a
                for b in (0..<8).reversed() {
                    block[b] ^= UInt8(t & 0xff)
                    t >>= 8
                }
                block += r[i]
                var out = [UInt8](repeating: 0, count: 16)
                var moved = 0
                guard CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                              k, k.count, nil, block, 16, &out, 16, &moved) == kCCSuccess else { return nil }
                a = Array(out[0..<8])
                r[i] = Array(out[8..<16])
            }
        }
        guard a == [UInt8](repeating: 0xA6, count: 8) else { return nil }
        return Data(r.joined())
    }

    static func aesCBCDecrypt(key: Data, iv: Data = Data(count: 16), data: Data) -> Data? {
        var cryptor: CCCryptorRef?
        let status = key.withUnsafeBytes { k in
            iv.withUnsafeBytes { v in
                CCCryptorCreate(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), 0,
                                k.baseAddress, key.count, v.baseAddress, &cryptor)
            }
        }
        guard status == kCCSuccess, let cryptor else { return nil }
        defer { CCCryptorRelease(cryptor) }
        let length = data.count - data.count % 16
        var out = Data(count: length + 16)
        var moved = 0
        let result = data.withUnsafeBytes { d in
            out.withUnsafeMutableBytes { o in
                CCCryptorUpdate(cryptor, d.baseAddress, length, o.baseAddress, length + 16, &moved)
            }
        }
        return result == kCCSuccess ? Data(out.prefix(moved)) : nil
    }

    static func decryptFile(key: Data, from source: URL, to destination: URL, size: Int64) throws {
        var cryptor: CCCryptorRef?
        let status = key.withUnsafeBytes {
            CCCryptorCreate(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), 0, $0.baseAddress, key.count, nil, &cryptor)
        }
        guard status == kCCSuccess, let cryptor else { throw BackupError.invalid("cipher setup failed") }
        defer { CCCryptorRelease(cryptor) }

        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        let chunk = 1 << 20
        var buffer = [UInt8](repeating: 0, count: chunk + 16)
        var written: Int64 = 0
        while true {
            let data = try input.read(upToCount: chunk) ?? Data()
            if data.isEmpty { break }
            var moved = 0
            let result = data.withUnsafeBytes {
                CCCryptorUpdate(cryptor, $0.baseAddress, data.count, &buffer, buffer.count, &moved)
            }
            guard result == kCCSuccess else { throw BackupError.invalid("decryption failed") }
            try output.write(contentsOf: Data(buffer[0..<moved]))
            written += Int64(moved)
        }
        if size >= 0, size < written { try output.truncate(atOffset: UInt64(size)) }
    }
}

struct Keybag {
    private(set) var classKeys: [UInt32: Data] = [:]

    private static func debug(_ lines: [String]) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("restor-keybag-debug.log")
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    init(data: Data, password: String) throws {
        try? data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("restor-keybag.bin"))
        var header: [String: Data] = [:]
        var classes: [[String: Data]] = []
        var current: [String: Data]?
        var sawHeaderUUID = false
        var tagLog: [String] = []
        let bytes = [UInt8](data)
        var i = 0
        while i + 8 <= bytes.count {
            let tag = String(bytes: bytes[i..<i + 4], encoding: .ascii) ?? ""
            let length = Int(Self.uint(bytes[i + 4..<i + 8]))
            guard i + 8 + length <= bytes.count else { break }
            let value = Data(bytes[i + 8..<i + 8 + length])
            i += 8 + length
            tagLog.append("\(tag)(\(length))")
            if tag == "UUID" {
                if !sawHeaderUUID {
                    header[tag] = value
                    sawHeaderUUID = true
                } else {
                    if let current { classes.append(current) }
                    current = [tag: value]
                }
            } else if current != nil {
                current?[tag] = value
            } else {
                header[tag] = value
            }
        }
        if let current { classes.append(current) }
        if header["CLAS"] != nil, header["WPKY"] != nil {
            classes.append(header)
            for key in ["UUID", "CLAS", "WRAP", "KTYP", "WPKY"] { header.removeValue(forKey: key) }
        }

        var log = [
            "keybag bytes: \(data.count)",
            "password chars: \(password.count), nfc-equal: \(password == password.precomposedStringWithCanonicalMapping)",
            "VERS=\(header["VERS"].map { String(Self.uint($0)) } ?? "?") TYPE=\(header["TYPE"].map { String(Self.uint($0)) } ?? "?") WRAP=\(header["WRAP"].map { String(Self.uint($0)) } ?? "?")",
            "tlv tags: \(tagLog.joined(separator: " "))",
            "header keys: \(header.keys.sorted().map { "\($0)=\(header[$0]?.count ?? 0)B" }.joined(separator: " "))",
            "classes parsed: \(classes.count)",
        ]
        for (index, item) in classes.enumerated() {
            let clas = item["CLAS"].map { String(Self.uint($0)) } ?? "?"
            let wrap = item["WRAP"].map { String(Self.uint($0)) } ?? "?"
            log.append("  class[\(index)]: CLAS=\(clas) WRAP=\(wrap) WPKY=\(item["WPKY"]?.count ?? 0)B KTYP=\(item["KTYP"].map { String(Self.uint($0)) } ?? "?")")
        }

        guard let salt = header["SALT"], let iterValue = header["ITER"] else {
            log.append("FAIL: missing SALT or ITER")
            Self.debug(log)
            throw BackupError.invalid("keybag is malformed")
        }
        let iterations = Self.iterations(iterValue, max: 1_000_000)
        let dpsl = header["DPSL"], dpic = header["DPIC"]
        let dpicRounds = dpic.map { Self.iterations($0) }
        log.append("ITER=\(iterations) SALT=\(salt.count)B DPSL=\(dpsl?.count ?? 0)B DPIC=\(dpicRounds.map(String.init) ?? "-")")

        // Password byte-encoding variants (UTF-8 is standard; others are fallbacks).
        let stripped = password.trimmingCharacters(in: .whitespacesAndNewlines)
        var passVariants: [(String, Data)] = [("utf8", Data(password.utf8))]
        if stripped != password { passVariants.append(("utf8-strip", Data(stripped.utf8))) }
        if let le = password.data(using: .utf16LittleEndian) { passVariants.append(("utf16le", le)) }
        if let be = password.data(using: .utf16BigEndian) { passVariants.append(("utf16be", be)) }

        // Stage-1 derivation (~10M rounds) is expensive; cache per password variant + hash.
        var stage1Cache: [String: Data] = [:]
        func stage1(_ pwName: String, _ pw: Data, sha256: Bool) -> Data? {
            guard let dpsl, let dpicRounds else { return nil }
            let key = "\(pwName)|\(sha256)"
            if let cached = stage1Cache[key] { return cached }
            let v = Crypto.pbkdf2(pw, salt: dpsl, rounds: dpicRounds, sha256: sha256)
            stage1Cache[key] = v
            return v
        }

        // Candidate KEK providers, evaluated lazily so the common path succeeds fast.
        var attempts: [(String, () -> Data?)] = []
        for (pname, pdata) in passVariants {
            let isUTF16 = pname.hasPrefix("utf16")
            attempts.append(("\(pname)/ref sha256(dpsl,dpic)>sha1(salt,iter)", {
                guard let mid = stage1(pname, pdata, sha256: true) else { return nil }
                return Crypto.pbkdf2(mid, salt: salt, rounds: iterations, sha256: false)
            }))
            if !isUTF16 {
                attempts.append(("\(pname)/var sha256(dpsl,dpic)>sha256(salt,iter)", {
                    guard let mid = stage1(pname, pdata, sha256: true) else { return nil }
                    return Crypto.pbkdf2(mid, salt: salt, rounds: iterations, sha256: true)
                }))
            }
            attempts.append(("\(pname)/legacy sha1(salt,iter)", {
                Crypto.pbkdf2(pdata, salt: salt, rounds: iterations, sha256: false)
            }))
            if !isUTF16 {
                attempts.append(("\(pname)/var sha256(salt,iter)", {
                    Crypto.pbkdf2(pdata, salt: salt, rounds: iterations, sha256: true)
                }))
                attempts.append(("\(pname)/var sha1(dpsl,dpic)>sha1(salt,iter)", {
                    guard let mid = stage1(pname, pdata, sha256: false) else { return nil }
                    return Crypto.pbkdf2(mid, salt: salt, rounds: iterations, sha256: false)
                }))
            }
        }

        let wrappable = classes.filter { $0["WPKY"] != nil }.count
        var best: [UInt32: Data] = [:]
        var bestName = ""
        for (name, provider) in attempts {
            guard let kek = provider() else { continue }
            var unwrapped: [UInt32: Data] = [:]
            for item in classes {
                guard let clasValue = item["CLAS"], let wrapped = item["WPKY"],
                      let key = Crypto.aesUnwrap(kek: kek, wrapped: wrapped) else { continue }
                let clas = Self.uint(clasValue)
                unwrapped[clas] = key
                let masked = clas & 0xF
                if masked != clas { unwrapped[masked] = key }
            }
            log.append("candidate \(name): unwrapped \(unwrapped.count)/\(wrappable)")
            if unwrapped.count > best.count { best = unwrapped; bestName = name }
            if best.count == wrappable, best.count > 0 { break }
        }
        log.append("result: \(best.isEmpty ? "FAILED" : "ok (\(best.count) class keys via \(bestName))")")
        Self.debug(log)
        guard !best.isEmpty else { throw BackupError.wrongPassword }
        classKeys = best
    }

    func unwrap(_ blob: Data) -> Data? {
        guard blob.count > 4 else { return nil }
        let b = [UInt8](blob.prefix(4))
        let little = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
        let big = UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
        for clas in [little, big] {
            if let classKey = classKeys[clas] {
                return Crypto.aesUnwrap(kek: classKey, wrapped: blob.dropFirst(4))
            }
        }
        return nil
    }

    private static func uint<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        bytes.reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func iterations(_ value: Data, max maxRounds: Int = 20_000_000) -> Int {
        let be = Int(uint(value))
        if be > 0, be <= maxRounds { return be }
        let le = Int(uint([UInt8](value).reversed()))
        if le > 0, le <= maxRounds { return le }
        return min(max(be, 1), maxRounds)
    }
}
