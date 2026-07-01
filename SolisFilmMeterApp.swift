//
//  SolisFilmMeterApp.swift
//  Solis film meter
//

// MARK: - 役割: アプリのエントリーポイントと全体初期設定
// MARK: - 目次
// 1. AppDelegateの縦向き固定
// 2. AppSessionStore/PurchaseAccessStore生成
// 3. RevenueCat初期化
// 4. UIKitナビゲーション外観設定
// 5. MeterContainerView起動と購入状態更新

import SwiftUI
import RevenueCat

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return .portrait
    }
}

@main
struct SolisFilmMeterApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var sessionStore = AppSessionStore()
    @StateObject private var accessStore = PurchaseAccessStore()
    
    init() {
        #if DEBUG
        Purchases.logLevel = .debug
        #endif
        Purchases.configure(withAPIKey: "test_mWmhPMqwLvqTbcchKPhRLPIUZrM")
        
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(Color.meterBackground)
        appearance.titleTextAttributes = [.foregroundColor: UIColor(Color.meterSecondary)]
        
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        
        UISegmentedControl.appearance().selectedSegmentTintColor = UIColor(Color.meterAccent)
        UISegmentedControl.appearance().setTitleTextAttributes([.foregroundColor: UIColor.black], for: .selected)
        UISegmentedControl.appearance().setTitleTextAttributes([.foregroundColor: UIColor(Color.meterSecondary)], for: .normal)
    }
    
    var body: some Scene {
        WindowGroup {
            MeterContainerView(sessionStore: sessionStore, accessStore: accessStore)
                .preferredColorScheme(accessStore.policy.isFullVersion ? .dark : .light)
                .task {
                    accessStore.refreshPurchasedAccess()
                }
        }
    }
}
