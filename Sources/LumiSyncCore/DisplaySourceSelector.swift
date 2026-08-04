public enum DisplayKind: Equatable, Sendable {
    case builtIn
    case external
}

public enum DisplayAdapterKind: Equatable, Sendable {
    case builtIn
    case apple
    case ddc
}

public struct DisplayCandidate: Equatable, Sendable {
    public let id: UInt32
    public let kind: DisplayKind
    public let adapter: DisplayAdapterKind
    public let readableBrightness: Double?
    public let isMain: Bool

    public init(
        id: UInt32,
        kind: DisplayKind,
        adapter: DisplayAdapterKind,
        readableBrightness: Double?,
        isMain: Bool
    ) {
        self.id = id
        self.kind = kind
        self.adapter = adapter
        self.readableBrightness = readableBrightness
        self.isMain = isMain
    }
}

public struct DisplaySelection: Equatable, Sendable {
    public let brightness: Double
    public let sourceDescription: String
    public let fallbackReason: String?

    public init(brightness: Double, sourceDescription: String, fallbackReason: String?) {
        self.brightness = brightness
        self.sourceDescription = sourceDescription
        self.fallbackReason = fallbackReason
    }
}

public struct DisplaySourceSelector {
    public init() {}

    public func select(from candidates: [DisplayCandidate]) -> DisplaySelection? {
        let externalCandidates = candidates.filter { $0.kind == .external }
        if let selected = externalCandidates
            .filter({ $0.readableBrightness != nil })
            .sorted(by: externalSelectionOrder)
            .first,
           let brightness = selected.readableBrightness {
            return DisplaySelection(
                brightness: brightness,
                sourceDescription: externalSourceDescription(for: selected),
                fallbackReason: nil
            )
        }

        guard let selected = candidates
            .filter({ $0.kind == .builtIn && $0.readableBrightness != nil })
            .sorted(by: builtInSelectionOrder)
            .first,
            let brightness = selected.readableBrightness
        else {
            return nil
        }

        let reason = externalCandidates.isEmpty
            ? "No external display is available; using the built-in display."
            : "External display brightness is unavailable; using the built-in display."

        return DisplaySelection(
            brightness: brightness,
            sourceDescription: "Built-in display",
            fallbackReason: reason
        )
    }

    private func externalSelectionOrder(_ lhs: DisplayCandidate, _ rhs: DisplayCandidate) -> Bool {
        if lhs.isMain != rhs.isMain {
            return lhs.isMain
        }
        if lhs.id != rhs.id {
            return lhs.id < rhs.id
        }
        return adapterPriority(lhs.adapter) < adapterPriority(rhs.adapter)
    }

    private func builtInSelectionOrder(_ lhs: DisplayCandidate, _ rhs: DisplayCandidate) -> Bool {
        if lhs.id != rhs.id {
            return lhs.id < rhs.id
        }
        return adapterPriority(lhs.adapter) < adapterPriority(rhs.adapter)
    }

    private func adapterPriority(_ adapter: DisplayAdapterKind) -> Int {
        switch adapter {
        case .apple:
            0
        case .ddc:
            1
        case .builtIn:
            2
        }
    }

    private func externalSourceDescription(for candidate: DisplayCandidate) -> String {
        switch candidate.adapter {
        case .apple:
            "External display \(candidate.id) (Apple adapter)"
        case .ddc:
            "External display \(candidate.id) (DDC/CI)"
        case .builtIn:
            "External display \(candidate.id)"
        }
    }
}
