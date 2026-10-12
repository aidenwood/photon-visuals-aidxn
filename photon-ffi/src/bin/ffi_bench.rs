//! Measures the FFI boundary cost — R0 #5.
//!
//! The question the spike exists to answer: is one packed crossing per frame
//! cheap enough to ignore, and how much worse would per-layer calls have been?

use photon_ffi::*;
use std::time::Instant;

fn layer(id: u32) -> PhotonLayer {
    PhotonLayer { id, blend: 0, opacity: 1.0, tex_slot: -1, position: 0.0, active: 1 }
}

fn main() {
    const ITERS: u32 = 2_000_000;
    println!("FFI boundary cost — photon-ffi\n");
    println!("struct sizes: PhotonLayer={}B  PhotonFrame={}B  abi=v{}",
             photon_layer_stride(), photon_frame_stride(), photon_abi_version());

    for layers in [1usize, 4, 8, 12, 32] {
        let h = photon_create(120.0);
        let stack: Vec<PhotonLayer> = (0..layers as u32).map(layer).collect();
        unsafe { photon_set_layers(h, stack.as_ptr(), layers as u32) };

        // warm
        for _ in 0..10_000 { let _ = unsafe { photon_tick(h, 8_333_333) }; }

        let t0 = Instant::now();
        let mut sink = 0f64;
        for _ in 0..ITERS {
            let f = unsafe { photon_tick(h, 8_333_333) };
            // Read the packed array the way the shell would, so the cost of
            // actually consuming it is included rather than optimised away.
            let s = unsafe { std::slice::from_raw_parts(f.layers, f.layer_count as usize) };
            sink += f64::from(s[s.len() - 1].opacity) + f.beat;
        }
        let ns = t0.elapsed().as_nanos() as f64 / f64::from(ITERS);
        // At 120fps a frame is 8.33ms; express the cost as a share of that.
        let pct = ns / 8_333_333.0 * 100.0;
        println!("  {layers:2} layers: {ns:7.1} ns/frame  ({pct:.6}% of a 120fps frame)  [{sink:.0}]");
        unsafe { photon_destroy(h) };
    }

    // What the naive design would have cost: one crossing per layer per frame.
    let h = photon_create(120.0);
    let stack: Vec<PhotonLayer> = (0..12u32).map(layer).collect();
    unsafe { photon_set_layers(h, stack.as_ptr(), 12) };
    for _ in 0..10_000 { unsafe { photon_set_bpm(h, 120.0) }; }
    let t0 = Instant::now();
    for _ in 0..ITERS { unsafe { photon_set_bpm(h, 120.0) }; }
    let per_call = t0.elapsed().as_nanos() as f64 / f64::from(ITERS);
    println!("\n  bare trivial call: {per_call:.1} ns");
    println!("  12 per-layer calls would cost ~{:.0} ns/frame vs one packed crossing",
             per_call * 12.0);
    unsafe { photon_destroy(h) };
}
