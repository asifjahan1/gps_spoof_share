import 'package:get/get.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../../routes/app_pages.dart';

class AuthController extends GetxController {
  final FirebaseAuth _auth = FirebaseAuth.instance;

  final isLoading = false.obs;

  void signInAnonymous() async {
    isLoading.value = true;
    try {
      await _auth.signInAnonymously();
      Get.offAllNamed(Routes.HOME);
    } catch (e) {
      Get.snackbar(
        "Error",
        "Authentication failed. (Are Firebase options configured?)\n$e",
      );
      // Fallback for development if Firebase is not yet configured:
      Get.offAllNamed(Routes.HOME);
    } finally {
      isLoading.value = false;
    }
  }
}
