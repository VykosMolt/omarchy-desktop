local paths = require("default.hypr.paths")

local nvidia = paths.omarchy_path .. "/bin/omarchy-hw-nvidia"
local hybrid = paths.omarchy_path .. "/bin/omarchy-hw-hybrid-gpu"
local nvidia_gsp = paths.omarchy_path .. "/bin/omarchy-hw-nvidia-gsp"
local nvidia_without_gsp = paths.omarchy_path .. "/bin/omarchy-hw-nvidia-without-gsp"

-- These detectors read cached sysfs IDs rather than shelling out to lspci.
-- lspci reads PCI config space, which resumes a runtime-suspended GPU, and on a
-- hybrid laptop that wake alone outlasts Hyprland's 1.5s config reload budget.
-- Only when NVIDIA is the GPU, not merely present. On a hybrid laptop the
-- display is driven by the integrated GPU and the discrete card sits in runtime
-- suspend; pointing GLX and VA-API at NVIDIA there wakes it for every GL
-- application that starts. Measured on an Arrow Lake + RTX 5070 Ti laptop, that
-- put 175ms on the front of every terminal launch -- 385ms against 210ms -- and
-- kept the card powered for as long as something was using it.
if o.shell_succeeds(o.shell_quote(nvidia)) and not o.shell_succeeds(o.shell_quote(hybrid)) then
  if o.shell_succeeds(o.shell_quote(nvidia_gsp)) then
    hl.env("NVD_BACKEND", "direct")
    hl.env("LIBVA_DRIVER_NAME", "nvidia")
    hl.env("__GLX_VENDOR_LIBRARY_NAME", "nvidia")
  elseif o.shell_succeeds(o.shell_quote(nvidia_without_gsp)) then
    hl.env("NVD_BACKEND", "egl")
    hl.env("__GLX_VENDOR_LIBRARY_NAME", "nvidia")
  end
end
