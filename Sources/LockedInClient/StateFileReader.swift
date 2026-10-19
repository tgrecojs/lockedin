import Foundation
import LockedInCore

/// Read-only view of the daemon's state file, for display when the daemon cannot be reached.
public enum StateFileReader {
    public static func read(path: String = RuntimePaths.current.stateFile) -> StateDocument? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? NDJSON.makeDecoder().decode(StateDocument.self, from: data)
    }
}
