//
//  RectangleFeaturesFunnel.swift
//  WeScan
//
//  Created by Boris Emorine on 2/9/18.
//  Copyright © 2018 WeTransfer. All rights reserved.
//
//  swiftlint:disable line_length

import AVFoundation
import Foundation

enum AddResult {
    case showAndAutoScan
    case showOnly
}

/// `RectangleFeaturesFunnel` is used to improve the confidence of the detected rectangles.
/// Feed rectangles to a `RectangleFeaturesFunnel` instance, and it will call the completion block with a rectangle whose confidence is high enough to be displayed.
///
/// Enhanced with:
/// - Exponential Moving Average (EMA) smoothing for stable corner positions
/// - Adaptive matching threshold based on image size
/// - Weighted recency scoring (newer detections count more)
final class RectangleFeaturesFunnel {

    /// `RectangleMatch` is a class used to assign matching scores to rectangles.
    private final class RectangleMatch: NSObject {
        /// The rectangle feature object associated to this `RectangleMatch` instance.
        let rectangleFeature: Quadrilateral

        /// Timestamp when this rectangle was added.
        let timestamp: TimeInterval

        /// The score to indicate how strongly the rectangle of this instance matches other recently added rectangles.
        /// A higher score indicates that many recently added rectangles are very close to the rectangle of this instance.
        var matchingScore = 0

        init(rectangleFeature: Quadrilateral) {
            self.rectangleFeature = rectangleFeature
            self.timestamp = CACurrentMediaTime()
        }

        override var description: String {
            return "Matching score: \(matchingScore) - Rectangle: \(rectangleFeature)"
        }

        /// Whether the rectangle of this instance is within the distance of the given rectangle.
        func matches(_ rectangle: Quadrilateral, withThreshold threshold: CGFloat) -> Bool {
            return rectangleFeature.isWithin(threshold, ofRectangleFeature: rectangle)
        }
    }

    /// The queue of last added rectangles.
    private var rectangles = [RectangleMatch]()

    /// The maximum number of rectangles to compare newly added rectangles with.
    let maxNumberOfRectangles = 12

    /// The minimum number of rectangles needed to start making comparisons.
    let minNumberOfRectangles = 3

    /// Base matching threshold in pixels. Adapted dynamically based on image size.
    private let baseMatchingThreshold: CGFloat = 50.0

    /// The current adaptive matching threshold (set per-frame based on image dimensions).
    private var matchingThreshold: CGFloat = 50.0

    /// The minimum number of matching rectangles to be confident enough to display.
    let minNumberOfMatches = 2

    /// The number of similar rectangles that need to be found to auto scan.
    let autoScanThreshold = 35

    /// The number of times the rectangle has passed the threshold to be auto-scanned.
    var currentAutoScanPassCount = 0

    /// For auto-scan: how close corners must be (in pixels) to count as "stable".
    var autoScanMatchingThreshold: CGFloat = 10.0

    /// EMA smoothing factor (0 = no smoothing, 1 = no memory). 0.3 provides smooth but responsive tracking.
    private let emaSmoothingFactor: CGFloat = 0.3

    /// The EMA-smoothed rectangle corners, updated with each new best rectangle.
    private var smoothedRectangle: Quadrilateral?

    /// Maximum age (in seconds) for rectangles in the queue. Older ones are purged.
    private let maxRectangleAge: TimeInterval = 1.5

    // MARK: - Public API

    /// Add a rectangle to the funnel with adaptive threshold.
    func add(_ rectangleFeature: Quadrilateral, currentlyDisplayedRectangle currentRectangle: Quadrilateral?, completion: (AddResult, Quadrilateral) -> Void) {
        add(rectangleFeature, currentlyDisplayedRectangle: currentRectangle, imageSize: nil, completion: completion)
    }

    /// Add a rectangle to the funnel. If `imageSize` is provided, the matching threshold adapts
    /// to the image dimensions for better accuracy at different resolutions.
    func add(_ rectangleFeature: Quadrilateral, currentlyDisplayedRectangle currentRectangle: Quadrilateral?, imageSize: CGSize?, completion: (AddResult, Quadrilateral) -> Void) {
        // Adapt threshold to image size
        if let imageSize {
            let diag = sqrt(imageSize.width * imageSize.width + imageSize.height * imageSize.height)
            // ~50px for a 1920-diagonal image, scales proportionally
            matchingThreshold = max(20, baseMatchingThreshold * (diag / 1920.0))
            autoScanMatchingThreshold = max(5, 10.0 * (diag / 1920.0))
        }

        let rectangleMatch = RectangleMatch(rectangleFeature: rectangleFeature)
        rectangles.append(rectangleMatch)

        // Purge old rectangles by age
        purgeOldRectangles()

        guard rectangles.count >= minNumberOfRectangles else {
            return
        }

        if rectangles.count > maxNumberOfRectangles {
            rectangles.removeFirst()
        }

        updateRectangleMatches()

        guard let bestRectangle = bestRectangle(withCurrentlyDisplayedRectangle: currentRectangle) else {
            return
        }

        // Apply EMA smoothing for stable output
        let smoothed = applyEMASmoothing(to: bestRectangle.rectangleFeature)

        if let previousRectangle = currentRectangle,
            smoothed.isWithin(autoScanMatchingThreshold, ofRectangleFeature: previousRectangle) {
            currentAutoScanPassCount += 1
            if currentAutoScanPassCount > autoScanThreshold {
                currentAutoScanPassCount = 0
                completion(AddResult.showAndAutoScan, smoothed)
            }
        } else {
            completion(AddResult.showOnly, smoothed)
        }
    }

    // MARK: - EMA Smoothing

    /// Applies Exponential Moving Average to the rectangle corners for smooth, jitter-free display.
    private func applyEMASmoothing(to newRect: Quadrilateral) -> Quadrilateral {
        guard let prev = smoothedRectangle else {
            smoothedRectangle = newRect
            return newRect
        }

        let alpha = emaSmoothingFactor
        let oneMinusAlpha = 1.0 - alpha

        let smoothed = Quadrilateral(
            topLeft: CGPoint(
                x: alpha * newRect.topLeft.x + oneMinusAlpha * prev.topLeft.x,
                y: alpha * newRect.topLeft.y + oneMinusAlpha * prev.topLeft.y
            ),
            topRight: CGPoint(
                x: alpha * newRect.topRight.x + oneMinusAlpha * prev.topRight.x,
                y: alpha * newRect.topRight.y + oneMinusAlpha * prev.topRight.y
            ),
            bottomRight: CGPoint(
                x: alpha * newRect.bottomRight.x + oneMinusAlpha * prev.bottomRight.x,
                y: alpha * newRect.bottomRight.y + oneMinusAlpha * prev.bottomRight.y
            ),
            bottomLeft: CGPoint(
                x: alpha * newRect.bottomLeft.x + oneMinusAlpha * prev.bottomLeft.x,
                y: alpha * newRect.bottomLeft.y + oneMinusAlpha * prev.bottomLeft.y
            )
        )

        smoothedRectangle = smoothed
        return smoothed
    }

    /// Resets the EMA state (call when detection is lost and restarted).
    func resetSmoothing() {
        smoothedRectangle = nil
    }

    // MARK: - Rectangle Selection

    /// Determines which rectangle is best to display.
    /// Uses matching score with recency weighting – newer rectangles with high scores are preferred.
    private func bestRectangle(withCurrentlyDisplayedRectangle currentRectangle: Quadrilateral?) -> RectangleMatch? {
        var bestMatch: RectangleMatch?
        guard !rectangles.isEmpty else { return nil }

        let now = CACurrentMediaTime()

        rectangles.reversed().forEach { rectangle in
            guard let best = bestMatch else {
                bestMatch = rectangle
                return
            }

            // Recency bonus: rectangles detected within the last 0.5s get a boost
            let recencyBonus = max(0, 1.0 - (now - rectangle.timestamp) / maxRectangleAge)
            let bestRecencyBonus = max(0, 1.0 - (now - best.timestamp) / maxRectangleAge)

            let rectScore = CGFloat(rectangle.matchingScore) + CGFloat(recencyBonus) * 0.5
            let bestScore = CGFloat(best.matchingScore) + CGFloat(bestRecencyBonus) * 0.5

            if rectScore > bestScore {
                bestMatch = rectangle
                return
            } else if abs(rectScore - bestScore) < 0.1 {
                guard let currentRectangle else {
                    return
                }
                bestMatch = breakTie(between: best, rect2: rectangle, currentRectangle: currentRectangle)
            }
        }

        guard let bestMatch, bestMatch.matchingScore >= minNumberOfMatches else {
            return nil
        }

        return bestMatch
    }

    /// Breaks a tie between two rectangles by preferring the one closer to the currently displayed rectangle.
    private func breakTie(between rect1: RectangleMatch, rect2: RectangleMatch, currentRectangle: Quadrilateral) -> RectangleMatch {
        if rect1.rectangleFeature.isWithin(matchingThreshold, ofRectangleFeature: currentRectangle) {
            return rect1
        } else if rect2.rectangleFeature.isWithin(matchingThreshold, ofRectangleFeature: currentRectangle) {
            return rect2
        }

        return rect1
    }

    // MARK: - Matching

    /// Gives each rectangle a score depending on how many others it matches.
    private func updateRectangleMatches() {
        resetMatchingScores()
        guard !rectangles.isEmpty else { return }
        for (i, currentRect) in rectangles.enumerated() {
            for (j, rect) in rectangles.enumerated() {
                if j > i && currentRect.matches(rect.rectangleFeature, withThreshold: matchingThreshold) {
                    currentRect.matchingScore += 1
                    rect.matchingScore += 1
                }
            }
        }
    }

    /// Resets all matching scores to 0.
    private func resetMatchingScores() {
        guard !rectangles.isEmpty else { return }
        for rectangle in rectangles {
            rectangle.matchingScore = 0
        }
    }

    /// Removes rectangles older than `maxRectangleAge`.
    private func purgeOldRectangles() {
        let now = CACurrentMediaTime()
        rectangles.removeAll { now - $0.timestamp > maxRectangleAge }
    }

}
