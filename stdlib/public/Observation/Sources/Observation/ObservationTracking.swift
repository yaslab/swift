//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
//
//===----------------------------------------------------------------------===//

@available(SwiftStdlib 5.9, *)
public struct ObservationTracking {
  struct Entry: @unchecked Sendable {
    let emit: @Sendable (Set<AnyKeyPath>, @Sendable @escaping () -> Void) -> Int
    let remove: @Sendable (Int) -> Void
    var rawKeyPaths = Set<AnyKeyPath>()
    
    init<Subject: Observable>(_ context: ObservationRegistrar<Subject>.Context) {
      emit = { rawKeyPaths, observer in
        context.nextTracking(for: TrackedProperties(raw: rawKeyPaths), observer)
      }
      remove = { generation in
        context.cancel(generation)
      }
    }
    
    func addObserver(_ changed: @Sendable @escaping () -> Void) -> Int {
      return emit(rawKeyPaths, changed)
    }
    
    func removeObserver(_ token: Int) {
      remove(token)
    }
    
    mutating func insert(_ keyPath: AnyKeyPath) {
      rawKeyPaths.insert(keyPath)
    }
  }
  
  struct AccessList {
    var entries = [ObjectIdentifier : Entry]()
    
    mutating func addAccess<Subject: Observable>(
      keyPath: PartialKeyPath<Subject>, 
      context: ObservationRegistrar<Subject>.Context
    ) {
      entries[context.id, default: Entry(context)].insert(keyPath)
    }
  }
  
  public static func withTracking<T>(
    _ apply: () -> T, 
    onChange: @autoclosure () -> @Sendable () -> Void
  ) -> T {
    var accessList: AccessList?
    let result = withUnsafeMutablePointer(to: &accessList) { ptr in
      _ThreadLocal.value = UnsafeMutableRawPointer(ptr)
      defer { _ThreadLocal.value = nil }
      return apply()
    }
    if let list = accessList {
      let state = _ManagedCriticalState([ObjectIdentifier: Int]())
      let onChange = onChange()
      let values = list.entries.mapValues { $0.addObserver {
        onChange()
        let values = state.withCriticalRegion { $0 }
        for (id, token) in values {
          list.entries[id]?.removeObserver(token)
        }
      }}
      state.withCriticalRegion { $0 = values }
    }
    return result
  }

  public static func _installTracking(
    _ storage: UnsafeRawPointer, 
    onChange: @escaping @Sendable () -> Void
  ) {
    let list = unsafeBitCast(storage, to: AccessList.self)
    let state = _ManagedCriticalState([ObjectIdentifier: Int]())
    let values = list.entries.mapValues { $0.addObserver {
      onChange()
      let values = state.withCriticalRegion { $0 }
      for (id, token) in values {
        list.entries[id]?.removeObserver(token)
      }
    }}
    state.withCriticalRegion { $0 = values }
  }
}
