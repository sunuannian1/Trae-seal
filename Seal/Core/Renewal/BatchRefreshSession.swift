import Foundation

struct BatchRefreshSession: Identifiable, Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case preparing
        case running
        case preparingSealUpdate
        case completed(BatchRefreshResult)
        case failed(ImportFailure)
    }

    struct Item: Identifiable, Equatable, Sendable {
        enum State: Equatable, Sendable {
            case waiting
            case running
            case completed
            case failed
            case preparingSealUpdate
        }

        let id: UUID
        var name: String
        var isSeal: Bool
        var state: State
        var stage: SigningStage? = nil
    }

    let id: UUID
    var status: Status
    var currentIndex: Int
    var total: Int
    var currentAppName: String?
    var currentStage: SigningStage?
    var succeeded: Int
    var failed: Int
    var items: [Item]

    init(id: UUID = UUID()) {
        self.id = id
        status = .preparing
        currentIndex = 0
        total = 0
        succeeded = 0
        failed = 0
        items = []
    }
}
