hl.on("hyprland.start", function()
  -- All long-lived Omarchy processes belong to this session-specific target.
  -- UWSM already owns propagation of the graphical session environment.
  hl.exec_cmd("systemctl --user start omarchy-arch-session.target")

  -- Only initialize Omarchy-Arch-owned state automatically.
  -- Upstream global first-run integration is ported independently.
  hl.exec_cmd("omarchy-arch-provision-first-run")

  -- User post-boot hooks live entirely under the isolated Omarchy config root.
  hl.exec_cmd("sleep 2 && omarchy-hook post-boot")
end)
