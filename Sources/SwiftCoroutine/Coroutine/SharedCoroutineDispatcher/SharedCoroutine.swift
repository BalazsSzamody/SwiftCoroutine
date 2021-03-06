//
//  SharedCoroutine.swift
//  SwiftCoroutine
//
//  Created by Alex Belozierov on 03.04.2020.
//  Copyright © 2020 Alex Belozierov. All rights reserved.
//

internal final class SharedCoroutine {
    
    internal typealias CompletionState = SharedCoroutineQueue.CompletionState
    
    private struct StackBuffer {
        let stack: UnsafeMutableRawPointer, size: Int
    }
    
    internal var dispatcher: SharedCoroutineDispatcher!
    internal var queue: SharedCoroutineQueue!
    internal var scheduler: CoroutineScheduler!
    
    private var state: Int = .running
    private var environment: UnsafeMutablePointer<CoroutineContext.SuspendData>!
    private var stackBuffer: StackBuffer!
    
    internal func reset() {
        dispatcher = nil
        queue = nil
        scheduler = nil
        state = .running
    }
    
    // MARK: - Actions
    
    internal func start() -> CompletionState {
        performAsCurrent { perform(queue.context.start) }
    }
    
    internal func resume() -> CompletionState {
        performAsCurrent(resumeContext)
    }
    
    private func resumeContext() -> CompletionState {
        perform { queue.context.resume(from: environment.pointee.env) }
    }
    
    private func perform(_ block: () -> Bool) -> CompletionState {
        if block() { return .finished }
        switch atomicExchange(&state, with: .suspended) {
        case .running: return resumeContext()
        case .restarting: return .restarting
        default: return .suspended
        }
    }
    
    private func suspend() {
        if environment == nil {
            environment = .allocate(capacity: 1)
            environment.initialize(to: .init())
        }
        queue.context.suspend(to: environment)
    }
    
    // MARK: - Stack
    
    internal func saveStack() {
        let size = environment.pointee.sp.distance(to: queue.context.stackTop)
        let stack = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        stack.copyMemory(from: environment.pointee.sp, byteCount: size)
        stackBuffer = .init(stack: stack, size: size)
    }
    
    internal func restoreStack() {
        environment.pointee.sp.copyMemory(from: stackBuffer.stack, byteCount: stackBuffer.size)
        stackBuffer.stack.deallocate()
        stackBuffer = nil
    }
    
    deinit {
        environment?.pointee.env.deallocate()
        environment?.deallocate()
    }
    
}

extension SharedCoroutine: CoroutineProtocol {
    
    internal func await<T>(_ callback: (@escaping (T) -> Void) -> Void) -> T {
        state = .suspending
        var resultState = 0
        var result: T!
        callback { value in
            if atomicExchange(&resultState, with: 1) == 1 { return }
            result = value
            if atomicExchange(&self.state, with: .running) == .suspended {
                self.queue.resume(coroutine: self)
            }
        }
        if state == .suspending { suspend() }
        return result
    }
    
    internal func await<T>(on scheduler: CoroutineScheduler, task: () throws -> T) rethrows -> T {
        let currentScheduler = self.scheduler!
        setScheduler(scheduler)
        defer { setScheduler(currentScheduler) }
        return try task()
    }
    
    private func setScheduler(_ scheduler: CoroutineScheduler) {
        self.scheduler = scheduler
        state = .restarting
        suspend()
    }
    
}

extension Int {
    
    fileprivate static let running = 0
    fileprivate static let suspending = 1
    fileprivate static let suspended = 2
    fileprivate static let restarting = 3
    
}
