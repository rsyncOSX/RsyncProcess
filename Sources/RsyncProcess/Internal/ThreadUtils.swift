//
//  ThreadUtils.swift
//  RsyncProcess
//
//  Created by Thomas Evensen on 12/11/2025.
//

import Foundation

public extension Thread {
    static var isMain: Bool { isMainThread }
    static var currentThread: Thread { Thread.current }
}
