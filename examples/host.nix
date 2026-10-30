# An example host: the smallest config that boots an ethereum LAN node.
# Copy it, then change the marked lines for your machine. Birth it with
# nixos-anywhere (add a disko layout) or install it any other way.
{lib, ...}: {
  networking.hostName = "ethereum"; # -> ethereum.local on the LAN

  # CHANGE: your disk and boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };
  fileSystems."/boot" = {
    device = "/dev/disk/by-label/boot";
    fsType = "vfat";
  };

  hardware.enableRedistributableFirmware = true;

  services.openssh.enable = true;
  # CHANGE: your key.
  users.users.root.openssh.authorizedKeys.keys = [];

  # .local names on the LAN (phones that can resolve mDNS find ethereum.local).
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;
    publish = {
      enable = true;
      addresses = true;
    };
  };

  services.ethereumLanNode = {
    enable = true;
    # CHANGE: the wireless interface that should be the hotspot (`ip link`).
    # network.ap = { enable = true; interface = "wlan0"; };
  };

  system.stateVersion = "26.05";
}
