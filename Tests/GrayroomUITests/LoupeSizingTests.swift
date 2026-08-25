import XCTest
@testable import GrayroomUI

/// How big a picture the loupe loads, and which ones it keeps.
final class LoupeSizingTests: XCTestCase {
    // MARK: - How many pixels a zoom needs

    func testRequiredLongEdgeIsTheFrameScaledByTheZoom() {
        XCTAssertEqual(LoupeSizing.requiredLongEdge(imageLongEdge: 6000, zoom: 0.5), 3000)
        XCTAssertEqual(LoupeSizing.requiredLongEdge(imageLongEdge: 6000, zoom: 1), 6000)
    }

    func testRequiredLongEdgeNeverExceedsTheFile() {
        // Above 100 % there are no more pixels to be had.
        XCTAssertEqual(LoupeSizing.requiredLongEdge(imageLongEdge: 6000, zoom: 4), 6000)
    }

    func testRequiredLongEdgeRoundsUp() {
        XCTAssertEqual(LoupeSizing.requiredLongEdge(imageLongEdge: 1001, zoom: 0.5), 501)
    }

    func testRequiredLongEdgeOfNothing() {
        XCTAssertEqual(LoupeSizing.requiredLongEdge(imageLongEdge: 0, zoom: 1), 0)
    }

    // MARK: - The first pass

    /// Fit in a window is the window's pixel count, not the file's: a hundred
    /// megapixels rendered into a 3 MP view is a second of work nobody can see.
    func testFitLoadsWhatTheViewCanShow() {
        // 11664 px frame fitted into a 2800 px view.
        let zoom = 2800.0 / 11664.0
        XCTAssertEqual(LoupeSizing.initial(imageLongEdge: 11664, zoom: zoom),
                       .sized(longEdge: 2800))
    }

    /// A frame the view can already show whole is loaded whole — fit never
    /// magnifies, so there is nothing to reduce.
    func testAFrameSmallerThanTheViewLoadsFull() {
        XCTAssertEqual(LoupeSizing.initial(imageLongEdge: 1200, zoom: 1), .full)
    }

    // MARK: - The upgrade

    func testZoomingPastTheLoadedPictureAsksForTheFile() {
        XCTAssertEqual(LoupeSizing.upgrade(loaded: .sized(longEdge: 2800),
                                           imageLongEdge: 11664,
                                           zoom: 1, fitZoom: 0.24),
                       .full)
    }

    func testStayingWithinTheLoadedPictureAsksForNothing() {
        XCTAssertNil(LoupeSizing.upgrade(loaded: .sized(longEdge: 2800),
                                         imageLongEdge: 11664,
                                         zoom: 0.24, fitZoom: 0.24))
    }

    /// A nudge of the zoom is not worth a re-decode: the softness it fixes is
    /// invisible and the decode is seconds.
    func testASmallZoomIsInsideTheSlack() {
        XCTAssertNil(LoupeSizing.upgrade(loaded: .sized(longEdge: 2800),
                                         imageLongEdge: 11664,
                                         zoom: 0.26, fitZoom: 0.24))
    }

    /// A window that grows while the frame is fitted reloads at the window's new
    /// size — not at a hundred megapixels, which is not what it is showing.
    func testAResizeWhileFittedStaysSized() {
        XCTAssertEqual(LoupeSizing.upgrade(loaded: .sized(longEdge: 1000),
                                           imageLongEdge: 11664,
                                           zoom: 0.4, fitZoom: 0.4),
                       .sized(longEdge: 4666))
    }

    func testTheFileItselfIsNeverUpgraded() {
        XCTAssertNil(LoupeSizing.upgrade(loaded: .full, imageLongEdge: 11664,
                                         zoom: 4, fitZoom: 0.24))
    }

    /// A picture already at the file's own long edge is the file, whatever the
    /// case says.
    func testASizedPictureAtTheFilesResolutionIsNotUpgraded() {
        XCTAssertNil(LoupeSizing.upgrade(loaded: .sized(longEdge: 1200),
                                         imageLongEdge: 1200,
                                         zoom: 4, fitZoom: 1))
    }

    // MARK: - Resolutions

    func testALongEdgeIsCappedByTheFile() {
        XCTAssertEqual(LoupeResolution.sized(longEdge: 4000).longEdge(native: 1200), 1200)
        XCTAssertEqual(LoupeResolution.full.longEdge(native: 1200), 1200)
    }

    // MARK: - Keys

    /// The development is part of the key, so an edit that has been saved
    /// invalidates the picture of the edit before it without anything comparing
    /// fingerprints by hand.
    func testTheDevelopmentIsPartOfTheKey() {
        let before = LoupeRenderKey(photoID: 1, fingerprint: Data([1]), resolution: .full)
        let after = LoupeRenderKey(photoID: 1, fingerprint: Data([2]), resolution: .full)
        XCTAssertNotEqual(before, after)
        XCTAssertNotEqual(before,
                          LoupeRenderKey(photoID: 1, fingerprint: nil, resolution: .full))
        XCTAssertEqual(before,
                       LoupeRenderKey(photoID: 1, fingerprint: Data([1]), resolution: .full))
    }

    // MARK: - The cache

    func testAStoredPictureComesBack() {
        var cache = LoupeImageCache<Int>(capacity: 3)
        let key = LoupeRenderKey(photoID: 1, fingerprint: nil, resolution: .sized(longEdge: 800))
        cache.store(7, for: key)
        XCTAssertEqual(cache.value(for: key), 7)
    }

    /// Two full-resolution frames is most of a gigabyte, so there is only ever
    /// one — and storing a second drops the first, whoever it belonged to.
    func testOnlyOneFullResolutionPictureIsEverHeld() {
        var cache = LoupeImageCache<Int>(capacity: 3)
        let first = LoupeRenderKey(photoID: 1, fingerprint: nil, resolution: .full)
        let second = LoupeRenderKey(photoID: 2, fingerprint: nil, resolution: .full)
        cache.store(1, for: first)
        cache.store(2, for: second)
        XCTAssertNil(cache.value(for: first))
        XCTAssertEqual(cache.value(for: second), 2)
    }

    func testSteppingAwayDropsTheOtherPhotosFullResolutionPicture() {
        var cache = LoupeImageCache<Int>(capacity: 3)
        let full = LoupeRenderKey(photoID: 1, fingerprint: nil, resolution: .full)
        let sized = LoupeRenderKey(photoID: 1, fingerprint: nil, resolution: .sized(longEdge: 800))
        cache.store(1, for: full)
        cache.store(2, for: sized)
        cache.dropFullResolution(except: 2)
        XCTAssertNil(cache.value(for: full))
        XCTAssertEqual(cache.value(for: sized), 2, "the small ones are what a walk back needs")
    }

    func testTheFullResolutionPictureOfThePhotoOnScreenStays() {
        var cache = LoupeImageCache<Int>(capacity: 3)
        let full = LoupeRenderKey(photoID: 1, fingerprint: nil, resolution: .full)
        cache.store(1, for: full)
        cache.dropFullResolution(except: 1)
        XCTAssertEqual(cache.value(for: full), 1)
    }

    /// The view-sized ones are evicted least-recently-used first, so a walk back
    /// along the row the user just came down re-renders nothing.
    func testTheOldestViewSizedPictureIsEvictedFirst() {
        var cache = LoupeImageCache<Int>(capacity: 2)
        let keys = (1...3).map {
            LoupeRenderKey(photoID: Int64($0), fingerprint: nil,
                           resolution: .sized(longEdge: 800))
        }
        for (index, key) in keys.enumerated() { cache.store(index, for: key) }
        XCTAssertNil(cache.value(for: keys[0]))
        XCTAssertEqual(cache.value(for: keys[1]), 1)
        XCTAssertEqual(cache.value(for: keys[2]), 2)
    }

    func testALookupIsAUse() {
        var cache = LoupeImageCache<Int>(capacity: 2)
        let keys = (1...3).map {
            LoupeRenderKey(photoID: Int64($0), fingerprint: nil,
                           resolution: .sized(longEdge: 800))
        }
        cache.store(1, for: keys[0])
        cache.store(2, for: keys[1])
        _ = cache.value(for: keys[0])
        cache.store(3, for: keys[2])
        XCTAssertEqual(cache.value(for: keys[0]), 1, "looked at last, so kept")
        XCTAssertNil(cache.value(for: keys[1]))
    }

    /// A full-resolution picture does not count against the view-sized ones:
    /// they are different orders of magnitude and different policies.
    func testTheFullResolutionPictureDoesNotEvictTheSmallOnes() {
        var cache = LoupeImageCache<Int>(capacity: 2)
        let sized = (1...2).map {
            LoupeRenderKey(photoID: Int64($0), fingerprint: nil,
                           resolution: .sized(longEdge: 800))
        }
        for (index, key) in sized.enumerated() { cache.store(index, for: key) }
        cache.store(9, for: LoupeRenderKey(photoID: 3, fingerprint: nil, resolution: .full))
        XCTAssertEqual(cache.value(for: sized[0]), 0)
        XCTAssertEqual(cache.value(for: sized[1]), 1)
    }

    /// Stepping to a photo the arrows walked past puts the biggest picture of it
    /// the cache holds on screen, in the same turn of the run loop.
    func testTheBiggestPictureOfAPhotoIsWhatComesBack() {
        var cache = LoupeImageCache<Int>(capacity: 4)
        let small = LoupeRenderKey(photoID: 1, fingerprint: nil, resolution: .sized(longEdge: 800))
        let large = LoupeRenderKey(photoID: 1, fingerprint: nil, resolution: .full)
        cache.store(1, for: small)
        cache.store(2, for: large)
        cache.store(3, for: LoupeRenderKey(photoID: 2, fingerprint: nil,
                                           resolution: .sized(longEdge: 800)))
        let best = cache.best(photoID: 1, fingerprint: nil, nativeLongEdge: 6000)
        XCTAssertEqual(best?.value, 2)
        XCTAssertEqual(best?.key, large)
    }

    func testAPictureOfAnotherDevelopmentIsNotThisPhotosPicture() {
        var cache = LoupeImageCache<Int>(capacity: 4)
        cache.store(1, for: LoupeRenderKey(photoID: 1, fingerprint: Data([1]),
                                           resolution: .full))
        XCTAssertNil(cache.best(photoID: 1, fingerprint: Data([2]), nativeLongEdge: 6000))
        XCTAssertNil(cache.best(photoID: 1, fingerprint: nil, nativeLongEdge: 6000))
    }
}
