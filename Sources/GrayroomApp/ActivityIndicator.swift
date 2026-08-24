import Combine
import GrayroomUI
import SwiftUI

/// The activity centre's compact face: one task's title and progress, in about
/// 220 pt.
///
/// Modelled on Lightroom's identity-plate progress bar, including the part
/// people miss — when more than one thing is running it **cycles**, showing
/// each active task for two seconds, with a "+N" badge saying how many others
/// there are. That beats both alternatives: a stack of bars that shoves the
/// toolbar around, and a single fixed bar that silently hides everything except
/// whichever task happened to start first.
///
/// Clicking opens the full list, where each task has its own cancel button.
///
/// # The slot is always there
///
/// The indicator *draws* nothing when nothing is running, but it still takes up
/// exactly the same rectangle. That is not tidiness: it sits at the head of the
/// toolbar, so a view that collapses to zero width when the last task finishes
/// drags every button after it 230 pt to the left, and takes the toolbar's
/// intrinsic width — and therefore the window's minimum width — with it, which
/// AppKit answers by resizing the window under the user. An import finishing
/// must not move the Import button.
struct ActivityIndicator: View {
    let tasks: TaskCenter
    /// The import window's bottom bar is tighter than the main toolbar.
    var width: Double = 220

    @State private var index = 0
    @State private var isPopoverPresented = false

    /// `.common` so the cycle keeps running while a menu or a scroll is
    /// tracking; a progress display that freezes exactly when the user is
    /// interacting is worse than none.
    private let cycle = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        let list = tasks.tasks
        ZStack(alignment: .leading) {
            // The reservation. Everything else in this view is drawn on top of
            // it and never decides how big it is.
            Color.clear
            if let task = list.isEmpty ? nil : list[min(index, list.count - 1)] {
                indicator(for: task, others: list.count - 1)
            }
        }
        .frame(width: width, height: ActivityIndicator.height)
        .controlProbe(ActivityIndicator.slotProbeName)
        .onReceive(cycle) { _ in
            let count = tasks.tasks.count
            index = count == 0 ? 0 : (index + 1) % count
        }
    }

    private func indicator(for task: TaskCenter.BackgroundTask,
                           others: Int) -> some View {
        // One line, status-bar sized: the indicator lives in the bottom bar
        // (Lightroom keeps it top-left; ours was there once and the user moved
        // it), so it has to fit between the status text and the ms readout.
        HStack(spacing: 6) {
            Text(task.title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            TaskProgressBar(task: task)
                .frame(width: 70)
            if let completed = task.completed, let total = task.total {
                Text("\(completed) / \(total)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if others > 0 {
                Text("+\(others)")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.2), in: Capsule())
            }
        }
        .frame(width: width)
        // An `NSView` behind it rather than a `Button`, for the reason the
        // Folders panel's rows have one: this sits in the toolbar of a window
        // that is often not the front one, and a click that brings the window
        // forward should still open the list.
        .clickTarget(ActivityIndicator.probeName,
                     label: task.title,
                     value: ActivityIndicator.progressDescription(task),
                     tooltip: task.detail ?? task.title) {
            isPopoverPresented = true
        }
        .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
            ActivityList(tasks: tasks)
        }
    }

    /// What the indicator reads out: how far along, in words, or that it does
    /// not know.
    static func progressDescription(_ task: TaskCenter.BackgroundTask) -> String {
        guard let completed = task.completed, let total = task.total else {
            return "in progress"
        }
        return "\(completed) of \(total)"
    }

    /// The slot's height, busy or idle: one status-bar line, so the bottom bar
    /// is exactly as tall with the indicator as without it.
    static let height: Double = 16

    /// The name the indicator's button answers to from outside. There is no
    /// button at all when nothing is running, which is how the self-test knows
    /// the indicator cleared — while `slotProbeName` is there either way, which
    /// is how it knows nothing moved.
    static let probeName = "activity-indicator"
    static let slotProbeName = "activity-slot"
}

/// Determinate when the task knows its size, a barber pole when it does not.
private struct TaskProgressBar: View {
    let task: TaskCenter.BackgroundTask

    var body: some View {
        Group {
            if let fraction = task.fractionCompleted {
                ProgressView(value: fraction)
            } else {
                ProgressView()
            }
        }
        .progressViewStyle(.linear)
        .controlSize(.small)
        .opacity(task.isCancelled ? 0.4 : 1)
    }
}

/// The popover: every task, with a cancel button for the ones that have one.
struct ActivityList: View {
    let tasks: TaskCenter

    var body: some View {
        let list = tasks.tasks
        VStack(alignment: .leading, spacing: 10) {
            Text("Background Activity").font(.headline)
            if list.isEmpty {
                Text("Nothing running").foregroundStyle(.secondary).font(.system(size: 11))
            }
            ForEach(list) { task in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(task.title).font(.system(size: 12, weight: .medium))
                            Spacer(minLength: 0)
                            if let completed = task.completed, let total = task.total {
                                Text("\(completed) / \(total)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        TaskProgressBar(task: task)
                        Text(task.isCancelled ? "Cancelling…" : (task.detail ?? " "))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if task.isCancellable {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .opacity(task.isCancelled ? 0.4 : 1)
                            .clickTarget(ActivityList.cancelProbeName(task),
                                         label: "Cancel \(task.title)",
                                         tooltip: "Cancel this task") {
                                guard !task.isCancelled else { return }
                                tasks.cancel(task.id)
                            }
                    }
                }
                .frame(width: 280)
                .controlProbe(ActivityList.rowProbeName(task))
            }
            if list.contains(where: { $0.isCancellable && !$0.isCancelled }) {
                Divider()
                Button("Cancel All") { tasks.cancelAll() }
                    .controlSize(.small)
                    .controlProbe("activity-cancel-all")
            }
        }
        .padding(14)
    }

    /// One row of the popover, by the task it is showing. The self-test reads
    /// these to know the popover lists what is running, and clicks the cancel
    /// one to know the ⓧ is wired to the task and not just drawn.
    static func rowProbeName(_ task: TaskCenter.BackgroundTask) -> String {
        "activity-task-\(task.id.uuidString)"
    }

    static func cancelProbeName(_ task: TaskCenter.BackgroundTask) -> String {
        "activity-cancel-\(task.id.uuidString)"
    }
}
