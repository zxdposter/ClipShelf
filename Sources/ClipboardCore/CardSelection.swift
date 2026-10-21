import Foundation

public struct CardSelection: Equatable {
    public private(set) var ids: Set<UUID> = []
    public private(set) var focusedID: UUID?
    private var anchorID: UUID?
    public init() {}

    public mutating func select(_ id: UUID, in orderedIDs: [UUID], command: Bool = false, shift: Bool = false) {
        guard let end = orderedIDs.firstIndex(of: id) else { return }
        ids.formIntersection(orderedIDs)
        if shift, let anchorID, let start = orderedIDs.firstIndex(of: anchorID) {
            let range = Set(orderedIDs[min(start, end)...max(start, end)])
            ids = command ? ids.union(range) : range
        } else if command {
            if !ids.insert(id).inserted { ids.remove(id) }
            anchorID = id
        } else {
            ids = [id]; anchorID = id
        }
        focusedID = id
    }
    public mutating func selectAll(in orderedIDs: [UUID]) {
        ids = Set(orderedIDs)
        if focusedID == nil || !ids.contains(focusedID!) { focusedID = orderedIDs.first }
        if anchorID == nil || !ids.contains(anchorID!) { anchorID = focusedID }
    }
    public mutating func reset(in orderedIDs: [UUID]) {
        ids = []; focusedID = nil; anchorID = nil
        if let first = orderedIDs.first { select(first, in: orderedIDs) }
    }
    public mutating func move(_ direction: Int, in orderedIDs: [UUID], extending: Bool) {
        guard !orderedIDs.isEmpty else { reset(in: []); return }
        let current = focusedID.flatMap { orderedIDs.firstIndex(of: $0) } ?? (direction > 0 ? -1 : orderedIDs.count)
        let index = min(max(current + direction, 0), orderedIDs.count - 1)
        select(orderedIDs[index], in: orderedIDs, shift: extending)
    }
}
