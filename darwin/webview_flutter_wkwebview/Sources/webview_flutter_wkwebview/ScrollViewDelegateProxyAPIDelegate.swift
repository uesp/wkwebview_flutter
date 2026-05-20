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
