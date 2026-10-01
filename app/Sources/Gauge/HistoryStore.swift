import Foundation
import SQLite3

/// One averaged history row. Stored every 10 seconds.
struct HistoryPoint: Identifiable, Hashable {
    var id: Date { date }
    var date: Date
    var cpu: Double
    var memoryUsed: Double
    var memoryTotal: Double
    var gpu: Double
    var download: Double
    var upload: Double
    var diskRead: Double
    var diskWrite: Double
    var battery: Double?
}

/// Local SQLite history in ~/Library/Application Support/Gauge.
/// History stays on this Mac: the store has no network code and nothing syncs it.
final class HistoryStore: @unchecked Sendable {
    static let folder: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Gauge", isDirectory: true)
    static let file = folder.appendingPathComponent("history.sqlite")

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "gauge.history")

    init() {
        queue.sync {
            try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            guard sqlite3_open_v2(Self.file.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
                db = nil
                return
            }
            exec("""
                PRAGMA journal_mode = WAL;
                CREATE TABLE IF NOT EXISTS samples (
                    t INTEGER PRIMARY KEY, cpu REAL, mem REAL, mem_total REAL, gpu REAL,
                    down REAL, up REAL, disk_read REAL, disk_write REAL, battery REAL);
                CREATE TABLE IF NOT EXISTS app_cpu (
                    hour INTEGER, app TEXT, seconds REAL, PRIMARY KEY (hour, app));
                """)
        }
    }

    deinit { sqlite3_close(db) }

    struct Row {
        var t: Int
        var cpu, memory, memoryTotal, gpu, down, up, diskRead, diskWrite: Double
        var battery: Double?
    }

    func insert(_ row: Row) {
        queue.async { [self] in
            run("INSERT OR REPLACE INTO samples VALUES (?,?,?,?,?,?,?,?,?,?)") { s in
                sqlite3_bind_int64(s, 1, Int64(row.t))
                for (i, v) in [row.cpu, row.memory, row.memoryTotal, row.gpu, row.down, row.up, row.diskRead, row.diskWrite].enumerated() {
                    sqlite3_bind_double(s, Int32(i + 2), v)
                }
                if let b = row.battery { sqlite3_bind_double(s, 10, b) } else { sqlite3_bind_null(s, 10) }
                _ = sqlite3_step(s)
            }
        }
    }

    func addCPUTime(_ seconds: [String: Double], at date: Date) {
        let hour = Int64(date.timeIntervalSince1970) / 3600
        queue.async { [self] in
            exec("BEGIN")
            for (app, value) in seconds where value > 0 {
                run("INSERT INTO app_cpu VALUES (?,?,?) ON CONFLICT(hour, app) DO UPDATE SET seconds = seconds + excluded.seconds") { s in
                    sqlite3_bind_int64(s, 1, hour)
                    sqlite3_bind_text(s, 2, app, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_double(s, 3, value)
                    _ = sqlite3_step(s)
                }
            }
            exec("COMMIT")
        }
    }

    /// Averaged into at most `points` buckets.
    func series(since: Date, points: Int = 240, completion: @escaping @MainActor ([HistoryPoint]) -> Void) {
        let start = Int64(since.timeIntervalSince1970)
        let bucket = max(10, (Int64(Date().timeIntervalSince1970) - start) / Int64(points))
        queue.async { [self] in
            var result: [HistoryPoint] = []
            run("SELECT (t / ?) * ? AS b, avg(cpu), avg(mem), max(mem_total), avg(gpu), avg(down), avg(up), avg(disk_read), avg(disk_write), avg(battery) FROM samples WHERE t >= ? GROUP BY b ORDER BY b") { s in
                sqlite3_bind_int64(s, 1, bucket)
                sqlite3_bind_int64(s, 2, bucket)
                sqlite3_bind_int64(s, 3, start)
                while sqlite3_step(s) == SQLITE_ROW {
                    result.append(HistoryPoint(date: Date(timeIntervalSince1970: Double(sqlite3_column_int64(s, 0))),
                                               cpu: sqlite3_column_double(s, 1),
                                               memoryUsed: sqlite3_column_double(s, 2),
                                               memoryTotal: sqlite3_column_double(s, 3),
                                               gpu: sqlite3_column_double(s, 4),
                                               download: sqlite3_column_double(s, 5),
                                               upload: sqlite3_column_double(s, 6),
                                               diskRead: sqlite3_column_double(s, 7),
                                               diskWrite: sqlite3_column_double(s, 8),
                                               battery: sqlite3_column_type(s, 9) == SQLITE_NULL ? nil : sqlite3_column_double(s, 9)))
                }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func topApps(since: Date, limit: Int = 6, completion: @escaping @MainActor ([(String, Double)]) -> Void) {
        let hour = Int64(since.timeIntervalSince1970) / 3600
        queue.async { [self] in
            var result: [(String, Double)] = []
            run("SELECT app, sum(seconds) AS s FROM app_cpu WHERE hour >= ? GROUP BY app ORDER BY s DESC LIMIT ?") { s in
                sqlite3_bind_int64(s, 1, hour)
                sqlite3_bind_int64(s, 2, Int64(limit))
                while sqlite3_step(s) == SQLITE_ROW {
                    result.append((String(cString: sqlite3_column_text(s, 0)), sqlite3_column_double(s, 1)))
                }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func prune(keepingDays days: Int) {
        let cutoff = Int64(Date().timeIntervalSince1970) - Int64(days) * 86_400
        queue.async { [self] in
            run("DELETE FROM samples WHERE t < ?") { s in sqlite3_bind_int64(s, 1, cutoff); _ = sqlite3_step(s) }
            run("DELETE FROM app_cpu WHERE hour < ?") { s in sqlite3_bind_int64(s, 1, cutoff / 3600); _ = sqlite3_step(s) }
        }
    }

    /// Empties the history tables when the user asks to clear history.
    func clear(completion: @escaping @MainActor () -> Void) {
        queue.async { [self] in
            exec("DELETE FROM samples; DELETE FROM app_cpu; VACUUM;")
            DispatchQueue.main.async { completion() }
        }
    }

    func oldestSample(completion: @escaping @MainActor (Date?) -> Void) {
        queue.async { [self] in
            var date: Date?
            run("SELECT min(t) FROM samples") { s in
                if sqlite3_step(s) == SQLITE_ROW, sqlite3_column_type(s, 0) != SQLITE_NULL {
                    date = Date(timeIntervalSince1970: Double(sqlite3_column_int64(s, 0)))
                }
            }
            DispatchQueue.main.async { completion(date) }
        }
    }

    static var sizeOnDisk: Int64 {
        let names = ["history.sqlite", "history.sqlite-wal", "history.sqlite-shm"]
        return names.reduce(0) { total, name in
            let url = folder.appendingPathComponent(name)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return total + Int64(size)
        }
    }

    // MARK: SQLite helpers (call on `queue`)

    private func exec(_ sql: String) {
        guard let db else { return }
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func run(_ sql: String, _ body: (OpaquePointer) -> Void) {
        guard let db else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return }
        body(statement)
        sqlite3_finalize(statement)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
