//
//  RectangleDetector.swift
//  WeScan
//
//  Created by Boris Emorine on 2/13/18.
//  Copyright © 2018 WeTransfer. All rights reserved.
//

import AVFoundation
import CoreImage
import Foundation

/// Class used to detect rectangles from an image.
/// Enhanced with preprocessing fallback for better detection on low-contrast images.
enum CIRectangleDetector {

    static let rectangleDetector = CIDetector(ofType: CIDetectorTypeRectangle,
                                              context: CIContext(options: nil),
                                              options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])

    /// Detects rectangles from the given image, trying preprocessing fallbacks if original fails.
    static func rectangle(forImage image: CIImage, completion: @escaping ((Quadrilateral?) -> Void)) {
        // Try original first
        if let result = rectangle(forImage: image) {
            completion(result)
            return
        }

        // Fallback: contrast-enhanced
        let enhanced = ImagePreprocessor.preprocess(image, strategy: .contrastEnhanced)
        if let result = rectangle(forImage: enhanced) {
            completion(result)
            return
        }

        // Fallback: grayscale + edge enhancement
        let edgeEnhanced = ImagePreprocessor.preprocess(image, strategy: .grayscaleEdgeEnhanced)
        if let result = rectangle(forImage: edgeEnhanced) {
            completion(result)
            return
        }

        completion(nil)
    }

    static func rectangle(forImage image: CIImage) -> Quadrilateral? {
        guard let rectangleFeatures = rectangleDetector?.features(in: image) as? [CIRectangleFeature] else {
            return nil
        }

        let quads = rectangleFeatures.map { rectangle in
            return Quadrilateral(rectangleFeature: rectangle)
        }

        return quads.biggest()
    }
}
