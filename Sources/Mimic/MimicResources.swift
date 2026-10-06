//
//  MimicResources.swift
//  Mimic
//
//  Created by Василий Маслов on 04.10.2026.
import Foundation

/// Packaged apps resolve resources inside Contents; development retains SwiftPM's module bundle.
enum MimicResources {
    static let bundle: Bundle = {
        let resources = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Mimic_Mimic.bundle")
        if let bundle = Bundle(url: resources) { return bundle }
        #if DEBUG
        return Bundle.module
        #else
        return Bundle.main
        #endif
    }()
}
