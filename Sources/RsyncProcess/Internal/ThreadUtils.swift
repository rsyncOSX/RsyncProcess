//
//  ThreadUtils.swift
//  RsyncProcess
//
//  Created by Thomas Evensen on 12/11/2025.
//

import Foundation

enum ThreadUtils {
    static var isMain: Bool {
        Thread.isMainThread
    }
}
