// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#if os(iOS)
  import UIKit
#elseif os(macOS)
  import AppKit
#endif

#if os(iOS)
  /// Implementation of `UIScrollViewDelegate` that calls to Dart in callback methods.
  class ScrollViewDelegateImpl: NSObject, UIScrollViewDelegate {
    let api: PigeonApiProtocolUIScrollViewDelegate
    unowned let registrar: ProxyAPIRegistrar

    init(api: PigeonApiProtocolUIScrollViewDelegate, registrar: ProxyAPIRegistrar) {
      self.api = api
      self.registrar = registrar
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
      registrar.dispatchOnMainThread { onFailure in
        self.api.scrollViewDidScroll(
          pigeonInstance: self, scrollView: scrollView, x: scrollView.contentOffset.x,
          y: scrollView.contentOffset.y
        ) { result in
          if case .failure(let error) = result {
            onFailure("UIScrollViewDelegate.scrollViewDidScroll", error)
          }
        }
      }
    }
  }
#endif

#if os(macOS)
  /// Observes macOS scroll view content offset and reports changes to Dart.
  class FWFNSScrollViewDelegateImpl: NSObject, FWFNSScrollViewDelegate {
    let api: PigeonApiProtocolFWFNSScrollViewDelegate
    unowned let registrar: ProxyAPIRegistrar
    weak var scrollView: NSScrollView?
    var contentViewBoundsObserver: NSObjectProtocol?

    weak var wheelView: NSView?
    var scrollWheelMonitor: Any?
    var consumeScrollWheelEvents = false
    var mouseWheelIdleTimer: Timer?
    var mouseWheelActive = false
    var lastScrollWheelEvent: NSEvent?

    private static let MOUSE_WHEEL_IDLE_END_INTERVAL: TimeInterval = 0.12

    init(api: PigeonApiProtocolFWFNSScrollViewDelegate, registrar: ProxyAPIRegistrar) {
      self.api = api
      self.registrar = registrar
    }

    func attach(to scrollView: NSScrollView) {
      detach()
      self.scrollView = scrollView
      scrollView.contentView.postsBoundsChangedNotifications = true
      reportScrollPosition(for: scrollView)
      contentViewBoundsObserver = NotificationCenter.default.addObserver(
        forName: NSView.boundsDidChangeNotification,
        object: scrollView.contentView,
        queue: .main
      ) { [weak self] _ in
        guard let self, let scrollView = self.scrollView else { return }
        self.reportScrollPosition(for: scrollView)
      }
    }

    func detach() {
      if let observer = contentViewBoundsObserver {
        NotificationCenter.default.removeObserver(observer)
        contentViewBoundsObserver = nil
      }
      scrollView?.contentView.postsBoundsChangedNotifications = false
      scrollView = nil
    }

    func attachScrollWheel(to view: NSView, consume: Bool) {
      detachScrollWheel()
      wheelView = view
      consumeScrollWheelEvents = consume
      scrollWheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
        [weak self] event in
        guard let self, let targetView = self.wheelView else { return event }
        guard let window = targetView.window, event.window == window else { return event }
        let locationInView = targetView.convert(event.locationInWindow, from: nil)
        guard targetView.bounds.contains(locationInView) else { return event }
        self.handleScrollWheel(event: event, view: targetView)
        return self.consumeScrollWheelEvents ? nil : event
      }
    }

    func detachScrollWheel() {
      mouseWheelIdleTimer?.invalidate()
      mouseWheelIdleTimer = nil
      mouseWheelActive = false
      lastScrollWheelEvent = nil
      if let monitor = scrollWheelMonitor {
        NSEvent.removeMonitor(monitor)
        scrollWheelMonitor = nil
      }
      wheelView = nil
      consumeScrollWheelEvents = false
    }

    private func handleScrollWheel(event: NSEvent, view: NSView) {
      lastScrollWheelEvent = event
      let eventType = mapPhase(for: event, view: view)
      let isMomentum = !event.momentumPhase.isEmpty
      let hasPreciseDeltas = event.hasPreciseScrollingDeltas
      let deltaX = hasPreciseDeltas ? event.scrollingDeltaX : event.deltaX
      let deltaY = hasPreciseDeltas ? event.scrollingDeltaY : event.deltaY
      let globalPoint: NSPoint
      if let window = event.window {
        globalPoint = window.convertPoint(toScreen: event.locationInWindow)
      } else {
        globalPoint = event.locationInWindow
      }
      let localPoint = view.convert(event.locationInWindow, from: nil)
      reportScrollWheel(
        scrollView: nil,
        eventType: eventType,
        timestamp: event.timestamp,
        globalX: globalPoint.x,
        globalY: globalPoint.y,
        localX: localPoint.x,
        localY: localPoint.y,
        deltaX: deltaX,
        deltaY: deltaY,
        isMomentum: isMomentum,
        hasPreciseDeltas: hasPreciseDeltas
      )
    }

    private func activePhase(for event: NSEvent) -> NSEvent.Phase {
      if !event.momentumPhase.isEmpty {
        return event.momentumPhase
      }
      return event.phase
    }

    private func mapPhase(for event: NSEvent, view: NSView) -> FWFNSScrollWheelPhase {
      let phase = activePhase(for: event)
      if phase.isEmpty {
        return synthesizeMouseWheelPhase(for: event, view: view)
      }
      if phase.contains(.began) || phase.contains(.mayBegin) {
        return .start
      }
      if phase.contains(.changed) || phase.contains(.stationary) {
        return .update
      }
      if phase.contains(.ended) {
        return .end
      }
      if phase.contains(.cancelled) {
        return .cancel
      }
      return .update
    }

    private func synthesizeMouseWheelPhase(
      for event: NSEvent, view: NSView
    ) -> FWFNSScrollWheelPhase {
      mouseWheelIdleTimer?.invalidate()
      let eventType: FWFNSScrollWheelPhase
      if !mouseWheelActive {
        mouseWheelActive = true
        eventType = .start
      } else {
        eventType = .update
      }
      mouseWheelIdleTimer = Timer.scheduledTimer(
        withTimeInterval: Self.MOUSE_WHEEL_IDLE_END_INTERVAL, repeats: false
      ) { [weak self] _ in
        guard let self, let view = self.wheelView else { return }
        guard let lastEvent = self.lastScrollWheelEvent else { return }
        self.mouseWheelActive = false
        self.reportScrollWheel(
          scrollView: nil,
          eventType: .end,
          timestamp: lastEvent.timestamp,
          globalX: self.globalPoint(for: lastEvent).x,
          globalY: self.globalPoint(for: lastEvent).y,
          localX: view.convert(lastEvent.locationInWindow, from: nil).x,
          localY: view.convert(lastEvent.locationInWindow, from: nil).y,
          deltaX: 0,
          deltaY: 0,
          isMomentum: false,
          hasPreciseDeltas: lastEvent.hasPreciseScrollingDeltas
        )
        self.lastScrollWheelEvent = nil
      }
      return eventType
    }

    private func globalPoint(for event: NSEvent) -> NSPoint {
      if let window = event.window {
        return window.convertPoint(toScreen: event.locationInWindow)
      }
      return event.locationInWindow
    }

    private func reportScrollWheel(
      scrollView: NSScrollView?,
      eventType: FWFNSScrollWheelPhase,
      timestamp: TimeInterval,
      globalX: CGFloat,
      globalY: CGFloat,
      localX: CGFloat,
      localY: CGFloat,
      deltaX: CGFloat,
      deltaY: CGFloat,
      isMomentum: Bool,
      hasPreciseDeltas: Bool
    ) {
      registrar.dispatchOnMainThread { onFailure in
        self.api.scrollWheel(
          pigeonInstance: self,
          scrollView: scrollView,
          eventType: eventType,
          timestamp: timestamp,
          globalX: globalX,
          globalY: globalY,
          localX: localX,
          localY: localY,
          deltaX: deltaX,
          deltaY: deltaY,
          isMomentum: isMomentum,
          hasPreciseDeltas: hasPreciseDeltas
        ) { result in
          if case .failure(let error) = result {
            onFailure("FWFNSScrollViewDelegate.scrollWheel", error)
          }
        }
      }
    }

    private func reportScrollPosition(for scrollView: NSScrollView) {
      let origin = scrollView.contentView.bounds.origin
      registrar.dispatchOnMainThread { onFailure in
        self.api.scrollViewDidScroll(
          pigeonInstance: self, scrollView: scrollView, x: origin.x, y: origin.y
        ) { result in
          if case .failure(let error) = result {
            onFailure("FWFNSScrollViewDelegate.scrollViewDidScroll", error)
          }
        }
      }
    }

    #if DEBUG
      var hasScrollWheelMonitorForTesting: Bool {
        scrollWheelMonitor != nil
      }

      func reportScrollWheelForTesting(
        scrollView: NSScrollView,
        eventType: FWFNSScrollWheelPhase,
        timestamp: TimeInterval,
        globalX: CGFloat,
        globalY: CGFloat,
        localX: CGFloat,
        localY: CGFloat,
        deltaX: CGFloat,
        deltaY: CGFloat,
        isMomentum: Bool,
        hasPreciseDeltas: Bool
      ) {
        reportScrollWheel(
          scrollView: scrollView,
          eventType: eventType,
          timestamp: timestamp,
          globalX: globalX,
          globalY: globalY,
          localX: localX,
          localY: localY,
          deltaX: deltaX,
          deltaY: deltaY,
          isMomentum: isMomentum,
          hasPreciseDeltas: hasPreciseDeltas
        )
      }
    #endif
  }
#endif

/// ProxyApi implementation for `UIScrollViewDelegate` and `FWFNSScrollViewDelegate`.
///
/// This class may handle instantiating native object instances that are attached to a Dart instance
/// or handle method calls on the associated native class or an instance of that class.
class ScrollViewDelegateProxyAPIDelegate: PigeonApiDelegateUIScrollViewDelegate,
  PigeonApiDelegateFWFNSScrollViewDelegate
{
  #if os(iOS)
    func pigeonDefaultConstructor(pigeonApi: PigeonApiUIScrollViewDelegate) throws
      -> UIScrollViewDelegate
    {
      return ScrollViewDelegateImpl(
        api: pigeonApi, registrar: pigeonApi.pigeonRegistrar as! ProxyAPIRegistrar)
    }
  #endif

  #if os(macOS)
    func pigeonDefaultConstructor(pigeonApi: PigeonApiFWFNSScrollViewDelegate) throws
      -> FWFNSScrollViewDelegate
    {
      return FWFNSScrollViewDelegateImpl(
        api: pigeonApi, registrar: pigeonApi.pigeonRegistrar as! ProxyAPIRegistrar)
    }
  #endif
}
