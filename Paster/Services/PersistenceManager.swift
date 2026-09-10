import Foundation
import SwiftData

/// A failed open must never delete the user's history. Fall back to a clearly
/// announced, temporary in-memory session while leaving the original store intact.
@MainActor
final class PersistenceManager {
    static let shared = PersistenceManager()

    let container: ModelContainer
    let storageError: String?
    let storeURL: URL

    init(configuration: ModelConfiguration? = nil) {
        let schema = Schema([ClipboardItem.self])
        let configuration = configuration ?? ModelConfiguration("PasterStore", schema: schema, isStoredInMemoryOnly: false)
        storeURL = configuration.url
        do {
            container = try ModelContainer(for: schema, configurations: [configuration])
            storageError = nil
        } catch {
            storageError = error.localizedDescription
            NSLog("[Paster] Cannot open history; keeping the original store: \(error)")
            do {
                let temporary = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                container = try ModelContainer(for: schema, configurations: [temporary])
            } catch {
                fatalError("Cannot create temporary clipboard storage: \(error)")
            }
        }
    }

    var mainContext: ModelContext { container.mainContext }
}
