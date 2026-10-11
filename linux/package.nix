{ lib, rustPlatform, pkg-config, gtk4, wrapGAppsHook4 }:
rustPlatform.buildRustPackage {
  pname = "keystats-linux";
  version = "0.1.0";
  src = lib.cleanSourceWith {
    name = "keystats-linux-source";
    src = ./.;
    filter = path: type: builtins.baseNameOf path != "target" && lib.cleanSourceFilter path type;
  };
  cargoLock.lockFile = ./Cargo.lock;
  nativeBuildInputs = [ pkg-config wrapGAppsHook4 ];
  buildInputs = [ gtk4 ];
  doCheck = true;
  postInstall = ''
    install -Dm644 data/net.gapul.KeyStats.desktop $out/share/applications/net.gapul.KeyStats.desktop
    install -Dm644 data/net.gapul.KeyStats.svg $out/share/icons/hicolor/scalable/apps/net.gapul.KeyStats.svg
  '';
  meta = {
    description = "Native GTK4 keyboard analytics for Linux/Hyprland";
    homepage = "https://github.com/gapul/keystats";
    platforms = lib.platforms.linux;
    mainProgram = "keystats";
  };
}
