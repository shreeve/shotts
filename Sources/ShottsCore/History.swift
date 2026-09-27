import Foundation

/// Undo and redo over whole documents. A `Document` is a few dozen values, so keeping every
/// state is cheap and every edit is one `push`.
public struct History<State: Equatable> {
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

    /// Replaces the present without recording a step: a drag or text entry shows its progress
    /// this way, then ends with `record(since:)` or goes back with `replaceCurrent(base)`.
    public mutating func replaceCurrent(_ state: State) {
        current = state
    }

    /// Ends a change made in place: one step from `base`, the state when the change began, to
    /// the present, or no step at all if they are equal. However many times the present was
    /// replaced along the way, undo goes straight back to `base`.
    public mutating func record(since base: State) {
        let now = current
        current = base
        push(now)
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
