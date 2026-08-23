# Note 8 USB3 Dock PHY Recovery

A Magisk module that works around a USB 3.x initialization issue on the
Samsung Galaxy Note 8 (Exynos 8895) when a USB-C dock is already connected
during boot.

The affected device may boot with its USB Ethernet adapter connected through
USB 2.0 High-Speed (`480 Mbit/s`) instead of USB 3.x SuperSpeed
(`5000 Mbit/s`).

On the tested setup this limited Gigabit Ethernet throughput to roughly
190 Mbit/s.

After recovering the USB3 PHY, the same RTL8153 adapter reaches more than
900 Mbit/s with `iperf3`.

Example result:

```text
[ ID] Interval           Transfer     Bitrate         Retr
[  5]   0.00-10.00 sec  1.08 GBytes   924 Mbits/sec    0  sender
[  5]   0.00-10.02 sec  1.08 GBytes   922 Mbits/sec       receiver
```

## Tested environment

Tested on:

- Samsung Galaxy Note 8
- Exynos 8895
- Linux 4.4.302 based Android kernel
- Android 16 custom ROM
- Magisk
- VIA-based USB-C dock
- Realtek RTL8153 Gigabit Ethernet
- USB2 hub: `2109:2822`
- USB3 hub: `2109:0822`
- USB-PD identity: `2109:0102`
- Ethernet: `0bda:8153`

This module is currently intentionally specific to this dock configuration.

---

## Background

There are two related problems in the Samsung Exynos 8895 USB-C / DisplayPort
Alt Mode implementation.

### 1. Samsung CCIC incorrectly forces USB High-Speed mode

The Samsung S2MM005 CCIC alternate-mode driver contains a comment in:

```text
drivers/ccic/ccic_alternate.c
```

It correctly explains that DisplayPort pin assignments using four DP lanes
should disable USB SuperSpeed, while two-lane configurations should keep
SuperSpeed available.

Conceptually:

```text
DP 4-lane:
Pin A / C / E
dp_hs_connect = 1
USB limited to High-Speed

DP 2-lane:
Pin B / D / F
dp_hs_connect = 0
USB SuperSpeed remains available
```

However, immediately after that comment the Samsung driver hardcodes:

```c
usbpd_data->dp_hs_connect = 1;
```

regardless of the actual DisplayPort pin assignment.

This is particularly problematic with docks that negotiate DisplayPort
Pin Assignment D, because Pin D uses two DisplayPort lanes while leaving
the SuperSpeed USB lanes available.

The driver itself later prefers Pin D when the partner requests
multi-function operation.

The value eventually reaches the xHCI Type-C notifier.

In:

```text
drivers/usb/host/xhci-plat.c
```

Samsung's `ccic_xhci_handle_notification()` does approximately:

```c
if (usb_status.hs_connect) {
    PORTSC &= ~PORT_POWER;
} else {
    PORTSC |= PORT_POWER;
}
```

Therefore an incorrect `dp_hs_connect = 1` causes the xHCI SuperSpeed port
to be powered down even though the selected DP configuration is capable of
simultaneous USB3 operation.

### Important

This Magisk module does **not** fix the above CCIC source bug.

The kernel used with this module must already report:

```text
ccic_xhci_handle_notification:
is connect 1, hs connect 0
```

for a two-lane DP configuration such as Pin Assignment D.

On the test device this CCIC issue was fixed separately in the kernel.

---

## 2. USB3 PHY sometimes remains in a degraded state after boot

After fixing `dp_hs_connect`, another issue remained.

When the dock was physically connected while the phone rebooted, the system
sometimes came up like this:

```text
Bus 001 Device ...: ID 2109:2822
Bus 001 Device ...: ID 0bda:8153
```

The RTL8153 was connected through the USB2 topology.

Its sysfs speed was:

```text
480
```

The USB3 root hub itself existed, but the SuperSpeed companion hub:

```text
2109:0822
```

was missing.

At the same time:

```text
DWC3 id    = 0
DWC3 state = a_host
CCIC       = 2109:0102
```

and the kernel had already received:

```text
ccic_xhci_handle_notification:
is connect 1, hs connect 0
```

So this was not simply the earlier `dp_hs_connect` problem.

Physically disconnecting and reconnecting the dock immediately restored
SuperSpeed.

The exact single offending source line for this second issue has not been
identified. What is confirmed is that fully cycling the DWC3 host state
causes the Exynos USB DRD/PIPE3 PHY and xHCI path to be reinitialized, after
which SuperSpeed enumerates correctly.

---

## USB3 PHY recovery

The same recovery can be performed without physically reconnecting the dock.

The Samsung/Exynos DWC3 kernel exposes:

```text
/sys/devices/platform/10c00000.usb/10c00000.dwc3/id
```

Writing:

```sh
echo 1 > id
```

moves the OTG state machine from host mode toward `b_idle`.

Writing:

```sh
echo 0 > id
```

moves it back into host mode.

During the transition the kernel performs the DWC3 host teardown and startup
paths.

The relevant host shutdown path includes:

```text
platform_device_del(xhci)
dwc3_core_exit()
```

The startup path includes:

```text
dwc3_phy_setup()
dwc3_core_init()
platform_device_add(xhci)
```

On Exynos this causes the USB DRD PHY to be powered off and back on.

Observed kernel log:

```text
dwc3 10c00000.dwc3: Turn off host
xhci_plat_remove

phy_exynos_usbdrd 10e00000.phy:
Request to power_off usbdrd_phy phy

...

dwc3 10c00000.dwc3: Turn on host

phy_exynos_usbdrd 10e00000.phy:
Request to power_on usbdrd_phy phy

phy_exynos_usbdrd 10e00000.phy:
exynos_usbdrd_pipe3_init: phy port[0]

xhci_plat_probe

usb 2-1:
new SuperSpeed USB device

usb 2-1:
idVendor=2109, idProduct=0822

usb 2-1.1.2:
new SuperSpeed USB device

usb 2-1.1.2:
idVendor=0bda, idProduct=8153
```

After this sequence:

```text
/sys/bus/usb/devices/.../speed
```

reports:

```text
5000
```

for the RTL8153.

---

## What this module does

The module runs during Magisk's `late_start service` stage.

It deliberately waits 60 seconds before making a decision because the
SuperSpeed hub may temporarily appear during early boot and later disappear.

The module then checks the actual negotiated USB speed of the RTL8153.

Healthy:

```text
RTL8153 speed = 5000
```

No action is taken.

Degraded:

```text
RTL8153 speed = 480
```

If all safety conditions match, the module performs:

```text
DWC3 host OFF
        ↓
USB DRD PHY power off
        ↓
wait 10 seconds
        ↓
DWC3 host ON
        ↓
USB DRD PHY power on
        ↓
PIPE3 initialization
        ↓
xHCI probe
        ↓
USB3 SuperSpeed enumeration
```

---

## Safety conditions

The recovery is only attempted when all of the following are true:

```text
VIA USB2 hub 2109:2822 is present
RTL8153 is not running at 5000 Mbit/s
DWC3 state is a_host
DWC3 id is 0
CCIC USB-PD identity is 2109:0102
```

This prevents the module from changing the USB role when the expected dock
is not connected.

The recovery is attempted only once per boot.

---

## Installation

Download or build the Magisk module ZIP.

Install it using:

```text
Magisk
→ Modules
→ Install from storage
```

Then reboot with the USB-C dock connected.

---

## Logs

The module writes its log to:

```text
/data/adb/modules/note8_usb3_phy_recovery/usb3fix.log
```

Successful recovery looks like:

```text
v3.1 start; waiting 60s for boot/USB to settle
degraded: RTL8153 speed=480 state=a_host id=0 ccic_ids=2109:0102
recovery: host OFF (id=1)
host-off state=b_idle; keeping PHY off for 10s
recovery: host ON (id=0)
SUCCESS: RTL8153 speed=5000 after 3s
```

If USB3 initialized normally:

```text
healthy: RTL8153 speed=5000; no action
```

---

## Manual recovery

The recovery can also be tested manually.

```sh
su

D=/sys/devices/platform/10c00000.usb/10c00000.dwc3

echo 1 > "$D/id"
sleep 10
echo 0 > "$D/id"

sleep 10
```

Verify the RTL8153 speed:

```sh
for d in /sys/bus/usb/devices/*; do
    [ "$(cat "$d/idVendor" 2>/dev/null)" = "0bda" ] || continue
    [ "$(cat "$d/idProduct" 2>/dev/null)" = "8153" ] || continue

    echo "device: $d"
    echo "speed: $(cat "$d/speed")"
done
```

Expected:

```text
speed: 5000
```

---

## Kernel source reference

The behavior was investigated against the Samsung Exynos 8895 Android
kernel tree:

```text
linhphikma/android16_kernel_samsung_universal8895
```

Reference commit:

```text
947128f03c3fefc005a483e64da35e8794be27bc
```

Relevant files:

```text
drivers/ccic/ccic_alternate.c
drivers/usb/host/xhci-plat.c
drivers/usb/dwc3/otg.c
drivers/usb/manager/usb_typec_manager_notifier.c
```

The actual kernel running on the test device was a Linux 4.4.302 based
Galaxy Note 8 kernel.

The public tree above was used to understand the corresponding Samsung USB,
CCIC, DWC3 and xHCI implementation.

---

## Limitations

The module currently identifies the tested dock using fixed VID/PID values.

A different USB-C dock may use different:

```text
USB2 hub VID/PID
USB3 hub VID/PID
USB-PD identity
Ethernet controller
```

The underlying Exynos USB3 PHY issue may still occur with another dock, but
this module will intentionally not reset the controller unless the known
hardware identifiers match.

A future version may support multiple dock profiles or a generic detection
mode.

---

## Disclaimer

This module directly changes the software OTG ID state exposed by the
Samsung/Exynos DWC3 driver.

It has only been tested on the hardware and kernel configuration described
above.

Use it only if you understand that temporarily restarting DWC3 host mode
disconnects all USB devices attached to that controller.

---

## License

MIT
