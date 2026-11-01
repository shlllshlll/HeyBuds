# Validation

Protocol and session tests cover simulated device responses. Application checks cover presentation, preference migration and signed update delivery. See [Actions](https://github.com/abaichuan1017/HeyBuds/actions) for build status.

Enco Air5 Pro has historical read/write observations. X4 coverage uses public EncoDeck frames and simulated sessions; HeyBuds/macOS hardware acceptance is still pending. Catalog entries do not guarantee hardware compatibility.

Sony WF-1000XM5, WH-1000XM5 and WH-CH720N coverage uses framing/parser fixtures and simulated MDR V2 sessions. Hardware acceptance for each model remains pending.

Xiaomi Buds 4 Pro was verified on macOS 27.0 (26A428) with a physical device running earbud firmware 2.5.7.4 on 2026-10-31. It connects successfully and reads left/right/case battery and charging; noise/transparency and depth, six EQ presets, dual-device, auto-answer, find, left/right gestures, spatial audio and wear/in-case state were each written and confirmed by fresh readback. The original family implementation could not connect to this model.

The default Xiaomi/Redmi family path remains the 0.5.0 implementation and is not changed; only `xiaomi:buds4pro` uses the new model-specific path. No other Xiaomi/Redmi model has hardware acceptance. Tests cover both paths; the app and a CLI probe must not hold the control channel at the same time.

Route selection and the single-service fallback are covered by unit tests, and the MMA parser has fixtures for the response layout, charging bits, invalid readings, in-ear state, gestures and config replies. The RFCOMM multi-route failover itself depends on IOBluetooth delegate callbacks, so it is exercised only by hardware runs; that layer is intentionally kept free of model-specific branches.

Build and release instructions are in [RELEASING.md](RELEASING.md). Model and feature limits are in [COMPATIBILITY.md](COMPATIBILITY.md).

The 0.5 expansion adds model-specific parser and simulated-session coverage for Samsung, Google Maestro, Bose BMAP, Nothing/CMF and Sony MDR V1/V2 profiles. Cases include invalid/truncated fields, checksum failures, fresh readback, delayed write completion, cancellation and stale-session events. BLE tests exercise segmentation without starting CoreBluetooth discovery.

All 16 newly listed models still need hardware acceptance: proprietary service discovery, model/firmware identity, actual battery/charging reports, each exposed setting and phone synchronization, plus disconnect/reconnect and sleep/wake behavior. Bose Ultra Earbuds 2 left/right component mapping remains unresolved. Local simulation is not a hardware compatibility claim.
