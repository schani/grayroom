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
        Group {
            if let task = list.isEmpty ? nil : list[min(index, list.count - 1)] {
                Button { isPopoverPresented = true } label: {
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(task.title)
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                if let completed = task.completed, let total = task.total {
                                    Text("\(completed) / \(total)")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            TaskProgressBar(task: task)
                        }
                        if list.count > 1 {
                            Text("+\(list.count - 1)")
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.2),
                                            in: Capsule())
                        }
                    }
                    .frame(width: width)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(task.detail ?? task.title)
                .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
                    ActivityList(tasks: tasks)
                }
            }
        }
        .onReceive(cycle) { _ in
            let count = tasks.tasks.count
            index = count == 0 ? 0 : (index + 1) % count
        }
    }
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
private struct ActivityList: View {
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
                        Button {
                            tasks.cancel(task.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .disabled(task.isCancelled)
                        .help("Cancel this task")
                    }
                }
                .frame(width: 280)
            }
            if list.contains(where: { $0.isCancellable && !$0.isCancelled }) {
                Divider()
                Button("Cancel All") { tasks.cancelAll() }
                    .controlSize(.small)
            }
        }
        .padding(14)
    }
}
