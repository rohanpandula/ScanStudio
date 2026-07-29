/// Pure state transitions for a pre-project preview's film process. The
/// selected value is pending until the terminal completion event; an ACK is
/// not proof that registration succeeded.
public enum PreviewProcessLifecyclePolicy {
    public static func requestProcess(projectProcess: FilmProcess?, selectedProcess: FilmProcess) -> FilmProcess {
        projectProcess ?? selectedProcess
    }

    public static func commitAfterCompletion(pending: FilmProcess?) -> FilmProcess? { pending }

    public static func clearAfterFailureOrMediaReset() -> FilmProcess? { nil }
}
