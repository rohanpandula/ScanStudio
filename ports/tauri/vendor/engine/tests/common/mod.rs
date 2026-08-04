//! Shared test helpers. Not `tests/common.rs` — a subdirectory file is not
//! auto-discovered by Cargo as its own test binary, so each `tests/*.rs`
//! file that wants this must declare `#[path = "common/mod.rs"] mod
//! common;` itself (every top-level file under `tests/` is its own crate
//! root).

use serde_json::Value;

/// Recursively asserts two JSON values are equal as *parsed* values, not
/// byte strings: object key sets match (order-independent), arrays match
/// length and element order (recursing element-wise), strings/bools/null
/// match exactly, and numbers are within `tol` of each other rather than
/// requiring exact equality. This is D-9a's "re-serializing with
/// parsed-value equality (float tolerance 1e-9)" requirement.
pub fn assert_json_close(a: &Value, b: &Value, tol: f64) {
    assert_json_close_at("$", a, b, tol);
}

fn assert_json_close_at(path: &str, a: &Value, b: &Value, tol: f64) {
    match (a, b) {
        (Value::Object(map_a), Value::Object(map_b)) => {
            let keys_a: std::collections::BTreeSet<&String> = map_a.keys().collect();
            let keys_b: std::collections::BTreeSet<&String> = map_b.keys().collect();
            assert_eq!(keys_a, keys_b, "object key sets differ at {path}");
            for key in keys_a {
                let child_path = format!("{path}.{key}");
                assert_json_close_at(&child_path, &map_a[key], &map_b[key], tol);
            }
        }
        (Value::Array(arr_a), Value::Array(arr_b)) => {
            assert_eq!(arr_a.len(), arr_b.len(), "array length differs at {path}");
            for (i, (item_a, item_b)) in arr_a.iter().zip(arr_b.iter()).enumerate() {
                let child_path = format!("{path}[{i}]");
                assert_json_close_at(&child_path, item_a, item_b, tol);
            }
        }
        (Value::Number(num_a), Value::Number(num_b)) => {
            let fa = num_a.as_f64().expect("number a as f64");
            let fb = num_b.as_f64().expect("number b as f64");
            assert!(
                (fa - fb).abs() <= tol,
                "numbers differ beyond tolerance {tol} at {path}: {fa} vs {fb}"
            );
        }
        (Value::String(s_a), Value::String(s_b)) => {
            assert_eq!(s_a, s_b, "strings differ at {path}");
        }
        (Value::Bool(b_a), Value::Bool(b_b)) => {
            assert_eq!(b_a, b_b, "bools differ at {path}");
        }
        (Value::Null, Value::Null) => {}
        (other_a, other_b) => {
            panic!("value kind mismatch at {path}: {other_a:?} vs {other_b:?}");
        }
    }
}
