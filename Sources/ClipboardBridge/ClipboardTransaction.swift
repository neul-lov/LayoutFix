/// Borrows the pasteboard for one operation and gives it back afterwards.
///
/// The original contents are captured on creation. Every change we cause (our own write, or
/// a copy we triggered in the target app) is recorded by its `changeCount`. On `finish()`
/// the original is restored only if the pasteboard is still at the last change we know
/// about; if anything else wrote to it in the meantime (the user copying something new),
/// that newer content is left alone and the saved copy is discarded.
@MainActor
public final class ClipboardTransaction {
    public enum Outcome: Equatable, Sendable {
        case restored
        /// Nothing ever changed the pasteboard, so it was not rewritten.
        case untouched
        /// Someone else changed the pasteboard after us; their content was kept.
        case keptNewerContent
        case alreadyFinished
    }

    private let pasteboard: PasteboardAccessing
    private var saved: PasteboardSnapshot?
    private var expectedChangeCount: Int

    /// Saves the current contents. Throws, without having changed anything, if they cannot
    /// be saved completely or should not be touched.
    public init(pasteboard: PasteboardAccessing) throws(ClipboardUnavailable) {
        self.pasteboard = pasteboard
        // Read the change count first: if anything writes while the (possibly slow) snapshot
        // runs, the copy would be stale and restoring it would overwrite the newer content.
        let before = pasteboard.changeCount
        let snapshot = try pasteboard.snapshot()
        guard pasteboard.changeCount == before else { throw .changedWhileSaving }
        guard !snapshot.isConcealed else { throw .sensitiveContent }
        saved = snapshot
        expectedChangeCount = before
        initialChangeCount = before
    }

    private let initialChangeCount: Int

    public var changeCountAtStart: Int { expectedChangeCount }

    /// Call after a change we caused indirectly (a synthetic ⌘C in the target app).
    public func acceptCurrentChange() {
        expectedChangeCount = pasteboard.changeCount
    }

    public func write(_ text: String) -> PasteWriteHandle {
        let handle = pasteboard.writeTransientString(text)
        expectedChangeCount = pasteboard.changeCount
        return handle
    }

    @discardableResult
    public func finish() -> Outcome {
        guard let snapshot = saved else { return .alreadyFinished }
        saved = nil
        guard pasteboard.changeCount == expectedChangeCount else { return .keptNewerContent }
        // Rewriting an unchanged clipboard would only bump its change count (and look like a
        // new copy to clipboard tools).
        guard pasteboard.changeCount != initialChangeCount else { return .untouched }
        pasteboard.restore(snapshot)
        return .restored
    }

    /// True if nothing outside this transaction has touched the pasteboard yet.
    public var isUndisturbed: Bool { pasteboard.changeCount == expectedChangeCount }
}
