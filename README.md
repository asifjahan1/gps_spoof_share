# GPS Spoof Share

A cross-platform Flutter application that allows an Android device to spoof its GPS location and broadcast those spoofed coordinates via Bluetooth Low Energy (BLE) to an iOS device.

## 📱 How It Works (100% Truth)

This app utilizes platform-specific native code (Kotlin for Android, Swift for iOS) to achieve hardware-level functionality that Flutter cannot do alone. 

### 1. Android (The Sender & Spoofer)
- **State:** Acts as a BLE Peripheral (Server).
- **Functionality:** 
  - Android uses `LocationManager.addTestProvider` to actively trick the Android OS into thinking it is at a different location (Mock Location).
  - A background Foreground Service (`SpoofService.kt`) continuously generates these mock coordinates.
  - It broadcasts these coordinates over Bluetooth (BLE) to any connected device.
- **Current Limitation:** Currently, the spoofed location is hardcoded to `(37.7749, -122.4194)`. The ability to change this location by tapping on the Google Map from the Flutter UI is **not fully implemented** (the method channel is commented out in Dart and missing in Kotlin).

### 2. iOS (The Receiver & Tracker)
- **State:** Acts as a BLE Central (Client).
- **Functionality:** 
  - iOS uses `CBCentralManager` in `AppDelegate.swift` to scan for the Android device.
  - Once connected, it listens for the GPS coordinates broadcasted by the Android device.
  - It receives these coordinates via a `MethodChannel` (`native_bridge`) and updates the Google Map in the Flutter UI to show where the Android device is pretending to be.
- **Important Technical Truth:** The iOS device **DOES NOT** spoof its own system GPS. Apple's iOS is highly restricted, and an app cannot spoof system-wide GPS without a Mac (Xcode simulated location) or a jailbreak. Therefore, the iOS app simply acts as a *viewer/tracker* for the spoofed Android location.

### 3. Flutter / UI Layer
- Built with GetX for state management and routing.
- Uses `google_maps_flutter` to display the map.
- Uses Firebase Authentication (Anonymous Login) to let users enter the app.

---

## 🛠 Setup & Installation

### Prerequisites
- Flutter SDK (`^3.12.2` or later)
- Firebase CLI (`firebase-tools`)
- FlutterFire CLI

### Running the App
1. Clone the repository and run `flutter pub get`.
2. Ensure Firebase Anonymous Authentication is enabled in your Firebase Console.
3. For iOS, ensure you have a valid Google Maps API Key in `ios/Runner/AppDelegate.swift`.
4. Run the app on a physical Android device to test spoofing (requires Developer Options -> Select Mock Location App).
5. Run the app on a physical iOS device to test BLE receiving (BLE does not work well on iOS simulators).

---

## 🐛 Recent Fixes Applied
- **Firebase Initialization:** Properly integrated `firebase_options.dart` to initialize Firebase safely across platforms.
- **iOS Google Maps Crash:** Added the missing `GMSServices.provideAPIKey()` to prevent iOS from crashing on the map screen.
- **iOS MissingPluginException:** Fixed the `MethodChannel` registration in `AppDelegate.swift` which was failing due to the presence of `SceneDelegate`.
- **Firebase Auth Internal Error:** Directed the user to enable Anonymous Auth in the Firebase console, resolving the simulator login failure.
