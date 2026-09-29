// swift-tools-version: 5.9

// سبّورة — تطبيق ملاحظات للآيباد
// افتح المجلد Sabboura.swiftpm في تطبيق Swift Playgrounds على الآيباد ثم اضغط تشغيل.
// يمكن أيضاً فتحه مباشرة في Xcode على الماك.

import PackageDescription
import AppleProductTypes

let package = Package(
    name: "Sabboura",
    platforms: [
        .iOS("17.0")
    ],
    products: [
        .iOSApplication(
            name: "Sabboura",
            targets: ["AppModule"],
            bundleIdentifier: "com.sabboura.notes",
            displayVersion: "1.0",
            bundleVersion: "1",
            appIcon: .asset("AppIcon"),
            accentColor: .asset("AccentColor"),
            supportedDeviceFamilies: [
                .pad,
                .phone
            ],
            supportedInterfaceOrientations: [
                .portrait,
                .landscapeRight,
                .landscapeLeft,
                .portraitUpsideDown(.when(deviceFamilies: [.pad]))
            ],
            appCategory: .education
        )
    ],
    targets: [
        .executableTarget(
            name: "AppModule",
            path: "."
        )
    ]
)
