public enum ControlWaitCondition: String, CaseIterable, Sendable {
    case filmPresent = "film-present"
    case filmAbsent = "film-absent"
    case idle
    case jobDone = "job-done"
    case registered

    public func matches(_ status: ControlStatusResult) -> Bool {
        switch self {
        case .filmPresent:
            guard let scanner = status.scanner else { return false }
            return scanner.filmPresent == true
                || (scanner.mediaLoaded && status.device?.kind == "simulated")
        case .filmAbsent:
            guard let scanner = status.scanner, scanner.mediaLoaded == false else { return false }
            return scanner.filmPresent == false || (scanner.filmPresent == nil && status.device?.kind == "simulated")
        case .idle:
            let jobIdle = status.jobState == nil || status.jobState?.isTerminal == true
            return jobIdle && status.mutatingOperationInFlight == nil && status.scanner?.transport == "idle" && !status.refeedRequired
        case .jobDone:
            return status.jobState?.isTerminal == true
        case .registered:
            return status.previewComplete && !status.refeedRequired
        }
    }
}
