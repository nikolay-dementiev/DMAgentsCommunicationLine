/// The names of the files the service keeps inside the store folder, shared by the service and its
/// clients.
public enum ServiceFiles {
  public static let socketName = "commline.sock"
  /// Held with `flock` for as long as a service uses the store, and by an uninstall that deletes it.
  public static let lockName = "commline.lock"
}
