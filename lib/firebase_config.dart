import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

/// Public app identifiers in the Firebase project shared with the Inventory
/// app (Spoke). These are not secrets: access is protected by Firebase
/// Authentication and the Firestore rules in the Inventory repository.
class OffersFirebaseConfig {
  static const projectId = 'inventory-molenstraat';
  static const senderId = '39036121879';

  static bool get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  static bool get _ios =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  static String get apiKey => kIsWeb
      ? 'AIzaSyDMeZr_ehiP_q4RJYrLz80DO8JHMhIG_es'
      : _android
      ? 'AIzaSyDOE6hBSQf9lskBUdVy814bNfA6v1JinNg'
      : 'AIzaSyDHUly3YslgkQNReIVlRXqmcOIQq3SFYsY';

  static String get appId => kIsWeb
      ? '1:39036121879:web:8eeefd58ead2cf11cdfd52'
      : _android
      ? '1:39036121879:android:c9ffc194599df46ccdfd52'
      : _ios
      ? '1:39036121879:ios:3c4fc31896679327cdfd52'
      : '';

  static bool get configured => appId.isNotEmpty;

  static FirebaseOptions get options => FirebaseOptions(
    apiKey: apiKey,
    appId: appId,
    messagingSenderId: senderId,
    projectId: projectId,
    authDomain: kIsWeb ? '$projectId.firebaseapp.com' : null,
    storageBucket: '$projectId.firebasestorage.app',
    iosBundleId: 'com.petehon.molenstraatOffers',
  );
}
