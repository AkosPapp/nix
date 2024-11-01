{pkgs, ...}: {
  systemd.services.kanata = {
    enable = true;
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      ExecStart = "${pkgs.kanata}/bin/kanata -c ${./config.kbd}";
      User = "root";
    };
  };
}
