// bench/xlang/rust/src/main.rs — serde_json's column.
//
// One line out: `<name> <ns/op> <iterations>`. See bench/xlang/README.md.
//
// serde has no declarative `min_length`, so the derive does the types and the shape and
// `validate` does the constraints by hand. That is what a fair column costs here: dropping
// them would make this row faster and stop it being a comparison.

// Deserialisation fills every field whether or not this program goes on to read it, which is
// the work being timed. `validate` reads the ones that carry a constraint; the rest are here
// because leaving them out would make serde skip them and stop this being the same job.
#![allow(dead_code)]

use serde::Deserialize;
use std::time::Instant;

#[derive(Deserialize)]
struct Settings {
    theme: String,
    size: i64,
}

#[derive(Deserialize)]
struct Profile {
    age: i64,
    city: String,
    settings: Settings,
}

#[derive(Deserialize)]
struct Payload {
    id: String,
    name: String,
    active: bool,
    score: f64,
    profile: Profile,
    tags: Vec<String>,
}

fn validate(p: &Payload) -> bool {
    !p.id.is_empty()
        && !p.name.is_empty()
        && p.score >= 0.0
        && p.profile.age >= 0
        && p.profile.age <= 150
        && p.tags.iter().all(|t| !t.is_empty())
}

fn decode(bytes: &[u8]) -> Option<Payload> {
    let payload: Payload = serde_json::from_slice(bytes).ok()?;
    if validate(&payload) {
        Some(payload)
    } else {
        None
    }
}

fn from_env(name: &str, fallback: u64) -> u64 {
    std::env::var(name).ok().and_then(|v| v.parse().ok()).unwrap_or(fallback)
}

fn main() {
    let path = std::env::args().nth(1).expect("usage: xlang-serde <fixture.json>");
    let bytes = std::fs::read(&path).expect("could not read the fixture");

    // The fixture has to decode before anything is timed, so a fast column can never be one
    // that quietly failed.
    assert!(decode(&bytes).is_some(), "the fixture did not decode");

    // Both are read from the environment so every column can be re-run at a different warmup
    // with one variable, which is the only way to tell a slow library from an under-warmed one.
    let warmup = from_env("XLANG_WARMUP", 50_000);
    let iterations = from_env("XLANG_ITERATIONS", 100_000);

    for _ in 0..warmup {
        std::hint::black_box(decode(std::hint::black_box(&bytes)));
    }

    let started = Instant::now();
    for _ in 0..iterations {
        std::hint::black_box(decode(std::hint::black_box(&bytes)));
    }
    let elapsed = started.elapsed();

    let per_op = elapsed.as_nanos() as f64 / iterations as f64;
    println!("serde_json {:.1} {}", per_op, iterations);
}
