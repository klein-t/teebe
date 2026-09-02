import Foundation
import CoreServices

/// `FileSystemWatcher` backed by FSEvents (TECH_SPEC §5). Raw events are coalesced
/// and debounced so a burst of agent writes flushes as a single batch of changed
/// paths.
public final class FSEventsWatcher: FileSystemWatcher, @unchecked Sendable {
    private var stream: FSEventStreamRef?
    /// Serial queue: serializes all coalescing-state access and FSEvents callbacks.
    private let queue = DispatchQueue(label: "teebe.fsevents", qos: .utility)

    // Coalescing state — accessed only on `queue`.
    var handler: (@Sendable ([String]) -> Void)?
    var debounceInterval: TimeInterval = 0.2
    /// Upper bound on how long a flush can be pushed back by fresh events. A pure
    /// trailing debounce starves under continuous writes (exactly the busy-agent
    /// case): every event re-arms the timer and nothing flushes until the burst
    /// ends. The cap forces a flush at least this often while events keep coming.
    var maxCoalesceInterval: TimeInterval = 2.0
    private var pending = Set<String>()
    private var flushWorkItem: DispatchWorkItem?
    /// When the oldest still-unflushed event arrived (nil when `pending` is empty).
    private var firstPendingAt: DispatchTime?

    public private(set) var isWatching = false

    public init() {}

    deinit { stop() }

    public func start(paths: [String], debounce: TimeInterval, onChange: @escaping @Sendable ([String]) -> Void) {
        stop()
        guard !paths.isEmpty else { return }
        // Publish handler/interval onto the serial queue before the stream can
        // deliver, so the callback sees them with proper memory ordering.
        queue.sync {
            handler = onChange
            debounceInterval = debounce
        }

        let info = Unmanaged.passUnretained(self).toOpaque()
        var context = FSEventStreamContext(version: 0, info: info, retain: nil, release: nil, copyDescription: nil)

        let callback: FSEventStreamCallback = { _, clientInfo, numEvents, eventPaths, _, _ in
            guard let clientInfo, numEvents > 0 else { return }
            let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(clientInfo).takeUnretainedValue()
            let cfArray = unsafeBitCast(eventPaths, to: CFArray.self)
            let paths = (cfArray as NSArray) as? [String] ?? []
            watcher.ingest(paths)
        }

        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagUseCFTypes
        )

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            debounce,
            flags
        ) else {
            return
        }

        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
        isWatching = true
    }

    public func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        isWatching = false
        queue.async { [weak self] in
            self?.flushWorkItem?.cancel()
            self?.flushWorkItem = nil
            self?.pending.removeAll()
            self?.firstPendingAt = nil
        }
    }

    /// Accept a batch of raw event paths and schedule a debounced, coalesced flush.
    /// Invoked by the FSEvents callback; also called directly by tests.
    func ingest(_ paths: [String]) {
        queue.async { [weak self] in
            guard let self else { return }
            let now = DispatchTime.now()
            if self.pending.isEmpty { self.firstPendingAt = now }
            self.pending.formUnion(paths)
            self.flushWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let batch = Array(self.pending)
                self.pending.removeAll()
                self.firstPendingAt = nil
                if !batch.isEmpty { self.handler?(batch) }
            }
            self.flushWorkItem = work
            // Trailing debounce, but never past the cap measured from the oldest
            // pending event — a steady write stream still flushes periodically.
            let cap = (self.firstPendingAt ?? now) + self.maxCoalesceInterval
            self.queue.asyncAfter(deadline: min(now + self.debounceInterval, cap), execute: work)
        }
    }
}
