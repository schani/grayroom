import Foundation
import Observation

/// The app's activity centre: every piece of long-running background work, with
/// its progress and its cancel button, in one list.
///
/// Lightroom puts this in the identity plate, and the reason is not decoration:
/// a photo app's slow work (hashing a card, importing it, exporting a frame) is
/// long enough that a status line saying "Importing 37 of 142…" is both too
/// small to notice and unable to show two things at once. A registry the UI can
/// enumerate solves both — the indicator shows the front task and a "+N" badge,
/// and the popover shows every one of them with its own ⓧ.
///
/// # Threading
///
/// Main-thread only, like the rest of the observable stores: `begin`, `update`,
/// `finish`, `cancel` and `tasks` all assume it, and background callers hop to
/// main before touching them.
///
/// `isCancelled(_:)` is the deliberate exception. It is what a worker loop polls
/// between files, and a queue hop per file would cost more than the work it
/// guards, so cancellation is kept in a lock-protected set that any thread may
/// read. The flag mirrored into `tasks` is only there for the UI.
@Observable
public final class TaskCenter {
    public struct BackgroundTask: Identifiable, Equatable, Sendable {
        public let id: UUID
        public var title: String
        /// A second line — the file being worked on, usually.
        public var detail: String?
        public var completed: Int?
        /// `nil` for work whose size is not known in advance, which the UI
        /// draws as an indeterminate bar.
        public var total: Int?
        public var isCancellable: Bool
        public var isCancelled: Bool

        /// `nil` when the task is indeterminate.
        public var fractionCompleted: Double? {
            guard let completed, let total, total > 0 else { return nil }
            return min(max(Double(completed) / Double(total), 0), 1)
        }

        public init(id: UUID = UUID(), title: String, detail: String? = nil,
                    completed: Int? = nil, total: Int? = nil,
                    isCancellable: Bool = false, isCancelled: Bool = false) {
            self.id = id
            self.title = title
            self.detail = detail
            self.completed = completed
            self.total = total
            self.isCancellable = isCancellable
            self.isCancelled = isCancelled
        }
    }

    /// In the order they were begun, so the indicator's "front task" is stable
    /// rather than jumping around as progress arrives.
    public private(set) var tasks: [BackgroundTask] = []

    private let cancelled = CancellationSet()

    public init() {}

    public var isBusy: Bool { !tasks.isEmpty }

    @discardableResult
    public func begin(title: String, total: Int? = nil,
                      cancellable: Bool = false) -> BackgroundTask.ID {
        let task = BackgroundTask(title: title,
                                  completed: total == nil ? nil : 0,
                                  total: total,
                                  isCancellable: cancellable)
        tasks.append(task)
        return task.id
    }

    /// Every argument is optional so a caller can move one without clearing the
    /// others; passing none is a no-op.
    ///
    /// `total` is settable after the fact because some work only learns its own
    /// size partway through — the import scan has to begin its task before it
    /// has enumerated the folder, so it starts indeterminate and fills the
    /// total in with its first progress report.
    public func update(_ id: BackgroundTask.ID, completed: Int? = nil,
                       total: Int? = nil, detail: String? = nil) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        if let completed { tasks[index].completed = completed }
        if let total { tasks[index].total = total }
        if let detail { tasks[index].detail = detail }
    }

    public func finish(_ id: BackgroundTask.ID) {
        tasks.removeAll { $0.id == id }
        cancelled.remove(id)
    }

    /// Raises the flag; it is the worker's job to notice and stop. The task
    /// stays in the list until that worker calls `finish`, so the user sees
    /// that the cancellation is being acted on rather than the row vanishing
    /// while the work carries on.
    public func cancel(_ id: BackgroundTask.ID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }),
              tasks[index].isCancellable else { return }
        tasks[index].isCancelled = true
        cancelled.insert(id)
    }

    public func cancelAll() {
        for task in tasks { cancel(task.id) }
    }

    /// Safe to call from any thread — see the threading note above.
    public func isCancelled(_ id: BackgroundTask.ID) -> Bool { cancelled.contains(id) }

    public func task(_ id: BackgroundTask.ID) -> BackgroundTask? {
        tasks.first { $0.id == id }
    }
}

/// A `Set<UUID>` any thread may read.
private final class CancellationSet {
    private let lock = NSLock()
    private var ids: Set<UUID> = []

    func insert(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        ids.insert(id)
    }

    func remove(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        ids.remove(id)
    }

    func contains(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return ids.contains(id)
    }
}
