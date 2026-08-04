//! Self-compare and perturbed-negative-control tests for the four parity
//! scorers (color, autocrop, deskew, ICE mask agreement) — proves each
//! scorer's math is directionally correct with small hand-built synthetic
//! fixtures, no file I/O, no corpus (Task 3, plan 13-01).

use scanstudio_engine::parity::image_io::{NormalizedMask, Rgb16Image};
use scanstudio_engine::parity::{
    score_color, score_crop_iou, score_deskew_angle, score_ice_mask_agreement, Rect,
    AUTOCROP_IOU_THRESHOLD, COLOR_DELTA_E76_TOLERANCE, COLOR_PER_CHANNEL_TOLERANCE_U16,
    DESKEW_ANGLE_EPSILON_DEGREES, ICE_MASK_AGREEMENT_THRESHOLD,
};

#[test]
fn score_color_self_compare_is_near_zero_and_under_threshold() {
    let pixels: Vec<[u16; 3]> = vec![
        [10000, 20000, 30000],
        [40000, 50000, 60000],
        [5000, 15000, 25000],
        [60000, 40000, 20000],
    ];
    let candidate = Rgb16Image {
        width: 2,
        height: 2,
        pixels: pixels.clone(),
    };
    let reference = Rgb16Image {
        width: 2,
        height: 2,
        pixels,
    };

    let score = score_color(&candidate, &reference).expect("score_color failed");

    assert_eq!(score.max_channel_diff_u16, 0);
    assert!(
        score.delta_e76 < 1e-9,
        "expected ~0 delta_e76 for identical images, got {}",
        score.delta_e76
    );
    assert!(score.max_channel_diff_u16 < COLOR_PER_CHANNEL_TOLERANCE_U16);
    assert!(score.delta_e76 < COLOR_DELTA_E76_TOLERANCE);
}

#[test]
fn score_color_perturbed_exceeds_both_thresholds() {
    let base_pixel = [32768u16, 32768, 32768];
    let candidate = Rgb16Image {
        width: 2,
        height: 2,
        pixels: vec![base_pixel; 4],
    };
    let mut perturbed_pixels = vec![base_pixel; 4];
    perturbed_pixels[0][0] = base_pixel[0] + 2000; // red channel, one pixel only
    let reference = Rgb16Image {
        width: 2,
        height: 2,
        pixels: perturbed_pixels,
    };

    let score = score_color(&candidate, &reference).expect("score_color failed");

    assert!(
        score.max_channel_diff_u16 > COLOR_PER_CHANNEL_TOLERANCE_U16,
        "max_channel_diff_u16 {} should exceed tolerance {}",
        score.max_channel_diff_u16,
        COLOR_PER_CHANNEL_TOLERANCE_U16
    );
    assert!(
        score.delta_e76 > COLOR_DELTA_E76_TOLERANCE,
        "delta_e76 {} should exceed tolerance {}",
        score.delta_e76,
        COLOR_DELTA_E76_TOLERANCE
    );
}

#[test]
fn score_crop_iou_self_compare_then_perturbed() {
    let reference = Rect {
        x: 0,
        y: 0,
        width: 400,
        height: 400,
    };

    assert_eq!(score_crop_iou(reference, reference), 1.0);

    let shifted = Rect {
        x: 50,
        y: 0,
        width: 400,
        height: 400,
    };
    let iou = score_crop_iou(shifted, reference);
    assert!(
        iou < AUTOCROP_IOU_THRESHOLD,
        "50px shift in a 400x400 frame should drop IoU below {}, got {}",
        AUTOCROP_IOU_THRESHOLD,
        iou
    );
}

#[test]
fn score_deskew_angle_self_compare_then_perturbed() {
    assert_eq!(score_deskew_angle(3.0, 3.0), 0.0);

    let diff = score_deskew_angle(5.0, 3.0);
    assert_eq!(diff, 2.0);
    assert!(diff > DESKEW_ANGLE_EPSILON_DEGREES);
}

#[test]
fn score_ice_mask_agreement_self_compare_then_perturbed() {
    // 3x2 mask: pixels 0 and 3 are "on" (>= 0.5 threshold), rest are "off".
    let on_pixels_0_and_3 = NormalizedMask {
        width: 3,
        height: 2,
        pixels: vec![0.9, 0.1, 0.1, 0.9, 0.1, 0.1],
    };
    let self_score = score_ice_mask_agreement(&on_pixels_0_and_3, &on_pixels_0_and_3, 0.5)
        .expect("score_ice_mask_agreement failed");
    assert_eq!(self_score, 1.0);

    // Same "on" count, but no overlapping index with the first mask.
    let on_pixels_1_and_4 = NormalizedMask {
        width: 3,
        height: 2,
        pixels: vec![0.1, 0.9, 0.1, 0.1, 0.9, 0.1],
    };
    let disjoint_score = score_ice_mask_agreement(&on_pixels_0_and_3, &on_pixels_1_and_4, 0.5)
        .expect("score_ice_mask_agreement failed");
    assert_eq!(disjoint_score, 0.0);
    assert!(disjoint_score < ICE_MASK_AGREEMENT_THRESHOLD);
}
