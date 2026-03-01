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
@available(iOS 11.0, *)
enum VisionRectangleDetector {

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

    private static func bestObservation(from observations: [VNRectangleObservation]) -> VNRectangleObservation? {
        guard !observations.isEmpty else {
            return nil
        }

        // Keep candidate ranking simple and robust: confidence + useful area, while rejecting obvious frame-border hits.
        func score(for observation: VNRectangleObservation) -> CGFloat {
            let box = observation.boundingBox
            let area = box.width * box.height

            // Ignore very tiny and nearly full-frame candidates. Both are common false positives.
            guard area >= 0.04, area <= 0.98 else {
                return -.greatestFiniteMagnitude
            }

            let areaScore = min(1.0, max(0.0, area / 0.5))

            let margin: CGFloat = 0.02
            let corners = [observation.topLeft, observation.topRight, observation.bottomRight, observation.bottomLeft]
            let touchesFrame = corners.contains { corner in
                corner.x < margin || corner.x > (1.0 - margin) || corner.y < margin || corner.y > (1.0 - margin)
            }
            let borderPenalty: CGFloat = touchesFrame ? 0.2 : 0.0

            return (CGFloat(observation.confidence) * 0.7)
                + (areaScore * 0.3)
                - borderPenalty
        }

        return observations.max(by: { score(for: $0) < score(for: $1) })
    }

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

        let transform = CGAffineTransform.identity
            .scaledBy(x: width, y: height)

        return Quadrilateral(rectangleObservation: best).applying(transform)
    }

    private static func completeImageRequest(
        for request: VNImageRequestHandler,
        width: CGFloat,
        height: CGFloat,
        completion: @escaping ((Quadrilateral?) -> Void)
    ) {
        if let strictResult = detectRectangle(
            for: request,
            width: width,
            height: height,
            configuration: strictConfiguration
        ) {
            completion(strictResult)
            return
        }

        if let relaxedResult = detectRectangle(
            for: request,
            width: width,
            height: height,
            configuration: relaxedConfiguration
        ) {
            completion(relaxedResult)
            return
        }

        completion(nil)
    }

    /// Detects rectangles from the given CVPixelBuffer/CVImageBuffer on iOS 11 and above.
    ///
    /// - Parameters:
    ///   - pixelBuffer: The pixelBuffer to detect rectangles on.
    ///   - completion: The biggest rectangle on the CVPixelBuffer
    static func rectangle(forPixelBuffer pixelBuffer: CVPixelBuffer, completion: @escaping ((Quadrilateral?) -> Void)) {
        let imageRequestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        VisionRectangleDetector.completeImageRequest(
            for: imageRequestHandler,
            width: CGFloat(CVPixelBufferGetWidth(pixelBuffer)),
            height: CGFloat(CVPixelBufferGetHeight(pixelBuffer)),
            completion: completion)
    }

    /// Detects rectangles from the given image on iOS 11 and above.
    ///
    /// - Parameters:
    ///   - image: The image to detect rectangles on.
    /// - Returns: The biggest rectangle detected on the image.
    static func rectangle(forImage image: CIImage, completion: @escaping ((Quadrilateral?) -> Void)) {
        let imageRequestHandler = VNImageRequestHandler(ciImage: image, options: [:])
        VisionRectangleDetector.completeImageRequest(
            for: imageRequestHandler, width: image.extent.width,
            height: image.extent.height, completion: completion)
    }

    static func rectangle(
        forImage image: CIImage,
        orientation: CGImagePropertyOrientation,
        completion: @escaping ((Quadrilateral?) -> Void)
    ) {
        let imageRequestHandler = VNImageRequestHandler(ciImage: image, orientation: orientation, options: [:])
        let orientedImage = image.oriented(orientation)
        VisionRectangleDetector.completeImageRequest(
            for: imageRequestHandler, width: orientedImage.extent.width,
            height: orientedImage.extent.height, completion: completion)
    }
}
