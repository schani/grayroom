import AppKit
import GrayroomCanvas
import GrayroomCore
import Metal

/// `GRAYROOM_SELFTEST=grain` — see `SelfTest.Mode.grain`.
extension SelfTest {
    static func runGrain(canvas: CanvasNSView, model: AppModel) {
        waitForGrainPhoto(model) { photoID in
            var failures: [String] = []
            var baseline: [Float] = []
            var amountSample: [Float] = []
            var sizeSample: [Float] = []

            func check(_ ok: Bool, _ what: String) {
                log("grain self-test: \(ok ? "PASS" : "FAIL") — \(what)")
                if !ok { failures.append(what) }
            }

            let steps: [() -> Void] = [
                {
                    revealControl(named: "grain-amount")
                    check(role(named: "grain-amount") == .slider, "Amount is a slider")
                    check(role(named: "grain-size") == .slider, "Size is a slider")
                    check(probeView("grain-roughness") == nil, "Roughness is absent")
                    check(probeView("grain-roughness-reset") == nil,
                          "Roughness reset label is absent")
                    check(isEnabled(named: "grain-amount") == true, "Amount is enabled at zero")
                    check(isEnabled(named: "grain-size") == false, "Size is disabled at zero")
                    check(model.store.edit.grain.amount == 0, "Amount starts at zero")
                    check(model.store.edit.grain.size == 25, "Size starts at 25")
                    baseline = grainSample(canvas.imageTexture)
                    check(!baseline.isEmpty, "the ungrained render can be sampled")
                    check(setGrainSlider(model, named: "grain-amount", to: 0.65,
                                         undoName: "Grain Amount"),
                          "Amount target/action updates its binding")
                },
                {
                    check(model.store.edit.grain.amount > 50, "the Amount control changed the edit")
                    check(isEnabled(named: "grain-size") == true, "Size enabled with grain")
                    amountSample = grainSample(canvas.imageTexture)
                    check(grainDifference(baseline, amountSample) > 0.001,
                          "Amount changes the rendered pixels")
                    check(setGrainSlider(model, named: "grain-size", to: 0.75,
                                         undoName: "Grain Size"),
                          "Size target/action updates its binding")
                },
                {
                    check(model.store.edit.grain.size > 60, "the Size control changed the edit")
                    sizeSample = grainSample(canvas.imageTexture)
                    check(grainDifference(amountSample, sizeSample) > 0.0001,
                          "Size changes the rendered pixels")
                    guard let window = canvas.window else { fail("grain canvas has no window") }
                    sendKey("z", modifiers: .command, window: window)
                },
                {
                    check(model.store.edit.grain.size == 25,
                          "Cmd-Z undoes one Size slider drag")
                    guard let window = canvas.window else { fail("grain canvas has no window") }
                    sendKey("z", modifiers: [.command, .shift], window: window)
                },
                {
                    check(model.store.edit.grain.size > 60,
                          "Cmd-Shift-Z restores the Size slider drag")
                    check(clickProbe(named: "grain-size-reset", clickCount: 2),
                          "double-clicking Size resets it")
                },
                {
                    check(model.store.edit.grain.size == 25, "Size reset to 25")
                    check(clickProbe(named: "grain-amount-reset", clickCount: 2),
                          "double-clicking Amount resets it")
                },
                {
                    check(model.store.edit.grain.amount == 0, "Amount reset to zero")
                    check(isEnabled(named: "grain-size") == false,
                          "resetting Amount disables Size")
                    model.store.update { $0.grain.size = 70 }
                    check(clickProbe(named: "grain-size-reset", clickCount: 2),
                          "the disabled Size label receives the test click")
                },
                {
                    check(model.store.edit.grain.size == 70,
                          "disabled Size does not reset")
                    model.store.update { $0.grain.size = 25 }
                    guard let window = canvas.window else { fail("grain canvas has no window") }
                    sendKey("z", modifiers: .command, window: window)
                },
                {
                    check(model.store.edit.grain.amount > 50,
                          "Cmd-Z restores the reset Amount")
                    check(isEnabled(named: "grain-size") == true,
                          "undoing the reset enables Size")
                    model.saveNow()
                    let stored = storedDevelopment(photoID)
                    check(stored?.grain == model.store.edit.grain,
                          "Amount and Size persist in the library")
                },
            ]

            runSteps(steps, model: model) {
                if failures.isEmpty {
                    log("grain self-test: PASS (all \(steps.count) checkpoints)")
                    exit(0)
                }
                log("grain self-test: FAILED — \(failures.count) check(s): "
                    + failures.joined(separator: "; "))
                exit(4)
            }
        }
    }

    static func waitForGrainPhoto(_ model: AppModel, then body: @escaping (Int64) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let photoID = model.currentPhotoID {
                body(photoID)
            } else if Date() < deadline {
                waitForGrainPhoto(model, then: body)
            } else {
                fail("timed out waiting for the grain test photo to enter the library")
            }
        }
    }

    static func revealControl(named name: String) {
        guard let probe = probeView(name) else { return }
        probe.scrollToVisible(probe.bounds)
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }

    /// Drives the actual SwiftUI slider's target/action. The harness brackets
    /// it because an inactive below-desktop window cannot enter AppKit's modal
    /// mouse-tracking loop, while the real slider supplies that bracket itself.
    static func setGrainSlider(_ model: AppModel, named name: String, to fraction: Double,
                               undoName: String) -> Bool {
        revealControl(named: name)
        model.beginEdit()
        let changed = setSliderFraction(named: name, to: fraction)
        model.endEdit(undoName)
        return changed
    }

    static func grainSample(_ texture: MTLTexture?) -> [Float] {
        guard let texture else { return [] }
        let width = min(texture.width, 192)
        let height = min(texture.height, 192)
        let x = max((texture.width - width) / 2, 0)
        let y = max((texture.height - height) / 2, 0)
        return (try? TextureReadback.readRegion(texture, x: x, y: y,
                                                width: width, height: height).pixels) ?? []
    }

    static func grainDifference(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var total = 0.0
        var count = 0
        for i in stride(from: 0, to: a.count, by: 4) {
            total += abs(Double(a[i] - b[i]))
                + abs(Double(a[i + 1] - b[i + 1]))
                + abs(Double(a[i + 2] - b[i + 2]))
            count += 3
        }
        return total / Double(count)
    }
}
