import Foundation
import SQLite3

struct Row {
    let values: [String: Any]

    func string(_ key: String) -> String? {
        switch values[key] {
        case let s as String: return s
        case let i as Int64: return String(i)
        case let d as Double: return String(d)
        case let d as Data: return String(data: d, encoding: .utf8)
        default: return nil
        }
    }

    func int(_ key: String) -> Int64? {
        switch values[key] {
        case let i as Int64: return i
        case let d as Double: return Int64(d)
        case let s as String: return Int64(s)
        default: return nil
        }
    }

    func double(_ key: String) -> Double? {
        switch values[key] {
        case let d as Double: return d
        case let i as Int64: return Double(i)
        case let s as String: return Double(s)
        default: return nil
        }
    }

    func data(_ key: String) -> Data? { values[key] as? Data }
    func bool(_ key: String) -> Bool { (int(key) ?? 0) != 0 }
}

struct SQLiteError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class SQLiteDB: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        if sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil) != SQLITE_OK {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            throw SQLiteError(message: "Cannot open database: \(message)")
        }
        sqlite3_busy_timeout(handle, 2000)
    }

    deinit { sqlite3_close(handle) }

    func query(_ sql: String, _ params: [Any?] = []) throws -> [Row] {
        let started = Date() // TEMP-DIAG
        lock.lock()
        defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteError(message: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(stmt) }
        for (i, param) in params.enumerated() {
            let idx = Int32(i + 1)
            switch param {
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, Self.transient)
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Int64: sqlite3_bind_int64(stmt, idx, v)
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            case let v as Data: _ = v.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(v.count), Self.transient) }
            default: sqlite3_bind_null(stmt, idx)
            }
        }
        let count = sqlite3_column_count(stmt)
        let names = (0..<count).map { String(cString: sqlite3_column_name(stmt, $0)) }
        var rows: [Row] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var values: [String: Any] = [:]
            for i in 0..<count {
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: values[names[Int(i)]] = sqlite3_column_int64(stmt, i)
                case SQLITE_FLOAT: values[names[Int(i)]] = sqlite3_column_double(stmt, i)
                case SQLITE_TEXT: values[names[Int(i)]] = String(cString: sqlite3_column_text(stmt, i))
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(stmt, i))
                    values[names[Int(i)]] = sqlite3_column_blob(stmt, i).map { Data(bytes: $0, count: n) } ?? Data()
                default: break
                }
            }
            rows.append(Row(values: values))
        }
        let elapsed = Date().timeIntervalSince(started) * 1000 // TEMP-DIAG
        if elapsed > 500 {
            Diag.log("slow query \(Int(elapsed))ms rows=\(rows.count) sql=\(sql.prefix(140))")
        }
        return rows
    }

    func rows(_ sql: String, _ params: [Any?] = []) -> [Row] {
        (try? query(sql, params)) ?? []
    }

    func columns(_ table: String) -> Set<String> {
        Set(rows("PRAGMA table_info(\"\(table)\")").compactMap { $0.string("name") })
    }

    func hasTable(_ table: String) -> Bool {
        !rows("SELECT name FROM sqlite_master WHERE type='table' AND name=?", [table]).isEmpty
    }
}
