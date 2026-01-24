import Foundation
import OSLog
import PumpSimulatorKit

class Storage: StorageDelegate {
    private let logger = Logger(subsystem: "com.bastiaanv.unified-pump-simulator", category: "Storage")
    private let localDocuments: URL?

    init() {
        localDocuments = try? FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }

    func getState(_ pumpManager: PumpManagerProtocol.Type) -> StateRawValue? {
        guard let localDocuments = localDocuments else {
            logger.error("[getState] No localDocuments URL available...")
            return nil
        }

        do {
            let storageURL = localDocuments.appendingPathComponent(pumpManager.identifier + ".plist")
            let data = try Data(contentsOf: storageURL)

            guard let value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? StateRawValue else {
                logger.warning("No data...")
                return nil
            }

            return value
        } catch {
            logger.error("Got error during state read: \(error.localizedDescription)")
            return nil
        }
    }

    func saveState(_ pumpManager: PumpManagerProtocol.Type, _ state: StateRawValue) {
        guard let localDocuments = localDocuments else {
            logger.error("[saveState] No localDocuments URL available...")
            return
        }

        do {
            let storageURL = localDocuments.appendingPathComponent(pumpManager.identifier + ".plist")
            let data = try PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            logger.error("Got error during state saving: \(error.localizedDescription)")
        }
    }
}
