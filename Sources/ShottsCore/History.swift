import Foundation

/// Undo and redo over whole documents. A `Document` is a few dozen values, so keeping every
/// state is cheap and every edit is one `push`.
public struct History<State: Equatable>: Equatable {
    public private(set) var current: State
    private var past: [State] = []
    private var future: [State] = []

    public init(_ initial: State) {
        current = initial
    }

    public var canUndo: Bool { !past.isEmpty }
    public var canRedo: Bool { !future.isEmpty }

    /// Records a new state. Recording a state equal to the current one is a no-op, so a drag
    /// that ended where it started leaves no undo step.
    public mutating func push(_ state: State) {
        guard state != current else { return }
        past.append(current)
        future.removeAll()
        current = state
    }

    /// Replaces the present without recording a step: a drag shows its progress this way and
    /// records one step when it ends.
    public mutating func replaceCurrent(_ state: State) {
        current = state
    }

    @discardableResult
    public mutating func undo() -> State? {
        guard let previous = past.popLast() else { return nil }
        future.append(current)
        current = previous
        return current
    }

    @discardableResult
    public mutating func redo() -> State? {
        guard let next = future.popLast() else { return nil }
        past.append(current)
        current = next
        return current
    }
}
