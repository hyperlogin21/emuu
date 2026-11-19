import Foundation
import EmuuBase

/// The "farm" instance profile and golden-image preparation. Defaults are the result of the measurements in
/// docs/BENCHMARKS.md ("Farm"); `emuu golden create --ram/--cores/--gpu` overrides them.
public enum FarmProfile {
    /// Guest RAM of farm devices (MB), enforced below the engine's 2048 MB floor with `-qemu -m`.
    public static let guestRAMMB = 2048
    public static let cores = 2
    public static let gpu = GPUMode.host
    public static let display = DisplaySpec.lightweightPhone

    /// Shell commands run on the golden before sealing (as the shell user; all verified on android-36.1):
    /// animations off (standard for UI tests), no adb-install verification prompt, screen stays on.
    public static let prepCommands = [
        "settings put global window_animation_scale 0",
        "settings put global transition_animation_scale 0",
        "settings put global animator_duration_scale 0",
        "settings put global verifier_verify_adb_installs 0",
        "settings put global package_verifier_user_consent -1",
        "svc power stayon true",
    ]

    /// Preinstalled packages `--lean` disables with `pm disable-user --user 0` (mirrors
    /// scripts/farm-lean-packages.txt). Play Store, Play services, launcher, System UI, Settings, WebView, Chrome,
    /// Contacts and the keyboard stay enabled.
    public static let leanPackages = [
        "com.google.android.apps.messaging", "com.google.android.dialer", "com.google.android.googlequicksearchbox",
        "com.google.android.apps.safetyhub", "com.google.android.apps.wellbeing", "com.google.android.marvin.talkback",
        "com.google.android.apps.accessibility.voiceaccess", "com.google.android.accessibility.switchaccess",
        "com.google.android.apps.youtube.music", "com.google.android.youtube", "com.google.android.apps.photos",
        "com.google.android.apps.maps", "com.google.android.gm", "com.google.android.calendar", "com.google.android.apps.docs",
        "com.google.android.projection.gearhead", "com.google.android.glasses.core", "com.google.android.apps.restore",
        "com.google.android.deskclock", "com.google.android.tts", "com.google.android.settings.intelligence",
        "com.google.android.as", "com.google.android.feedback", "com.google.android.apps.customization.pixel",
        "com.android.camera2", "com.android.egg",
    ]

    /// Seal only once the guest has been up this long: first-boot work (Play services updates, dex2oat) has
    /// mostly settled, so clones do not all redo it after every resume.
    public static let minimumUptimeBeforeSeal: TimeInterval = 120

    /// Measured per-device cost of the default profile (docs/BENCHMARKS.md, "Farm").
    public static var measuredCost: DeviceCost {
        DeviceCost.estimate(guestRAMMB: guestRAMMB, cores: cores)
    }
}
