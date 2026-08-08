import Foundation

/// Extracts the plain-English `probable_cause` sentence Rung 3 of the
/// feeding UX ladder (FEEDING-UX-LADDER-OVERNIGHT-20260807.md) attaches to
/// a `REFEED_REQUIRED` refusal, out of the raw engine detail text.
///
/// The detail text is never clean top-level JSON: it is CoolscanPy's
/// `IndexDecodeError.__str__` shape (`"<message> [<error-id>] <json
/// diagnostics dict>"`), itself embedded inside more prefix/suffix prose
/// the bridge's `preview()` wraps it in, then embedded again inside the
/// engine's own `"bridge error <CODE>: <message>"` wrapper
/// (`real_backend.rs::map_bridge_error`). A concrete, real shape looks like
/// this (captured from `bridge/tests/test_transport_coolscanpy.py`'s own
/// `test_preview_probable_cause_survives_into_refeed_required_message`):
///
/// ```
/// bridge error REFEED_REQUIRED: transport read was not one uniform
/// traversal; eject or refeed the strip and run the preview again -- if
/// this recurs on clean feeds it may be a capture or driver defect
/// (transport anchor residual is inconsistent with one affine preview
/// traversal (MAE 4.447 rows, max 11.241 rows) [gap-lattice-anchor]
/// {"probable_cause": "this looks like half-frame film (frames about every
/// 19 mm); this driver expects standard 35 mm spacing"})
/// ```
///
/// Adversarial review S8 (2026-08-08) tightened this from an earlier,
/// looser version that took the FIRST textual `"probable_cause"` match
/// anywhere in the string: that could be fooled by a coincidental or
/// attacker-influenced substring earlier in the message (a device/firmware
/// string, a file path, arbitrary echoed input) that merely *looks* like
/// the key, without it belonging to the real trailing diagnostics object at
/// all. This version instead locates the LAST complete, balanced top-level
/// `{...}` object in the string -- exactly where `IndexDecodeError`'s own
/// `json.dumps(diagnostics, sort_keys=True)` always places the real
/// diagnostics blob -- and decodes `probable_cause` out of THAT object
/// through `JSONSerialization`, never by scanning raw text for the key a
/// second time. A key appearing more than once inside that one object (never
/// produced by a real caller -- `json.dumps` on a Python dict cannot contain
/// a duplicate key, since a dict cannot hold one) resolves however
/// `JSONSerialization` itself deterministically resolves it; this type
/// never disambiguates further, and never looks at a SECOND `{...}` object
/// even if one exists earlier in the string.
public enum ProbableCauseExtractor {
    /// The plain-English sentence, or `nil` when `detail` carries no
    /// `probable_cause` diagnostics key inside its own last JSON object
    /// (the common case: most refusals, including most `REFEED_REQUIRED`s,
    /// have no Rung-3 diagnosis attached at all).
    public static func extract(from detail: String) -> String? {
        guard let jsonRange = lastTopLevelJSONObjectRange(in: detail) else { return nil }
        let token = detail[jsonRange]
        guard let data = token.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sentence = parsed["probable_cause"] as? String,
              !sentence.isEmpty
        else {
            return nil
        }
        return sentence
    }

    /// Finds the last complete, balanced top-level `{...}` span in `text` --
    /// a single left-to-right scan that tracks brace depth and string-
    /// literal state (so a `{`/`}`/`"` inside a quoted string, or an
    /// escaped quote, never confuses it), recording a new candidate every
    /// time depth returns to zero after having opened. Whichever candidate
    /// was recorded LAST is the one returned, so an earlier, unrelated
    /// `{...}` elsewhere in the same string is never chosen over the real
    /// trailing diagnostics object.
    private static func lastTopLevelJSONObjectRange(in text: String) -> Range<String.Index>? {
        var depth = 0
        var inString = false
        var escaped = false
        var currentStart: String.Index?
        var lastCandidate: Range<String.Index>?

        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                index = text.index(after: index)
                continue
            }
            switch character {
            case "\"":
                inString = true
            case "{":
                if depth == 0 {
                    currentStart = index
                }
                depth += 1
            case "}":
                if depth > 0 {
                    depth -= 1
                    if depth == 0, let start = currentStart {
                        lastCandidate = start..<text.index(after: index)
                        currentStart = nil
                    }
                }
            default:
                break
            }
            index = text.index(after: index)
        }
        return lastCandidate
    }
}
