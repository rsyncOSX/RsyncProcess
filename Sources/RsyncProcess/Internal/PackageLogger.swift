//
//  PackageLogger.swift
//  RsyncProcess
//
//  Created by Thomas Evensen on 12/11/2025.
//

import OSLog

internal extension Logger {
    private static let subsystem = Bundle.main.bundleIdentifier!
    static let process = Logger(subsystem: subsystem, category: "process")
}
