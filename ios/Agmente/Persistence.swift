import CoreData

struct PersistenceController {
    private final class BundleMarker {}

    static let shared = PersistenceController()

    /// Shared managed object model so multiple in-memory or temporary SQLite test containers
    /// do not trigger duplicate entity description warnings in the same process.
    static let managedObjectModel: NSManagedObjectModel = {
        let bundles = [Bundle.main, Bundle(for: BundleMarker.self)]
        for bundle in bundles {
            if let momdURL = bundle.url(forResource: "Agmente", withExtension: "momd"),
               let model = NSManagedObjectModel(contentsOf: momdURL) {
                return model
            }
        }
        return NSManagedObjectModel.mergedModel(from: bundles) ?? NSManagedObjectModel()
    }()

    static func model(versionName: String) -> NSManagedObjectModel? {
        let bundles = [Bundle.main, Bundle(for: BundleMarker.self)]
        for bundle in bundles {
            if let url = bundle.url(forResource: versionName, withExtension: "mom", subdirectory: "Agmente.momd"),
               let model = NSManagedObjectModel(contentsOf: url) {
                return model
            }
        }
        return nil
    }

    @MainActor
    static let preview: PersistenceController = {
        PersistenceController(inMemory: true)
    }()

    let container: NSPersistentContainer

    init(
        inMemory: Bool = false,
        storeURL: URL? = nil,
        managedObjectModel: NSManagedObjectModel = PersistenceController.managedObjectModel
    ) {
        container = NSPersistentContainer(name: "Agmente", managedObjectModel: managedObjectModel)
        if let description = container.persistentStoreDescriptions.first {
            if inMemory {
                description.url = URL(fileURLWithPath: "/dev/null")
            } else if let storeURL {
                description.url = storeURL
            }
            description.shouldMigrateStoreAutomatically = true
            description.shouldInferMappingModelAutomatically = true
        }
        container.loadPersistentStores(completionHandler: { (storeDescription, error) in
            if let error = error as NSError? {
                // Replace this implementation with code to handle the error appropriately.
                // fatalError() causes the application to generate a crash log and terminate. You should not use this function in a shipping application, although it may be useful during development.

                /*
                 Typical reasons for an error here include:
                 * The parent directory does not exist, cannot be created, or disallows writing.
                 * The persistent store is not accessible, due to permissions or data protection when the device is locked.
                 * The device is out of space.
                 * The store could not be migrated to the current model version.
                 Check the error message to determine what the actual problem was.
                 */
                fatalError("Unresolved error \(error), \(error.userInfo)")
            }
        })
        container.viewContext.automaticallyMergesChangesFromParent = true
    }
}
