ui_print "********************************"
ui_print " Note8 USB3 Dock PHY Recovery"
ui_print " v3.1"
ui_print "********************************"

ui_print "- Waits 60 seconds before checking USB state"
ui_print "- Health check: RTL8153 USB speed == 5000"
ui_print "- Recovery: DWC3 id 1 -> wait -> id 0"
ui_print "- Log:"
ui_print "  /data/adb/modules/note8_usb3_phy_recovery/usb3fix.log"

set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/worker.sh" 0 0 0755
