import Foundation
import Testing

@testable import ScanStudioKit

/// Pins `ProbableCauseExtractor` against the real message shape a
/// REFEED_REQUIRED detail carries (FEEDING-UX-LADDER-OVERNIGHT-20260807.md,
/// Rung 3). The fixture below is assembled from the exact pieces the real
/// pipeline produces, each independently confirmed against the source:
///
/// 1. CoolscanPy's `IndexDecodeError.__str__`
///    (`coolscanpy/src/coolscanpy/protocol/ls5000_single_pass/roll_index.py`):
///    `"<message> [<error_id>] " + json.dumps(diagnostics, sort_keys=True)`.
/// 2. The bridge's `except IndexDecodeError as exc` branch
///    (`bridge/src/scanstudio_bridge/transport/coolscanpy_transport.py`):
///    wraps that string as
///    `"transport read was not one uniform traversal; eject or refeed the
///    strip and run the preview again -- if this recurs on clean feeds it
///    may be a capture or driver defect (" + str(exc) + ")"`.
/// 3. The engine's `map_bridge_error` (`real_backend.rs`): wraps the whole
///    thing again as `"bridge error <CODE>: <message>"`.
///
/// `bridge/tests/test_transport_coolscanpy.py`'s own
/// `test_preview_probable_cause_survives_into_refeed_required_message` pins
/// step 2's output for exactly this sentence and error id, which is where
/// this fixture's wording comes from.
struct ProbableCauseExtractionTests {
    private static let sentence =
        "this looks like half-frame film (frames about every 19 mm); this "
        + "driver expects standard 35 mm spacing"

    /// The exact detail string `SessionModel.lastErrorMessage` would hold
    /// after a real REFEED_REQUIRED carrying this Rung-3 diagnosis.
    private static let realCapturedDetail =
        "bridge error REFEED_REQUIRED: transport read was not one uniform "
        + "traversal; eject or refeed the strip and run the preview again "
        + "-- if this recurs on clean feeds it may be a capture or driver "
        + "defect (transport anchor residual is inconsistent with one "
        + "affine preview traversal (MAE 4.447 rows, max 11.241 rows) "
        + "[gap-lattice-anchor] {\"probable_cause\": \"\(sentence)\"})"

    @Test("extracts the sentence from a real captured REFEED_REQUIRED detail")
    func extractsFromRealCapturedDetail() {
        #expect(ProbableCauseExtractor.extract(from: Self.realCapturedDetail) == Self.sentence)
    }

    @Test("never returns the surrounding prose, error id, or raw JSON")
    func extractionExcludesEverythingElse() {
        let extracted = ProbableCauseExtractor.extract(from: Self.realCapturedDetail)
        #expect(extracted?.contains("probable_cause") == false)
        #expect(extracted?.contains("{") == false)
        #expect(extracted?.contains("}") == false)
        #expect(extracted?.contains("gap-lattice-anchor") == false)
        #expect(extracted?.contains("MAE 4.447") == false)
        #expect(extracted?.contains("eject or refeed") == false)
    }

    @Test("finds probable_cause even when it isn't the only or first diagnostics key")
    func extractsWhenNotTheOnlyKey() {
        // json.dumps(..., sort_keys=True) alphabetizes keys -- "probable_cause"
        // can land in the middle of a multi-key diagnostics dict, e.g.
        // roll_diagnosis's own gap-geometry check attaches numeric context
        // alongside its sentence.
        let multiKeyDetail =
            "bridge error REFEED_REQUIRED: transport read was not one uniform "
            + "traversal; eject or refeed the strip and run the preview again "
            + "-- if this recurs on clean feeds it may be a capture or driver "
            + "defect (a blank region is too narrow [gap-count-floor] "
            + "{\"aperture_columns\": [12, 340], \"probable_cause\": "
            + "\"the blank strips between your frames measure under ~0.8 mm "
            + "-- too narrow for the detector\", \"run_width_rows\": 2})"
        #expect(
            ProbableCauseExtractor.extract(from: multiKeyDetail)
                == "the blank strips between your frames measure under ~0.8 mm "
                + "-- too narrow for the detector"
        )
    }

    @Test("handles an escaped quote inside the sentence")
    func handlesEscapedQuoteInsideSentence() {
        let detail = "bridge error REFEED_REQUIRED: refused [some-id] "
            + "{\"probable_cause\": \"the film has a \\\"double perf\\\" pattern\"}"
        #expect(
            ProbableCauseExtractor.extract(from: detail)
                == "the film has a \"double perf\" pattern"
        )
    }

    @Test("returns nil for a REFEED_REQUIRED with no Rung-3 diagnosis attached")
    func returnsNilWhenNoProbableCausePresent() {
        // The far more common shape: a plain film-shift refusal, no
        // diagnostics dict at all.
        let plainRefeed =
            "bridge error REFEED_REQUIRED: preview could not establish a "
            + "usable roll session; refeed the strip and try again"
        #expect(ProbableCauseExtractor.extract(from: plainRefeed) == nil)
    }

    @Test("returns nil for an unrelated error message")
    func returnsNilForUnrelatedMessage() {
        #expect(ProbableCauseExtractor.extract(from: "NOT_CONNECTED: scanner is not connected") == nil)
    }

    // MARK: - S8 (adversarial review round 2, 2026-08-08): last-object-only,
    // never first-match-anywhere

    @Test("picks the LAST JSON object's probable_cause, never an earlier lookalike")
    func picksTheLastJSONObjectNotAnEarlierOne() {
        // Two JSON-shaped objects in the same string: an earlier, unrelated
        // one (e.g. an echoed device/firmware diagnostic block) and the
        // real trailing diagnostics blob. Only the real, LAST one may win.
        let detail = """
            bridge error REFEED_REQUIRED: device reported {"probable_cause": "decoy: earlier lookalike object, never the real diagnosis"} during setup; \
            transport read was not one uniform traversal [gap-lattice-anchor] {"probable_cause": "the real diagnosis: half-frame film detected"}
            """
        #expect(
            ProbableCauseExtractor.extract(from: detail)
                == "the real diagnosis: half-frame film detected"
        )
    }

    @Test("an object with no probable_cause key after a real one is not what wins")
    func lastObjectWithoutTheKeyYieldsNilEvenWithAnEarlierRealOne() {
        // The LAST top-level object is authoritative -- if it has no
        // probable_cause key, this must return nil, not fall back to an
        // earlier object that did have one.
        let detail = """
            bridge error REFEED_REQUIRED: [gap-lattice-anchor] {"probable_cause": "an earlier real-shaped sentence"} then {"unrelated_key": "no diagnosis here"}
            """
        #expect(ProbableCauseExtractor.extract(from: detail) == nil)
    }

    @Test("duplicate probable_cause keys within one object resolve deterministically, never a crash or a blend of both")
    func duplicateKeysWithinOneObjectResolveDeterministically() {
        // Real callers never produce this -- `json.dumps` on a Python dict
        // cannot contain a duplicate key in the first place, since a dict
        // cannot hold one. This only proves that a hand-crafted duplicate
        // never crashes and never fabricates a blended/garbled string; the
        // exact winner is `JSONSerialization`'s own deterministic behavior
        // (empirically the first occurrence), not this type's own choice.
        let detail =
            "bridge error REFEED_REQUIRED: refused [some-id] "
            + "{\"probable_cause\": \"first value\", \"probable_cause\": \"second value\"}"
        #expect(ProbableCauseExtractor.extract(from: detail) == "first value")
    }

    @Test("a nested object inside the diagnostics blob does not confuse the outer-object boundary")
    func nestedObjectDoesNotConfuseOuterBoundary() {
        let detail =
            "bridge error REFEED_REQUIRED: refused [some-id] "
            + "{\"context\": {\"nested\": true}, \"probable_cause\": \"the real sentence\"}"
        #expect(ProbableCauseExtractor.extract(from: detail) == "the real sentence")
    }

    @Test("returns nil for an empty string")
    func returnsNilForEmptyString() {
        #expect(ProbableCauseExtractor.extract(from: "") == nil)
    }

    @Test("returns nil when the key is present but truncated before a value")
    func returnsNilForTruncatedDetail() {
        #expect(ProbableCauseExtractor.extract(from: "... {\"probable_cause\": ") == nil)
        #expect(ProbableCauseExtractor.extract(from: "... {\"probable_cause\"") == nil)
    }

    @Test("returns nil rather than an empty sentence")
    func returnsNilForEmptySentenceValue() {
        #expect(ProbableCauseExtractor.extract(from: "{\"probable_cause\": \"\"}") == nil)
    }
}
