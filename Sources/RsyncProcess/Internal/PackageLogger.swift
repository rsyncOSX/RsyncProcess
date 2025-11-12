//
//  PackageLogger.swift
//  RsyncProcess
//
//  Created by Thomas Evensen on 12/11/2025.
//

import OSLog

enum PackageLogger {
    static let process = Logger(subsystem: "com.rsyncprocess", category: "process")
}
