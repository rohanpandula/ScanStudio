//! Read-only receipt checks used by the calibration CLI.
//!
//! This module deliberately does not read or write files. Collection owns
//! artifact copying; callers that need that check must provide a separate
//! filesystem authority instead of treating receipt paths as authority.

use serde::{Deserialize, Serialize};

use crate::domain::{HardwareTelemetry, ScanProject, ScanReceipt};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum VerificationStatus {
    Pass,
    Fail,
    Unknown,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VerificationIssue {
    pub status: VerificationStatus,
    pub job_id: Option<String>,
    pub frame_index: Option<u32>,
    pub field: String,
    pub detail: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VerificationReport {
    pub status: VerificationStatus,
    pub exposure_identical: bool,
    pub no_clipping: bool,
    pub checked_receipts: usize,
    pub issues: Vec<VerificationIssue>,
}

/// Verifies the requested receipt properties without changing the project.
/// `selected_job_ids` is an optional caller-resolved pass selection; `None`
/// checks every receipt in the project. An empty selection is unknown rather
/// than a false pass.
pub fn verify(
    project: &ScanProject,
    selected_job_ids: Option<&[String]>,
    exposure_identical: bool,
    no_clipping: bool,
) -> VerificationReport {
    let selected = |receipt: &&ScanReceipt| {
        selected_job_ids.is_none_or(|ids| ids.iter().any(|id| id == &receipt.job_id))
    };
    let receipts: Vec<&ScanReceipt> = project
        .frames
        .iter()
        .flat_map(|frame| frame.receipts.iter())
        .filter(selected)
        .collect();
    let mut issues = Vec::new();

    if receipts.is_empty() {
        issues.push(issue(
            VerificationStatus::Unknown,
            None,
            None,
            "receipts",
            "no receipts matched the selected job IDs",
        ));
    }

    if exposure_identical {
        verify_exposure(&receipts, &mut issues);
    }
    if no_clipping {
        verify_clipping(&receipts, &mut issues);
    }

    let status = if issues
        .iter()
        .any(|entry| entry.status == VerificationStatus::Fail)
    {
        VerificationStatus::Fail
    } else if issues
        .iter()
        .any(|entry| entry.status == VerificationStatus::Unknown)
    {
        VerificationStatus::Unknown
    } else {
        VerificationStatus::Pass
    };

    VerificationReport {
        status,
        exposure_identical,
        no_clipping,
        checked_receipts: receipts.len(),
        issues,
    }
}

fn verify_exposure(receipts: &[&ScanReceipt], issues: &mut Vec<VerificationIssue>) {
    let mut baseline: Option<(&ScanReceipt, [u32; 3])> = None;
    for receipt in receipts {
        let Some(authority) = receipt.exposure_authority.as_ref() else {
            issues.push(issue(
                VerificationStatus::Unknown,
                Some(receipt.job_id.clone()),
                Some(receipt.frame_index),
                "exposureAuthority",
                "receipt has no exposure authority evidence",
            ));
            continue;
        };

        let Some(values) = rgb_commanded(authority, receipt, issues) else {
            continue;
        };
        if let Some((first, expected)) = baseline {
            for (channel, actual, expected) in [
                ("R", values[0], expected[0]),
                ("G", values[1], expected[1]),
                ("B", values[2], expected[2]),
            ] {
                if actual != expected {
                    issues.push(issue(
                        VerificationStatus::Fail,
                        Some(receipt.job_id.clone()),
                        Some(receipt.frame_index),
                        format!("exposureAuthority.commandedChannelsRaw10ns.{channel}"),
                        format!(
                            "{channel} is {actual} ticks; frame {} job {} is the baseline at {expected} ticks",
                            first.frame_index, first.job_id
                        ),
                    ));
                }
            }
        } else {
            baseline = Some((receipt, values));
        }
    }
}

fn rgb_commanded(
    authority: &crate::domain::ExposureAuthority,
    receipt: &ScanReceipt,
    issues: &mut Vec<VerificationIssue>,
) -> Option<[u32; 3]> {
    let [minimum, maximum] = authority.device_exposure_bounds_raw_10ns;
    if minimum == 0 || maximum < minimum {
        issues.push(issue(
            VerificationStatus::Unknown,
            Some(receipt.job_id.clone()),
            Some(receipt.frame_index),
            "exposureAuthority.deviceExposureBoundsRaw10ns",
            "receipt has malformed or zero-inclusive device exposure bounds",
        ));
        return None;
    }
    let mut values = [0; 3];
    for (index, channel) in ["R", "G", "B"].into_iter().enumerate() {
        let Some(value) = authority.commanded_channels_raw_10ns.get(channel) else {
            issues.push(issue(
                VerificationStatus::Unknown,
                Some(receipt.job_id.clone()),
                Some(receipt.frame_index),
                format!("exposureAuthority.commandedChannelsRaw10ns.{channel}"),
                "receipt omits a commanded RGB channel",
            ));
            return None;
        };
        if *value == 0 || *value < minimum || *value > maximum {
            issues.push(issue(
                VerificationStatus::Unknown,
                Some(receipt.job_id.clone()),
                Some(receipt.frame_index),
                format!("exposureAuthority.commandedChannelsRaw10ns.{channel}"),
                format!(
                    "commanded {channel} value {value} is outside the nonzero device bounds [{minimum}, {maximum}]"
                ),
            ));
            return None;
        }
        values[index] = *value;
    }
    Some(values)
}

fn verify_clipping(receipts: &[&ScanReceipt], issues: &mut Vec<VerificationIssue>) {
    for receipt in receipts {
        let Some(telemetry) = receipt.hardware_telemetry.as_ref() else {
            issues.push(issue(
                VerificationStatus::Unknown,
                Some(receipt.job_id.clone()),
                Some(receipt.frame_index),
                "hardwareTelemetry.clipping",
                "receipt has no clipping telemetry",
            ));
            continue;
        };
        verify_clipping_telemetry(receipt, telemetry, issues);
    }
}

fn verify_clipping_telemetry(
    receipt: &ScanReceipt,
    telemetry: &HardwareTelemetry,
    issues: &mut Vec<VerificationIssue>,
) {
    let clipping = &telemetry.clipping;
    let finite = clipping.clip_level.is_finite()
        && clipping.warning_fraction.is_finite()
        && (0.0..=1.0).contains(&clipping.clip_level)
        && (0.0..=1.0).contains(&clipping.warning_fraction)
        && [
            clipping.fractions.0,
            clipping.fractions.1,
            clipping.fractions.2,
        ]
        .into_iter()
        .all(|fraction| fraction.is_finite() && (0.0..=1.0).contains(&fraction));
    if !finite {
        issues.push(issue(
            VerificationStatus::Unknown,
            Some(receipt.job_id.clone()),
            Some(receipt.frame_index),
            "hardwareTelemetry.clipping",
            "clipping telemetry is malformed or non-finite",
        ));
    } else if clipping.warning {
        issues.push(issue(
            VerificationStatus::Fail,
            Some(receipt.job_id.clone()),
            Some(receipt.frame_index),
            "hardwareTelemetry.clipping.warning",
            "receipt reports a clipping warning",
        ));
    } else if [
        clipping.fractions.0,
        clipping.fractions.1,
        clipping.fractions.2,
    ]
    .into_iter()
    .any(|fraction| fraction >= clipping.warning_fraction)
    {
        issues.push(issue(
            VerificationStatus::Fail,
            Some(receipt.job_id.clone()),
            Some(receipt.frame_index),
            "hardwareTelemetry.clipping.warning",
            "clipping fractions meet or exceed the warning threshold while warning is false",
        ));
    }
}

fn issue(
    status: VerificationStatus,
    job_id: Option<String>,
    frame_index: Option<u32>,
    field: impl Into<String>,
    detail: impl Into<String>,
) -> VerificationIssue {
    VerificationIssue {
        status,
        job_id,
        frame_index,
        field: field.into(),
        detail: detail.into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::{
        CaptureRecipe, ClippingTelemetry, ExposureAuthority, ExposureVector, FilmProcess,
        FocusDetailTelemetry, FrameAlignment, HardwareVerification, MetadataSet, OutputRecipe,
        ProjectFrame, ScanProject, TransportSmearAssessment,
    };
    use std::collections::BTreeMap;

    fn authority(rgb: [u32; 3]) -> ExposureAuthority {
        let commanded_channels_raw_10ns = BTreeMap::from([
            ("R".into(), rgb[0]),
            ("G".into(), rgb[1]),
            ("B".into(), rgb[2]),
        ]);
        ExposureAuthority {
            rgb_source: "locked".into(),
            ir_source: "metered".into(),
            commanded_channels_raw_10ns,
            active_controller_channels_raw_10ns: BTreeMap::new(),
            device_bound_clamped_channels_raw_10ns: BTreeMap::new(),
            device_exposure_bounds_raw_10ns: [1, 100_000],
        }
    }

    fn telemetry(warning: bool) -> HardwareTelemetry {
        HardwareTelemetry {
            exposure: ExposureVector {
                focus_position: 1,
                exposure_multiplier: 1.0,
                red_exposure_us: 10.0,
                green_exposure_us: 10.0,
                blue_exposure_us: 10.0,
            },
            clipping: ClippingTelemetry {
                fractions: (0.0, 0.0, 0.0),
                clip_level: 0.995,
                warning_fraction: 0.01,
                warning,
            },
            focus_detail: FocusDetailTelemetry {
                method: "test".into(),
                verdict: "pass".into(),
                score: Some(1.0),
                texture_span: 1.0,
            },
            transport_smear: TransportSmearAssessment {
                verdict: "clean".into(),
                start_row: None,
                suffix_rows: 0,
                minimum_matches: 0,
                tail_median_rms: None,
                tail_min_corr: None,
                pre_tail_median_rms: None,
                texture_span: None,
                reason: "test".into(),
            },
        }
    }

    fn receipt(
        job_id: &str,
        frame_index: u32,
        rgb: Option<[u32; 3]>,
        clipping_warning: bool,
    ) -> ScanReceipt {
        ScanReceipt {
            job_id: job_id.into(),
            pass_token: None,
            frame_index,
            started_at: "2026-09-08T00:00:00Z".into(),
            duration_ms: 1,
            passes: 1,
            resolution_dpi: 4000,
            bit_depth: 16,
            channels: "rgbi".into(),
            engine_version: "test".into(),
            device_id: "sim-ls5000-0".into(),
            device_model: Some("SUPER COOLSCAN 5000 ED".into()),
            hardware_verification: HardwareVerification::Verified,
            simulated: false,
            settings_fingerprint: "settings".into(),
            processing: None,
            output: None,
            outputs: None,
            rgb_path: None,
            ir_path: None,
            storage_transform: None,
            meter_rgbi_path: None,
            hardware_telemetry: Some(telemetry(clipping_warning)),
            nikonlook: None,
            auto_crop: None,
            exposure_authority: rgb.map(authority),
        }
    }

    fn project(receipts: Vec<ScanReceipt>) -> ScanProject {
        ScanProject {
            schema_version: 1,
            id: "project".into(),
            name: "test".into(),
            carrier: crate::domain::MediaCarrier::Roll36,
            frame_count: receipts.len() as u32,
            film_process: FilmProcess::C41ColorNegative,
            recipes: OutputRecipe::default(),
            roll_metadata: MetadataSet::default(),
            created_at: "2026-09-08T00:00:00Z".into(),
            frames: receipts
                .into_iter()
                .map(|receipt| ProjectFrame {
                    index: receipt.frame_index,
                    excluded: false,
                    capture_override: Some(CaptureRecipe::default()),
                    processing_override: None,
                    output_override: None,
                    alignment: Some(FrameAlignment::draft(0)),
                    metadata_override: None,
                    receipts: vec![receipt],
                })
                .collect(),
        }
    }

    #[test]
    fn verify_reports_match_mismatch_missing_and_clipping() {
        let matching = project(vec![
            receipt("job-a", 1, Some([10, 20, 30]), false),
            receipt("job-b", 2, Some([10, 20, 30]), false),
        ]);
        let report = verify(&matching, None, true, true);
        assert_eq!(report.status, VerificationStatus::Pass);
        assert_eq!(report.checked_receipts, 2);

        let mismatch = project(vec![
            receipt("job-a", 1, Some([10, 20, 30]), false),
            receipt("job-b", 2, Some([10, 21, 30]), false),
        ]);
        let report = verify(&mismatch, None, true, false);
        assert_eq!(report.status, VerificationStatus::Fail);
        assert!(report
            .issues
            .iter()
            .any(|issue| issue.field.ends_with(".G")));

        let missing = project(vec![receipt("job-a", 1, None, false)]);
        let report = verify(&missing, None, true, true);
        assert_eq!(report.status, VerificationStatus::Unknown);

        let clipped = project(vec![receipt("job-a", 1, Some([10, 20, 30]), true)]);
        let report = verify(&clipped, None, false, true);
        assert_eq!(report.status, VerificationStatus::Fail);
        assert!(report
            .issues
            .iter()
            .any(|issue| issue.field == "hardwareTelemetry.clipping.warning"));

        let mut inconsistent = receipt("job-a", 1, Some([10, 20, 30]), false);
        inconsistent
            .hardware_telemetry
            .as_mut()
            .unwrap()
            .clipping
            .fractions = (0.02, 0.0, 0.0);
        let report = verify(&project(vec![inconsistent]), None, false, true);
        assert_eq!(report.status, VerificationStatus::Fail);

        let empty = project(Vec::new());
        let report = verify(&empty, None, false, false);
        assert_eq!(report.status, VerificationStatus::Unknown);
    }
}
