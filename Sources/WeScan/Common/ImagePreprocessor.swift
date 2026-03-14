//
//  ImagePreprocessor.swift
//  WeScan
//
//  Created by SR-Media on 14/3/2026.
//  Copyright © 2026 SR-Media. All rights reserved.
//

import CoreImage
import Foundation

/// Preprocessing pipeline that enhances images before rectangle detection
/// to improve edge detection accuracy in challenging conditions.
enum ImagePreprocessor {

    /// Preprocessing strategy ordered by aggressiveness.
    enum Strategy: CaseIterable {
        /// Original image – no modifications.
        case original
        /// Contrast-enhanced with sharpening.
        case contrastEnhanced
        /// Grayscale with strong edge enhancement.
        case grayscaleEdgeEnhanced
        /// High-contrast adaptive (for low-contrast documents on similar backgrounds).
        case highContrastAdaptive
    }

    // MARK: - Public API

    /// Returns the preprocessed image for the given strategy.
    static func preprocess(_ image: CIImage, strategy: Strategy) -> CIImage {
        switch strategy {
        case .original:
            return image
        case .contrastEnhanced:
            return applyContrastEnhancement(to: image)
        case .grayscaleEdgeEnhanced:
            return applyGrayscaleEdgeEnhancement(to: image)
        case .highContrastAdaptive:
            return applyHighContrastAdaptive(to: image)
        }
    }

    /// Downscales the image so its longest edge is at most `maxDimension` pixels.
    /// Smaller images produce less noise and faster, more robust rectangle detection.
    static func downscale(_ image: CIImage, maxDimension: CGFloat = 720) -> CIImage {
        let extent = image.extent
        let longestEdge = max(extent.width, extent.height)
        guard longestEdge > maxDimension else { return image }

        let scale = maxDimension / longestEdge
        let transform = CGAffineTransform(scaleX: scale, y: scale)
        return image.transformed(by: transform)
    }

    /// Downscales a CVPixelBuffer to a CIImage with at most `maxDimension` on its longest edge.
    static func downscale(pixelBuffer: CVPixelBuffer, maxDimension: CGFloat = 720) -> CIImage {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        return downscale(image, maxDimension: maxDimension)
    }

    // MARK: - Strategies

    /// Increases contrast and applies unsharp mask to sharpen edges.
    private static func applyContrastEnhancement(to image: CIImage) -> CIImage {
        // Step 1: Boost contrast
        var result = image
        if let colorControls = CIFilter(name: "CIColorControls") {
            colorControls.setValue(result, forKey: kCIInputImageKey)
            colorControls.setValue(1.3, forKey: kCIInputContrastKey)       // moderate boost
            colorControls.setValue(0.05, forKey: kCIInputBrightnessKey)    // slight brightness lift
            colorControls.setValue(0.0, forKey: kCIInputSaturationKey)     // desaturate for cleaner edges
            if let output = colorControls.outputImage {
                result = output
            }
        }

        // Step 2: Sharpen luminance
        if let sharpen = CIFilter(name: "CISharpenLuminance") {
            sharpen.setValue(result, forKey: kCIInputImageKey)
            sharpen.setValue(0.8, forKey: kCIInputSharpnessKey)
            if let output = sharpen.outputImage {
                result = output
            }
        }

        return result
    }

    /// Converts to grayscale, then applies strong unsharp mask for edge enhancement.
    private static func applyGrayscaleEdgeEnhancement(to image: CIImage) -> CIImage {
        var result = image

        // Step 1: Full desaturation → grayscale
        if let colorControls = CIFilter(name: "CIColorControls") {
            colorControls.setValue(result, forKey: kCIInputImageKey)
            colorControls.setValue(0.0, forKey: kCIInputSaturationKey)
            colorControls.setValue(1.5, forKey: kCIInputContrastKey)
            if let output = colorControls.outputImage {
                result = output
            }
        }

        // Step 2: Strong unsharp mask to enhance edges
        if let unsharpMask = CIFilter(name: "CIUnsharpMask") {
            unsharpMask.setValue(result, forKey: kCIInputImageKey)
            unsharpMask.setValue(2.5, forKey: kCIInputRadiusKey)
            unsharpMask.setValue(1.5, forKey: kCIInputIntensityKey)
            if let output = unsharpMask.outputImage {
                result = output
            }
        }

        return result
    }

    /// Aggressive pipeline for very low-contrast scenes (white paper on light table).
    /// Uses exposure adjustment + high contrast + edge work.
    private static func applyHighContrastAdaptive(to image: CIImage) -> CIImage {
        var result = image

        // Step 1: Exposure adjustment to normalize brightness
        if let exposure = CIFilter(name: "CIExposureAdjust") {
            exposure.setValue(result, forKey: kCIInputImageKey)
            exposure.setValue(-0.3, forKey: kCIInputEVKey)     // slightly darken to reveal edges
            if let output = exposure.outputImage {
                result = output
            }
        }

        // Step 2: High contrast + desaturation
        if let colorControls = CIFilter(name: "CIColorControls") {
            colorControls.setValue(result, forKey: kCIInputImageKey)
            colorControls.setValue(2.0, forKey: kCIInputContrastKey)
            colorControls.setValue(0.0, forKey: kCIInputSaturationKey)
            if let output = colorControls.outputImage {
                result = output
            }
        }

        // Step 3: Edges filter to highlight document boundaries
        if let edges = CIFilter(name: "CIEdges") {
            edges.setValue(result, forKey: kCIInputImageKey)
            edges.setValue(5.0, forKey: kCIInputIntensityKey)
            if let edgeOutput = edges.outputImage {
                // Blend edge-detected image with the contrast-enhanced version
                // to keep structure while boosting edges
                if let blend = CIFilter(name: "CIAdditionCompositing") {
                    blend.setValue(result, forKey: kCIInputImageKey)
                    blend.setValue(edgeOutput, forKey: kCIInputBackgroundImageKey)
                    if let output = blend.outputImage {
                        result = output
                    }
                }
            }
        }

        return result
    }
}
