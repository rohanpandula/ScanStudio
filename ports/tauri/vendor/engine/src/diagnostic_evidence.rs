//! Bounded, share-safe structural evidence for transport-binding refusals.
//!
//! The scanner-facing guard lives below the engine, so the bridge supplies
//! only a fresh evidence id and a numbers-only witness. The engine binds that
//! value to its already-proven operation/session/device context and exact
//! build identities before anything can reach a client. Invalid or missing
//! evidence is reported separately and never replaces the scanner error.

use std::collections::HashSet;

use serde::{Deserialize, Serialize};

pub const DIAGNOSTIC_EVIDENCE_SCHEMA_VERSION: u32 = 1;
pub const MAX_DIAGNOSTIC_EVIDENCE_BYTES: usize = 16 * 1024;
pub const MAX_DIAGNOSTIC_RECORD_COUNT: u32 = 8_192;
pub const MAX_DIAGNOSTIC_SOURCE_BYTES: u64 = 8 * 1024 * 1024;
pub const MAX_DIAGNOSTIC_ANCHORS: usize = 40;

const MAX_ID_BYTES: usize = 128;
const MAX_BUILD_ID_BYTES: usize = 128;
const MAX_DEVICE_LABEL_BYTES: usize = 96;
const MAX_ABSOLUTE_ROW_VALUE: f64 = 1_000_000_000.0;
const MAX_RESIDUAL_THRESHOLD_ROWS: f64 = 1_000.0;

#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum DiagnosticOperationKind {
    Preview,
    ScanBinding,
}

#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum DiagnosticHolder {
    Mounted,
    Strip6,
    Roll36,
}

impl DiagnosticHolder {
    pub(crate) fn capacity(self) -> u32 {
        match self {
            Self::Mounted => 1,
            Self::Strip6 => 6,
            Self::Roll36 => 40,
        }
    }
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DiagnosticEvidenceReference {
    pub schema_version: u32,
    pub evidence_id: String,
    pub operation_id: String,
    /// Decimal engine session epoch encoded as a string so JavaScript clients
    /// never lose integer precision.
    pub session_epoch: String,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DiagnosticBuildIdentities {
    pub app: String,
    pub engine: String,
    pub bridge: String,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DiagnosticDevice {
    pub model: String,
    pub adapter: String,
    pub holder: DiagnosticHolder,
}

#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum DiagnosticParity {
    Even,
    Odd,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DiagnosticMismatchLocation {
    pub record_index: u32,
    pub byte_offset: u64,
}

/// Counts only. It intentionally cannot represent an RGB value, raw excerpt,
/// transport record, path, serial, or stable film-derived identifier.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TerminalPaddingWitness {
    pub record_count: u32,
    pub byte_count: u64,
    pub parity: DiagnosticParity,
    pub housekeeping_byte_count: u32,
    pub nonzero_rgb_count: u32,
    pub mismatch_location: DiagnosticMismatchLocation,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DiagnosticAffineAnchor {
    pub ordinal: u32,
    pub input_row: f64,
    pub observed_row: f64,
    pub fitted_row: f64,
    pub residual_rows: f64,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DiagnosticAffineTransform {
    pub slope: f64,
    pub intercept: f64,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DiagnosticAffineThresholds {
    pub maximum_mean_absolute_residual_rows: f64,
    pub maximum_residual_rows: f64,
}

/// A selected, holder-bounded set of anchors. Aggregate residual values are
/// retained separately because a bridge may select only the diagnostically
/// useful anchors rather than publish the complete transport table.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AffineWitness {
    pub holder_capacity: u32,
    pub anchors: Vec<DiagnosticAffineAnchor>,
    pub transform: DiagnosticAffineTransform,
    pub thresholds: DiagnosticAffineThresholds,
    pub mean_absolute_residual_rows: f64,
    pub maximum_residual_rows: f64,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub enum DiagnosticWitness {
    TerminalPadding(TerminalPaddingWitness),
    Affine(AffineWitness),
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DiagnosticEvidence {
    pub schema_version: u32,
    pub evidence_id: String,
    pub operation_id: String,
    pub session_epoch: String,
    pub operation_kind: DiagnosticOperationKind,
    pub builds: DiagnosticBuildIdentities,
    pub device: DiagnosticDevice,
    pub witness: DiagnosticWitness,
}

impl DiagnosticEvidence {
    pub fn reference(&self) -> DiagnosticEvidenceReference {
        DiagnosticEvidenceReference {
            schema_version: self.schema_version,
            evidence_id: self.evidence_id.clone(),
            operation_id: self.operation_id.clone(),
            session_epoch: self.session_epoch.clone(),
        }
    }
}

/// Bridge-authored portion. The bridge is not allowed to choose an app,
/// engine, operation, session, model, adapter, or holder identity; those are
/// bound from engine-owned context after the event crosses the active-session
/// ownership proof.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BridgeDiagnosticEvidence {
    pub schema_version: u32,
    pub evidence_id: String,
    pub witness: DiagnosticWitness,
}

#[derive(Debug, Clone)]
pub(crate) struct DiagnosticEvidenceContext<'a> {
    pub operation_id: Option<&'a str>,
    pub session_epoch: u64,
    pub operation_kind: DiagnosticOperationKind,
    pub app_build: Option<&'a str>,
    pub engine_build: &'a str,
    pub bridge_build: &'a str,
    pub model: &'a str,
    pub adapter: Option<&'a str>,
    pub holder: Option<DiagnosticHolder>,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub(crate) struct DiagnosticEvidenceBinding {
    pub evidence: Option<DiagnosticEvidence>,
    pub unavailable_reason: Option<String>,
}

impl DiagnosticEvidenceBinding {
    pub(crate) fn reference(&self) -> Option<DiagnosticEvidenceReference> {
        self.evidence.as_ref().map(DiagnosticEvidence::reference)
    }
}

/// Binds one bridge witness to the exact operation. `expected` is true only
/// for the #42/#43/#68 failure family; absence on unrelated errors remains
/// byte-compatible with older clients.
pub(crate) fn bind_bridge_diagnostic_evidence(
    raw: Option<&serde_json::Value>,
    expected: bool,
    context: DiagnosticEvidenceContext<'_>,
) -> DiagnosticEvidenceBinding {
    if !expected {
        return DiagnosticEvidenceBinding::default();
    }
    let Some(raw) = raw else {
        return DiagnosticEvidenceBinding {
            evidence: None,
            unavailable_reason: expected.then(|| {
                "the failing transport guard did not provide bounded diagnostic evidence"
                    .to_string()
            }),
        };
    };

    match bind_bridge_diagnostic_evidence_inner(raw, context) {
        Ok(evidence) => DiagnosticEvidenceBinding {
            evidence: Some(evidence),
            unavailable_reason: None,
        },
        Err(reason) => DiagnosticEvidenceBinding {
            evidence: None,
            unavailable_reason: Some(format!(
                "bounded diagnostic evidence was unavailable: {reason}"
            )),
        },
    }
}

fn bind_bridge_diagnostic_evidence_inner(
    raw: &serde_json::Value,
    context: DiagnosticEvidenceContext<'_>,
) -> Result<DiagnosticEvidence, String> {
    let raw_bytes =
        serde_json::to_vec(raw).map_err(|_| "bridge evidence could not be measured".to_string())?;
    if raw_bytes.len() > MAX_DIAGNOSTIC_EVIDENCE_BYTES {
        return Err(format!(
            "bridge evidence exceeded the {MAX_DIAGNOSTIC_EVIDENCE_BYTES}-byte limit"
        ));
    }
    let source: BridgeDiagnosticEvidence = serde_json::from_slice(&raw_bytes)
        .map_err(|_| "bridge evidence did not match schema version 1".to_string())?;

    let operation_id = context
        .operation_id
        .filter(|value| valid_identifier(value))
        .ok_or_else(|| "the engine had no bounded operation id to bind".to_string())?;
    if context.session_epoch == 0 {
        return Err("the engine had no active session epoch to bind".to_string());
    }
    let app_build = context
        .app_build
        .filter(|value| valid_build_identity(value))
        .ok_or_else(|| "the client did not report a bounded app build identity".to_string())?;
    if !valid_build_identity(context.engine_build) {
        return Err("the engine build identity was invalid".to_string());
    }
    if !valid_build_identity(context.bridge_build) {
        return Err("the bridge build identity was invalid".to_string());
    }
    if !valid_device_label(context.model) {
        return Err("the engine device model was invalid".to_string());
    }
    let adapter = context
        .adapter
        .filter(|value| valid_device_label(value))
        .ok_or_else(|| "the engine had no bounded adapter identity to bind".to_string())?;
    let holder = context
        .holder
        .ok_or_else(|| "the engine had no bounded holder identity to bind".to_string())?;

    let evidence = DiagnosticEvidence {
        schema_version: source.schema_version,
        evidence_id: source.evidence_id,
        operation_id: operation_id.to_string(),
        session_epoch: context.session_epoch.to_string(),
        operation_kind: context.operation_kind,
        builds: DiagnosticBuildIdentities {
            app: app_build.to_string(),
            engine: context.engine_build.to_string(),
            bridge: context.bridge_build.to_string(),
        },
        device: DiagnosticDevice {
            model: context.model.to_string(),
            adapter: adapter.to_string(),
            holder,
        },
        witness: source.witness,
    };
    validate_diagnostic_evidence(&evidence)?;
    Ok(evidence)
}

pub fn validate_diagnostic_evidence(evidence: &DiagnosticEvidence) -> Result<(), String> {
    if evidence.schema_version != DIAGNOSTIC_EVIDENCE_SCHEMA_VERSION {
        return Err("unsupported diagnostic evidence schema version".to_string());
    }
    if !valid_identifier(&evidence.evidence_id) {
        return Err("evidenceId was empty, oversized, or contained unsafe characters".to_string());
    }
    if !valid_identifier(&evidence.operation_id) {
        return Err("operationId was empty, oversized, or contained unsafe characters".to_string());
    }
    if evidence
        .session_epoch
        .parse::<u64>()
        .ok()
        .filter(|v| *v > 0)
        .is_none()
    {
        return Err("sessionEpoch was not a positive decimal engine epoch".to_string());
    }
    for (name, value) in [
        ("app", evidence.builds.app.as_str()),
        ("engine", evidence.builds.engine.as_str()),
        ("bridge", evidence.builds.bridge.as_str()),
    ] {
        if !valid_build_identity(value) {
            return Err(format!("{name} build identity was invalid"));
        }
    }
    if !valid_device_label(&evidence.device.model) || !valid_device_label(&evidence.device.adapter)
    {
        return Err("device labels were empty, oversized, or unsafe".to_string());
    }

    match &evidence.witness {
        DiagnosticWitness::TerminalPadding(witness) => validate_terminal_padding(witness)?,
        DiagnosticWitness::Affine(witness) => validate_affine(witness, evidence.device.holder)?,
    }

    let bytes = serde_json::to_vec(evidence)
        .map_err(|_| "diagnostic evidence could not be serialized".to_string())?;
    if bytes.len() > MAX_DIAGNOSTIC_EVIDENCE_BYTES {
        return Err(format!(
            "diagnostic evidence exceeded the {MAX_DIAGNOSTIC_EVIDENCE_BYTES}-byte limit"
        ));
    }
    Ok(())
}

fn validate_terminal_padding(witness: &TerminalPaddingWitness) -> Result<(), String> {
    if witness.record_count == 0 || witness.record_count > MAX_DIAGNOSTIC_RECORD_COUNT {
        return Err(format!(
            "terminal recordCount was outside 1..={MAX_DIAGNOSTIC_RECORD_COUNT}"
        ));
    }
    if witness.byte_count == 0 || witness.byte_count > MAX_DIAGNOSTIC_SOURCE_BYTES {
        return Err(format!(
            "terminal byteCount was outside 1..={MAX_DIAGNOSTIC_SOURCE_BYTES}"
        ));
    }
    if u64::from(witness.housekeeping_byte_count) > witness.byte_count {
        return Err("housekeepingByteCount exceeded byteCount".to_string());
    }
    let maximum_rgb_samples = u64::from(witness.record_count) * 96 * 3;
    if u64::from(witness.nonzero_rgb_count) > maximum_rgb_samples {
        return Err("nonzeroRgbCount exceeded the bounded record geometry".to_string());
    }
    if witness.mismatch_location.record_index >= witness.record_count
        || witness.mismatch_location.byte_offset >= witness.byte_count
    {
        return Err("terminal mismatchLocation was outside the bounded source".to_string());
    }
    Ok(())
}

fn validate_affine(witness: &AffineWitness, holder: DiagnosticHolder) -> Result<(), String> {
    let expected_capacity = holder.capacity();
    if witness.holder_capacity != expected_capacity {
        return Err("affine holderCapacity did not match the engine-bound holder".to_string());
    }
    if witness.anchors.len() < 3
        || witness.anchors.len() > MAX_DIAGNOSTIC_ANCHORS
        || witness.anchors.len() > witness.holder_capacity as usize
    {
        return Err("affine anchors were outside the three-to-holder-capacity bound".to_string());
    }
    let mut ordinals = HashSet::with_capacity(witness.anchors.len());
    for anchor in &witness.anchors {
        if anchor.ordinal >= witness.holder_capacity || !ordinals.insert(anchor.ordinal) {
            return Err(
                "affine anchor ordinals were duplicate or outside holderCapacity".to_string(),
            );
        }
        for value in [
            anchor.input_row,
            anchor.observed_row,
            anchor.fitted_row,
            anchor.residual_rows,
        ] {
            if !finite_bounded(value) {
                return Err("affine anchor contained an invalid numeric value".to_string());
            }
        }
        let expected_fitted =
            witness.transform.intercept + witness.transform.slope * anchor.input_row;
        let expected_residual =
            (expected_fitted - anchor.observed_row) / witness.transform.slope;
        if (expected_fitted - anchor.fitted_row).abs() > 0.01 {
            return Err("affine fittedRow did not match the reported transform".to_string());
        }
        if (expected_residual - anchor.residual_rows).abs() > 0.01 {
            return Err("affine residualRows did not replay from the transform".to_string());
        }
    }
    if !finite_bounded(witness.transform.slope)
        || witness.transform.slope <= 0.0
        || !finite_bounded(witness.transform.intercept)
    {
        return Err("affine transform was invalid".to_string());
    }
    for threshold in [
        witness.thresholds.maximum_mean_absolute_residual_rows,
        witness.thresholds.maximum_residual_rows,
    ] {
        if !threshold.is_finite() || threshold <= 0.0 || threshold > MAX_RESIDUAL_THRESHOLD_ROWS {
            return Err("affine threshold was invalid".to_string());
        }
    }
    for aggregate in [
        witness.mean_absolute_residual_rows,
        witness.maximum_residual_rows,
    ] {
        if !aggregate.is_finite() || aggregate < 0.0 || aggregate > MAX_RESIDUAL_THRESHOLD_ROWS {
            return Err("affine aggregate residual was invalid".to_string());
        }
    }
    if witness.mean_absolute_residual_rows > witness.maximum_residual_rows {
        return Err("affine mean residual exceeded maximum residual".to_string());
    }
    let calculated_mean = witness
        .anchors
        .iter()
        .map(|anchor| anchor.residual_rows.abs())
        .sum::<f64>()
        / witness.anchors.len() as f64;
    let calculated_maximum = witness
        .anchors
        .iter()
        .map(|anchor| anchor.residual_rows.abs())
        .fold(0.0_f64, f64::max);
    if (calculated_mean - witness.mean_absolute_residual_rows).abs() > 0.01 {
        return Err("affine mean residual did not match its anchors".to_string());
    }
    if (calculated_maximum - witness.maximum_residual_rows).abs() > 0.01 {
        return Err("affine maximum residual did not match its anchors".to_string());
    }
    if witness.mean_absolute_residual_rows
        <= witness.thresholds.maximum_mean_absolute_residual_rows
        && witness.maximum_residual_rows <= witness.thresholds.maximum_residual_rows
    {
        return Err("affine witness did not reproduce a refusal".to_string());
    }
    Ok(())
}

fn finite_bounded(value: f64) -> bool {
    value.is_finite() && value.abs() <= MAX_ABSOLUTE_ROW_VALUE
}

fn valid_identifier(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= MAX_ID_BYTES
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b':'))
}

fn valid_build_identity(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= MAX_BUILD_ID_BYTES
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b'+'))
}

fn valid_device_label(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= MAX_DEVICE_LABEL_BYTES
        && value
            .bytes()
            .all(|byte| byte.is_ascii_graphic() || byte == b' ')
        && !value.bytes().any(|byte| matches!(byte, b'/' | b'\\'))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn context<'a>(holder: DiagnosticHolder) -> DiagnosticEvidenceContext<'a> {
        DiagnosticEvidenceContext {
            operation_id: Some("preview-42"),
            session_epoch: 42,
            operation_kind: DiagnosticOperationKind::Preview,
            app_build: Some("0.7.0-beta.14+abc1234"),
            engine_build: "0.1.0+def5678",
            bridge_build: "0.4.0+987abcd",
            model: "SUPER COOLSCAN 5000 ED",
            adapter: Some(match holder {
                DiagnosticHolder::Mounted => "MA-21",
                DiagnosticHolder::Strip6 => "SA-21",
                DiagnosticHolder::Roll36 => "SA-30",
            }),
            holder: Some(holder),
        }
    }

    fn affine_source(maximum: f64, mean: f64) -> serde_json::Value {
        let residuals: Vec<f64> = if maximum > 10.0 {
            vec![21.975, 5.0, 3.0, 3.117]
        } else {
            vec![3.005, 0.2, 0.2, 0.2, 0.137, 0.2]
        };
        let anchors: Vec<serde_json::Value> = residuals
            .iter()
            .enumerate()
            .map(|(ordinal, residual)| {
                let input = ordinal as f64 * 10.0;
                let fitted = input * 42.0;
                json!({
                    "ordinal": ordinal,
                    "inputRow": input,
                    "observedRow": fitted - residual * 42.0,
                    "fittedRow": fitted,
                    "residualRows": residual
                })
            })
            .collect();
        json!({
            "schemaVersion": 1,
            "evidenceId": "evidence-42-affine",
            "witness": {
                "kind": "affine",
                "holderCapacity": 40,
                "anchors": anchors,
                "transform": {"slope": 42.0, "intercept": 0.0},
                "thresholds": {
                    "maximumMeanAbsoluteResidualRows": 0.5,
                    "maximumResidualRows": 3.0
                },
                "meanAbsoluteResidualRows": mean,
                "maximumResidualRows": maximum
            }
        })
    }

    #[test]
    fn affine_evidence_binds_exact_attempt_and_reproduces_42_and_68_decisions() {
        for (maximum, mean, rejected) in [(3.005, 0.657, true), (21.975, 8.273, true)] {
            let binding = bind_bridge_diagnostic_evidence(
                Some(&affine_source(maximum, mean)),
                true,
                context(DiagnosticHolder::Roll36),
            );
            let evidence = binding.evidence.expect("valid bounded evidence");
            assert_eq!(evidence.operation_id, "preview-42");
            assert_eq!(evidence.session_epoch, "42");
            assert_eq!(evidence.builds.app, "0.7.0-beta.14+abc1234");
            let DiagnosticWitness::Affine(witness) = evidence.witness else {
                panic!("expected affine witness")
            };
            let actual_rejection = witness.mean_absolute_residual_rows
                > witness.thresholds.maximum_mean_absolute_residual_rows
                || witness.maximum_residual_rows > witness.thresholds.maximum_residual_rows;
            assert_eq!(actual_rejection, rejected);
        }
    }

    #[test]
    fn terminal_padding_evidence_is_counts_only_and_reproduces_43_mismatch() {
        let raw = json!({
            "schemaVersion": 1,
            "evidenceId": "evidence-43-terminal-padding",
            "witness": {
                "kind": "terminalPadding",
                "recordCount": 91,
                "byteCount": 5824,
                "parity": "even",
                "housekeepingByteCount": 448,
                "nonzeroRgbCount": 1,
                "mismatchLocation": {"recordIndex": 90, "byteOffset": 5760}
            }
        });
        let binding =
            bind_bridge_diagnostic_evidence(Some(&raw), true, context(DiagnosticHolder::Strip6));
        let evidence = binding.evidence.expect("valid bounded evidence");
        let serialized = serde_json::to_string(&evidence).expect("serialize evidence");
        assert!(!serialized.contains("rgbValues"));
        assert!(!serialized.contains("transportTable"));
        assert!(!serialized.contains("path"));
        assert!(!serialized.contains("serial"));
        assert!(matches!(
            evidence.witness,
            DiagnosticWitness::TerminalPadding(TerminalPaddingWitness {
                nonzero_rgb_count: 1,
                ..
            })
        ));
    }

    #[test]
    fn privacy_fields_unknown_schema_and_hard_bounds_fail_before_publication() {
        for forbidden in ["serial", "path", "rawExcerpt", "completeTransportTable"] {
            let mut raw = affine_source(3.005, 0.657);
            raw.as_object_mut()
                .expect("object")
                .insert(forbidden.to_string(), json!("private"));
            let binding = bind_bridge_diagnostic_evidence(
                Some(&raw),
                true,
                context(DiagnosticHolder::Roll36),
            );
            assert!(binding.evidence.is_none(), "{forbidden} must be rejected");
            assert!(binding.unavailable_reason.is_some());
        }

        let mut excess_anchors = affine_source(3.005, 0.657);
        let anchors = excess_anchors
            .pointer_mut("/witness/anchors")
            .and_then(serde_json::Value::as_array_mut)
            .expect("anchors");
        while anchors.len() <= MAX_DIAGNOSTIC_ANCHORS {
            let ordinal = anchors.len();
            anchors.push(json!({
                "ordinal": ordinal,
                "inputRow": ordinal,
                "observedRow": ordinal,
                "fittedRow": ordinal,
                "residualRows": 0.0
            }));
        }
        assert!(bind_bridge_diagnostic_evidence(
            Some(&excess_anchors),
            true,
            context(DiagnosticHolder::Roll36),
        )
        .evidence
        .is_none());

        let oversized = json!({
            "schemaVersion": 1,
            "evidenceId": "x".repeat(MAX_DIAGNOSTIC_EVIDENCE_BYTES),
            "witness": {"kind": "terminalPadding"}
        });
        assert!(bind_bridge_diagnostic_evidence(
            Some(&oversized),
            true,
            context(DiagnosticHolder::Strip6),
        )
        .evidence
        .is_none());
    }

    #[test]
    fn invalid_or_missing_evidence_never_replaces_the_original_error_contract() {
        let unrelated = bind_bridge_diagnostic_evidence(
            Some(&affine_source(3.005, 0.657)),
            false,
            context(DiagnosticHolder::Roll36),
        );
        assert_eq!(unrelated, DiagnosticEvidenceBinding::default());

        let absent = bind_bridge_diagnostic_evidence(None, true, context(DiagnosticHolder::Roll36));
        assert!(absent.evidence.is_none());
        assert!(absent
            .unavailable_reason
            .as_deref()
            .is_some_and(|reason| reason.contains("did not provide")));

        let missing_app = bind_bridge_diagnostic_evidence(
            Some(&affine_source(3.005, 0.657)),
            true,
            DiagnosticEvidenceContext {
                app_build: None,
                ..context(DiagnosticHolder::Roll36)
            },
        );
        assert!(missing_app.evidence.is_none());
        assert!(missing_app
            .unavailable_reason
            .as_deref()
            .is_some_and(|reason| reason.contains("app build")));
    }

    #[test]
    fn shared_protocol_fixture_corpus_decodes_and_replays() {
        for source in [
            include_str!("../../protocol/fixtures/diagnostic-evidence-v1/evidence-42-affine.json"),
            include_str!("../../protocol/fixtures/diagnostic-evidence-v1/evidence-43-terminal-padding.json"),
            include_str!("../../protocol/fixtures/diagnostic-evidence-v1/evidence-68-affine.json"),
        ] {
            let evidence: DiagnosticEvidence =
                serde_json::from_str(source).expect("shared fixture must match Rust schema");
            match &evidence.witness {
                DiagnosticWitness::Affine(witness) => {
                    validate_affine(witness, evidence.device.holder)
                        .expect("shared affine fixture must replay");
                }
                DiagnosticWitness::TerminalPadding(witness) => {
                    validate_terminal_padding(witness)
                        .expect("shared terminal fixture must replay");
                }
            }
        }
    }

    #[test]
    fn reference_selects_the_exact_artifact_not_a_newer_operation() {
        let first = bind_bridge_diagnostic_evidence(
            Some(&affine_source(3.005, 0.657)),
            true,
            context(DiagnosticHolder::Roll36),
        )
        .evidence
        .expect("first evidence");
        let mut second_context = context(DiagnosticHolder::Roll36);
        second_context.operation_id = Some("preview-newer");
        second_context.session_epoch = 43;
        let second = bind_bridge_diagnostic_evidence(
            Some(&affine_source(3.005, 0.657)),
            true,
            second_context,
        )
        .evidence
        .expect("second evidence");

        assert_ne!(first.reference(), second.reference());
        assert_eq!(first.reference().operation_id, "preview-42");
        assert_eq!(first.reference().session_epoch, "42");
    }
}
