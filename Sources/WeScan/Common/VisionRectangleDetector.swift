//
//  VisionRectangleDetector.swift
//  WeScan
//
//  Created by Julian Schiavo on 28/7/2018.
//  Copyright © 2018 WeTransfer. All rights reserved.
//

import CoreImage
import Foundation
import Vision

/// Enum encapsulating static functions to detect rectangles from an image.
/// Uses a multi-strategy cascade with image preprocessing for robust detection
/// even in challenging lighting / low-contrast conditions.
@available(iOS 11.0, *)
enum VisionRectangleDetector {

    // MARK: - Detection Configuration

    private struct DetectionConfiguration {
        let minimumConfidence: VNConfidence
        let minimumAspectRatio: VNAspectRatio
        let minimumSize: Float
        let quadratureTolerance: VNDegrees
        let maximumObservations: Int
    }

    private static let strictConfiguration = DetectionConfiguration(
        minimumConfidence: 0.3,
        minimumAspectRatio: 0.2,
        minimumSize: 0.12,
        quadratureTolerance: 30.0,
        maximumObservations: 18
    )

    private static let relaxedConfiguration = DetectionConfiguration(
        minimumConfidence: 0.2,
        minimumAspectRatio: 0.15,
        minimumSize: 0.1,
        quadratureTolerance: 45.0,
        maximumObservations: 22
    )

    private static let ultraRelaxedConfiguration = DetectionConfiguration(
        minimumConfidence: 0.1,
        minimumAspectRatio: 0.1,
        minimumSize: 0.08,
        quadratureTolerance: 55.0,
        maximumObservations: 25
    )

    // MARK: - Observation Scoring

    private static func bestObservation(from observations: [VNRectangleObservation]) -> VNRectangleObservation? {
        guard !observations.isEmpty else {
            return nil
        }

        func score(for observation: VNRectangleObservation) -> CGFloat {
            let box = observation.boundingBox
            let area = box.width * box.height

            guard area >= 0.04, area <= 0.98 else {
                return -.greatestFiniteMagnitude
            }

            let areaScore = min(1.0, max(0.0, area / 0.5))

            // Rectangularity: how close the angles are to 90°
            let rectangularity = rectangularityScore(for: observation)

            let margin: CGFloat = 0.02
            let corners = [observation.topLeft, observation.topRight, observation.bottomRight, observation.bottomLeft]
            let touchesFrame = corners.contains { corner in
                corner.x < margin || corner.x > (1.0 - margin) || corner.y < margin || corner.y > (1.0 - margin)
            }
            let borderPenalty: CGFloat = touchesFrame ? 0.2 : 0.0

            // Prefer rectangles that are well-centered (not at the very edge)
            let centerX = box.midX
            let centerY = box.midY
            let centerDistance = sqrt(pow(centerX - 0.5, 2) + pow(centerY - 0.5, 2))
            let centerBonus: CGFloat = max(0.0, 0.1 * (1.0 - centerDistance * 2.0))

            return (CGFloat(observation.confidence) * 0.5)
                + (areaScore * 0.2)
                + (rectangularity * 0.2)
                + centerBonus
                - borderPenalty
        }

        return observations.max(by: { score(for: $0) < score(for: $1) })
    }

    /// Measures how close the quadrilateral's angles are to 90°. Returns 0...1.
    private static func rectangularityScore(for observation: VNRectangleObservation) -> CGFloat {
        let corners = [observation.topLeft, observation.topRight, observation.bottomRight, observation.bottomLeft]
        var totalDeviation: CGFloat = 0.0

        for i in 0..<4 {
            let prev = corners[(i + 3) % 4]
            let curr = corners[i]
            let next = corners[(i + 1) % 4]

            let v1 = CGPoint(x: prev.x - curr.x, y: prev.y - curr.y)
            let v2 = CGPoint(x: next.x - curr.x, y: next.y - curr.y)

            let dot = v1.x * v2.x + v1.y * v2.y
            let mag1 = sqrt(v1.x * v1.x + v1.y * v1.y)
            let mag2 = sqrt(v2.x * v2.x + v2.y * v2.y)

            guard mag1 > 0, mag2 > 0 else { continue }

            let cosAngle = dot / (mag1 * mag2)
            let clampedCos = max(-1.0, min(1.0, cosAngle))
            let angle = acos(clampedCos)
            let deviation = abs(angle - .pi / 2)
            totalDeviation += deviation
        }

        // Max total deviation = 4 * π/2 = 2π (all angles completely wrong)
        let normalizedDeviation = totalDeviation / (2.0 * .pi)
        return max(0.0, 1.0 - normalizedDeviation * 4.0)
    }

    // MARK: - Edge Strength Validation

    /// Validates whether a detected rectangle actually has strong edges in the source image.
    /// Samples pixels along each edge and measures gradient strength.
    private static func validateEdgeStrength(
        for quad: Quadrilateral,
        in image: CIImage,
        imageWidth: CGFloat,
        imageHeight: CGFloat,
        threshold: CGFloat = 0.15
    ) -> Bool {
        let context = CIContext(options: [.useSoftwareRenderer: false])

        // Create edge-detected version of the image
        guard let edgeFilter = CIFilter(name: "CIEdges") else { return true }
        edgeFilter.setValue(image, forKey: kCIInputImageKey)
        edgeFilter.setValue(3.0, forKey: kCIInputIntensityKey)
        guard let edgeImage = edgeFilter.outputImage else { return true }

        let edges: [(CGPoint, CGPoint)] = [
            (quad.topLeft, quad.topRight),
            (quad.topRight, quad.bottomRight),
            (quad.bottomRight, quad.bottomLeft),
            (quad.bottomLeft, quad.topLeft)
        ]

        let samplesPerEdge = 5
        var strongEdges = 0

        for (start, end) in edges {
            var edgeSamples = 0
            var strongSamples = 0

            for s in 0..<samplesPerEdge {
                let t = CGFloat(s + 1) / CGFloat(samplesPerEdge + 1)
                let x = start.x + (end.x - start.x) * t
                let y = start.y + (end.y - start.y) * t

                // Clamp to image bounds
                let sampleX = max(0, min(imageWidth - 1, x))
                let sampleY = max(0, min(imageHeight - 1, y))

                let sampleRect = CGRect(x: sampleX, y: sampleY, width: 1, height: 1)

                var pixel = [UInt8](repeating: 0, count: 4)
                context.render(edgeImage, toBitmap: &pixel, rowBytes: 4,
                              bounds: sampleRect, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())

                let brightness = (CGFloat(pixel[0]) + CGFloat(pixel[1]) + CGFloat(pixel[2])) / (3.0 * 255.0)
                edgeSamples += 1
                if brightness > threshold {
                    strongSamples += 1
                }
            }

            // At least 40% of samples along this edge should be strong
            if edgeSamples > 0 && CGFloat(strongSamples) / CGFloat(edgeSamples) >= 0.4 {
                strongEdges += 1
            }
        }

        // At least 3 of 4 edges should have strong gradients
        return strongEdges >= 3
    }

    // MARK: - Single-Image Detection

    private static func detectRectangle(
        for ciImage: CIImage,
        width: CGFloat,
        height: CGFloat,
        configuration: DetectionConfiguration
    ) -> Quadrilateral? {
        let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])
        let rectangleDetectionRequest = VNDetectRectanglesRequest()
        rectangleDetectionRequest.minimumConfidence = configuration.minimumConfidence
        rectangleDetectionRequest.maximumObservations = configuration.maximumObservations
        rectangleDetectionRequest.minimumAspectRatio = configuration.minimumAspectRatio
        rectangleDetectionRequest.minimumSize = configuration.minimumSize
        rectangleDetectionRequest.quadratureTolerance = configuration.quadratureTolerance

        do {
            try handler.perform([rectangleDetectionRequest])
        } catch {
            return nil
        }

        guard let results = rectangleDetectionRequest.results as? [VNRectangleObservation],
              let best = bestObservation(from: results) else {
            return nil
        }

        let transform = CGAffineTransform.identity.scaledBy(x: width, y: height)
        return Quadrilateral(rectangleObservation: best).applying(transform)
    }

    /// Legacy overload for existing VNImageRequestHandler-based callers.
    private static func detectRectangle(
        for request: VNImageRequestHandler,
        width: CGFloat,
        height: CGFloat,
        configuration: DetectionConfiguration
    ) -> Quadrilateral? {
        let rectangleDetectionRequest = VNDetectRectanglesRequest()
        rectangleDetectionRequest.minimumConfidence = configuration.minimumConfidence
        rectangleDetectionRequest.maximumObservations = configuration.maximumObservations
        rectangleDetectionRequest.minimumAspectRatio = configuration.minimumAspectRatio
        rectangleDetectionRequest.minimumSize = configuration.minimumSize
        rectangleDetectionRequest.quadratureTolerance = configuration.quadratureTolerance

        do {
            try request.perform([rectangleDetectionRequest])
        } catch {
            return nil
        }

        guard let results = rectangleDetectionRequest.results as? [VNRectangleObservation],
              let best = bestObservation(from: results) else {
            return nil
        }

        let transform = CGAffineTransform.identity.scaledBy(x: width, y: height)
        return Quadrilateral(rectangleObservation: best).applying(transform)
    }

    // MARK: - Multi-Strategy Cascade

    /// Runs the full multi-strategy detection cascade:
    /// 1. Original image, strict config
    /// 2. Original image, relaxed config
    /// 3. Contrast-enhanced, strict config
    /// 4. Contrast-enhanced, relaxed config
    /// 5. Grayscale + edge-enhanced, strict config
    /// 6. Grayscale + edge-enhanced, relaxed config
    /// 7. High-contrast adaptive, ultra-relaxed config
    ///
    /// The first successful detection wins. For live preview (pixelBuffer),
    /// only strategies 1-4 are used to keep latency low.
    private static func multiStrategyDetect(
        image: CIImage,
        originalWidth: CGFloat,
        originalHeight: CGFloat,
        fullCascade: Bool = true
    ) -> Quadrilateral? {
        // Downscale for faster and more robust detection
        let downscaled = ImagePreprocessor.downscale(image, maxDimension: 720)
        let dsExtent = downscaled.extent
        let scaleX = originalWidth / dsExtent.width
        let scaleY = originalHeight / dsExtent.height

        // Helper: detect on a (possibly preprocessed) image, then scale result back to original coordinates
        func detect(on img: CIImage, config: DetectionConfiguration) -> Quadrilateral? {
            guard let quad = detectRectangle(for: img, width: dsExtent.width, height: dsExtent.height, configuration: config) else {
                return nil
            }
            let upscale = CGAffineTransform(scaleX: scaleX, y: scaleY)
            return quad.applying(upscale)
        }

        // Strategy 1 & 2: Original, strict → relaxed
        if let result = detect(on: downscaled, config: strictConfiguration) { return result }
        if let result = detect(on: downscaled, config: relaxedConfiguration) { return result }

        // Strategy 3 & 4: Contrast-enhanced
        let contrastEnhanced = ImagePreprocessor.preprocess(downscaled, strategy: .contrastEnhanced)
        if let result = detect(on: contrastEnhanced, config: strictConfiguration) { return result }
        if let result = detect(on: contrastEnhanced, config: relaxedConfiguration) { return result }

        guard fullCascade else { return nil }

        // Strategy 5 & 6: Grayscale + edge-enhanced
        let edgeEnhanced = ImagePreprocessor.preprocess(downscaled, strategy: .grayscaleEdgeEnhanced)
        if let result = detect(on: edgeEnhanced, config: strictConfiguration) { return result }
        if let result = detect(on: edgeEnhanced, config: relaxedConfiguration) { return result }

        // Strategy 7: High-contrast adaptive, ultra-relaxed (last resort)
        let adaptive = ImagePreprocessor.preprocess(downscaled, strategy: .highContrastAdaptive)
        if let result = detect(on: adaptive, config: ultraRelaxedConfiguration) { return result }

        return nil
    }

    // MARK: - Public API

    /// Detects rectangles from the given CVPixelBuffer using the multi-strategy cascade.
    /// Uses a reduced cascade (4 strategies) for live preview performance.
    static func rectangle(forPixelBuffer pixelBuffer: CVPixelBuffer, completion: @escaping ((Quadrilateral?) -> Void)) {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))

        // Live preview: use reduced cascade for performance
        let result = multiStrategyDetect(image: image, originalWidth: width, originalHeight: height, fullCascade: false)
        completion(result)
    }

    /// Detects rectangles from the given image using the full multi-strategy cascade.
    static func rectangle(forImage image: CIImage, completion: @escaping ((Quadrilateral?) -> Void)) {
        let result = multiStrategyDetect(image: image, originalWidth: image.extent.width, originalHeight: image.extent.height, fullCascade: true)
        completion(result)
    }

    /// Detects rectangles from the given image with orientation using the full multi-strategy cascade.
    static func rectangle(
        forImage image: CIImage,
        orientation: CGImagePropertyOrientation,
        completion: @escaping ((Quadrilateral?) -> Void)
    ) {
        let orientedImage = image.oriented(orientation)
        let result = multiStrategyDetect(
            image: orientedImage,
            originalWidth: orientedImage.extent.width,
            originalHeight: orientedImage.extent.height,
            fullCascade: true
        )
        completion(result)
    }
}
